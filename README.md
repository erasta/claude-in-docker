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

### Python environment support
To expose your current Python environment inside the container:
```sh
claude-docker.sh --update_environment
```
This captures your host's `pip freeze` into `requirements.txt` and installs the packages in a persistent venv (`~/.claude-venv`). Packages are only reinstalled when `requirements.txt` changes, so subsequent starts are fast.

On later runs, just use `claude-docker.sh` — the venv persists. Re-run with `--update_environment` whenever you add new packages to your host environment.

## Is this safe?
The [script](claude-docker.sh) is short. If you're unsure, paste it into Claude and ask _"Is this script safe to run?"_
