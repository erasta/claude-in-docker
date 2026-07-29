#!/bin/bash
set -e

# ── Persistent worker container ──────────────────────────────────────
# Load optional user-wide config; sets CLAUDE_* env vars used below.
# Generate a template with `make docker-config`.
if [ -f "$HOME/.claude/docker.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/docker.env"
fi

# ── Capability contract (evolvix#931, reshaped by evolvix#935) ────────
# Two modes, mutually exclusive:
#   * contract (default) — read capabilities.conf, validate, apply exactly
#                          what it says. Two hosts, same file → equivalent
#                          containers.
#   * --auto             — pre-#931 behaviour (auto-detect GPU, --network
#                          host interactive, host tool passthrough for gh,
#                          $HOME/.ssh mount, cuda if present,
#                          set-environment-vars.conf, readonly-mounts.conf).
# Fail-closed: neither + no config → error. Both → error.
#
# v1 rewrite (#935): the launcher now has no built-in knowledge of gh /
# ssh / cuda — everything the container needs is declared under
# `resources:`. `readonly-mounts.conf` and `set-environment-vars.conf`
# are retired in contract mode (still honoured in --auto).
#
# Format (YAML subset, parsed by an embedded python3):
#   version: 1
#   capabilities:
#     gpu: nvidia            # nvidia | dri | kfd | none
#     network_mode: host     # host | bridge | none
#     python_mode: link      # link | copy
#   resources:
#     github:
#       cli: gh                                        # PATH-check on host
#       mounts:
#         - ~/.config/gh:/home/node/.config/gh:ro
#       env:                                           # names, never values
#         - GH_TOKEN
#         - GITHUB_TOKEN
#     ssh:
#       mounts:
#         - ${SSH_AUTH_SOCK}:/ssh-agent
#       env_set:                                       # non-secret literals
#         SSH_AUTH_SOCK: /ssh-agent

CAP_SUPPORTED_VERSIONS="1"

# capabilities_parse PATH
# Invokes an embedded python3 parser that produces shell assignments the
# caller sources. The parser handles:
#   * missing `version` → error, never a default
#   * unsupported `version` → error
#   * unknown top-level key → error (never silent)
#   * unknown key under `capabilities:` → error
#   * invalid enum value → error
#   * `~` / `${VAR}` expansion in mount paths
#   * mount source not present on host → error at parse time
#   * resource `cli:` not on host `PATH` → error at parse time
# Output shell variables:
#   CAP_gpu, CAP_network_mode, CAP_python_mode
#   RES_NAMES (space-separated list of resource names, order-stable)
#   For each name N:
#     RES_N_cli          (may be empty)
#     RES_N_mounts       (newline-separated host:container[:ro])
#     RES_N_env_keys     (space-separated env-var names to forward)
#     RES_N_env_set_keys (space-separated env_set keys)
#     RES_N_env_set_<K>  (one variable per env_set key)
capabilities_parse() {
  local path="$1"
  local shell_output
  if ! shell_output="$(python3 - "$path" <<'PYPARSE'
import os, re, shlex, sys, shutil

PATH = sys.argv[1]
SUPPORTED = {"1"}
CAP_KEYS = {"gpu", "network_mode", "python_mode"}
CAP_ALLOWED = {
    "gpu": {"nvidia", "dri", "kfd", "none"},
    "network_mode": {"host", "bridge", "none"},
    "python_mode": {"link", "copy"},
}
CAP_DEFAULTS = {"gpu": "none", "network_mode": "bridge", "python_mode": "link"}
RES_KEYS = {"cli", "mounts", "env", "env_set"}
TOP_KEYS = {"version", "capabilities", "resources"}

def die(msg):
    sys.stderr.write(f"ERROR: {PATH}: {msg}\n")
    sys.exit(2)

# Tiny indent-based YAML-subset parser. Supports:
#   key: value
#   key:
#     nested:
#       ...
#   list:
#     - item
#     - item
#   dict of scalars:
#     KEY: value

def parse(text):
    lines = []
    for raw in text.splitlines():
        # strip trailing comments (only when '#' follows whitespace or is at col 0)
        # but leave '#' inside quoted strings alone (we don't support quotes here)
        stripped = raw.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue
        # find inline # after two spaces (yaml convention)
        m = re.match(r"^(.*?)(\s{2,}#.*)?$", stripped)
        stripped = m.group(1).rstrip() if m else stripped
        if not stripped:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if "\t" in raw[:indent]:
            die(f"tab in indentation: {raw!r}")
        lines.append((indent, stripped.lstrip()))
    result, i = _parse_block(lines, 0, 0)
    return result

def _parse_block(lines, i, base_indent):
    """Parse a block at base_indent. Returns (value, next_i).
    Detects dict vs list from the first non-empty line at that indent."""
    if i >= len(lines):
        return None, i
    indent, first = lines[i]
    if indent < base_indent:
        return None, i
    if first.startswith("- "):
        return _parse_list(lines, i, indent)
    return _parse_dict(lines, i, indent)

def _parse_dict(lines, i, my_indent):
    out = {}
    while i < len(lines):
        indent, line = lines[i]
        if indent < my_indent:
            break
        if indent > my_indent:
            die(f"unexpected indent at line {line!r}")
        if ":" not in line:
            die(f"expected 'key: value' or 'key:', got: {line!r}")
        k, sep, v = line.partition(":")
        k = k.strip()
        v = v.strip()
        i += 1
        if v == "":
            # nested block
            nested, i = _parse_block(lines, i, my_indent + 1) if i < len(lines) and lines[i][0] > my_indent else ({}, i)
            # allow empty nested = {}
            out[k] = nested if nested is not None else {}
        else:
            out[k] = v
    return out, i

def _parse_list(lines, i, my_indent):
    out = []
    while i < len(lines):
        indent, line = lines[i]
        if indent < my_indent or not line.startswith("- "):
            break
        if indent > my_indent:
            die(f"unexpected list indent at {line!r}")
        item = line[2:].strip()
        out.append(item)
        i += 1
    return out, i

try:
    with open(PATH) as f:
        text = f.read()
except OSError as e:
    die(f"cannot read: {e}")

data = parse(text)
if not isinstance(data, dict):
    die("top-level must be a mapping")

# Unknown top-level key?
for k in data.keys():
    if k not in TOP_KEYS:
        die(f"unknown top-level key '{k}' (known: version, capabilities, resources)")

# version — required, must be supported
version = data.get("version")
if version is None:
    die(f"missing required 'version' key (supported: {sorted(SUPPORTED)})")
version = str(version)
if version not in SUPPORTED:
    die(f"unsupported version '{version}' (this launcher supports: {sorted(SUPPORTED)})")

# capabilities section
caps = data.get("capabilities") or {}
if not isinstance(caps, dict):
    die("`capabilities:` must be a mapping")
for k in caps.keys():
    if k not in CAP_KEYS:
        die(f"unknown key '{k}' under 'capabilities:' (known: {sorted(CAP_KEYS)})")
resolved_caps = {}
for k in CAP_KEYS:
    v = caps.get(k, CAP_DEFAULTS[k])
    if v not in CAP_ALLOWED[k]:
        die(f"capabilities.{k}: invalid value '{v}' (allowed: {sorted(CAP_ALLOWED[k])})")
    resolved_caps[k] = v

# resources section
resources = data.get("resources") or {}
if not isinstance(resources, dict):
    die("`resources:` must be a mapping")

def expand(s):
    return os.path.expanduser(os.path.expandvars(s))

def emit_var(name, value):
    print(f"{name}={shlex.quote(value)}")

emit_var("CAP_gpu", resolved_caps["gpu"])
emit_var("CAP_network_mode", resolved_caps["network_mode"])
emit_var("CAP_python_mode", resolved_caps["python_mode"])

resource_names = []
for name, spec in resources.items():
    if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_-]*$", name):
        die(f"invalid resource name '{name}' (must match [a-zA-Z_][a-zA-Z0-9_-]*)")
    if not isinstance(spec, dict):
        die(f"resource '{name}' must be a mapping")
    for k in spec.keys():
        if k not in RES_KEYS:
            die(f"resource '{name}': unknown key '{k}' (known: {sorted(RES_KEYS)})")

    cli = spec.get("cli", "")
    mounts_raw = spec.get("mounts", [])
    if isinstance(mounts_raw, dict):
        die(f"resource '{name}': `mounts:` must be a list, not a mapping")
    if not isinstance(mounts_raw, list):
        mounts_raw = [mounts_raw] if mounts_raw else []

    env_raw = spec.get("env", [])
    if isinstance(env_raw, dict):
        die(f"resource '{name}': `env:` must be a list of names, not a mapping (use env_set for literals)")
    if not isinstance(env_raw, list):
        env_raw = [env_raw] if env_raw else []

    env_set_raw = spec.get("env_set", {})
    if isinstance(env_set_raw, list):
        die(f"resource '{name}': `env_set:` must be a mapping, not a list")
    if not isinstance(env_set_raw, dict):
        die(f"resource '{name}': `env_set:` must be a mapping of key: literal")

    # env: names never carry values
    for v in env_raw:
        if "=" in str(v):
            die(f"resource '{name}': `env` items are NAMES only (found '{v}' — literals go under env_set)")

    # cli preconditon check — host PATH
    if cli:
        if shutil.which(cli) is None:
            die(f"resource '{name}': cli '{cli}' not found on host PATH (install it or drop the resource)")

    # mount validation — expand + check source exists
    expanded_mounts = []
    for m in mounts_raw:
        m = str(m)
        parts = m.split(":")
        if len(parts) < 2 or len(parts) > 3:
            die(f"resource '{name}': mount '{m}' must be host:container[:ro]")
        host = expand(parts[0])
        container = parts[1]
        mode = parts[2] if len(parts) == 3 else ""
        if mode and mode not in ("ro", "rw"):
            die(f"resource '{name}': mount '{m}': mode must be ro|rw|(empty), got '{mode}'")
        if not os.path.exists(host):
            die(f"resource '{name}': mount source not found on host: {host}")
        rendered = f"{host}:{container}" + (f":{mode}" if mode else "")
        expanded_mounts.append(rendered)

    resource_names.append(name)
    n = name.replace("-", "_")
    emit_var(f"RES_{n}_cli", cli)
    emit_var(f"RES_{n}_mounts", "\n".join(expanded_mounts))
    emit_var(f"RES_{n}_env_keys", " ".join(str(x) for x in env_raw))
    emit_var(f"RES_{n}_env_set_keys", " ".join(env_set_raw.keys()))
    for k, v in env_set_raw.items():
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            die(f"resource '{name}': env_set key '{k}' is not a valid env name")
        emit_var(f"RES_{n}_env_set_{k}", str(v))

emit_var("RES_NAMES", " ".join(resource_names))
PYPARSE
  )"; then
    exit 2
  fi
  eval "$shell_output"
}

