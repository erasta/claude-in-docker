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
