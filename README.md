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
