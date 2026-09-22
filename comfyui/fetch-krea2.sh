#!/usr/bin/env bash
# Fetch the Krea-2 model set into ComfyUI's model tree.
# Resumable: wget -c, so a dropped connection picks up where it left off.
set -uo pipefail

BASE="https://huggingface.co/Comfy-Org/Krea-2/resolve/main"
MODELS="$HOME/comfyui/models"
LOG="$HOME/comfyui/fetch-krea2.log"

# remote-subpath -> local dir
set -- \
  "loras/krea2_darkbrush.safetensors:loras" \
  "vae/qwen_image_vae.safetensors:vae" \
  "text_encoders/qwen3vl_4b_fp8_scaled.safetensors:text_encoders" \
  "diffusion_models/krea2_turbo_fp8_scaled.safetensors:diffusion_models"

: > "$LOG"
fail=0
for pair in "$@"; do
  remote="${pair%%:*}"
  dir="${pair##*:}"
  name="$(basename "$remote")"
  dest="$MODELS/$dir/$name"
  mkdir -p "$MODELS/$dir"

  echo "=== $name -> models/$dir/ ===" | tee -a "$LOG"
  expected=$(curl -sIL --max-time 30 "$BASE/$remote" | grep -i '^content-length:' | tail -1 | tr -d '\r' | awk '{print $2}')

  if [ -f "$dest" ] && [ -n "$expected" ] && [ "$(stat -c%s "$dest")" = "$expected" ]; then
    echo "  already complete ($expected bytes), skipping" | tee -a "$LOG"
    continue
  fi

  wget -c -q --show-progress --progress=dot:giga -O "$dest" "$BASE/$remote" >>"$LOG" 2>&1
  rc=$?
  actual=$(stat -c%s "$dest" 2>/dev/null || echo 0)
  if [ "$rc" -ne 0 ] || { [ -n "$expected" ] && [ "$actual" != "$expected" ]; }; then
    echo "  FAILED rc=$rc size=$actual expected=${expected:-?}" | tee -a "$LOG"
    fail=1
  else
    echo "  OK $actual bytes" | tee -a "$LOG"
  fi
done

echo "=== summary ===" | tee -a "$LOG"
for pair in "$@"; do
  remote="${pair%%:*}"; dir="${pair##*:}"; name="$(basename "$remote")"
  printf '  %-52s %s\n' "$name" "$(du -h "$MODELS/$dir/$name" 2>/dev/null | cut -f1 || echo MISSING)" | tee -a "$LOG"
done
exit $fail