# capabilities_apply_gpu
# Sets GPU_FLAG per CAP_gpu, errors if the host cannot satisfy it.
# Values (v1 rewrite): nvidia | dri | kfd | none.
#   nvidia — prefers the container runtime, falls back to /dev/nvidia* passthrough.
#   dri    — /dev/dri/renderD* (AMD or Intel).
#   kfd    — /dev/kfd (+ /dev/dri if present). ROCm.
#   none   — no GPU, regardless of host.
capabilities_apply_gpu() {
  local flags=""
  case "$CAP_gpu" in
    none)
      GPU_FLAG=""
      echo "==> GPU: disabled (capability: none)"
      ;;
    nvidia)
      if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
        GPU_FLAG="--gpus all"
        echo "==> GPU: NVIDIA container runtime (capability: nvidia)"
      else
        for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
          [ -c "$dev" ] && flags="$flags --device $dev"
        done
        if [ -n "$flags" ]; then
          GPU_FLAG="$flags"
          echo "==> GPU: NVIDIA device passthrough (capability: nvidia)"
        else
          echo "ERROR: capability 'gpu: nvidia' requested but no NVIDIA runtime or /dev/nvidia* devices found." >&2
          exit 2
        fi
      fi
      ;;
    dri)
      for dev in /dev/dri/renderD*; do
        [ -c "$dev" ] && flags="$flags --device $dev"
      done
      if [ -n "$flags" ]; then
        GPU_FLAG="$flags"
        echo "==> GPU: DRI render nodes (capability: dri)"
      else
        echo "ERROR: capability 'gpu: dri' requested but no /dev/dri/renderD* found." >&2
        exit 2
      fi
      ;;
    kfd)
      [ -c /dev/kfd ] || { echo "ERROR: capability 'gpu: kfd' requested but /dev/kfd not present." >&2; exit 2; }
      flags="--device /dev/kfd"
      for dev in /dev/dri/renderD*; do
        [ -c "$dev" ] && flags="$flags --device $dev"
      done
      GPU_FLAG="$flags"
      echo "==> GPU: AMD ROCm (capability: kfd)"
      ;;
  esac
}

