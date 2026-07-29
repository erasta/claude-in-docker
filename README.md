# claude-in-docker
Run Claude Code in a Docker container so it can't touch your system. Per-project memory is preserved between sessions.

## Prerequisites
- Docker ([install instructions](https://docs.docker.com/get-docker/))
- Run `claude` once anywhere to log in (this creates `~/.claude.json`)

## Install (linux/mac)
```sh
git clone https://github.com/erasta/claude-in-docker.git
chmod +x claude-in-docker/claude-docker.sh
echo 'export PATH="$PATH:'"$PWD/claude-in-docker"'"' >> ~/.bashrc
source ~/.bashrc
```

## Usage
From any project directory:
```sh
claude-docker.sh
```

Run `claude-docker.sh --help` for the full flag list.

## Capability contract

Since [evolvix#931](https://github.com/yehudarav/Evolvix/issues/931) the launcher runs in **one of two mutually exclusive modes**:

- **contract mode** (default) — reads a versioned `capabilities.conf` in the current directory and applies exactly what it says. Two hosts with the same file get equivalent containers. Missing or invalid keys are errors, never silent defaults.
- **`--auto` mode** — the pre-#931 behaviour (auto-detect GPU, hardcoded `--network host` interactive, PYTHONPATH forwarding when `$PYTHONPATH` is set). Fast for one-off runs; not deterministic across hosts.

Neither present → error. Both present → error. `--stop` / `--status` bypass the check.

### Migration

If you were running `claude-docker.sh` before #931 and want the old behaviour:

```sh
claude-docker.sh --auto
```

To adopt the contract, generate a config:

```sh
claude-docker.sh --generate-capabilities --output capabilities.conf --gpu=nvidia --network-mode=host
```

Interactive users who relied on `localhost` reaching the host **must** set `network_mode: host` in the config — contract mode defaults to `bridge` on all paths.

### The format (v1)

```
version: 1
gpu: nvidia
network_mode: host
pythonpath_forward: false
latex: false
python_sci: false
ollama: false
```

- `version:` **required**. Missing → error, unsupported → error (never a default).
- Unknown keys → error (never silent).
- Requested-but-unavailable capability → error at container start, naming what's missing.

Keys and accepted values:

| Key | Values | Default | Notes |
|---|---|---|---|
| `version` | `1` | — | Required. |
| `gpu` | `none` \| `nvidia` \| `nvidia-runtime` \| `nvidia-passthrough` \| `amd` \| `intel` | `none` | `nvidia` prefers the container runtime, falls back to device passthrough. Errors if neither is present on the host. |
| `network_mode` | `host` \| `bridge` \| `none` | `bridge` | Applied uniformly to interactive and daemon paths. |
| `pythonpath_forward` | `true` \| `false` | `false` | When `true` and `$PYTHONPATH` is set on the host, each directory is bind-mounted read-only at the same path and `PYTHONPATH` is forwarded. |
| `latex` | `true` \| `false` | `false` | Requires the LaTeX overlay (`make docker-add-latex`, adds label `claude.overlay.latex=1`). |
| `python_sci` | `true` \| `false` | `false` | Requires the python-sci overlay (`make docker-add-python-sci`, label `claude.overlay.python-sci=1`). |
| `ollama` | `true` \| `false` | `false` | Requires the ollama overlay (`make docker-add-ollama`, label `claude.overlay.ollama=1`). |

Deferred to a later version (currently unconditional): CUDA toolkit mount, SSH forwarding (daemon-only), host `gh` passthrough. File an issue if you need these as capabilities.

### Discovery

Contract mode looks up the config in **one place only**:

1. `--capabilities-file PATH` if given, else
2. `./capabilities.conf` in the current directory.

There is no merge with a global default. That is deliberate — the whole point is that two hosts with the same file produce equivalent containers.

### Image overlay labels

Overlays declare their presence with a Docker image label:

| Overlay | Label |
|---|---|
| LaTeX | `claude.overlay.latex=1` |
| python-sci | `claude.overlay.python-sci=1` |
| ollama | `claude.overlay.ollama=1` |

The launcher inspects the image and errors if `capabilities.conf` requests an overlay whose label isn't present. Inspect what's baked into your image:

```sh
docker image inspect claude-code-env --format '{{json .Config.Labels}}' | jq
```

### Generator CLI

The launcher itself is the reference implementation of the format:

```sh
# Flag-driven
claude-docker.sh --generate-capabilities \
  --gpu=nvidia --network-mode=host --pythonpath-forward=false \
  --latex --output capabilities.conf

# Interactive prompt for each key
claude-docker.sh --generate-capabilities --interactive --output capabilities.conf

# Print to stdout instead of writing a file
claude-docker.sh --generate-capabilities --gpu=none
```

For the same effective inputs both paths produce byte-identical output — that IS the contract.

Downstream generators (e.g. Evolvix's `project install`) must produce files this launcher accepts. If a downstream generator disagrees with `claude-docker.sh --generate-capabilities`, the launcher is correct.

### Tests

```sh
bash tests/test_capabilities.sh
```

Exercises the contract's error paths (missing/unknown/unsupported/malformed), the round-trip (generator → parser), and generator determinism. Does not start any container.

## Python environment

Two modes, chosen at startup:

| Mode | When to use | How |
|---|---|---|
| `--link_environment` (default) | Host has Python installed; you want zero install time | Mounts host site-packages read-only at `/opt/host-site-packages`. All projects share the same packages. |
| `--copy_environment` | You need isolation, or the host has no Python | Builds a persistent venv at `~/.claude-venv`, installs from `requirements.txt`. Only reinstalls when the file changes. |

Snapshot the current host environment into `requirements.txt` before launching:
```sh
claude-docker.sh --update_environment                       # snapshot, then link
claude-docker.sh --update_environment --copy_environment    # snapshot, then copy
```

If neither flag is passed, the script picks `link` when the host has Python, else `copy` when a `requirements.txt` exists, else no env setup.

### Editable installs and `PYTHONPATH`

If your host shell exports `PYTHONPATH` (e.g. dev packages activated via `export PYTHONPATH=/path/to/pkg:$PYTHONPATH`), each existing directory is mounted into the container read-only at the same path, and `PYTHONPATH` is forwarded so `import` resolves there. Directories already covered by other mounts (project, main repo, host venv) stay in `PYTHONPATH` but aren't re-mounted.

No-op when `PYTHONPATH` is unset.

## API keys and secrets

Create `set-environment-vars.conf` in your project directory listing files to mount into the container. One path per line — absolute, relative, or `~`-prefixed:

```
setOpenAIKey.sh
setOpenRouterKey.sh
/etc/mycompany/env.sh
~/.claude-docker-keys/github_ed25519
```

How it works:
- `.sh` files are **sourced** at startup, so any `export KEY=value` lines become env vars inside the container.
- Non-`.sh` files (PEM keys, certs, plain configs) are **mounted read-only** at `/home/node/api-keys/<basename>` but not sourced.
- The `.conf` file itself is safe to commit. **The listed files are not** — keep them outside your repo.

Example `setOpenAIKey.sh`:
```sh
export OPENAI_API_KEY=sk-...
```

### GitHub SSH push from inside the container

Without exposing all of `~/.ssh`, give the container its own SSH key for GitHub:

```sh
mkdir -p ~/.claude-docker-keys
ssh-keygen -t ed25519 -f ~/.claude-docker-keys/github_ed25519 -N "" -C "claude-docker"
```

Add `~/.claude-docker-keys/github_ed25519.pub` to your GitHub SSH keys.

Create `~/.claude-docker-keys/setup-github-ssh.sh`:
```sh
export GIT_SSH_COMMAND="ssh -i /home/node/api-keys/github_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
```

Add both to your project's `set-environment-vars.conf`:
```
~/.claude-docker-keys/github_ed25519
~/.claude-docker-keys/setup-github-ssh.sh
```

The key is mounted (not sourced) and the helper script is sourced to point `git` at it. The rest of your `~/.ssh` is never visible to the container.

## Read-only mounts

Some host-installed tools need their config or data directory to be present on disk to work (e.g. a library that reads `~/.toolname/config.sys` on import). To make those visible inside the container without copying or exposing the whole home directory, create `readonly-mounts.conf` listing host paths — one per line, absolute, relative, or `~`-prefixed:

```
~/.pyhera
~/.config/myapp
/etc/somecfg
data/shared
```

Each existing entry (file or directory) is bind-mounted **read-only at the same absolute path** inside the container, so imports and lookups using that path resolve unchanged. Missing paths print a warning and are skipped.

Lookup order:
1. `./readonly-mounts.conf` in the project directory
2. `<claude-docker.sh dir>/readonly-mounts.conf` (global default)

Both files are read and merged, with duplicates skipped. Use the global one for stable per-user state (`~/.pyhera`, dotfile dirs) and the project one for paths only one project needs. `#` lines and blanks are ignored.

## GPU support

The script auto-detects what's available and passes it through:

- **NVIDIA via container runtime** — used when `nvidia-container-toolkit` is registered with Docker. Best path.
- **NVIDIA via device passthrough** — fallback when devices exist but the toolkit isn't installed. The script prints a hint to run `./setup-gpu.sh` (Debian/Ubuntu installer for `nvidia-container-toolkit`).
- **AMD ROCm** — passes through `/dev/dri/renderD*` and `/dev/kfd`.
- **Intel** — passes through `/dev/dri/renderD*`.

No flags needed. The detected path is printed at startup.

## Git worktrees

If you run from a `git worktree`, the script detects it via `git rev-parse --git-common-dir` and also mounts the main repo at the same absolute path. This lets `git` inside the container read shared object data — commits, pushes, log, and blame all work normally.

No-op when not in a worktree.

## Host tools

`gh` is mounted from the host into the container (resolved via `command -v`), so the container picks up whichever install you already have. `git` is installed in the image.

## Make targets

`make help` prints all targets. Quick reference:

| Target | What it does |
|---|---|
| `make docker-config` | Generate `~/.claude/docker.env` template (chmod 600). If it exists, print a diff of missing keys. |
| `make docker-build` | Build the base image (`claude`, `git`, `gh`, `node`). |
| `make docker-add-latex` | Layer TeX Live 2026 + latexmk onto the image. |
| `make docker-add-python-sci` | Layer `python3` + numpy/scipy/matplotlib/pandas onto the image. |
| `make docker-add-ollama` | Layer the ollama client onto the image. |
| `make docker-run` | Wrapper for `./claude-docker.sh` (interactive). |
| `make docker-daemon` / `docker-status` / `docker-stop` | Persistent worker lifecycle. |
| `make docker-clean` | Stop the worker and remove the image + derived containers. |

## Persistent worker mode

`./claude-docker.sh --daemon` starts a long-lived worker container that a dispatcher (MCP server, cron, etc.) can drive via `docker exec`. Interactive mode is unchanged — the same script handles both.

Configuration lives in `~/.claude/docker.env` (generate with `make docker-config`) or the environment. All `CLAUDE_*` vars have generic defaults:

| Env var | Default | Purpose |
|---|---|---|
| `CLAUDE_CONTAINER_NAME` | `claude-worker` | Container name (must match the dispatcher's config). |
| `CLAUDE_PROJECTS_DIR` | `$HOME/claude-projects` | Persistent project clones; mounted at `/workspace/projects`. |
| `CLAUDE_DISPATCH_DIR` | `/tmp/claude-dispatch` | Per-dispatch worktrees; mounted at `/workspace/dispatch`. |
| `CLAUDE_MCP_HOST` | `host.docker.internal` | MCP server hostname (added via Docker's `--add-host=…:host-gateway`). |
| `CLAUDE_MCP_PORT` | `8765` | MCP server port. |

Daemon mode also:
- Mounts `$HOME/.ssh:/home/node/.ssh:ro`, so the container inherits the host's `~/.ssh/config` alias → key mapping. Use aliases in repo URLs (e.g. `git@github-foo:org/repo.git`).
- Adds `--add-host=host.docker.internal:host-gateway`, so `http://host.docker.internal:$CLAUDE_MCP_PORT/mcp` reaches an MCP server running on the host.
- Does **not** set git identity. The dispatcher injects it per-dispatch: `docker exec -e GIT_AUTHOR_NAME=… -e GIT_COMMITTER_NAME=… -e GIT_AUTHOR_EMAIL=… -e GIT_COMMITTER_EMAIL=… claude-worker claude "…"`.
- In link mode, symlinks `/opt/venv → $HOST_VENV` inside the container after startup, so the image's baked `PATH=/opt/venv/bin:$PATH` resolves to the working interpreter. Runs a fail-loud preflight (`python3 -c "assert sys.prefix.startswith($HOST_VENV)"`) and exits 1 with an actionable error if the environment is broken — a silent Python-env regression once cost ~1–2 h per dispatched run in filesystem archaeology (see `evolvix#710`/`#742`).
- Seeds `hasTrustDialogAccepted: true` in the shared `~/.claude.json` for every project's in-container path (`/workspace/projects/<name>`), so dispatched agents get their `.claude/settings.local.json` permission grants. Skipped silently if `jq` isn't installed on the host.

### Overriding the Python environment (`HOST_VENV`)

In link mode, the script auto-detects the active host venv via `python3 -c "import sys; print(sys.prefix if sys.prefix != sys.base_prefix else '')"`. For an atypical layout (a venv at a non-standard path, or wanting to force a specific one), export before `--daemon`:

```sh
HOST_VENV=/opt/my-project-venv ./claude-docker.sh --daemon
```

The value is same-path bind-mounted read-only into the container. Machine-specific overrides belong in a gitignored `env.local.sh` or `~/.claude/docker.env` rather than the tracked repo. The daemon's preflight will refuse to start if the resulting `python3` doesn't resolve inside `$HOST_VENV`.

Lifecycle:

```sh
./claude-docker.sh --daemon    # start (idempotent — reports "already running")
./claude-docker.sh --status    # exit 0 if running, 1 otherwise
./claude-docker.sh --stop
```

## Optional image features

The base image (`make docker-build`) is deliberately minimal — `claude`, `git`, `gh`, `node`, plus runtime `.so` deps. Heavy dependencies are separate overlays that layer on top:

```sh
make docker-add-latex         # TeX Live 2026 (~4 GB)
make docker-add-python-sci    # python3 + numpy/scipy/matplotlib/pandas
make docker-add-ollama        # ollama client
```

Each overlay re-tags `claude-code-env` with the new layer on top of the current tag, so they compose. `make docker-build` rebuilds from the base Dockerfile and discards prior overlays.

`./claude-docker.sh` **skips the build if the image already exists**, so overlays persist across interactive runs. To force a rebuild, run `make docker-build`.

## Troubleshooting

**`make docker-add-*` fails with "Base image not built"**
Run `make docker-build` first.

**Container can't reach the MCP server at `host.docker.internal`**
Daemon mode adds `--add-host=host.docker.internal:host-gateway` automatically. On Linux this requires Docker Engine ≥ 20.10. Interactive mode uses `--network host`, so use `localhost` there instead.

**SSH push fails inside the daemon container**
`~/.ssh` is mounted read-only. Ensure your host `~/.ssh/config` uses relative (`~/.ssh/…`) or container-path (`/home/node/.ssh/…`) `IdentityFile` entries — absolute host paths that don't exist inside the container won't resolve.

**Overlays got wiped after running `./claude-docker.sh`**
Shouldn't happen — the script skips the build when the image exists. If it did, check `docker image ls claude-code-env` and re-run the relevant `make docker-add-*` targets.

## Is this safe?
The [script](claude-docker.sh) is short. If you're unsure, paste it into Claude and ask _"Is this script safe to run?"_
