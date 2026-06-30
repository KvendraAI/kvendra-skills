#!/usr/bin/env bash
#
# run-fixtures.sh — single-file pure-Bash, offline test runner for the
# `/setup` skill's self-hosted + local-embeddings automated flow.
#
# It mocks `docker` and `claude` on PATH (no network, no credentials, no real
# containers) and asserts the two load-bearing behaviours of the skill:
#
#   (a) TOKEN EXTRACTION RETRY LOOP — the S3 loop reads
#       `/data/auth.token` from the `kvendra-platform` service via
#       `docker compose exec -T`, retries until non-empty, and strips the
#       trailing CR. The mock fails attempts 1-2 (empty) and succeeds on
#       attempt 3 with a CR-terminated token, so a passing run proves the
#       retry + CR-strip work.
#
#   (b) REGISTRATION ARGV — the S4 step emits the exact
#       `claude mcp add kvendra-platform http://localhost:7777/mcp
#        --transport http -H "Authorization: Bearer <token>"` argv, with the
#       distinct server name `kvendra-platform` and the extracted token.
#
# The code under test is EXTRACTED from the skill's SKILL.md (the S3 fenced
# loop and the S4 fenced `claude mcp add` line) rather than duplicated here,
# so the test fails if the skill drifts from the canonical recipe.
#
# Usage:
#   bash tests/setup/run-fixtures.sh
#
# Exit code: 0 if all assertions pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$(cd "$SCRIPT_DIR/../../skills/setup" && pwd)/SKILL.md"

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }

if [[ ! -f "$SKILL_MD" ]]; then
  echo "ERROR: SKILL.md not found at $SKILL_MD" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Extract the S3 token-retry loop and the S4 registration line from the
# skill's fenced ```bash blocks, so the test exercises the SAME recipe the
# skill ships (drift guard). Both live inside fenced code blocks.
# ------------------------------------------------------------------
TOKEN_LOOP="$(awk '
  /^for attempt in 1 2 3; do$/ { capture=1 }
  capture { print }
  capture && /^done$/ { exit }
' "$SKILL_MD")"

REGISTER_LINE="$(grep -m1 '^claude mcp add kvendra-platform ' "$SKILL_MD" || true)"

# ------------------------------------------------------------------
# Mocks on PATH: a fake `docker` and a fake `claude`. No network, no real
# containers. The docker mock simulates the token lagging the healthcheck
# (empty on attempts 1-2, present on attempt 3) and emits a CR.
# ------------------------------------------------------------------
MOCK_BIN="$(mktemp -d -t kvendra_setup_mock.XXXXXX)"
STATE_DIR="$(mktemp -d -t kvendra_setup_state.XXXXXX)"
cleanup() { rm -rf "$MOCK_BIN" "$STATE_DIR" 2>/dev/null || true; }
trap cleanup EXIT

DOCKER_ARGV_LOG="$STATE_DIR/docker_argv.log"
DOCKER_ATTEMPTS="$STATE_DIR/docker_attempts"
CLAUDE_ARGV_LOG="$STATE_DIR/claude_argv.log"
: > "$DOCKER_ARGV_LOG"; : > "$CLAUDE_ARGV_LOG"; echo 0 > "$DOCKER_ATTEMPTS"

# The token the mock platform "generates" (printf %q-safe, trailing CR added
# by the mock to exercise the ${TOKEN//$'\r'/} strip).
EXPECTED_TOKEN="ey-mock-platform-token-12345"

cat > "$MOCK_BIN/docker" <<MOCK
#!/usr/bin/env bash
# Mock docker. Only handles: compose exec -T kvendra-platform cat /data/auth.token
printf '%s\n' "\$*" >> "$DOCKER_ARGV_LOG"
n="\$(cat "$DOCKER_ATTEMPTS")"; n=\$((n+1)); echo "\$n" > "$DOCKER_ATTEMPTS"
# Must be a 'compose exec' that reads the auth token from the platform service.
if [[ "\$1" == "compose" && "\$2" == "exec" && "\$*" == *"kvendra-platform"* && "\$*" == *"/data/auth.token"* ]]; then
  if [[ "\$n" -ge 3 ]]; then
    # Emit the token WITH a trailing CR to exercise the CR-strip.
    printf '%s\r\n' "$EXPECTED_TOKEN"
    exit 0
  fi
  # Attempts 1-2: token not generated yet -> empty + non-zero (lagging).
  exit 1
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/docker"

cat > "$MOCK_BIN/claude" <<MOCK
#!/usr/bin/env bash
# Mock claude. Records the full argv of 'mcp add' so the test can assert it.
if [[ "\$1" == "mcp" && "\$2" == "add" ]]; then
  # Log one arg per line to assert the argv precisely (quoting-safe).
  for a in "\$@"; do printf '%s\n' "\$a"; done >> "$CLAUDE_ARGV_LOG"
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/claude"

