#!/bin/bash
set -e

# ── Persistent worker container ──────────────────────────────────────
# Load optional user-wide config; sets CLAUDE_* env vars used below.
# Generate a template with `make docker-config`.
if [ -f "$HOME/.claude/docker.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/docker.env"
fi

CLAUDE_CONTAINER_NAME="${CLAUDE_CONTAINER_NAME:-claude-worker}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/claude-projects}"
# Default under $HOME so /workspace/dispatch survives host reboot. /tmp is
# tmpfs on many distros (and swept by systemd-tmpfiles even when not) — a
# reboot returned /workspace/dispatch empty and root-owned, losing in-flight
# worktrees + run state (evolvix#697). Callers can still point elsewhere via
# CLAUDE_DISPATCH_DIR; the ownership fix below runs regardless.
CLAUDE_DISPATCH_DIR="${CLAUDE_DISPATCH_DIR:-$HOME/claude-dispatch}"

# Parse flags
UPDATE_ENV=false
DAEMON_MODE=false
STOP_MODE=false
STATUS_MODE=false
ENV_MODE=""
ENV_FILE=""
NAME_EXPLICIT=false
EXTRA_ENV_FLAGS=()
EXTRA_VOLUME_FLAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --name requires a value" >&2
        exit 2
      fi
      CLAUDE_CONTAINER_NAME="$2"
      NAME_EXPLICIT=true
      shift 2
      ;;
    --env-file)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --env-file requires a value" >&2
        exit 2
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    -e)
      if [ -z "${2:-}" ]; then
        echo "ERROR: -e requires a value" >&2
        exit 2
      fi
      EXTRA_ENV_FLAGS+=(-e "$2")
      shift 2
      ;;
    -v)
      if [ -z "${2:-}" ]; then
        echo "ERROR: -v requires a value" >&2
        exit 2
      fi
      EXTRA_VOLUME_FLAGS+=(-v "$2")
      shift 2
      ;;
    --update_environment) UPDATE_ENV=true; shift ;;
    --copy_environment)   ENV_MODE="copy"; shift ;;
    --link_environment)   ENV_MODE="link"; shift ;;
    --daemon)             DAEMON_MODE=true; shift ;;
    --stop)               STOP_MODE=true;   shift ;;
    --status)             STATUS_MODE=true; shift ;;
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

Persistent worker mode (for MCP dispatch):
  --daemon              Start a persistent worker container in the background.
                        The dispatcher drives it via `docker exec`. Mounts
                        $CLAUDE_PROJECTS_DIR (default ~/claude-projects) at
                        /workspace/projects. Mounts $HOME/.ssh read-only so
                        the container inherits your host's key-alias mapping.
                        Container is named $CLAUDE_CONTAINER_NAME (default
                        claude-worker). The /workspace/dispatch mount is
                        NOT baked (evolvix#906) — the caller declares it via
                        `-v <host_dir>:/workspace/dispatch` so host source
                        and container target can differ (docker-out-of-docker).
                        Settings can also be placed in ~/.claude/docker.env
                        — generate a template with `make docker-config`.
  --stop                Stop the persistent worker.
  --status              Show worker status. Exit 1 if not running.
  --name NAME           Override the container name. Applies to --daemon,
                        --stop, --status, and interactive mode. Enables
                        running multiple named workers side-by-side.
                        Defaults to $CLAUDE_CONTAINER_NAME (claude-worker).
  --env-file FILE       Load additional env vars from FILE (docker
                        --env-file format) into the started container.
                        Use for per-project credentials (GH_TOKEN,
                        GIT_SSH_COMMAND, etc.).
  -e KEY=VALUE          Pass an env var to the started container.
                        Repeatable. Values may contain spaces when
                        quoted, e.g. -e "GIT_SSH_COMMAND=ssh -i ...".

API keys and secrets:
  Create set-environment-vars.conf in the project directory listing files
  to mount, one per line (relative or absolute paths):
    setOpenAIKey.sh
    setOpenRouterKey.sh
    /etc/mycompany/env.sh
  .sh files are sourced at startup; all other files are mounted read-only
  at /home/node/api-keys/<basename> but not sourced.
  Never commit secret files to git.

Read-only mounts (configs, data dirs, etc.):
  Create readonly-mounts.conf listing host paths (files or directories) to
  mount read-only at the SAME path inside the container, one per line.
  Looked up in the project directory first, then in the script directory
  (global default). Both files are read and merged. Supports ~, # comments.

GitHub SSH (push from container without exposing ~/.ssh):
  Generate a dedicated key outside ~/.ssh:
    mkdir -p ~/.claude-docker-keys
    ssh-keygen -t ed25519 -f ~/.claude-docker-keys/github_ed25519 -N "" -C "claude-docker"
  Add ~/.claude-docker-keys/github_ed25519.pub to GitHub SSH keys.
  Create ~/.claude-docker-keys/setup-github-ssh.sh:
    export GIT_SSH_COMMAND="ssh -i /home/node/api-keys/github_ed25519 \
      -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  Add both to set-environment-vars.conf:
    ~/.claude-docker-keys/github_ed25519
    ~/.claude-docker-keys/setup-github-ssh.sh

Examples:
  ./claude-docker.sh                          # link mode (default)
  ./claude-docker.sh --copy_environment       # isolated venv per project
  ./claude-docker.sh --update_environment     # refresh requirements.txt, then link
  ./claude-docker.sh --update_environment --copy_environment
HELP
      exit 0
      ;;
    *) shift ;;
  esac
