# ComfyUI on Blackwell (sm_120).
# cu130, not cu128: ComfyUI 0.35.1 gates its fused-kernel backend
# (comfy_kitchen - nvfp4/fp8, fused RoPE/AdaLN, SVDQuant) behind cu130+.
# On cu128 it loads as available-but-disabled and the fast paths are lost
# silently. Driver 595.84 reports CUDA 13.2, so 13.0 is well within range.
FROM nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04

ARG COMFYUI_REF=v0.35.1
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# libgl/libglib are needed by image-handling deps pulled in via custom nodes.
# Ubuntu 24.04 renamed glib with the t64 ABI transition; tolerate both names.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip git ca-certificates libgl1 \
 && (apt-get install -y --no-install-recommends libglib2.0-0t64 \
     || apt-get install -y --no-install-recommends libglib2.0-0) \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv && pip install --upgrade pip wheel

# cu130 wheels carry sm_120 kernels AND satisfy comfy_kitchen's gate.
RUN pip install torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu130

RUN git clone --depth 1 --branch ${COMFYUI_REF} \
      https://github.com/comfyanonymous/ComfyUI.git /opt/comfyui
WORKDIR /opt/comfyui
RUN pip install -r requirements.txt

# Run as the host user so bind-mounted outputs aren't root-owned.
RUN chown -R ${UID}:${GID} /opt/comfyui /opt/venv

# Triton JIT-compiles a CUDA utils extension on first kernel launch, and
# torch.compile's inductor backend emits C++ — neither works on a -runtime-
# base image, which ships no compiler. Failure is a RuntimeError deep in
# triton/runtime/build.py at generation time, not at startup, so the
# container looks healthy right up until the first prompt.
# Placed after the torch layers so adding it does not invalidate them.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3-dev \
 && rm -rf /var/lib/apt/lists/*

# PyTorch 2.14 dispatches ordinary ops (even a plain bmm) through Triton,
# which JIT-compiles a CUDA utils extension on first use. A -runtime- base
# image ships no compiler, so this fails at GENERATION time, not startup:
# the container looks healthy until the first prompt, then raises
# "Failed to find C compiler" from triton/runtime/build.py.
# Placed after the torch layers so adding it doesn't invalidate them.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3-dev \
 && rm -rf /var/lib/apt/lists/*

# Custom nodes routinely list `torch` in their requirements.txt. Installing
# one unconstrained can silently swap this cu130 build for a generic PyPI
# wheel and take the fused kernels with it — a failure that shows up later
# as "generation got slow" with nothing obviously broken. Pin what shipped.
RUN pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > /opt/constraints.txt

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER ${UID}:${GID}

EXPOSE 8188
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--listen", "0.0.0.0", "--port", "8188"]
