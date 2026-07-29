#!/bin/bash
# tests/test_capabilities.sh — exercises the capability contract (#931).
#
# Runs against a real `claude-docker.sh`. It stops before the first
# `docker run` by short-circuiting with `--stop --name <bogus>` for the
# no-container-touch cases, or by asserting a specific error message for
# the fail-closed cases. Nothing here starts a container.
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
    echo "    got: $haystack" | head -c 800
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
  # Run the launcher in a subshell with a working dir we control, so a
  # capabilities.conf in the real cwd never leaks in. Capture stderr.
  local workdir="$1"; shift
  ( cd "$workdir" && "$CLAUDE" "$@" ) 2>&1
}

echo "=== 1. No config + no --auto → fail-closed ==="
mkdir -p "$TMP/empty"
out=$(run_launcher "$TMP/empty" --stop --name __bogus_never_exists__ 2>&1)  # sanity: subcommands still work
out=$(run_launcher "$TMP/empty" --link_environment 2>&1) || true
assert_contains "error message names capabilities.conf" "no capabilities.conf found" "$out"

echo "=== 2. --auto + config present → mutually-exclusive error ==="
mkdir -p "$TMP/both"
cat > "$TMP/both/capabilities.conf" <<'CONF'
version: 1
gpu: none
CONF
out=$(run_launcher "$TMP/both" --auto 2>&1) || true
assert_contains "mutually-exclusive error" "mutually exclusive" "$out"

echo "=== 3. Missing version → error ==="
mkdir -p "$TMP/noversion"
cat > "$TMP/noversion/capabilities.conf" <<'CONF'
gpu: none
CONF
out=$(run_launcher "$TMP/noversion" 2>&1) || true
assert_contains "missing version → error" "missing required 'version'" "$out"

echo "=== 4. Unsupported version → error, no default ==="
mkdir -p "$TMP/badver"
cat > "$TMP/badver/capabilities.conf" <<'CONF'
version: 99
gpu: none
CONF
out=$(run_launcher "$TMP/badver" 2>&1) || true
assert_contains "unsupported version → error" "unsupported version '99'" "$out"

echo "=== 5. Unknown key → error, never silent ==="
mkdir -p "$TMP/unknown"
cat > "$TMP/unknown/capabilities.conf" <<'CONF'
version: 1
gpu: none
totally_fake_key: hello
CONF
out=$(run_launcher "$TMP/unknown" 2>&1) || true
assert_contains "unknown key → error" "unknown key 'totally_fake_key'" "$out"

echo "=== 6. Invalid value for enum → error ==="
mkdir -p "$TMP/badval"
cat > "$TMP/badval/capabilities.conf" <<'CONF'
version: 1
gpu: fantasy_gpu
CONF
out=$(run_launcher "$TMP/badval" 2>&1) || true
assert_contains "invalid enum value → error" "invalid value 'fantasy_gpu'" "$out"

echo "=== 7. Malformed line → error ==="
mkdir -p "$TMP/mal"
cat > "$TMP/mal/capabilities.conf" <<'CONF'
version: 1
this line has no colon
CONF
out=$(run_launcher "$TMP/mal" 2>&1) || true
assert_contains "malformed line → error" "malformed line" "$out"

echo "=== 8. Generator produces a valid file that the parser accepts ==="
gen_out="$TMP/generated.conf"
"$CLAUDE" --generate-capabilities --output "$gen_out" \
  --gpu=none --network-mode=bridge --pythonpath-forward=false >/dev/null 2>&1
if [ -f "$gen_out" ]; then
  echo "  PASS: generator wrote file"; pass=$((pass + 1))
  cp "$gen_out" "$TMP/roundtrip/capabilities.conf" 2>/dev/null || mkdir -p "$TMP/roundtrip" && cp "$gen_out" "$TMP/roundtrip/capabilities.conf"
  # The launcher will get past parsing and error later on a docker step —
  # we just want to confirm the parser does NOT reject the generated file.
  out=$(run_launcher "$TMP/roundtrip" 2>&1) || true
  if printf '%s' "$out" | grep -qE "malformed|unknown key|unsupported version|missing required|invalid value"; then
    echo "  FAIL: parser rejected the generator's output"
    echo "    got: $out" | head -c 800
    fail=$((fail + 1))
  else
    echo "  PASS: parser accepted the generator's output"
    pass=$((pass + 1))
  fi
else
  echo "  FAIL: generator did not write file"
  fail=$((fail + 1))
fi

echo "=== 9. Generator: same inputs → identical output (two-hosts invariant) ==="
out1=$("$CLAUDE" --generate-capabilities --gpu=nvidia --network-mode=host --pythonpath-forward=true --latex 2>&1)
out2=$("$CLAUDE" --generate-capabilities --gpu=nvidia --network-mode=host --pythonpath-forward=true --latex 2>&1)
if [ "$out1" = "$out2" ]; then
  echo "  PASS: byte-identical generator output"
  pass=$((pass + 1))
else
  echo "  FAIL: generator output diverges between calls"
  fail=$((fail + 1))
fi

echo "=== 10. Generator rejects an invalid value ==="
out=$("$CLAUDE" --generate-capabilities --gpu=fantasy 2>&1) && rc=0 || rc=$?
assert_contains "generator rejects bad --gpu" "invalid value 'fantasy'" "$out"
assert_rc "generator exit code" 2 "$rc"

echo "=== 11. --help still works ==="
out=$("$CLAUDE" --help 2>&1)
assert_contains "help mentions capability contract" "Capability contract" "$out"
assert_contains "help mentions --auto" "--auto" "$out"
assert_contains "help mentions --generate-capabilities" "--generate-capabilities" "$out"

echo
echo "=== Summary: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