# capabilities_apply_network
# Sets NETWORK_FLAG per CAP_network_mode. Applied uniformly to interactive
# and daemon paths (--auto keeps the old interactive=host / daemon=bridge
# split).
capabilities_apply_network() {
  case "$CAP_network_mode" in
    host)   NETWORK_FLAG="--network host" ;;
    bridge) NETWORK_FLAG="" ;;
    none)   NETWORK_FLAG="--network none" ;;
  esac
  echo "==> Network: $CAP_network_mode (capability)"
}

# capabilities_apply_resources
# Populates RESOURCE_MOUNTS (space-separated -v flags) and RESOURCE_ENV_FLAGS
# (space-separated -e flags: name-only forwards and key=value env_set writes).
# The parser already validated cli existence + mount sources; this just emits
# docker-cli arguments in a stable order.
#
# Note: env names go in as `-e NAME` (no value) — docker resolves the value
# from the launcher's environment at start time. env_set literals go in as
# `-e NAME=LITERAL`. Neither ever writes a value into capabilities.conf
# (README: `env:` carries names only; never write secrets to the file).
capabilities_apply_resources() {
  RESOURCE_MOUNTS=""
  RESOURCE_ENV_FLAGS=""
  RESOURCE_ENV_SET_LITERALS=()
  local name n mounts_var env_keys_var env_set_keys_var cli_var
  local mounts env_keys env_set_keys cli
  for name in $RES_NAMES; do
    n="${name//-/_}"
    cli_var="RES_${n}_cli";                cli="${!cli_var:-}"
    mounts_var="RES_${n}_mounts";          mounts="${!mounts_var:-}"
    env_keys_var="RES_${n}_env_keys";      env_keys="${!env_keys_var:-}"
    env_set_keys_var="RES_${n}_env_set_keys"; env_set_keys="${!env_set_keys_var:-}"
    echo "==> Resource: $name${cli:+ (cli: $cli)}"
    local m
    if [ -n "$mounts" ]; then
      while IFS= read -r m; do
        [ -z "$m" ] && continue
        RESOURCE_MOUNTS="$RESOURCE_MOUNTS -v $m"
        echo "    mount  $m"
      done <<< "$mounts"
    fi
    local k
    for k in $env_keys; do
      RESOURCE_ENV_FLAGS="$RESOURCE_ENV_FLAGS -e $k"
      echo "    env    $k (forwarded from launcher env)"
    done
    for k in $env_set_keys; do
      local vv_var="RES_${n}_env_set_${k}"
      local vv="${!vv_var:-}"
      RESOURCE_ENV_SET_LITERALS+=("-e" "$k=$vv")
      echo "    env_set $k=$vv"
    done
  done
}

