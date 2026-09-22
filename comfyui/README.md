# ComfyUI (containerised, single-GPU)

Containerised ComfyUI sharing one RTX 5090 with the vLLM inference stack in
`~/vllm-stack`. Reachable at **http://$TS_IP:8188** (Tailscale only).

Built 2026-09-12. ComfyUI pinned to **v0.35.1**, torch **2.14.0+cu130**.

---

## Layout

| Path | Mounted | Survives recreate |
|------|---------|-------------------|
| `models/` | bind | yes |
| `input/` · `output/` | bind | yes |
| `user/` | bind | yes — includes `comfyui.db` |
| `custom_nodes/` | bind | yes (but see below) |
| `cache/` → `/home/ubuntu/.cache` | bind | yes |
| `/opt/venv` | in image | **no** |

`user/comfyui.db` is a SQLite database under alembic migrations — it is the
real persistence layer, not just a settings file. Back up `user/` and
`models/` and you have everything irreplaceable.

Workflow *templates* ship as the pip package `comfyui-workflow-templates`,
baked into the image. That is deliberate: template data is read-only and
should be versioned with the image. Workflows **you** save go to `user/`.

---

## Why the three non-obvious pieces exist

### cu130, not cu128

ComfyUI 0.35.1 gates its fused-kernel backend (`comfy_kitchen`) behind
cu130+. Built on cu128 it loads as `available: True, disabled: True` and
falls back to generic PyTorch attention. The card still works, the UI shows
nothing wrong, and you silently lose the Blackwell numerics — `nvfp4`,
`mxfp8`, `scaled_mm_nvfp4`, fused RoPE/AdaLN, SVDQuant. That is the exact
hardware advantage a 5090 has over Ampere, so running cu128 gives up the
reason for the card.

Confirm after any rebuild:

```bash
docker logs comfyui 2>&1 | grep -o "backend cuda: {.available.: True, .disabled.: [A-Za-z]*"
# want: 'disabled': False
```

### `/opt/constraints.txt`

Custom nodes routinely list a bare `torch` in `requirements.txt`. Installing
one unconstrained replaces the cu130 build with a generic PyPI wheel and
takes the fused kernels with it. That surfaces weeks later as "generation
got slower" with nothing visibly broken — near-impossible to trace back.

The image bakes the shipped versions into `/opt/constraints.txt` and the
entrypoint installs against it. A node may bring its own dependencies; it
may not move torch.

### A C compiler in a `-runtime-` image

PyTorch 2.14 dispatches ordinary operations through Triton — even a plain
`bmm` inside `precompute_freqs_cis` lands in
`torch/_native/ops/bmm_outer_product/triton_impl.py`. Triton JIT-compiles a
CUDA utils extension on first use, so the image needs `build-essential` and
`python3-dev` despite being built on a runtime base.

The failure mode is the trap: the container starts cleanly, reports the GPU,
serves the UI, and only raises `Failed to find C compiler` when you queue
your first prompt. Nothing in the startup log hints at it.

`TRITON_CACHE_DIR` and `TORCHINDUCTOR_CACHE_DIR` are redirected into the
persisted `cache/` mount. Their defaults (`~/.triton/cache` and
`/tmp/torchinductor_*`) sit outside it, so without this every recreate
discards compiled kernels and pays recompilation again.

### `entrypoint.sh`

`custom_nodes/` is a bind mount and survives recreation. The venv it installs
into does not. Without intervention a recreate leaves nodes **present but
un-importable**, which presents as node corruption rather than a missing
dependency and sends you debugging the wrong layer.

The entrypoint re-resolves every `custom_nodes/*/requirements.txt` on boot,
against the constraints file, with the pip cache persisted in `cache/` so it
is fast after the first pass. Node dependency state is therefore derived, not
stored — the venv can be thrown away at any time.

---

## Sharing the GPU

The card is 32 GB and both vLLM and ComfyUI want it. `gpu`, from this
repo, arbitrates:

```bash
gpu status              # what holds the card right now
gpu comfy               # stop vLLM, hand the card to ComfyUI
gpu vllm                # hand it back to inference
gpu both --split 0.5    # run both, vLLM capped
gpu --help
```

Stopping vLLM is safe. LiteLLM stays up — `depends_on` governs startup
ordering only, not runtime — and its fallback chain routes `local-workhorse`
and `local-fast` to `claude-fast` while the local model is away. With
`allowed_fails: 3` / `cooldown_time: 60` it stops retrying quickly, so no
latency piles up.

**Trap:** do not run a bare `docker compose up -d` in `~/vllm-stack` while in
comfy mode. litellm's `depends_on` will pull vLLM back up and take the VRAM
with no obvious explanation. Use `docker compose up -d --no-deps litellm`.

