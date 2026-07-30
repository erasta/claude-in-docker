#!/bin/bash
# tests/test_capabilities.sh — exercises the capability contract as reshaped
# by evolvix#935 (v1 rewrite: `capabilities:` block + open-ended `resources:`).
#
# Runs against a real `claude-docker.sh` in a temp cwd so a real
# capabilities.conf never leaks in. Nothing here starts a container.
#
# Run: bash tests/test_capabilities.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE="$SCRIPT_DIR/claude-docker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label"
    echo "    expected substring: $needle"
    echo "    got: $(printf '%s' "$haystack" | head -c 800)"
    echo
    fail=$((fail + 1))
  fi
}

assert_rc() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" -eq "$expected" ]; then
    echo "  PASS: $label (rc=$got)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label (expected rc=$expected, got rc=$got)"
    fail=$((fail + 1))
  fi
}

run_launcher() {
  local workdir="$1"; shift
  ( cd "$workdir" && "$CLAUDE" "$@" ) 2>&1
}

echo "=== 1. No config + no --auto → fail-closed ==="
mkdir -p "$TMP/empty"
# evolvix#952: force HOME to a scratch dir so the ~/.evolvix/ fallback doesn't
# pick up an operator's actual generated file and mask the fail-closed path.
out=$(HOME="$TMP/empty_home" run_launcher "$TMP/empty" --link_environment 2>&1) || true
assert_contains "error message names capabilities file" "no capabilities file found" "$out"
assert_contains "error message names new filename" "claude-docker-capabilities.conf" "$out"

echo "=== 2. --auto + config present → mutually-exclusive error ==="
mkdir -p "$TMP/both"
cat > "$TMP/both/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
CONF
out=$(run_launcher "$TMP/both" --auto 2>&1) || true
assert_contains "mutually-exclusive error" "mutually exclusive" "$out"

echo "=== 3. Missing version → error ==="
mkdir -p "$TMP/noversion"
cat > "$TMP/noversion/capabilities.conf" <<'CONF'
capabilities:
  gpu: none
CONF
out=$(run_launcher "$TMP/noversion" 2>&1) || true
assert_contains "missing version → error" "missing required 'version'" "$out"

echo "=== 4. Unsupported version → error, no default ==="
mkdir -p "$TMP/badver"
cat > "$TMP/badver/capabilities.conf" <<'CONF'
version: 99
capabilities:
  gpu: none
CONF
out=$(run_launcher "$TMP/badver" 2>&1) || true
assert_contains "unsupported version → error" "unsupported version '99'" "$out"

echo "=== 5. Unknown top-level key → error ==="
mkdir -p "$TMP/unknown_top"
cat > "$TMP/unknown_top/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
totally_fake_top: hello
CONF
out=$(run_launcher "$TMP/unknown_top" 2>&1) || true
assert_contains "unknown top-level key → error" "unknown top-level key 'totally_fake_top'" "$out"

echo "=== 6. Unknown key under capabilities: → error ==="
mkdir -p "$TMP/unknown_cap"
cat > "$TMP/unknown_cap/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
  fantasy_key: hello
CONF
out=$(run_launcher "$TMP/unknown_cap" 2>&1) || true
assert_contains "unknown capability key → error" "unknown key 'fantasy_key' under 'capabilities:'" "$out"

echo "=== 7. Invalid value for enum → error ==="
mkdir -p "$TMP/badval"
cat > "$TMP/badval/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: fantasy_gpu
CONF
out=$(run_launcher "$TMP/badval" 2>&1) || true
assert_contains "invalid enum value → error" "capabilities.gpu: invalid value 'fantasy_gpu'" "$out"

echo "=== 8. Malformed line → error ==="
mkdir -p "$TMP/mal"
cat > "$TMP/mal/capabilities.conf" <<'CONF'
version: 1
this line has no colon
CONF
out=$(run_launcher "$TMP/mal" 2>&1) || true
assert_contains "malformed line → error" "expected 'key: value' or 'key:'" "$out"

echo "=== 9. Generator: byte-identical output for identical inputs ==="
out1=$("$CLAUDE" --generate-capabilities --gpu=nvidia --network-mode=host --python-mode=link \
  --resource "github:cli=gh,mount=/tmp:/tmp:ro,env=GH_TOKEN" 2>&1)
out2=$("$CLAUDE" --generate-capabilities --gpu=nvidia --network-mode=host --python-mode=link \
  --resource "github:cli=gh,mount=/tmp:/tmp:ro,env=GH_TOKEN" 2>&1)
if [ "$out1" = "$out2" ]; then
  echo "  PASS: byte-identical generator output"
  pass=$((pass + 1))