# capabilities_generate — writes a capabilities.conf to stdout or --output PATH.
# Flags:
#   --output FILE            Write to FILE instead of stdout.
#   --interactive            Prompt for capabilities: values (not resources).
#   --gpu=VAL                capabilities.gpu
#   --network-mode=VAL       capabilities.network_mode
#   --python-mode=VAL        capabilities.python_mode
#   --resource NAME:cli=CLI,mount=H:C[:ro],mount=H2:C2,env=KEY,env=KEY2,env_set=K=V
#                            (repeatable) One resource declaration.
# Same effective inputs → byte-identical output. Downstream generators
# (Evolvix `project install`, #932) must produce files this launcher accepts;
# if a downstream generator disagrees, the launcher is correct.
capabilities_generate() {
  local output_file="" interactive=false
  local gen_gpu="none" gen_network="bridge" gen_python="link"
  local resource_specs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        [ -z "${2:-}" ] && { echo "ERROR: --output requires a value" >&2; exit 2; }
        output_file="$2"; shift 2
        ;;
      --interactive) interactive=true; shift ;;
      --gpu=*)          gen_gpu="${1#*=}"; shift ;;
      --network-mode=*) gen_network="${1#*=}"; shift ;;
      --python-mode=*)  gen_python="${1#*=}"; shift ;;
      --resource)
        [ -z "${2:-}" ] && { echo "ERROR: --resource requires a value" >&2; exit 2; }
        resource_specs+=("$2"); shift 2
        ;;
      *)
        echo "ERROR: --generate-capabilities: unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done

  if [ "$interactive" = true ]; then
    local ans
    printf "gpu [%s] (nvidia|dri|kfd|none): " "$gen_gpu" >&2
    read -r ans; [ -n "$ans" ] && gen_gpu="$ans"
    printf "network_mode [%s] (host|bridge|none): " "$gen_network" >&2
    read -r ans; [ -n "$ans" ] && gen_network="$ans"
    printf "python_mode [%s] (link|copy): " "$gen_python" >&2
    read -r ans; [ -n "$ans" ] && gen_python="$ans"
  fi

  # Validate capabilities values against the parser's enum.
  case "$gen_gpu"     in nvidia|dri|kfd|none) ;; *) echo "ERROR: --gpu: invalid value '$gen_gpu' (allowed: nvidia|dri|kfd|none)" >&2; exit 2 ;; esac
  case "$gen_network" in host|bridge|none)   ;; *) echo "ERROR: --network-mode: invalid value '$gen_network' (allowed: host|bridge|none)" >&2; exit 2 ;; esac
  case "$gen_python"  in link|copy)          ;; *) echo "ERROR: --python-mode: invalid value '$gen_python' (allowed: link|copy)" >&2; exit 2 ;; esac

  # Emit via python for deterministic ordering + escaping.
  local generated
  if ! generated="$(python3 - "$gen_gpu" "$gen_network" "$gen_python" "${resource_specs[@]}" <<'PYGEN'
