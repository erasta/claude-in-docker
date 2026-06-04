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
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv git \
    && rm -rf /var/lib/apt/lists/*

USER node
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:$PATH
RUN npm install -g @anthropic-ai/claude-code
EOF

GPU_FLAG=""
if docker info --format '{{.Runtimes}}' | grep -q nvidia; then
  GPU_FLAG="--gpus all"
fi

# Mount host tools that are already installed into a guaranteed-in-PATH location
HOST_TOOL_MOUNTS=""
for tool in gh; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && HOST_TOOL_MOUNTS="$HOST_TOOL_MOUNTS -v $tool_path:/usr/local/bin/$tool:ro"
done

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
  $HOST_TOOL_MOUNTS \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME" \
  claude --dangerously-skip-permissions