done

# Handle worker lifecycle subcommands before any setup or image build.
if [ "$STOP_MODE" = true ]; then
  if docker stop "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Claude worker stopped: $CLAUDE_CONTAINER_NAME"
  else
    echo "No running worker: $CLAUDE_CONTAINER_NAME"
  fi
  exit 0
fi

if [ "$STATUS_MODE" = true ]; then
  if docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CLAUDE_CONTAINER_NAME}$"; then
    docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" \
      --format $'Name: {{.Names}}\nStatus: {{.Status}}\nUptime: {{.RunningFor}}'
    exit 0
  else
    echo "No running worker: $CLAUDE_CONTAINER_NAME"
    exit 1
  fi
fi

# Resolve --env-file to a docker flag; fail fast if the user pointed to a
# file that isn't there rather than silently launching without those creds.
ENV_FILE_FLAG=""
if [ -n "$ENV_FILE" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: --env-file not found: $ENV_FILE" >&2
    exit 2
  fi
  ENV_FILE_FLAG="--env-file $ENV_FILE"
fi

# --daemon: if a worker is already running, report and exit before any setup.
if [ "$DAEMON_MODE" = true ]; then
  if docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CLAUDE_CONTAINER_NAME}$"; then
    echo "Claude worker already running (container: $CLAUDE_CONTAINER_NAME)"
    docker ps --filter "name=^${CLAUDE_CONTAINER_NAME}$" --format 'Status: {{.Status}}'
    exit 0
  fi
  # Clear any stopped container carrying the same name so `docker run` succeeds.
  docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
  mkdir -p "$CLAUDE_PROJECTS_DIR" "$CLAUDE_DISPATCH_DIR"
fi

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/.claude-venv"

