#!/bin/bash
set -e

# Parse flags
UPDATE_ENV=false
ENV_MODE=""
for arg in "$@"; do
  case "$arg" in
    --update_environment) UPDATE_ENV=true ;;
    --copy_environment)   ENV_MODE="copy" ;;
    --link_environment)   ENV_MODE="link" ;;
    --help|-h)
      cat <<'HELP'
Usage: claude-docker.sh [OPTIONS]

Run Claude Code in a Docker container with Python environment support.

Environment modes:
  --link_environment    (default) Mount host Python site-packages into the
                        container read-only. Zero install time, no duplication.
                        All projects share the same packages.
  --copy_environment    Create an isolated venv inside the container, install
                        packages from requirements.txt. Persistent across runs
                        but duplicated per project. Use when you need isolation
                        or the host has no Python.

Other options:
  --update_environment  Snapshot the current host Python environment into
                        requirements.txt before starting. Combine with either
                        mode, e.g.: --update_environment --copy_environment
  --help, -h            Show this help message and exit.

Examples:
  ./claude-docker.sh                          # link mode (default)
  ./claude-docker.sh --copy_environment       # isolated venv per project
  ./claude-docker.sh --update_environment     # refresh requirements.txt, then link
  ./claude-docker.sh --update_environment --copy_environment
HELP
      exit 0
      ;;
  esac
done

PROJECT_DIR="$(pwd)"
PROJECT_SLUG="$(echo "$PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')"
IMAGE_NAME="claude-code-env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/.claude-venv"

# Detect host Python site-packages for --link_environment
HOST_SITE_PACKAGES=""
if command -v python3 &>/dev/null; then
  HOST_SITE_PACKAGES="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))' 2>/dev/null || true)"
fi

