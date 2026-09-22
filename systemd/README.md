# Booting Docker stacks that bind to a Tailscale address

If you publish a container port on a Tailscale IP, the container will fail to
start on every reboot, and the error will not appear anywhere you normally
look. These units fix that. The fix is four parts, only three of which are
files in this directory.

## The failure

A container published on the tailnet interface:

```yaml
ports:
  - "${TS_IP}:4000:4000"
```

After a reboot, `docker ps` shows it as `Up`. It is not reachable. `docker port`
prints nothing. The configured binding is intact but was never applied:

```
HostConfig.PortBindings  {"4000/tcp":[{"HostIp":"100.x.x.x","HostPort":"4000"}]}
NetworkSettings.Ports    {}
```

In a stack where one container binds loopback and others bind the tailnet
address, the split is unmistakable:

| container | binds | applied |
|---|---|---|
| vllm | `127.0.0.1:8000` | yes |
| litellm | `100.x.x.x:4000` | **no** |
| comfyui | `100.x.x.x:8188` | **no** |

Loopback exists the instant the kernel is up. The tailnet address does not.

## Why `After=tailscaled.service` does not fix it

This is the trap. Ordering on the service looks correct and changes nothing,
because systemd considers `tailscaled` active as soon as the daemon is
running — roughly 13 seconds before the control-plane handshake assigns an
address.

A real boot timeline, from `journalctl -b`:

```
08:26:05.990  tailscaled starts — tailscale0: "Link not found"
08:26:05.997  tailscale0 created, carries only fe80:: link-local
08:26:16.683  dockerd starts
08:26:16.939  bind 100.x.x.x:8188 → cannot assign requested address
08:26:16.940  bind 100.x.x.x:4000 → cannot assign requested address
08:26:19.264  tailscaled: peerapi serving on 100.x.x.x   ← address arrives
08:26:20.167  LinkChange: tailscale0 ips += 100.x.x.x/32
```

A 2.3-second miss. Note `tailscaled` was already active for **eleven seconds**
before dockerd even started. Ordering on the unit was never the problem; you
have to order on the *address*.

By the time you SSH in to investigate, the tailnet has been healthy for
minutes, which makes this easy to misdiagnose as intermittent. It is not.
It fails identically every boot.

## The four-part fix

### 1. Stop dockerd from starting containers at boot

```yaml
restart: on-failure    # was: unless-stopped
```

`always` and `unless-stopped` are the two policies dockerd acts on at daemon
startup. It starts those containers itself, in parallel, knowing nothing about
ordering — that is the race. `on-failure` keeps crash recovery while the daemon
runs but surrenders the boot-start duty.

**Do this and nothing else and your stack will not come back at all.** Parts 1
and 2 are a pair.

### 2. Let systemd run compose

The units here do that. Two things they buy you beyond ordering:

**`depends_on` starts working.** It is a compose-client construct, evaluated
only while `docker compose up` is running. dockerd has never heard of it, so at
boot it starts dependent containers against backends that are not up yet — in
our case a proxy that crash-looped 12 times against a model server that was
still loading. Run compose from a unit and the dependency graph is honored
again.

**`--wait` blocks on healthchecks**, so the unit does not report success while
the stack is still coming up.

### 3. `net.ipv4.ip_nonlocal_bind=1`

```sh
echo 'net.ipv4.ip_nonlocal_bind=1' | sudo tee /etc/sysctl.d/99-nonlocal-bind.conf
sudo sysctl --system
```

This is the part with no file in this repo, and it is the one that actually
closes the 2.3-second gap: it lets a process bind an address the host does not
hold yet. Standard practice for floating and VIP addresses. System-wide, which
on a single-user host is a non-issue.

### 4. `wait-tailscale-ip`

Belt and braces once part 3 is in place, but it is what makes the units
*correct* rather than lucky — it polls for the actual `100.x` address instead
of trusting that `tailscaled` being active means anything. Costs nothing when
the address is already there.

Keep it as a script. Inlining the same loop as
`ExecStartPre=/bin/sh -c '...'` works, but systemd unescapes the unit file
before handing the string to `sh`, and `grep -q "inet 100\."` trips
`Ignoring unknown escape sequences` on every `daemon-reload`.

## Installing

```sh
sudo install -m 755 wait-tailscale-ip /usr/local/bin/wait-tailscale-ip
sudo /usr/local/bin/wait-tailscale-ip && echo ok     # should exit 0 immediately

sudo cp vllm-stack.service comfyui-stack.service /etc/systemd/system/
# edit User=, Environment=HOME= and WorkingDirectory= in both
sudo systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/vllm-stack.service
```

### `Environment=HOME=` is mandatory

Not cosmetic. Compose files here mount `${HOME}/.cache/huggingface` to persist
model weights. Run the unit without setting `HOME` and it resolves to `/root`,
the cache comes up empty, and you re-download tens of gigabytes of weights on
every boot — silently, since nothing errors.

### Enable one, not both

```sh
sudo systemctl enable vllm-stack.service
# leave comfyui-stack.service installed but NOT enabled
```

These two stacks share one GPU and cannot coexist — the inference model's
weights alone exceed what is left after a diffusion model takes its share. If
both units are enabled, boot starts both: the inference server claims most of
the card, ComfyUI starts on the remainder and `--wait` *succeeds*, because
ComfyUI loads models lazily. Boot reports green and the first render fails.

The companion `gpu` command at the repo root arbitrates at runtime. Let systemd
own **boot** and `gpu` own **switching**. That also means you do not need
`Conflicts=`, and it means `systemctl is-active` is not a reliable answer to
"is it running" — `gpu` drives Docker directly, behind systemd's back.

## Verifying

The only test that counts is a reboot. Afterwards:

```sh
docker port litellm                  # expect a mapping, not silence
systemctl status vllm-stack.service
```

If `docker port` is silent, the bind failed again. The evidence is in
`journalctl -b -u docker | grep -i bind`, not in the container's own logs —
dockerd fails before the container's process ever starts, which is why the
application log looks like a clean run from some earlier boot.

## Notes

- **Healthchecks need a probe that exists in the image.** The LiteLLM image
  ships no `curl`, `wget`, or `nc` — only its own venv Python. A `curl`-based
  healthcheck marks the container permanently unhealthy and makes `--wait` hang
  for its full timeout, which is worse than having no healthcheck.
- **Budget the start timeout generously.** A 35B AWQ model reaches healthy in
  ~150s from a warm weight cache, and it is dominated by engine init —
  profiling, KV cache allocation, CUDA graph capture, warmup — at ~87s. Weight
  loading is under 8s of it. `nvidia-persistenced` with persistence mode
  actually enabled shaves driver init, not warmup. Note the packaged unit on
  Debian/Ubuntu-family distros runs with `--no-persistence-mode`, so
  "the daemon is running" does not mean persistence is on; check
  `nvidia-smi --query-gpu=persistence_mode --format=csv`.