import sys, re

gpu, net, pymode = sys.argv[1], sys.argv[2], sys.argv[3]
resource_specs = sys.argv[4:]

def die(m):
    sys.stderr.write(f"ERROR: --generate-capabilities: {m}\n")
    sys.exit(2)

# Parse: NAME:cli=CLI,mount=H:C[:ro],mount=H2:C2,env=KEY,env_set=K=V
resources = []
for spec in resource_specs:
    if ":" not in spec:
        die(f"--resource '{spec}' — missing NAME: prefix")
    name, _, body = spec.partition(":")
    name = name.strip()
    if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_-]*$", name):
        die(f"--resource '{spec}' — invalid name '{name}'")
    cli = ""
    mounts = []
    envs = []
    env_set = []
    # Fields comma-separated; a mount value may contain colons but not commas
    # (paths with commas are not supported — file an issue if you need this).
    for field in body.split(","):
        field = field.strip()
        if not field:
            continue
        if "=" not in field:
            die(f"--resource '{spec}' — field '{field}' must be key=value")
        k, _, v = field.partition("=")
        k = k.strip(); v = v.strip()
        if k == "cli":
            cli = v
        elif k == "mount":
            mounts.append(v)
        elif k == "env":
            if "=" in v:
                die(f"--resource '{spec}' — env values are NAMES only (found '{v}')")
            envs.append(v)
        elif k == "env_set":
            if "=" not in v:
                die(f"--resource '{spec}' — env_set needs K=V (got '{v}')")
            env_set.append(v)
        else:
            die(f"--resource '{spec}' — unknown field '{k}' (allowed: cli, mount, env, env_set)")
    resources.append((name, cli, mounts, envs, env_set))

lines = [
    "# capabilities.conf — see README (\"Capability contract\").",
    "# Generated by: claude-docker.sh --generate-capabilities",
    "version: 1",
    "capabilities:",
    f"  gpu: {gpu}",
    f"  network_mode: {net}",
    f"  python_mode: {pymode}",
]
if resources:
    lines.append("resources:")
    for name, cli, mounts, envs, env_set in resources:
        lines.append(f"  {name}:")
        if cli:
            lines.append(f"    cli: {cli}")
        if mounts:
            lines.append("    mounts:")
            for m in mounts:
                lines.append(f"      - {m}")
        if envs:
            lines.append("    env:")
            for e in envs:
                lines.append(f"      - {e}")
        if env_set:
            lines.append("    env_set:")
            for kv in env_set:
                k, _, v = kv.partition("=")
                lines.append(f"      {k}: {v}")
print("\n".join(lines))
PYGEN
  )"; then
    exit 2
  fi

  if [ -n "$output_file" ]; then
    printf '%s\n' "$generated" > "$output_file"
    echo "Wrote $output_file" >&2
  else
    printf '%s\n' "$generated"
  fi
}

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
AUTO_MODE=false
CAPABILITIES_FILE=""
CAPABILITIES_FILE_EXPLICIT=false
# Initialized here so --auto (which never calls capabilities_apply_resources)
# still expands them safely in the docker run arg list.
RESOURCE_MOUNTS=""
RESOURCE_ENV_FLAGS=""
RESOURCE_ENV_SET_LITERALS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)               AUTO_MODE=true; shift ;;
    --capabilities-file)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --capabilities-file requires a value" >&2
        exit 2
      fi
      CAPABILITIES_FILE="$2"
      CAPABILITIES_FILE_EXPLICIT=true
      shift 2
      ;;
    --generate-capabilities)
      shift
      capabilities_generate "$@"
      exit 0
      ;;
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