else
  echo "  FAIL: generator output diverges between calls"
  fail=$((fail + 1))
fi

echo "=== 10. Generator: rejects invalid enum ==="
out=$("$CLAUDE" --generate-capabilities --gpu=fantasy 2>&1) && rc=0 || rc=$?
assert_contains "generator rejects bad --gpu" "invalid value 'fantasy'" "$out"
assert_rc "generator exit code" 2 "$rc"

echo "=== 11. Generator → parser round-trip (a resource the launcher has never seen) ==="
gen="$TMP/roundtrip"
mkdir -p "$gen"
# `huggingface` is a name the launcher does not recognise — that's the point.
"$CLAUDE" --generate-capabilities --gpu=none --network-mode=bridge --python-mode=copy \
  --resource "huggingface:cli=bash,mount=/tmp:/root/.cache/hf,env=HF_TOKEN" \
  --output "$gen/capabilities.conf" 2>/dev/null
out=$(run_launcher "$gen" 2>&1) || true
# The launcher gets past parsing; if the parser rejected it we'd see one of these:
if printf '%s' "$out" | grep -qE "unknown top-level key|unknown key|unsupported version|missing required|invalid value|malformed line"; then
  echo "  FAIL: parser rejected the generator's output"
  echo "    got: $(printf '%s' "$out" | head -c 800)"
  fail=$((fail + 1))
else
  echo "  PASS: parser accepts an unknown-to-launcher resource end-to-end"
  pass=$((pass + 1))
fi
# Also confirm the resource was applied (message shows it processed the resource)
assert_contains "resource applied (huggingface)" "Resource: huggingface" "$out"

echo "=== 12. Mount source missing → error naming the path ==="
mkdir -p "$TMP/missing_mount"
cat > "$TMP/missing_mount/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
resources:
  x:
    mounts:
      - /this/path/does/not/exist:/somewhere
CONF
out=$(run_launcher "$TMP/missing_mount" 2>&1) || true
assert_contains "missing mount → error naming path" "mount source not found on host: /this/path/does/not/exist" "$out"

echo "=== 13. Declared cli missing on host PATH → error naming binary ==="
mkdir -p "$TMP/missing_cli"
cat > "$TMP/missing_cli/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
resources:
  x:
    cli: definitely_not_installed_binary_xyz
CONF
out=$(run_launcher "$TMP/missing_cli" 2>&1) || true
assert_contains "missing cli → error naming binary" "cli 'definitely_not_installed_binary_xyz' not found on host PATH" "$out"

echo "=== 14. env values with '=' rejected (names only, not literals) ==="
mkdir -p "$TMP/env_leak"
cat > "$TMP/env_leak/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
resources:
  x:
    env:
      - HF_TOKEN=leaked_secret
CONF
out=$(run_launcher "$TMP/env_leak" 2>&1) || true
assert_contains "env values rejected — names only" "env\` items are NAMES only" "$out"

echo "=== 15. mount path expands \${VAR} at parse time ==="
export TEST_HOST_PATH=/tmp
mkdir -p "$TMP/varsub"
cat > "$TMP/varsub/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
resources:
  x:
    mounts:
      - ${TEST_HOST_PATH}:/mounted
CONF
out=$(run_launcher "$TMP/varsub" 2>&1) || true
assert_contains "\${VAR} expanded in mount" "mount  /tmp:/mounted" "$out"
unset TEST_HOST_PATH

echo "=== 16. resources: absent → no resources applied, no error ==="
mkdir -p "$TMP/no_resources"
cat > "$TMP/no_resources/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
CONF
out=$(run_launcher "$TMP/no_resources" 2>&1) || true
# No error message about resources
if printf '%s' "$out" | grep -q "no capabilities file found\|malformed\|unknown key\|unsupported version"; then
  echo "  FAIL: parser errored on no-resources config"
  echo "    got: $(printf '%s' "$out" | head -c 500)"
  fail=$((fail + 1))
else
  echo "  PASS: resources: absent is legal"
  pass=$((pass + 1))
fi

echo "=== 17. --help mentions the new shape ==="
out=$("$CLAUDE" --help 2>&1)
assert_contains "help mentions capability contract" "Capability contract" "$out"
assert_contains "help mentions resources:" "resources:" "$out"
assert_contains "help mentions --resource generator flag" "--resource" "$out"
assert_contains "help mentions --python-mode" "python_mode" "$out"
assert_contains "help documents names-only rule" "NAMES only" "$out"

