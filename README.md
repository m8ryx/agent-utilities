## Agent Utilities

Miscellaneous tools, tips, tricks to make working with agents a bit easier.

I hope you find these handy. A few notes about my use cases:
- CLI/TUI first - I prefer nvim to Code 
- Multiple contexts, air-gapped. I have the desire and need to keep contexts safe from each other. 
- Personal AI hosting - I picked up an RTX 5090 based machine to run workloads locally, for hobby and profession.
- Linux - I use Linux. I haven't felt the need to use the new hotness, but instead run PopOS (which does have the new Costmic desktop, which is pretty cool). I've been running Debian family for decades, and was kicking around switching, but PopOS has good CUDA support.


## The Goods - Utilities

### herdr-recycle-machines

herdr's remote machines is super handy, but my logins expire and then everything is broken. The best way I can find it to cycle enabled off/on. This will do it for you.

Usage:
```bash
  herdr-recycle-machines [options] [id-or-label ...]

Options:
  -l, --label NAME  Cycle only the machine with this label. Repeatable, and
                    matches the label column only, so a label that happens to
                    look like an id is never mistaken for one.
  -n, --dry-run     Print what would happen and change nothing.
  -d, --delay SECS  Pause between disable and enable (default 2).
  -a, --all         Also cycle machines that are currently disabled.
  -q, --quiet       Only print problems and the final summary.
  -h, --help        Show this help.
```
With no --label and no positional arguments, every machine from `herdr machine list` is considered -- they are excluded if not in enabled state.

## The Goods - Local LLM

### gpu

One RTX 5090, two things that want all of it: a vLLM inference stack and ComfyUI. Doing the switch by hand means remembering which compose project to stop, in what order, and then sitting there wondering whether it actually came back. This arbitrates.

Usage:
```bash
  gpu status              what holds the card right now
  gpu comfy               hand the whole card to ComfyUI
  gpu vllm                hand it back to inference
  gpu both --split 0.5    run both, vLLM capped at 50%
  gpu off                 stop both, leave the proxy up
```
Stopping vLLM is only painless if you have a proxy in front with a fallback configured -- see `vllm-stack`. `gpu both` needs a model small enough to leave ComfyUI room, and refuses to run unless your compose command reads `${VLLM_GPU_UTIL}`, so it can't quietly recreate vLLM at full utilization and starve everything else.

### comfy

ComfyUI's model browser downloads to whichever machine your browser is on, which is never the machine with the GPU -- so you end up copying multi-GB files back across the network. This fetches server-side instead.

Usage:
```bash
  comfy pull hf:owner/repo:file.safetensors --to checkpoints
  comfy pull https://civitai.com/api/download/models/12345 --to loras
  comfy models          # what's installed, with sizes
  comfy dirs            # valid target subdirs
```
Paste URLs straight from ComfyUI's missing-models dialog. `/blob/` gets rewritten to `/resolve/` automatically, because the blob URL is the HTML page *about* a file -- download it and you get a few hundred KB of webpage sitting there named `.safetensors`, and the loader error that follows points at the model instead of the download. Anything arriving as HTML is sniffed, deleted, and reported.

Filenames resolve from `Content-Disposition` when the URL doesn't carry one, which Civitai links never do. A weights file without a `.safetensors` extension never appears in any loader, so you'd have the model on disk and an empty dropdown.

Tokens are read from the environment or the stacks' `.env` files and passed over stdin -- never as arguments, since `docker exec -e VAR=secret` and `curl -H "Authorization: ..."` both publish the secret to anyone who can run `ps`.

### vllm-stack

vLLM + LiteLLM + Postgres. Everything downstream talks to one OpenAI-compatible endpoint and stops caring whether the local box is up -- the router falls back to Claude when vLLM is away, which is what turns `gpu comfy` into a non-event instead of an outage.

Includes `custom_handler.py`, a LiteLLM pre-call hook that merges multi-block system prompts into a single leading system message. Without it, agentic clients don't work at all: vLLM's Qwen chat template accepts exactly one system message and opencode and Claude Code both send several. The error you get is `System message must be at the beginning`, which sends you looking at ordering -- but two system blocks at the front fail just as hard.

Copy `example.env` to `.env` before starting. Two things that cost me time: `LITELLM_MASTER_KEY` must begin with `sk-`, and `ANTHROPIC_API_KEY` has to be scoped to a workspace or every fallback dies on a `anthropic-workspace-id` error while the direct calls keep working fine.

### comfyui

Containerised ComfyUI for Blackwell (sm_120), pinned to a known-good ComfyUI and torch. Built on cu130 rather than cu128 deliberately -- ComfyUI gates its fused-kernel backend behind cu130+, and on cu128 it loads as available-but-disabled and you lose the fast paths without being told.

`fetch-krea2.sh` pulls a model set into the right subdirectories, resumable and size-verified, because a dropped connection 11GB into a diffusion model shouldn't start over.

### systemd

Boot units for both stacks. Publish a container port on a Tailscale IP and it will fail to bind on every single reboot while `docker ps` cheerfully reports `Up` -- and `After=tailscaled.service` looks like the fix but isn't, because the daemon goes active about thirteen seconds before it has an address. [systemd/README.md](systemd/README.md) has the boot timeline and the four-part change.