Capability contract (evolvix#931, reshaped by #935):
  The launcher runs in one of two mutually exclusive modes.
  --stop and --status are unaffected.

  --auto                Pre-#931 behaviour: auto-detect GPU, --network host
                        interactive, mount host gh + ~/.ssh (daemon) + CUDA,
                        read set-environment-vars.conf / readonly-mounts.conf.
                        Fast for one-off runs; NOT deterministic across hosts.
  (default)             Contract mode. Reads capabilities.conf in the current
                        directory (override with --capabilities-file).
                        Nothing is assumed — the launcher has NO built-in
                        knowledge of gh, ssh, cuda, or any other resource.
                        Everything the container needs is declared under
                        `resources:` (an open-ended, named bag of mounts +
                        env forwards + optional cli precondition-checks).
                        No file + no --auto → error. Both → error.

  --capabilities-file FILE
                        Read capabilities from FILE instead of ./capabilities.conf.
  --generate-capabilities [--output FILE] [--interactive]
                        [--gpu=VAL] [--network-mode=VAL] [--python-mode=VAL]
                        [--resource NAME:field=value,field=value ...]  (repeatable)
                        Emit a valid capabilities.conf. Prints to stdout unless
                        --output is given. Same effective inputs → byte-identical
                        output. This CLI is the reference implementation of
                        the format; downstream generators (Evolvix `project
                        install`, #932) must produce files this launcher accepts.

  Format (v1 rewrite, #935):
    version: 1
    capabilities:
      gpu: nvidia            # nvidia | dri | kfd | none        [default: none]
      network_mode: host     # host | bridge | none             [default: bridge]
      python_mode: link      # link | copy                      [default: link]
    resources:
      <operator-chosen name>:      # `github`, `cuda`, `ssh`, `hf_cache`, …
        cli: gh                    # optional; host-PATH check at start
        mounts:
          - <host>:<container>[:ro]     # supports ~ and ${VAR}
        env:                       # NAMES only — literals go under env_set
          - GH_TOKEN
          - GITHUB_TOKEN
        env_set:                   # non-secret literals only
          KEY: literal_value

  Resource name is an operator label — the launcher does not recognise it.
  Adding a new resource (`hf_cache: { mounts: [~/.cache/hf:/root/.cache/hf] }`)
  needs NO launcher change. `readonly-mounts.conf` and `set-environment-vars.conf`
  are retired in contract mode (still honoured under --auto for migration).

  DO NOT commit tokens to capabilities.conf. `env:` forwards by name from the
  launcher's environment; docker never sees the value in argv. `env_set:` is
  for non-secret literals only (paths, flags), not credentials.

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

API keys and secrets (--auto only, retired in contract mode):
  Under --auto: set-environment-vars.conf in the project directory lists
  files to mount, one per line (relative or absolute paths):
    setOpenAIKey.sh
    setOpenRouterKey.sh
    /etc/mycompany/env.sh
  .sh files are sourced at startup; all other files are mounted read-only
  at /home/node/api-keys/<basename> but not sourced.
  Contract mode equivalent: `resources: { openai: { mounts: [...], env: [OPENAI_API_KEY] } }`
  (source the key script in your host shell before running so the env var
  can be forwarded by name).
  Never commit secret files to git.

Read-only mounts (--auto only, retired in contract mode):
  Under --auto: readonly-mounts.conf lists host paths (files or directories)
  to mount read-only at the SAME path inside the container, one per line.
  Looked up in the project directory first, then in the script directory
  (global default). Both files are read and merged. Supports ~, # comments.
  Contract mode equivalent: any `resources: { <name>: { mounts: [...] } }`
  entry — a named resource IS a bag of mounts.

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

# ── Mode resolution (evolvix#931) ────────────────────────────────────
# Contract mode vs --auto vs error. --stop/--status skip this entirely
# (they don't start a container).
if [ "$STOP_MODE" != true ] && [ "$STATUS_MODE" != true ]; then
  if [ -z "$CAPABILITIES_FILE" ]; then
    CAPABILITIES_FILE="$PWD/capabilities.conf"
  fi
  if [ "$AUTO_MODE" = true ] && [ -f "$CAPABILITIES_FILE" ] && [ "$CAPABILITIES_FILE_EXPLICIT" = true ]; then
    echo "ERROR: --auto and --capabilities-file are mutually exclusive." >&2
    exit 2
  fi
  if [ "$AUTO_MODE" = true ] && [ -f "$CAPABILITIES_FILE" ] && [ "$CAPABILITIES_FILE_EXPLICIT" = false ]; then
    echo "ERROR: --auto passed but a capabilities.conf is present at $CAPABILITIES_FILE." >&2
    echo "       These are mutually exclusive. Remove the file, or drop --auto." >&2
    exit 2
  fi
  if [ "$AUTO_MODE" = false ] && [ ! -f "$CAPABILITIES_FILE" ]; then
    echo "ERROR: no capabilities.conf found at $CAPABILITIES_FILE." >&2
    echo "       Pass --auto to use host auto-detection (previous behaviour)," >&2
    echo "       or generate a config: claude-docker.sh --generate-capabilities --output capabilities.conf" >&2
    echo "       See README (\"Capability contract\") for the format." >&2
    exit 2
  fi
  if [ "$AUTO_MODE" = false ]; then
    echo "==> Reading capabilities: $CAPABILITIES_FILE"
    capabilities_parse "$CAPABILITIES_FILE"
  fi
fi

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

# ── Legacy conf discovery (--auto only, evolvix#935) ─────────────────
# `set-environment-vars.conf` and `readonly-mounts.conf` are retired in
# contract mode; the operator declares equivalents under `resources:`
# (which is a strict superset with named toggles). --auto still honours
# both so pre-#931 invocations keep working.
KEY_FILES=()
KEY_MOUNTS=""
KEY_PATHS_IN_CONTAINER=""
RO_PATHS=()
RO_MOUNTS=""
if [ "$AUTO_MODE" = true ]; then
  API_KEYS_CONF="$PWD/set-environment-vars.conf"
  if [ -f "$API_KEYS_CONF" ]; then
    CONF_DIR="$(cd "$(dirname "$API_KEYS_CONF")" && pwd)"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      line="${line/#\~/$HOME}"
      if [[ "$line" != /* ]]; then
        line="$CONF_DIR/$line"
      fi
      KEY_FILES+=("$line")
    done < "$API_KEYS_CONF"
  fi
  for keyfile in "${KEY_FILES[@]}"; do
    if [ -f "$keyfile" ]; then
      basename_key="$(basename "$keyfile")"
      KEY_MOUNTS="$KEY_MOUNTS -v $keyfile:/home/node/api-keys/$basename_key:ro"
      KEY_PATHS_IN_CONTAINER="$KEY_PATHS_IN_CONTAINER /home/node/api-keys/$basename_key"
    else
      echo "==> Warning: key file not found: $keyfile"
    fi
  done
  if [ -n "$KEY_PATHS_IN_CONTAINER" ]; then
    echo "==> API keys: $(echo $KEY_PATHS_IN_CONTAINER | tr ' ' '\n' | xargs -I{} basename {} | tr '\n' ' ')"
  fi

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

# Determine env mode. Contract mode (evolvix#935): `capabilities.python_mode`
# forces it; passing --link_environment / --copy_environment alongside a
# capabilities.conf is an error (the contract is deterministic — CLI overrides
# would reintroduce the silent-inheritance pattern #931 exists to remove).
# --auto: fall back to the pre-#931 detection (link if host has python, else
# copy if requirements.txt exists).
if [ "$AUTO_MODE" = false ]; then
  if [ -n "$ENV_MODE" ] && [ "$ENV_MODE" != "$CAP_python_mode" ]; then
    echo "ERROR: --${ENV_MODE}_environment conflicts with capabilities.python_mode=$CAP_python_mode." >&2
    echo "       In contract mode the capability wins. Drop the CLI flag or update the config." >&2
    exit 2
  fi
  ENV_MODE="$CAP_python_mode"
elif [ -z "$ENV_MODE" ]; then
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
if [ "$AUTO_MODE" = true ]; then
  # --auto path: preserve the pre-#931 auto-detection byte-equivalent.
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
else
  # Contract mode (evolvix#935): apply the requested GPU capability and
  # emit `-v`/`-e` flags for every declared resource. Overlays are no
  # longer capabilities — they're image labels a caller can inspect but
  # the launcher does not require. Under the v1-rewrite `resources:`
  # model, everything the container needs (gh, ssh, cuda, huggingface,
  # …) is a resource entry, not a hardcoded launcher behaviour.
  capabilities_apply_gpu
  capabilities_apply_resources
fi

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

# Mount host tools into a guaranteed-in-PATH location.
# Under the v1-rewrite `resources:` model (#935), `gh` is NOT a launcher
# assumption — declare it as a resource (mount host `gh` into the
# container). --auto keeps the pre-#931 unconditional passthrough.
HOST_TOOL_MOUNTS=""
if [ "$AUTO_MODE" = true ]; then
  for tool in gh; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] && HOST_TOOL_MOUNTS="$HOST_TOOL_MOUNTS -v $tool_path:/usr/local/bin/$tool:ro"
  done
fi

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

# Mount host CUDA toolkit if present.
# Under contract mode (#935) CUDA is NOT auto-mounted — declare it as a
# resource: `cuda: { mounts: [/usr/local/cuda:/usr/local/cuda:ro], env: [CUDA_HOME] }`.
# --auto keeps the pre-#931 unconditional mount.
CUDA_MOUNT=""
if [ "$AUTO_MODE" = true ] && [ -d /usr/local/cuda ]; then
  CUDA_MOUNT="-v /usr/local/cuda:/usr/local/cuda:ro"
fi

# Mount each host PYTHONPATH directory read-only at the same path so dev
# packages (e.g. editable installs activated via `export PYTHONPATH=...`)
# resolve inside the container. Dirs already covered by other mounts
# (project, main repo, host venv) are skipped to avoid double-mount.
PYTHONPATH_MOUNTS=""
PYTHONPATH_IN_CONTAINER=""
# Contract mode: PYTHONPATH forwarding is intrinsic to `python_mode: link`
# (the container reads packages from the host venv, so its dev-package
# imports need the same host paths). `python_mode: copy` isolates via a
# baked venv → no host PYTHONPATH forwarding. --auto keeps the pre-#931
# forward-if-set behaviour.
if [ "$AUTO_MODE" = false ] && [ "${CAP_python_mode:-link}" != "link" ]; then
  :  # skip
elif [ -n "${PYTHONPATH:-}" ]; then
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
# key-alias mapping from ~/.ssh/config.
#
# Under contract mode (#935) the launcher does not touch ~/.ssh — declare
# it as a resource: `ssh: { mounts: [~/.ssh:/home/node/.ssh:ro] }` (or
# `ssh: { mounts: [${SSH_AUTH_SOCK}:/ssh-agent], env_set: {SSH_AUTH_SOCK: /ssh-agent} }`
# for agent forwarding). --auto keeps the pre-#931 automatic mount.
SSH_MOUNTS=""
if [ "$AUTO_MODE" = true ] && [ "$DAEMON_MODE" = true ] && [ -d "$HOME/.ssh" ]; then
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

# ── Network flag ─────────────────────────────────────────────────────
# --auto reproduces pre-#931 behaviour: interactive gets --network host,
# daemon defaults to bridge. Contract mode applies CAP_network_mode
# uniformly to both paths (default `bridge`, so an interactive user who
# relies on `localhost` MUST set `network_mode: host` in the config —
# breaking change on day 1, documented in README).
NETWORK_FLAG_INTERACTIVE=""
NETWORK_FLAG_DAEMON=""
if [ "$AUTO_MODE" = true ]; then
  NETWORK_FLAG_INTERACTIVE="--network host"
  NETWORK_FLAG_DAEMON=""
else
  capabilities_apply_network
  NETWORK_FLAG_INTERACTIVE="$NETWORK_FLAG"
  NETWORK_FLAG_DAEMON="$NETWORK_FLAG"
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
    $NETWORK_FLAG_DAEMON \
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
    $RESOURCE_MOUNTS \
    $RESOURCE_ENV_FLAGS \
    "${RESOURCE_ENV_SET_LITERALS[@]}" \
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
  $NETWORK_FLAG_INTERACTIVE \
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
  $RESOURCE_MOUNTS \
  $RESOURCE_ENV_FLAGS \
  "${RESOURCE_ENV_SET_LITERALS[@]}" \
  $ENV_VARS \
  $ENV_FILE_FLAG \
  "${EXTRA_ENV_FLAGS[@]}" \
  "${EXTRA_VOLUME_FLAGS[@]}" \
  -e TERM=xterm-256color \
  -w "$PROJECT_DIR" \
  "$IMAGE_NAME"