echo "=== 18. --generate-capabilities annotates every option (evolvix#952) ==="
out=$("$CLAUDE" --generate-capabilities 2>&1)
assert_contains "generate: help pointer" "--help-capabilities" "$out"
assert_contains "generate: gpu option commented" "# gpu: nvidia | dri | kfd | none" "$out"
assert_contains "generate: gpu nvidia effect" "requires nvidia runtime" "$out"
assert_contains "generate: network_mode option commented" "# network_mode: host | bridge | none" "$out"
assert_contains "generate: python_mode option commented" "# python_mode: link | copy" "$out"
# Generated file must still parse cleanly against the launcher's own parser.
tmp_gen="$TMP/generated"
mkdir -p "$tmp_gen"
"$CLAUDE" --generate-capabilities --output "$tmp_gen/capabilities.conf" >/dev/null 2>&1
parse_out=$(run_launcher "$tmp_gen" 2>&1) || true
if printf '%s' "$parse_out" | grep -q "unknown key\|malformed\|unsupported version\|ERROR:"; then
  echo "  FAIL: parser rejected generator output (self-round-trip broken)"
  echo "    got: $(printf '%s' "$parse_out" | head -c 500)"
  fail=$((fail + 1))
else
  echo "  PASS: generator output round-trips through parser"
  pass=$((pass + 1))
fi

echo "=== 20. new filename claude-docker-capabilities.conf is preferred (evolvix#952) ==="
mkdir -p "$TMP/newname"
cat > "$TMP/newname/claude-docker-capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
  network_mode: host
CONF
out=$(HOME="$TMP/empty_home_a" run_launcher "$TMP/newname" 2>&1) || true
assert_contains "reads new name" "Reading capabilities: $TMP/newname/claude-docker-capabilities.conf" "$out"

echo "=== 21. old filename capabilities.conf still works — with deprecation WARNING (evolvix#952) ==="
mkdir -p "$TMP/oldname"
cat > "$TMP/oldname/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
  network_mode: host
CONF
out=$(HOME="$TMP/empty_home_b" run_launcher "$TMP/oldname" 2>&1) || true
assert_contains "reads old name" "Reading capabilities: $TMP/oldname/capabilities.conf" "$out"
assert_contains "warns about deprecation" "renamed to" "$out"
assert_contains "warning names new file" "claude-docker-capabilities.conf" "$out"
assert_contains "warning is time-boxed" "one release after" "$out"

echo "=== 22. new filename wins over old when both present (evolvix#952) ==="
mkdir -p "$TMP/both_names"
cat > "$TMP/both_names/claude-docker-capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
CONF
cat > "$TMP/both_names/capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: nvidia
CONF
out=$(HOME="$TMP/empty_home_c" run_launcher "$TMP/both_names" 2>&1) || true
assert_contains "prefers new name" "Reading capabilities: $TMP/both_names/claude-docker-capabilities.conf" "$out"
# Deprecation warning should NOT fire when the new file is present.
if printf '%s' "$out" | grep -q "renamed to"; then
  echo "  FAIL: deprecation warning fired even though new-name file was present"
  fail=$((fail + 1))
else
  echo "  PASS: no deprecation warning when new-name file is present"
  pass=$((pass + 1))
fi

echo "=== 23. ~/.evolvix fallback picks up Evolvix-generated file (evolvix#951+#952) ==="
mkdir -p "$TMP/empty_cwd"
mkdir -p "$TMP/fake_home/.evolvix"
cat > "$TMP/fake_home/.evolvix/claude-docker-capabilities.conf" <<'CONF'
version: 1
capabilities:
  gpu: none
  network_mode: host
CONF
out=$(HOME="$TMP/fake_home" run_launcher "$TMP/empty_cwd" 2>&1) || true
assert_contains "falls back to ~/.evolvix" "Reading capabilities: $TMP/fake_home/.evolvix/claude-docker-capabilities.conf" "$out"

echo "=== 19. --help-capabilities prints schema reference (evolvix#952) ==="
out=$("$CLAUDE" --help-capabilities 2>&1)
assert_contains "help-cap: title" "capabilities.conf — schema reference" "$out"
assert_contains "help-cap: gpu enum" "gpu: nvidia | dri | kfd | none" "$out"
assert_contains "help-cap: network enum" "network_mode: host | bridge | none" "$out"
assert_contains "help-cap: python_mode enum" "python_mode: link | copy" "$out"
assert_contains "help-cap: resources structure" "env_set:" "$out"
assert_contains "help-cap: mount syntax" "host:container[:ro]" "$out"
assert_contains "help-cap: --help mentions --help-capabilities" \
                "--help-capabilities" "$("$CLAUDE" --help 2>&1)"

echo
echo "=== Summary: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
