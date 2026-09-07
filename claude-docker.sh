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
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl \
    && rm -rf /var/lib/apt/lists/*

USER node
ENV PATH=/home/node/.local/bin:$PATH
RUN curl -fsSL https://claude.ai/install.sh | bash
EOF

GPU_FLAG=""
if docker info --format '{{.Runtimes}}' | grep -q nvidia; then
  GPU_FLAG="--gpus all"
fi

# Name like "claude-<project>-<random>" so multiple containers can run per project.
CONTAINER_NAME="claude-$(basename "$PROJECT_DIR")-$(printf '%04x' $RANDOM)"

echo "==> Starting Claude on container ($CONTAINER_NAME)..."
exec docker run -it --rm \
  --name "$CONTAINER_NAME" \
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