`gpu both` deliberately refuses until `~/vllm-stack/docker-compose.yml` reads
`--gpu-memory-utilization ${VLLM_GPU_UTIL:-0.88}`. Without that hook it would
recreate vLLM at 0.88 and leave ComfyUI nothing, failing in a way that looks
like a ComfyUI bug.

---

## Getting models

ComfyUI's model browser hands downloads to your browser, which puts the
weights on whichever machine is running it — then you copy multi-GB files
across the network to the box that needed them. Don't. The GPU host has the fast
link and the disk. Fetch server-side:

```bash
comfy pull hf:madebyollin/taesd:taesd_decoder.safetensors --to vae_approx
comfy pull https://civitai.com/api/download/models/12345 --to loras
comfy models          # what is installed, with sizes
comfy dirs            # valid target subdirs
comfy --help
```

HuggingFace pulls run `hf` **inside the container** — it is already there
(huggingface_hub 1.31.0) — writing straight into the bind-mounted models
tree. Non-HF URLs use host `curl` with resume (`-C -`).

**Paste URLs straight from ComfyUI's missing-models dialog.** Any
`huggingface.co/<repo>/(resolve|blob)/<rev>/<path>` URL is recognised and
routed through `hf` automatically, which buys three things over curl:
parallel chunked transfer, resume across interruptions, and a download that
survives the shell that started it disconnecting. Non-`main` revisions in the
URL are passed through as `--revision`.

`HF_TOKEN` and `CIVITAI_TOKEN` are read from the environment, then from
`~/vllm-stack/.env` and `~/comfyui/.env`. They are passed to `hf` and
`curl` **over stdin**, never as arguments — `docker exec -e VAR=secret` and
`curl -H "Authorization: ..."` both publish the secret to anyone who can
run `ps` on the host. Without a Civitai token, restricted
models return an HTML error page saved under a `.safetensors` name; `comfy
pull` warns when a download lands suspiciously small.

**Filenames resolve themselves.** Civitai links end in a numeric id rather
than a filename, and a file with no `.safetensors` extension never appears in
any loader — you would have the weights on disk and an empty dropdown. So
`comfy pull` asks the server first (`Content-Disposition`, falling back to a
one-byte ranged GET for origins that reject HEAD), then to the URL path, and
only then demands `--name`. Server-supplied names are reduced to a basename,
so a hostile `../../` cannot escape the target directory.

`--name` remains available to override the result.

**Paste the browser URL freely.** `huggingface.co/<repo>/blob/<rev>/<file>` is
the HTML page *about* a file — downloading it gives a few hundred KB of
webpage under a `.safetensors` name. The file lives at `/resolve/`. `comfy
pull` rewrites `/blob/` to `/resolve/` automatically for HuggingFace URLs.

Anything that arrives as HTML is sniffed after download, deleted, and
reported as an error rather than left on disk. A corrupt file that ComfyUI
lists is worse than no file: the loader error points at the model instead of
at the download.

`hf download` reproduces repo directory structure and writes bookkeeping into
`.cache/`. `comfy pull` prunes that and lifts weights to the top of the
target dir, so what lands is only the model file.

After pulling, use the refresh control in the UI or reload the page. No
restart needed.

---

## Security

- **ComfyUI has no authentication.** The port is bound to the Tailscale
  interface, not `0.0.0.0`. Anyone who reaches it can queue work, read
  outputs, and — via custom nodes — execute code. Do not port-forward it.
- **Custom nodes are arbitrary code execution**, and the entrypoint installs
  their declared dependencies automatically. That adds no exposure beyond
  running the node at all, but it does mean a compromised node's
  `requirements.txt` is acted on. There is precedent: `ComfyUI_LLMVISION`
  shipped as a credential stealer. Read what you install.

---

## Operations

```bash
# add models — see "Getting models" above; never via the browser
comfy pull hf:owner/repo:file.safetensors --to checkpoints

# rebuild after changing the Dockerfile (layers through the torch
# install are cached; only the tail rebuilds)
cd ~/comfyui && docker compose build && docker compose up -d --force-recreate

# bump ComfyUI: edit COMFYUI_REF in docker-compose.yml, then rebuild.
# Check the release notes for a CUDA floor change before assuming cu130
# is still enough.

# health
curl -s http://$TS_IP:8188/system_stats | python3 -m json.tool
```

Running as UID 1000 so bind-mounted outputs are owned by your host user, not
root. `HOME` is `/home/ubuntu` — the Ubuntu base image ships a UID-1000
`ubuntu` user — which is why the cache mount targets that path and not
something more obvious.

---

## API

`POST /prompt` submits a workflow; progress streams over websocket; results
land in `output/` and are readable via `/history`. That is the integration
point for driving generation from your own tooling rather than through the
browser.