# ── Environment variable file discovery ──────────────────────────────
# Read set-environment-vars.conf if present. Each non-comment line is
# a shell file to source. Relative paths resolved from the conf file's directory.
KEY_FILES=()
API_KEYS_CONF="$PWD/set-environment-vars.conf"
if [ -f "$API_KEYS_CONF" ]; then
  CONF_DIR="$(cd "$(dirname "$API_KEYS_CONF")" && pwd)"
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Expand leading ~ to $HOME
    line="${line/#\~/$HOME}"
    # Resolve relative paths
    if [[ "$line" != /* ]]; then
      line="$CONF_DIR/$line"
    fi
    KEY_FILES+=("$line")
  done < "$API_KEYS_CONF"
fi

# Build mount flags and container paths list for key files
KEY_MOUNTS=""
KEY_PATHS_IN_CONTAINER=""
for keyfile in "${KEY_FILES[@]}"; do
  if [ -f "$keyfile" ]; then
    basename_key="$(basename "$keyfile")"
    KEY_MOUNTS="$KEY_MOUNTS -v $keyfile:/home/node/api-keys/$basename_key:ro"
    KEY_PATHS_IN_CONTAINER="$KEY_PATHS_IN_CONTAINER /home/node/api-keys/$basename_key"
  else
    echo "==> Warning: key file not found: $keyfile"
  fi
done

# Pass the list of key paths into the container via env var
if [ -n "$KEY_PATHS_IN_CONTAINER" ]; then
  echo "==> API keys: $(echo $KEY_PATHS_IN_CONTAINER | tr ' ' '\n' | xargs -I{} basename {} | tr '\n' ' ')"
fi

# ── Read-only mount discovery ────────────────────────────────────────
# Read readonly-mounts.conf if present. Each non-comment line is a host
# path mounted read-only at the same path inside the container. Checks
# project dir first then script dir (global), merging both lists.
RO_PATHS=()
_RO_SEEN=""
for _ro_conf in "$PWD/readonly-mounts.conf" "$SCRIPT_DIR/readonly-mounts.conf"; do
  [ -f "$_ro_conf" ] || continue
  _RO_CONF_DIR="$(cd "$(dirname "$_ro_conf")" && pwd)"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line/#\~/$HOME}"
    if [[ "$line" != /* ]]; then
      line="$_RO_CONF_DIR/$line"
    fi
    case ":$_RO_SEEN:" in *":$line:"*) continue;; esac
    _RO_SEEN="${_RO_SEEN:+$_RO_SEEN:}$line"
    RO_PATHS+=("$line")
  done < "$_ro_conf"
done

RO_MOUNTS=""
for _p in "${RO_PATHS[@]}"; do
  if [ -e "$_p" ]; then
    RO_MOUNTS="$RO_MOUNTS -v $_p:$_p:ro"
  else
    echo "==> Warning: readonly mount path not found: $_p"
  fi
done
if [ -n "$RO_MOUNTS" ]; then
  echo "==> Read-only mounts: ${#RO_PATHS[@]} path(s)"
  for _p in "${RO_PATHS[@]}"; do echo "    $_p"; done
fi

# Detect host Python site-packages for --link_environment
HOST_SITE_PACKAGES=""
if command -v python3 &>/dev/null; then
  HOST_SITE_PACKAGES="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))' 2>/dev/null || true)"
fi

# Detect active host venv + its base interpreter/stdlib. Needed because the
# container's `python3` (trixie ships 3.13) cannot load wheels built for a
# different minor version (e.g. 3.11). Same-path bind-mounts let the venv's
# absolute shebangs and pyvenv.cfg resolve unchanged inside the container.
HOST_VENV=""
HOST_PY_INTERP=""
HOST_PY_STDLIB=""
if command -v python3 &>/dev/null; then
  HOST_VENV="$(python3 -c 'import sys; print(sys.prefix if sys.prefix != sys.base_prefix else "")' 2>/dev/null || true)"
  _HOST_PY_BASE="$(python3 -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
  _HOST_PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
  if [ -n "$_HOST_PY_BASE" ] && [ -n "$_HOST_PY_VER" ]; then
    HOST_PY_INTERP="$_HOST_PY_BASE/bin/python$_HOST_PY_VER"
    HOST_PY_STDLIB="$_HOST_PY_BASE/lib/python$_HOST_PY_VER"
  fi
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

# Build mount flags for local development packages
LOCAL_MOUNTS=""
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  while IFS= read -r pkg_path; do
    if [ -d "$pkg_path" ]; then
      LOCAL_MOUNTS="$LOCAL_MOUNTS -v $pkg_path:$pkg_path"
    fi
  done < <(grep '@ file://' "$SCRIPT_DIR/requirements.txt" | sed 's/.*@ file:\/\///')
fi

# Build the base image on first run only. Subsequent runs skip this so
# `make docker-add-latex` / `docker-add-python-sci` / `docker-add-ollama`
# overlays are not clobbered. Force a rebuild with `make docker-build`.
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "==> Building base image (first run)..."
  docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.base" "$SCRIPT_DIR"
fi

GPU_FLAG=""
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
  ENV_MOUNTS="-v $VENV_DIR:/opt/venv"
fi

MAIN_REPO_MOUNT=""
if [ -n "$MAIN_REPO_DIR" ] && [ "$MAIN_REPO_DIR" != "$PROJECT_DIR" ]; then
  MAIN_REPO_MOUNT="-v $MAIN_REPO_DIR:$MAIN_REPO_DIR"
fi

# Mount host tools that are already installed into a guaranteed-in-PATH location
HOST_TOOL_MOUNTS=""
for tool in gh; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] && HOST_TOOL_MOUNTS="$HOST_TOOL_MOUNTS -v $tool_path:/usr/local/bin/$tool:ro"
done

# Same-path bind mounts so a host venv (and its base interpreter + stdlib) is
# usable inside the container. Only built in link mode; non-link projects fall
# back to the existing /opt/venv flow. ENV_VARS gains HOST_VENV so the
# entrypoint can auto-activate.
PY_INTERP_MOUNTS=""
if [ "$ENV_MODE" = "link" ]; then
  [ -n "$HOST_VENV" ]      && [ -d "$HOST_VENV" ]      && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_VENV:$HOST_VENV:ro"
  [ -n "$HOST_PY_INTERP" ] && [ -f "$HOST_PY_INTERP" ] && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_PY_INTERP:$HOST_PY_INTERP:ro"
  [ -n "$HOST_PY_STDLIB" ] && [ -d "$HOST_PY_STDLIB" ] && PY_INTERP_MOUNTS="$PY_INTERP_MOUNTS -v $HOST_PY_STDLIB:$HOST_PY_STDLIB:ro"
  [ -n "$HOST_VENV" ]      && ENV_VARS="$ENV_VARS -e HOST_VENV=$HOST_VENV"
fi

# Mount host CUDA toolkit if present — host HOOMD may be linked against
# /usr/local/cuda/.../libcudart.so. --gpus all only injects the driver.
CUDA_MOUNT=""
[ -d /usr/local/cuda ] && CUDA_MOUNT="-v /usr/local/cuda:/usr/local/cuda:ro"

# Mount each host PYTHONPATH directory read-only at the same path so dev
# packages (e.g. editable installs activated via `export PYTHONPATH=...`)
# resolve inside the container. Dirs already covered by other mounts
# (project, main repo, host venv) are skipped to avoid double-mount.
PYTHONPATH_MOUNTS=""
PYTHONPATH_IN_CONTAINER=""
if [ -n "${PYTHONPATH:-}" ]; then
  _SEEN=""
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ -d "$entry" ] || continue
    abs="$(cd "$entry" 2>/dev/null && pwd)" || continue
    [ -z "$abs" ] && continue
    case ":$_SEEN:" in *":$abs:"*) continue;; esac
    _SEEN="${_SEEN:+$_SEEN:}$abs"
    PYTHONPATH_IN_CONTAINER="${PYTHONPATH_IN_CONTAINER:+$PYTHONPATH_IN_CONTAINER:}$abs"
    # Already mounted by other rules — keep in PYTHONPATH but don't re-mount.
    [ "$abs" = "$PROJECT_DIR" ] && continue
    case "$abs" in "$PROJECT_DIR"/*) continue;; esac
    if [ -n "$MAIN_REPO_DIR" ]; then
      [ "$abs" = "$MAIN_REPO_DIR" ] && continue
      case "$abs" in "$MAIN_REPO_DIR"/*) continue;; esac
    fi
    if [ -n "$HOST_VENV" ]; then
      case "$abs" in "$HOST_VENV"|"$HOST_VENV"/*) continue;; esac
    fi
    PYTHONPATH_MOUNTS="$PYTHONPATH_MOUNTS -v $abs:$abs:ro"
  done < <(printf '%s' "$PYTHONPATH" | tr ':' '\n')
  if [ -n "$PYTHONPATH_MOUNTS" ]; then
    echo "==> PYTHONPATH: mounting external dirs read-only"
    for d in $(printf '%s' "$PYTHONPATH_MOUNTS" | tr ' ' '\n' | grep '^/' | cut -d: -f1); do
      echo "    $d"
    done
  fi
  [ -n "$PYTHONPATH_IN_CONTAINER" ] && ENV_VARS="$ENV_VARS -e PYTHONPATH=$PYTHONPATH_IN_CONTAINER"
fi

# ── Daemon-only mounts ───────────────────────────────────────────────
# Mount the host's ~/.ssh read-only so the container inherits the host's
# key-alias mapping from ~/.ssh/config. No config generation happens inside
# the container.
SSH_MOUNTS=""
if [ "$DAEMON_MODE" = true ] && [ -d "$HOME/.ssh" ]; then
  SSH_MOUNTS="-v $HOME/.ssh:/home/node/.ssh:ro"
fi

# Persistent project clones. Daemon-only so the interactive mode is unchanged.
#
# NOTE (evolvix#906): the /workspace/dispatch mount is NOT baked here anymore.
# Evolvix's Stage-2 host gate runs `sh <container_path>` on the HOST, which only
# works when the caller can declare BOTH sides of the mount (host source and
# container target may differ under docker-out-of-docker). Baking a default
# source==target here collided with the caller's explicit `-v` (docker
# last-wins, order-dependent). The caller (evolvix ensure_worker /
# `evolvix up`) now passes `-v <host_dir>:/workspace/dispatch` via -v
# passthrough (EXTRA_VOLUME_FLAGS below) as the single source of truth.
DISPATCH_MOUNTS=""
if [ "$DAEMON_MODE" = true ]; then
  DISPATCH_MOUNTS="-v $CLAUDE_PROJECTS_DIR:/workspace/projects"
fi

if [ "$DAEMON_MODE" = true ]; then
  # Seed hasTrustDialogAccepted for each project's IN-CONTAINER worktree path
  # so dispatched agents get their .claude/settings.local.json permission grants
  # (currently ~20 silently dropped per run with a "workspace has not been
  # trusted" warning). The container's /workspace/projects/<name> is a distinct
  # path from any host directory, so the entry doesn't shadow user config.
  # Skipped silently if jq or ~/.claude.json is absent (best-effort).
  if command -v jq >/dev/null 2>&1 && [ -f "$HOME/.claude.json" ] && [ -d "$CLAUDE_PROJECTS_DIR" ]; then
    for _proj in "$CLAUDE_PROJECTS_DIR"/*/; do
      [ -d "$_proj" ] || continue
      _pname="$(basename "$_proj")"
      _cpath="/workspace/projects/$_pname"
      _tmp="$(mktemp)"
      if jq --arg p "$_cpath" '.projects[$p].hasTrustDialogAccepted = true' \
             "$HOME/.claude.json" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$HOME/.claude.json"
      else
        rm -f "$_tmp"
        echo "WARN: could not seed hasTrustDialogAccepted for $_cpath" >&2
      fi
    done
  fi

  echo "==> Starting persistent Claude worker (container: $CLAUDE_CONTAINER_NAME)..."
  # --init installs tini (docker's built-in) as PID 1 to reap orphaned child
  # processes (evolvix#764). Without it, every git subprocess claude spawns
  # can become a defunct zombie reparented to `tail -f /dev/null` (which
  # doesn't reap), and the worker eventually crashes at startup on the next
  # dispatch (evolvix#776). Cheap: tini adds ~10KB, no runtime overhead.
  docker run -d \
    --name "$CLAUDE_CONTAINER_NAME" \
    --restart unless-stopped \
    --init \
    --add-host=host.docker.internal:host-gateway \
    $GPU_FLAG \
    -v "$HOME/.claude":/home/node/.claude \
    -v "$HOME/.claude":"$HOME/.claude" \
    --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
    -v "$HOME/.claude.json":/home/node/.claude.json \
    $ENV_MOUNTS \
    $PY_INTERP_MOUNTS \
    $PYTHONPATH_MOUNTS \
    $CUDA_MOUNT \
    $REQ_MOUNT \
    $LOCAL_MOUNTS \
    $KEY_MOUNTS \
    $RO_MOUNTS \
    $HOST_TOOL_MOUNTS \
    $SSH_MOUNTS \
    $DISPATCH_MOUNTS \
    $ENV_VARS \
    $ENV_FILE_FLAG \
    "${EXTRA_ENV_FLAGS[@]}" \
    "${EXTRA_VOLUME_FLAGS[@]}" \
    -e CLAUDE_DAEMON=1 \
    -e TERM=xterm-256color \
    -w /workspace \
    "$IMAGE_NAME" \
    tail -f /dev/null >/dev/null

  # Guarantee /workspace is owned by the runtime user (node, uid 1000) every
  # time we start. A bind mount inherits the host directory's ownership, which
  # is how /workspace came back root-owned after a reboot recreated the tmp
  # source (evolvix#697). Dockerfile-time chown is not enough — it applies to
  # the image, not to a mount that overlays it. `docker exec -u 0` bypasses
  # the image USER so this works whichever way the image was built.
  docker exec -u 0 "$CLAUDE_CONTAINER_NAME" \
    chown -R node:node /workspace >/dev/null 2>&1 || \
    echo "WARN: could not chown /workspace to node:node in $CLAUDE_CONTAINER_NAME" >&2

  # In link mode, point /opt/venv at the mounted host venv so the image's
  # baked PATH (/opt/venv/bin first) resolves to the working interpreter.
  # Before this: the 2026-07-18 base/overlay split (commit 6a55d98) dropped
  # python3 from Dockerfile.base; link mode mounted HOST_VENV at its own
  # absolute path but nothing extended PATH there, so `python3` fell through
  # to the Debian minimal `/usr/bin/python3` with no packages. Dispatched
  # runs then spent large chunks of their budget doing filesystem archaeology
  # to rediscover the working interpreter (evolvix#710, #742).
  if [ "$ENV_MODE" = "link" ] && [ -n "$HOST_VENV" ]; then
    docker exec -u 0 "$CLAUDE_CONTAINER_NAME" \
      ln -sfn "$HOST_VENV" /opt/venv >/dev/null 2>&1 || \
      echo "WARN: could not link /opt/venv -> $HOST_VENV in $CLAUDE_CONTAINER_NAME" >&2
    # Fail-loud preflight: prove `python3` in the container can actually import
    # a basic package. A silent failure here is what let this bug go unnoticed
    # for six days; an assertion at start turns it into an immediate error.
    #
    # Use a FUNCTIONAL check (`import numpy`) rather than a path check —
    # sys.prefix returns "/opt/venv" (the symlink itself, not the resolved
    # target), so the earlier `sys.prefix.startswith($HOST_VENV)` assertion
    # failed even when the environment was working. What actually matters
    # is that packages resolve; if a real ImportError fires, we're broken.
    if ! docker exec "$CLAUDE_CONTAINER_NAME" \
         python3 -c "import numpy, pytest" \
         >/dev/null 2>&1; then
      echo "ERROR: python3 in $CLAUDE_CONTAINER_NAME cannot import numpy/pytest;" >&2
      echo "       dispatched runs will burn tokens re-discovering the interpreter." >&2
      echo "       Check PATH (expected /opt/venv/bin first), the /opt/venv" >&2
      echo "       symlink, and that HOST_VENV=$HOST_VENV actually has these" >&2
      echo "       packages installed." >&2
      exit 1
    fi
  fi

  echo "Claude worker started (container: $CLAUDE_CONTAINER_NAME)"
  echo "  Projects:  /workspace/projects  (host: $CLAUDE_PROJECTS_DIR)"
  echo "  Dispatch:  /workspace/dispatch  (host: $CLAUDE_DISPATCH_DIR)"
  echo "  Stop with: $0 --stop"
  exit 0
fi

if [ "$NAME_EXPLICIT" = true ]; then
  INTERACTIVE_NAME="$CLAUDE_CONTAINER_NAME"
else
  # Keep the `claude-worker-*` namespace reserved for dispatcher workers
  # (that's what `evolvix up` and `make stop`'s name=claude-worker- filter
  # target). Interactive containers get `claude-<basename>` so they can't
  # shadow a designated worker.
  INTERACTIVE_NAME="claude-$(basename "$PROJECT_DIR")"
fi

echo "==> Starting Claude (env: ${ENV_MODE:-none})..."
exec docker run -it --rm \
  --name "$INTERACTIVE_NAME" \
  --network host \
  $GPU_FLAG \
  -v "$PROJECT_DIR":"$PROJECT_DIR" \
  $MAIN_REPO_MOUNT \
  -v "$HOME/.claude":/home/node/.claude \
  -v "$HOME/.claude":"$HOME/.claude" \
  --tmpfs /home/node/.claude/projects:uid=1000,gid=1000 \
  -v "$HOME/.claude/projects/$PROJECT_SLUG":/home/node/.claude/projects/$PROJECT_SLUG \
  -v "$HOME/.claude.json":/home/node/.claude.json \
  $ENV_MOUNTS \
  $PY_INTERP_MOUNTS \
  $PYTHONPATH_MOUNTS \
  $CUDA_MOUNT \
  $REQ_MOUNT \
  $LOCAL_MOUNTS \
  $KEY_MOUNTS \
  $RO_MOUNTS \
  $HOST_TOOL_MOUNTS \
  $ENV_VARS \
  $ENV_FILE_FLAG \
  "${EXTRA_ENV_FLAGS[@]}" \
  "${EXTRA_VOLUME_FLAGS[@]}" \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME"
