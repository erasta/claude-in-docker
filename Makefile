SHELL := /bin/bash

CLAUDE_DIR    := $(HOME)/.claude
CONFIG_FILE   := $(CLAUDE_DIR)/docker.env
IMAGE_NAME    := claude-code-env
SCRIPT_DIR    := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@printf '\nClaude Docker Development Environment\n'
	@printf '======================================\n\n'
	@awk 'BEGIN {section=""} \
	  /^# ── / { \
	    sub(/^# ── /,""); sub(/ ─+.*$$/,""); \
	    section = $$0; \
	    printf "\n%s:\n", section; \
	    next \
	  } \
	  /^[a-zA-Z_-]+:.*## / { \
	    split($$0, a, ":.*## "); \
	    printf "  %-24s %s\n", a[1], a[2] \
	  }' $(MAKEFILE_LIST)
	@printf '\n'

# ── Setup ────────────────────────────────────────────────────────────
define CONFIG_TEMPLATE
# Claude Docker Configuration
# Source this before running claude-docker.sh, or add to your set_environment.
# Note: CLAUDE_* vars are consumed by claude-docker.sh on the host.
# To make API keys reach the container, add this file to set-environment-vars.conf
# (same directory as the project) so the entrypoint sources it inside the container.

# API keys
ANTHROPIC_API_KEY=sk-ant-REPLACE_ME
OPENAI_API_KEY=sk-REPLACE_ME

# Docker settings
CLAUDE_PROJECTS_DIR=$$HOME/claude-projects
CLAUDE_DISPATCH_DIR=/tmp/claude-dispatch
CLAUDE_CONTAINER_NAME=claude-worker

# MCP server (for dispatch connection from inside container)
CLAUDE_MCP_HOST=host.docker.internal
CLAUDE_MCP_PORT=8765
endef
export CONFIG_TEMPLATE

.PHONY: docker-config
docker-config: ## Generate template config file (~/.claude/docker.env)
	@mkdir -p "$(CLAUDE_DIR)"
	@if [ ! -f "$(CONFIG_FILE)" ]; then \
	  printf '%s\n' "$$CONFIG_TEMPLATE" > "$(CONFIG_FILE)"; \
	  chmod 600 "$(CONFIG_FILE)"; \
	  echo "Wrote $(CONFIG_FILE)"; \
	  echo "Edit it to fill in your API keys and adjust paths."; \
	else \
	  echo "$(CONFIG_FILE) already exists."; \
	  missing=$$(printf '%s\n' "$$CONFIG_TEMPLATE" \
	    | awk -F= '/^[A-Z]/{print $$1}' \
	    | while read k; do \
	        grep -q "^[[:space:]]*$$k=" "$(CONFIG_FILE)" || echo "$$k"; \
	      done); \
	  if [ -z "$$missing" ]; then \
	    echo "All expected keys present."; \
	  else \
	    echo "Missing keys (add these to $(CONFIG_FILE)):"; \
	    for k in $$missing; do \
	      printf '%s\n' "$$CONFIG_TEMPLATE" | grep -E "^[[:space:]]*$$k=" | sed 's/^/+ /'; \
	    done; \
	  fi; \
	fi

# ── Build ────────────────────────────────────────────────────────────
.PHONY: docker-build
docker-build: ## Build base image (claude, git, gh, node)
	docker build -t $(IMAGE_NAME) -f $(SCRIPT_DIR)/Dockerfile.base $(SCRIPT_DIR)

.PHONY: docker-add-latex
docker-add-latex: ## Add LaTeX (texlive + latexmk) to image
	@docker image inspect $(IMAGE_NAME) >/dev/null 2>&1 \
	  || { echo "Base image not built. Run 'make docker-build' first." >&2; exit 1; }
	docker build -t $(IMAGE_NAME) -f $(SCRIPT_DIR)/Dockerfile.latex $(SCRIPT_DIR)

.PHONY: docker-add-python-sci
docker-add-python-sci: ## Add scientific Python (numpy, scipy, matplotlib, pandas)
	@docker image inspect $(IMAGE_NAME) >/dev/null 2>&1 \
	  || { echo "Base image not built. Run 'make docker-build' first." >&2; exit 1; }
	docker build -t $(IMAGE_NAME) -f $(SCRIPT_DIR)/Dockerfile.python-sci $(SCRIPT_DIR)

.PHONY: docker-add-ollama
docker-add-ollama: ## Add Ollama client for local LLM
	@docker image inspect $(IMAGE_NAME) >/dev/null 2>&1 \
	  || { echo "Base image not built. Run 'make docker-build' first." >&2; exit 1; }
	docker build -t $(IMAGE_NAME) -f $(SCRIPT_DIR)/Dockerfile.ollama $(SCRIPT_DIR)

# ── Run ──────────────────────────────────────────────────────────────
.PHONY: docker-run
docker-run: ## Start interactive session
	$(SCRIPT_DIR)/claude-docker.sh

.PHONY: docker-daemon
docker-daemon: ## Start persistent worker (--daemon)
	$(SCRIPT_DIR)/claude-docker.sh --daemon

.PHONY: docker-stop
docker-stop: ## Stop persistent worker
	$(SCRIPT_DIR)/claude-docker.sh --stop

.PHONY: docker-status
docker-status: ## Check worker status
	@$(SCRIPT_DIR)/claude-docker.sh --status

# ── Maintenance ──────────────────────────────────────────────────────
.PHONY: docker-clean
docker-clean: ## Remove image and stopped containers
	@$(SCRIPT_DIR)/claude-docker.sh --stop 2>/dev/null || true
	@docker ps -a --filter "ancestor=$(IMAGE_NAME)" --format '{{.ID}}' \
	  | xargs -r docker rm -f
	@docker image rm -f $(IMAGE_NAME) 2>/dev/null || true
	@echo "Cleaned $(IMAGE_NAME) and any containers derived from it."