# Determine env mode: default to link (shared host env) if host Python exists
if [ -z "$ENV_MODE" ]; then
  if [ -n "$HOST_SITE_PACKAGES" ] && [ -d "$HOST_SITE_PACKAGES" ]; then
    ENV_MODE="link"
  elif [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    ENV_MODE="copy"
  fi
fi

mkdir -p "$HOME/.claude/projects/$PROJECT_SLUG"
mkdir -p "$VENV_DIR"

# Create entrypoint.sh next to this script (always regenerate to pick up changes)
echo "==> Creating entrypoint.sh..."
cat > "$SCRIPT_DIR/entrypoint.sh" <<'ENTRY'
#!/bin/bash
set -e

ENV_MODE="${ENV_MODE:-copy}"
VENV_PATH="/opt/venv"
REQ_FILE="/tmp/requirements.txt"

# ── Progress bar helper ──────────────────────────────────────────────
progress_pip_install() {
    local label="$1"
    local pip_cmd="$2"   # "pip" or "$VENV_PATH/bin/pip"
    local req_file="$3"
    shift 3
    # Count total requirements (non-empty, non-comment lines)
    local total
    total=$(grep -cvE '^\s*($|#)' "$req_file" 2>/dev/null || echo 0)
    if [ "$total" -eq 0 ]; then
        return 0
    fi

    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local bar_width=$((cols - 30))
    [ "$bar_width" -lt 10 ] && bar_width=10

    # Use a temp file for counters (pipe creates subshell, vars don't propagate)
    local counter_file
    counter_file=$(mktemp)
    echo "0" > "$counter_file"

    local draw_bar
    draw_bar() {
        local n=$1
        [ "$n" -gt "$total" ] && n=$total
        local pct=$((n * 100 / total))
        local filled=$((pct * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar_fill="" bar_empty=""
        [ "$filled" -gt 0 ] && bar_fill=$(printf '%*s' "$filled" '' | tr ' ' '█')
        [ "$empty" -gt 0 ]  && bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '░')
        printf "\r  %s [%s%s] %3d%% (%d/%d)" "$label" "$bar_fill" "$bar_empty" "$pct" "$n" "$total"
    }

    # Draw initial state
    draw_bar 0

    # Run pip without --quiet so we get per-package output lines
    $pip_cmd install --progress-bar off -r "$req_file" "$@" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *"Requirement already satisfied"*|*"Collecting "*|*"Successfully installed"*)
                local cnt
                cnt=$(cat "$counter_file")
                cnt=$((cnt + 1))
                echo "$cnt" > "$counter_file"
                draw_bar "$cnt"
                ;;
        esac
    done

    # Final state
    draw_bar "$total"
    echo ""
    rm -f "$counter_file"
}

# ── Link mode: host site-packages is mounted, just set PATH ──────────
if [ "$ENV_MODE" = "link" ]; then
    echo "==> Link mode: using host Python environment"
    if [ -d "/opt/host-site-packages" ]; then
        export PYTHONPATH="/opt/host-site-packages:${PYTHONPATH:-}"
        echo "    $(find /opt/host-site-packages -maxdepth 1 -name '*.dist-info' | wc -l) packages available"
    fi

    # Install any local (editable/file://) packages into a small overlay
    if [ -f "$REQ_FILE" ]; then
        local_pkgs=$(grep '@ file://' "$REQ_FILE" | sed 's/.*@ file:\/\///' || true)
        if [ -n "$local_pkgs" ]; then
            for pkg in $local_pkgs; do
                if [ -d "$pkg" ]; then
                    echo "==> Installing local package: $pkg"
                    pip install --quiet --target /opt/local-pkgs "$pkg" 2>/dev/null || true
                fi
            done
            export PYTHONPATH="/opt/local-pkgs:${PYTHONPATH:-}"
        fi
    fi

    exec "$@"
fi

# ── Copy mode: isolated venv with persistent cache ───────────────────
if [ ! -f "$REQ_FILE" ]; then
    echo "==> No requirements.txt found, skipping venv setup."
    exec "$@"
fi

REQ_HASH=$(md5sum "$REQ_FILE" | cut -d' ' -f1)

if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "==> Creating venv..."
    python3 -m venv "$VENV_PATH"
fi

# Check if packages are actually installed (more than just pip/setuptools)
PKG_COUNT=$("$VENV_PATH/bin/pip" list --format=freeze 2>/dev/null | wc -l)

if [ "$PKG_COUNT" -le 3 ] || [ ! -f "$VENV_PATH/.req_hash" ] || [ "$REQ_HASH" != "$(cat "$VENV_PATH/.req_hash")" ]; then
    echo "==> Installing/updating packages ($PKG_COUNT found, expecting more)..."

    # Prepare filtered requirements (no file:// entries)
    FILTERED_REQ=$(mktemp)
    grep -v '@ file://' "$REQ_FILE" > "$FILTERED_REQ" || true

    progress_pip_install "Packages" "$VENV_PATH/bin/pip" "$FILTERED_REQ"
    rm -f "$FILTERED_REQ"

    # Install local packages (may need write access for egg-info)
    for pkg in $(grep '@ file://' "$REQ_FILE" | sed 's/.*@ file:\/\///'); do
        if [ -d "$pkg" ]; then
            echo "==> Installing local package: $pkg"
            "$VENV_PATH/bin/pip" install --quiet "$pkg" 2>/dev/null \
              || "$VENV_PATH/bin/pip" install --quiet --no-build-isolation "$pkg" \
              || echo "    ⚠ Failed to install $pkg (check write permissions)"
        fi
    done

    echo "$REQ_HASH" > "$VENV_PATH/.req_hash"
else
    echo "==> Python venv up to date ($PKG_COUNT packages)."
fi

exec "$@"
ENTRY
chmod +x "$SCRIPT_DIR/entrypoint.sh"

# Update requirements.txt from current environment if requested
if [ "$UPDATE_ENV" = true ]; then
  echo "==> Updating requirements.txt from current Python environment..."
  pip freeze > "$SCRIPT_DIR/requirements.txt"
  echo "    $(wc -l < "$SCRIPT_DIR/requirements.txt") packages captured."
fi

# Check if requirements.txt exists for the mount
REQ_MOUNT=""
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  REQ_MOUNT="-v $SCRIPT_DIR/requirements.txt:/tmp/requirements.txt:ro"
fi

# Build mount flags for local development packages (rw needed for egg-info during pip build)
LOCAL_MOUNTS=""
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  while IFS= read -r pkg_path; do
    if [ -d "$pkg_path" ]; then
      LOCAL_MOUNTS="$LOCAL_MOUNTS -v $pkg_path:$pkg_path"
    fi
  done < <(grep '@ file://' "$SCRIPT_DIR/requirements.txt" | sed 's/.*@ file:\/\///')
fi

echo "==> Building Docker image..."
docker build -t "$IMAGE_NAME" -f - "$SCRIPT_DIR" <<'EOF'
FROM node:22-bookworm
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:/opt/venv/bin:$PATH
RUN npm install -g @anthropic-ai/claude-code
ENTRYPOINT ["entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
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
  [ -n "$GPU_FLAG" ] && echo "==> GPU: NVIDIA (device passthrough)"
fi

# AMD/Intel: DRI render nodes and AMD KFD compute device
for dev in /dev/dri/renderD*; do
  [ -c "$dev" ] && GPU_FLAG="$GPU_FLAG --device $dev"
done
if [ -c /dev/kfd ]; then
  GPU_FLAG="$GPU_FLAG --device /dev/kfd"
fi
[ -n "$(echo "$GPU_FLAG" | grep -o '/dev/dri\|/dev/kfd')" ] && echo "==> GPU: AMD/Intel (DRI render nodes)"

# ── Build env-specific docker flags ──────────────────────────────────
ENV_MOUNTS=""
ENV_VARS="-e ENV_MODE=${ENV_MODE:-copy}"

if [ "$ENV_MODE" = "link" ]; then
  if [ -z "$HOST_SITE_PACKAGES" ] || [ ! -d "$HOST_SITE_PACKAGES" ]; then
    echo "ERROR: Cannot find host Python site-packages. Is python3 installed?"
    exit 1
  fi
  echo "==> Link mode: mounting $HOST_SITE_PACKAGES (read-only)"
  ENV_MOUNTS="-v $HOST_SITE_PACKAGES:/opt/host-site-packages:ro"
else
  # Copy mode: mount persistent venv volume
  ENV_MOUNTS="-v $VENV_DIR:/opt/venv"
fi

echo "==> Starting Claude (env: ${ENV_MODE:-none})..."
exec docker run -it --rm \
  --name "claude-$(basename "$PROJECT_DIR")" \
  --network host \
  $GPU_FLAG \
  -v "$PROJECT_DIR":"$PROJECT_DIR" \
  -v "$HOME/.claude":/home/node/.claude \
  --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
  -v "$HOME/.claude/projects/$PROJECT_SLUG":/home/node/.claude/projects/$PROJECT_SLUG \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  $ENV_MOUNTS \
  $REQ_MOUNT \
  $LOCAL_MOUNTS \
  $ENV_VARS \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME"
