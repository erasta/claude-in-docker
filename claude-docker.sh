#!/bin/bash
set -e
PROJECT_DIR="$(pwd)"
PROJECT_SLUG="$(echo "$PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')"
IMAGE_NAME="claude-code-env"

mkdir -p "$HOME/.claude/projects/$PROJECT_SLUG"

echo "==> Building Docker image..."
docker build -t "$IMAGE_NAME" -f - "$PROJECT_DIR" <<'EOF'
FROM node:22-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

USER node
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:$PATH
RUN npm install -g @anthropic-ai/claude-code
EOF

GPU_FLAG=""
# NVIDIA: prefer container runtime, fall back to explicit device passthrough
if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  GPU_FLAG="--gpus all"
  echo "==> GPU: NVIDIA (nvidia container runtime)"
else
  for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
    [ -c "$dev" ] && GPU_FLAG="$GPU_FLAG --device $dev"
  done
  if [ -n "$GPU_FLAG" ]; then
    echo "==> GPU: NVIDIA (device passthrough)"
    echo "    Tip: install nvidia-container-toolkit for full GPU support:"
    echo "         $(dirname "${BASH_SOURCE[0]}")/setup-gpu.sh"
  fi
fi

# AMD/Intel: DRI render nodes and AMD KFD compute device
for dev in /dev/dri/renderD*; do
  [ -c "$dev" ] && GPU_FLAG="$GPU_FLAG --device $dev"
done
if [ -c /dev/kfd ]; then
  GPU_FLAG="$GPU_FLAG --device /dev/kfd"
fi
[ -n "$(echo "$GPU_FLAG" | grep -o '/dev/dri\|/dev/kfd')" ] && echo "==> GPU: AMD/Intel (DRI render nodes)"

echo "==> Starting Claude..."
exec docker run -it --rm \
  --name "claude-$(basename "$PROJECT_DIR")" \
  --network host \
  $GPU_FLAG \
  -v "$PROJECT_DIR":"$PROJECT_DIR" \
  -v "$HOME/.claude":/home/node/.claude \
  --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
  -v "$HOME/.claude/projects/$PROJECT_SLUG":/home/node/.claude/projects/$PROJECT_SLUG \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME" \
  claude --dangerously-skip-permissions
