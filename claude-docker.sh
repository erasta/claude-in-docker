#!/bin/bash
set -e
PROJECT_DIR="$(pwd)"
PROJECT_SLUG="$(echo "$PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')"

# Detect if PROJECT_DIR is a git worktree; if so, find the main repo root.
# A worktree's --git-dir points inside .git/worktrees/<name>, while
# --git-common-dir points to the shared .git — they differ only in worktrees.
MAIN_REPO_DIR=""
if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  _GIT_DIR="$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null || true)"
  _GIT_COMMON="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
  # Make paths absolute (git may return relative paths for the main worktree)
  _GIT_DIR="$(cd "$PROJECT_DIR" && realpath -m "$_GIT_DIR" 2>/dev/null || echo "$_GIT_DIR")"
  _GIT_COMMON="$(cd "$PROJECT_DIR" && realpath -m "$_GIT_COMMON" 2>/dev/null || echo "$_GIT_COMMON")"
  if [ -n "$_GIT_COMMON" ] && [ "$_GIT_DIR" != "$_GIT_COMMON" ]; then
    MAIN_REPO_DIR="$(dirname "$_GIT_COMMON")"
    echo "==> Worktree detected: main repo at $MAIN_REPO_DIR"
  fi
fi

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
if docker info --format '{{.Runtimes}}' | grep -q nvidia; then
  GPU_FLAG="--gpus all"
fi

MAIN_REPO_MOUNT=""
if [ -n "$MAIN_REPO_DIR" ] && [ "$MAIN_REPO_DIR" != "$PROJECT_DIR" ]; then
  MAIN_REPO_MOUNT="-v $MAIN_REPO_DIR:$MAIN_REPO_DIR"
fi

echo "==> Starting Claude..."
exec docker run -it --rm \
  --name "claude-$(basename "$PROJECT_DIR")" \
  --network host \
  $GPU_FLAG \
  -v "$PROJECT_DIR":"$PROJECT_DIR" \
  $MAIN_REPO_MOUNT \
  -v "$HOME/.claude":/home/node/.claude \
  --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
  -v "$HOME/.claude/projects/$PROJECT_SLUG":/home/node/.claude/projects/$PROJECT_SLUG \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME" \
  claude --dangerously-skip-permissions
