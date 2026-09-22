#!/usr/bin/env bash
# custom_nodes/ is a bind mount and survives container recreation; the venv
# it installs into does not. Without this, a recreate leaves nodes present
# but un-importable, which reads as node corruption rather than a missing
# dependency. Re-resolve them against the image's torch on every boot.
set -uo pipefail
shopt -s nullglob

for req in /opt/comfyui/custom_nodes/*/requirements.txt; do
  node=$(basename "$(dirname "$req")")
  echo ":: custom node deps: ${node}"
  if ! PIP_CONSTRAINT=/opt/constraints.txt \
       pip install --no-input --disable-pip-version-check -q -r "${req}"; then
    echo "WARN: dependency install failed for ${node}; it may not load" >&2
  fi
done

exec python /opt/comfyui/main.py "$@"