# ------------------------------------------------------------------
# Run the extracted recipe under the mocks, in a clean subshell.
# `sleep` is monkeypatched to a no-op so the retry loop does not stall.
# ------------------------------------------------------------------
RUN_OUT="$STATE_DIR/run.out"
(
  export PATH="$MOCK_BIN:$PATH"
  sleep() { :; }            # no-op: do not actually wait 2s between attempts
  TOKEN=""
  eval "$TOKEN_LOOP"        # S3: token-extraction retry loop (from SKILL.md)
  printf 'TOKEN=[%s]\n' "$TOKEN" > "$RUN_OUT"
  eval "$REGISTER_LINE"     # S4: registration (from SKILL.md), uses ${TOKEN}
) 2>/dev/null

# ------------------------------------------------------------------
# Assertion 1 — the recipe was actually extracted from the skill.
# ------------------------------------------------------------------
if [[ -n "$TOKEN_LOOP" && "$TOKEN_LOOP" == *"/data/auth.token"* && "$TOKEN_LOOP" == *'${TOKEN//$'* ]]; then
  pass "S3 token-retry loop extracted from SKILL.md (reads /data/auth.token, strips CR)"
else
  fail "S3 token-retry loop extracted from SKILL.md (reads /data/auth.token, strips CR)"
fi

if [[ -n "$REGISTER_LINE" ]]; then
  pass "S4 registration line extracted from SKILL.md"
else
  fail "S4 registration line extracted from SKILL.md"
fi

# ------------------------------------------------------------------
# Assertion 2 — the token loop read /data/auth.token via docker compose exec
# on the kvendra-platform service, and retried until non-empty.
# ------------------------------------------------------------------
docker_attempts="$(cat "$DOCKER_ATTEMPTS")"
if grep -q 'compose exec -T kvendra-platform cat /data/auth.token' "$DOCKER_ARGV_LOG"; then
  pass "docker compose exec -T kvendra-platform cat /data/auth.token invoked"
else
  fail "docker compose exec -T kvendra-platform cat /data/auth.token invoked"
fi

if [[ "$docker_attempts" -eq 3 ]]; then
  pass "retry loop ran 3 attempts (succeeded on attempt 3, not attempt 1)"
else
  fail "retry loop ran 3 attempts (saw $docker_attempts)"
fi

# ------------------------------------------------------------------
# Assertion 3 — the extracted TOKEN is correct AND CR-stripped (no \r).
# ------------------------------------------------------------------
got_token_line="$(grep '^TOKEN=\[' "$RUN_OUT" 2>/dev/null || true)"
# Detect a stray CR: it would print as ^M / break the bracket match.
if [[ "$got_token_line" == "TOKEN=[$EXPECTED_TOKEN]" ]]; then
  pass "TOKEN extracted and CR-stripped exactly (= $EXPECTED_TOKEN)"
else
  fail "TOKEN extracted and CR-stripped exactly (got: '$got_token_line')"
fi

# ------------------------------------------------------------------
# Assertion 4 — the EXACT registration argv was emitted to `claude mcp add`,
# with the distinct server name kvendra-platform and the extracted token.
# Expected argv (one per line):
#   mcp add kvendra-platform http://localhost:7777/mcp
#   --transport http -H "Authorization: Bearer <token>"
# ------------------------------------------------------------------
EXPECTED_ARGV="$(cat <<EOF
mcp
add
kvendra-platform
http://localhost:7777/mcp
--transport
http
-H
Authorization: Bearer $EXPECTED_TOKEN
EOF
)"

actual_argv="$(cat "$CLAUDE_ARGV_LOG")"
if [[ "$actual_argv" == "$EXPECTED_ARGV" ]]; then
  pass "claude mcp add emitted exact argv (kvendra-platform, http transport, Bearer token)"
else
  fail "claude mcp add exact argv"
  echo "       --- expected argv ---"; sed 's/^/       | /' <<<"$EXPECTED_ARGV"
  echo "       --- actual argv ---";   sed 's/^/       | /' <<<"$actual_argv"
  echo "       --- end ---"
fi

# ------------------------------------------------------------------
# Assertion 5 — the bundled cloud server is NOT touched: the only server name
# the registration argv adds is `kvendra-platform` (pattern B, coexistence).
# ------------------------------------------------------------------
if grep -q '^kvendra-cloud$' "$CLAUDE_ARGV_LOG"; then
  fail "kvendra-cloud must NOT be (re)registered by setup (pattern B coexistence)"
else
  pass "kvendra-cloud left untouched (only kvendra-platform registered)"
fi

echo ""
echo "==== summary ===="
echo "passed: $PASS"
echo "failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "failed assertions: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
