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
#   (c) CWD INDEPENDENCE — the S3 loop targets the ABSOLUTE stack root resolved
#       in S1b, so it must work with a cwd OUTSIDE the clone. The runner
#       deliberately executes the loop from an unrelated directory, and the
#       docker mock records its own `pwd -P`, which must equal `STACK_ROOT`.
#
#   (d) S1b ROOT RESOLUTION — the detection, destination-validation and clone
#       snippets are extracted from the same SKILL.md (same drift guard) and
#       exercised over temp dirs: no network, no Docker, no real clone.
#
#   (e) S2 BRING-UP / COLLISION — asserted as TEXT (executing them would run a
#       real `up.sh` and talk to a real Docker). The start script must be
#       invoked through the ABSOLUTE `$STACK_ROOT`, and every fenced
#       `docker compose` command must carry `cd "$STACK_ROOT"` on the same
#       line. Without these, a relative invocation reintroduces the
#       cwd-dependency bug S1b exists to remove, and no other test notices.
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
SKIPPED=0
FAILED_NAMES=()

pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }
skip() { echo "SKIP  $1"; SKIPPED=$((SKIPPED+1)); }

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
# WORK_ROOT holds the fake clone, the "outside" cwd and every S1b scenario dir.
# It is created under /tmp on purpose, NOT via `mktemp -t`: on macOS `-t` lands
# in /var/folders/..., and the S1b-4 validation snippet correctly REJECTs any
# destination under /var/*, which would make the destination fixtures untestable.
WORK_ROOT="$(mktemp -d /tmp/kvendra_setup_work.XXXXXX)"
# FIXT is a dedicated subtree for the S1b fixtures, deliberately NOT $WORK_ROOT
# itself: the detection snippet also probes the SIBLING
# `../kvendra-reference-stack`, and $WORK_ROOT holds the S3 fake clone under
# exactly that basename. Sharing the parent would make every S1b fixture
# resolve to that fake clone through the sibling branch.
FIXT="$WORK_ROOT/s1b"
mkdir -p "$FIXT"
cleanup() {
  chmod -R u+rwX "$WORK_ROOT" 2>/dev/null || true
  rm -rf "$MOCK_BIN" "$STATE_DIR" "$WORK_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

DOCKER_ARGV_LOG="$STATE_DIR/docker_argv.log"
DOCKER_PWD_LOG="$STATE_DIR/docker_pwd.log"
DOCKER_ATTEMPTS="$STATE_DIR/docker_attempts"
CLAUDE_ARGV_LOG="$STATE_DIR/claude_argv.log"
: > "$DOCKER_ARGV_LOG"; : > "$DOCKER_PWD_LOG"; : > "$CLAUDE_ARGV_LOG"
echo 0 > "$DOCKER_ATTEMPTS"

# The fake clone the S3 loop must `cd` into (STACK_ROOT), plus an unrelated
# directory used as the runner's cwd so the fixture reproduces the real bug
# (wizard invoked from the user's project, stack living somewhere else).
FAKE_CLONE="$WORK_ROOT/kvendra-reference-stack"
OUTSIDE_DIR="$WORK_ROOT/user-project"

# A docker-compose.yml carrying the `kvendra-platform` service key the S1b-2
# predicate greps for (third detection signal). Every directory the fixtures
# use as a VALID clone must be built with this, or the predicate rejects it.
write_compose() {  # write_compose <file>
  printf 'services:\n  kvendra-platform:\n    image: kvendra/kvendra-platform:test\n' > "$1"
}
# A compose file of somebody ELSE'S project: right shape, no platform service.
write_foreign_compose() {  # write_foreign_compose <file>
  printf 'services:\n  api:\n    image: node:20\n  postgres:\n    image: postgres:16\n' > "$1"
}
# An executable start script, the second detection signal.
write_up_sh() {  # write_up_sh <dir>
  mkdir -p "$1/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/scripts/up.sh"
  chmod +x "$1/scripts/up.sh"
}

mkdir -p "$FAKE_CLONE/scripts" "$OUTSIDE_DIR"
write_compose "$FAKE_CLONE/docker-compose.yml"
write_up_sh "$FAKE_CLONE"
EXPECTED_STACK_PWD="$(cd "$FAKE_CLONE" && pwd -P)"

# A transparent `git` shim: the S1b detection snippet calls git for labelling,
# and some machines have a broken `git` first on PATH (wrong architecture). Pick
# the first git that actually answers `--version` and shim it into MOCK_BIN so
# the S1b fixtures are hermetic. No network op is ever performed.
GIT_BIN=""
for cand in git /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do
  if resolved="$(command -v "$cand" 2>/dev/null)" && [[ -n "$resolved" ]] \
     && "$resolved" --version >/dev/null 2>&1; then
    GIT_BIN="$resolved"; break
  fi
done
if [[ -n "$GIT_BIN" ]]; then
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$GIT_BIN" > "$MOCK_BIN/git"
  chmod +x "$MOCK_BIN/git"
fi

# The token the mock platform "generates" (printf %q-safe, trailing CR added
# by the mock to exercise the ${TOKEN//$'\r'/} strip).
EXPECTED_TOKEN="ey-mock-platform-token-12345"

cat > "$MOCK_BIN/docker" <<MOCK
#!/usr/bin/env bash
# Mock docker. Only handles: compose exec -T kvendra-platform cat /data/auth.token
printf '%s\n' "\$*" >> "$DOCKER_ARGV_LOG"
printf '%s\n' "\$(pwd -P)" >> "$DOCKER_PWD_LOG"
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
  cd "$OUTSIDE_DIR" || exit 1   # cwd OUTSIDE the stack: the real-world case
  sleep() { :; }            # no-op: do not actually wait 2s between attempts
  STACK_ROOT="$FAKE_CLONE"  # S1b output, injected the way the skill injects it
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

# ------------------------------------------------------------------
# Assertion 6 — CWD INDEPENDENCE: the loop ran with a cwd OUTSIDE the stack,
# and every `docker` invocation still happened with the stack root as cwd.
# This is the direct proof of the "no reliance on a previous cd" invariant.
# ------------------------------------------------------------------
if [[ "$TOKEN_LOOP" == *'cd "$STACK_ROOT"'* ]]; then
  pass "S3 loop targets the absolute STACK_ROOT (no reliance on the caller cwd)"
else
  fail "S3 loop targets the absolute STACK_ROOT (no reliance on the caller cwd)"
fi

bad_pwd=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "$EXPECTED_STACK_PWD" ]] || bad_pwd=1
done < "$DOCKER_PWD_LOG"
logged_pwds="$(grep -c . "$DOCKER_PWD_LOG" | tr -d ' ')"
if [[ "$logged_pwds" -ge 1 && "$bad_pwd" -eq 0 ]]; then
  pass "docker ran with cwd == STACK_ROOT on all $logged_pwds invocations"
else
  fail "docker ran with cwd == STACK_ROOT (expected $EXPECTED_STACK_PWD, got: $(tr '\n' ' ' < "$DOCKER_PWD_LOG"))"
fi

# ------------------------------------------------------------------
# Assertion 7 — S2 BLOCKS. The bring-up cannot be executed here (it would run
# a real `up.sh`) so it is asserted as TEXT, extracted from the same SKILL.md
# as everything else. This is the guard that stops the pre-1.12.0 bug from
# being reintroduced: invoking the start script by a RELATIVE path silently
# depends on the caller cwd, which is exactly what S1b exists to remove.
# ------------------------------------------------------------------
BRINGUP_SNIPPET="$(awk '
  /^curl -fsS / { capture=1 }
  capture { print }
  capture && /with-ollama/ { exit }
' "$SKILL_MD")"

COLLISION_LINE="$(grep -m1 'docker compose ps -q kvendra-platform' "$SKILL_MD" || true)"

# Strip the canonical absolute invocation; anything left mentioning up.sh is a
# relative (cwd-dependent) invocation.
bringup_stripped="$(printf '%s\n' "$BRINGUP_SNIPPET" \
  | sed 's|"\$STACK_ROOT/scripts/up\.sh"||g')"

if [[ -n "$BRINGUP_SNIPPET" \
      && "$BRINGUP_SNIPPET" == *'curl -fsS '*'/healthz'* \
      && "$BRINGUP_SNIPPET" == *'"$STACK_ROOT/scripts/up.sh"'* \
      && "$bringup_stripped" != *'up.sh'* ]]; then
  pass "S2 bring-up invokes the start script by ABSOLUTE \$STACK_ROOT path (no relative up.sh)"
else
  fail "S2 bring-up invokes the start script by ABSOLUTE \$STACK_ROOT path (got: $(printf '%s' "$BRINGUP_SNIPPET" | tr '\n' '|'))"
fi

if [[ -n "$COLLISION_LINE" && "$COLLISION_LINE" == *'cd "$STACK_ROOT"'* ]]; then
  pass "S2 stack-collision Compose command runs from the resolved \$STACK_ROOT"
else
  fail "S2 stack-collision Compose command runs from \$STACK_ROOT (got: '$COLLISION_LINE')"
fi

# Generic invariant over the WHOLE SKILL.md: every fenced line that runs
# `docker compose` (other than the `docker compose version` capability probe)
# must carry `cd "$STACK_ROOT"` on the same line. Turns the "no reliance on a
# previous cd" criterion into an executable assertion instead of a read-through.
compose_no_cd="$(awk '
  /^```/ { inb = !inb; next }
  !inb { next }
  /docker compose / {
    if ($0 ~ /docker compose version/) next
    if (index($0, "cd \"$STACK_ROOT\"") == 0) printf("%d:%s\n", NR, $0)
  }
' "$SKILL_MD")"
compose_cd_count="$(awk '
  /^```/ { inb = !inb; next }
  !inb { next }
  /docker compose / { if ($0 !~ /docker compose version/) n++ }
  END { print n+0 }
' "$SKILL_MD")"

if [[ -z "$compose_no_cd" && "$compose_cd_count" -ge 2 ]]; then
  pass "every fenced docker-compose command ($compose_cd_count) carries cd \"\$STACK_ROOT\""
else
  fail "every fenced docker-compose command carries cd \"\$STACK_ROOT\" (count=$compose_cd_count, offenders: $(printf '%s' "$compose_no_cd" | tr '\n' '|'))"
fi

# ------------------------------------------------------------------
# Assertion 8 — S1b-1 prerequisites gate. `curl` is a hard dependency of S2
# (the /healthz probe) and of the stack's own up.sh: absent, the probe exits
# 127 and the `||` branch fires the bring-up unconditionally.
# ------------------------------------------------------------------
PREREQ_SNIPPET="$(awk '
  /^command -v git / { capture=1 }
  capture { print }
  capture && /^docker info / { exit }
' "$SKILL_MD")"

if [[ -n "$PREREQ_SNIPPET" \
      && "$PREREQ_SNIPPET" == *'MISSING git'* \
      && "$PREREQ_SNIPPET" == *'MISSING curl'* \
      && "$PREREQ_SNIPPET" == *'MISSING docker'* ]]; then
  pass "S1b-1 prerequisites gate checks git, curl AND docker before touching the disk"
else
  fail "S1b-1 prerequisites gate checks git, curl AND docker (got: $(printf '%s' "$PREREQ_SNIPPET" | tr '\n' '|'))"
fi

# ==================================================================
# S1b FIXTURES — reference-stack root resolution
#
# Same drift guard as S3/S4: the snippets under test are EXTRACTED from the
# skill's fenced ```bash blocks, never duplicated here. Everything runs over
# temp dirs: no network, no Docker, no real clone.
# ==================================================================
DETECT_SNIPPET="$(awk '
  /^CWD=/ { capture=1 }
  capture { print }
  capture && /remote\.origin\.url/ { exit }
' "$SKILL_MD")"

# The validation snippet is captured from the DEST NORMALISATION line on
# purpose: that skips the `DEST="<absolute destination confirmed by the user>"`
# placeholder line (so the fixture injects its own DEST) while still including
# the trailing-slash strip, which every string comparison below depends on.
VALIDATE_SNIPPET="$(awk '
  /^DEST=/ && /DEST%/ { capture=1 }
  capture { print }
  capture && /^df -h / { exit }
' "$SKILL_MD")"

# The clone snippet is asserted as TEXT only — never executed (it would hit the
# network and write to disk).
CLONE_SNIPPET="$(awk '
  /^GIT_TERMINAL_PROMPT=0 / { capture=1 }
  capture { print }
  capture && /rev-parse HEAD/ { exit }
' "$SKILL_MD")"

if [[ -n "$DETECT_SNIPPET" \
      && "$DETECT_SNIPPET" == *'docker-compose.yml'* \
      && "$DETECT_SNIPPET" == *'scripts/up.sh'* \
      && "$DETECT_SNIPPET" == *'kvendra-platform:'* \
      && "$DETECT_SNIPPET" == *'RESOLVED'* ]]; then
  pass "S1b-2 detection snippet extracted from SKILL.md (3-signal predicate + RESOLVED)"
else
  fail "S1b-2 detection snippet extracted from SKILL.md (3-signal predicate + RESOLVED)"
fi

# The predicate must be defined ONCE and reused, not repeated per branch: three
# copies of a condition are three chances to harden only two of them.
predicate_defs="$(printf '%s\n' "$DETECT_SNIPPET" | grep -c '^is_stack() {' | tr -d ' ')"
predicate_uses="$(printf '%s\n' "$DETECT_SNIPPET" | grep -c 'is_stack "' | tr -d ' ')"
if [[ "$predicate_defs" -eq 1 && "$predicate_uses" -ge 3 ]]; then
  pass "S1b-2 predicate is a single shared function reused by $predicate_uses call sites"
else
  fail "S1b-2 predicate is a single shared function (definitions=$predicate_defs, call sites=$predicate_uses)"
fi

# The predicate must STATE all three signals explicitly. Two of them are pinned
# by fixtures (F14/F15 for scripts/up.sh, F16/F17b for the platform service).
# The third — the `docker-compose.yml` existence test — is behaviourally
# subsumed by the service grep that follows it on the same file (grep on a
# missing file fails), so no fixture can observe its removal. It is asserted
# TEXTUALLY, as a drift guard on the canonical recipe, exactly the way the
# clone URL and the registration argv are: this file is read and executed by an
# agent, so the explicit form is part of the contract.
if [[ "$DETECT_SNIPPET" == *'[ -f "$1/docker-compose.yml" ]'* \
      && "$DETECT_SNIPPET" == *'[ -f "$1/scripts/up.sh" ]'* \
      && "$DETECT_SNIPPET" == *'kvendra-platform:'* ]]; then
  pass "S1b-2 predicate states all three signals explicitly (compose, up.sh, platform service)"
else
  fail "S1b-2 predicate states all three signals explicitly (compose, up.sh, platform service)"
fi

if [[ -n "$VALIDATE_SNIPPET" \
      && "$VALIDATE_SNIPPET" == *'REJECT filesystem-root'* \
      && "$VALIDATE_SNIPPET" == *'REJECT home-directory-itself'* \
      && "$VALIDATE_SNIPPET" == *'REJECT parent-not-writable'* \
      && "$VALIDATE_SNIPPET" == *'${DEST%/}'* ]]; then
  pass "S1b-4 validation snippet extracted from SKILL.md (REJECT rules + trailing-slash strip)"
else
  fail "S1b-4 validation snippet extracted from SKILL.md (REJECT rules + trailing-slash strip)"
fi

if [[ "$CLONE_SNIPPET" == *'GIT_TERMINAL_PROMPT=0'* \
      && "$CLONE_SNIPPET" == *'credential.helper='* \
      && "$CLONE_SNIPPET" == *'https://github.com/KvendraAI/kvendra-reference-stack.git'* ]]; then
  pass "S1b-5 clone snippet is non-interactive and pins the constant KvendraAI URL"
else
  fail "S1b-5 clone snippet is non-interactive and pins the constant KvendraAI URL"
fi

# ---- helpers -----------------------------------------------------
phys() { (cd "$1" 2>/dev/null && pwd -P); }

mk_stack() {  # mk_stack <dir> : minimal tree that passes the detection predicate
  mkdir -p "$1"
  write_compose "$1/docker-compose.yml"
  write_up_sh "$1"
}

run_detect() {  # run_detect <cwd> : evaluate the S1b-2 snippet from <cwd>
  (
    export PATH="$MOCK_BIN:$PATH"
    cd "$1" 2>/dev/null || exit 1
    eval "$DETECT_SNIPPET"
  ) 2>/dev/null
}

run_validate() {  # run_validate <dest> : evaluate the S1b-4 snippet for <dest>
  (
    export PATH="$MOCK_BIN:$PATH"
    cd "$WORK_ROOT" 2>/dev/null || exit 1
    DEST="$1"
    eval "$VALIDATE_SNIPPET"
  ) 2>/dev/null
}

has_line() { printf '%s\n' "$1" | grep -qx "$2"; }
count_lines() { printf '%s\n' "$1" | grep -c "$2" | tr -d ' '; }

# ---- F1: cwd IS the clone ----------------------------------------
mk_stack "$FIXT/f1-clone"
out="$(run_detect "$FIXT/f1-clone")"
if has_line "$out" "RESOLVED $(phys "$FIXT/f1-clone")"; then
  pass "S1b-2 F1: cwd is the clone -> resolved in place (no clone branch)"
else
  fail "S1b-2 F1: cwd is the clone (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F2: cwd is <clone>/scripts (upward walk) --------------------
out="$(run_detect "$FIXT/f1-clone/scripts")"
if has_line "$out" "RESOLVED $(phys "$FIXT/f1-clone")"; then
  pass "S1b-2 F2: cwd is <clone>/scripts -> upward walk resolves the clone root"
else
  fail "S1b-2 F2: cwd is <clone>/scripts (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F3: kvendra-reference-stack/ subdirectory -------------------
mkdir -p "$FIXT/f3-parent"
mk_stack "$FIXT/f3-parent/kvendra-reference-stack"
out="$(run_detect "$FIXT/f3-parent")"
if has_line "$out" "RESOLVED $(phys "$FIXT/f3-parent")/kvendra-reference-stack" \
   && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F3: kvendra-reference-stack/ subdirectory resolved without asking"
else
  fail "S1b-2 F3: kvendra-reference-stack/ subdirectory (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F4: two candidate subdirectories ----------------------------
mkdir -p "$FIXT/f4-parent"
mk_stack "$FIXT/f4-parent/stack-one"
mk_stack "$FIXT/f4-parent/stack-two"
out="$(run_detect "$FIXT/f4-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 2 ]]; then
  pass "S1b-2 F4: two candidates -> unresolved + both listed (no guessing)"
else
  fail "S1b-2 F4: two candidates (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F5: empty non-git directory ---------------------------------
mkdir -p "$FIXT/f5-empty"
out="$(run_detect "$FIXT/f5-empty")"
if has_line "$out" "RESOLVED none" \
   && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]] \
   && has_line "$out" "TOPLEVEL NOT_A_GIT_REPO"; then
  pass "S1b-2 F5: empty non-git directory -> RESOLVED none + TOPLEVEL NOT_A_GIT_REPO"
else
  fail "S1b-2 F5: empty non-git directory (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F6: foreign git repo (GUARD input) --------------------------
if [[ -z "$GIT_BIN" ]]; then
  skip "S1b-2 F6: foreign git repo (no working git binary on this machine)"
else
  mkdir -p "$FIXT/f6-repo"
  ( export PATH="$MOCK_BIN:$PATH"; cd "$FIXT/f6-repo" && git init -q . ) >/dev/null 2>&1
  out="$(run_detect "$FIXT/f6-repo")"
  if has_line "$out" "RESOLVED none" \
     && ! has_line "$out" "TOPLEVEL NOT_A_GIT_REPO" \
     && printf '%s\n' "$out" | grep -q '^TOPLEVEL .*f6-repo$'; then
    pass "S1b-2 F6: foreign git repo -> unresolved + labelled TOPLEVEL (GUARD input)"
  else
    fail "S1b-2 F6: foreign git repo (got: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
fi

# ---- F14: compose WITHOUT up.sh must NOT satisfy the predicate ----
# A real-looking compose (it even declares kvendra-platform) is not enough:
# S2/S3 also need `scripts/up.sh`. One fixture per detection branch (upward
# walk, canonical subdir, candidates). These are the fixtures that kill a
# mutant dropping the `scripts/up.sh` half of the predicate.
mkdir -p "$FIXT/f14a-half"
write_compose "$FIXT/f14a-half/docker-compose.yml"
out="$(run_detect "$FIXT/f14a-half")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F14a: cwd with compose but no scripts/up.sh does not resolve"
else
  fail "S1b-2 F14a: cwd with compose but no up.sh (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f14b-parent/kvendra-reference-stack"
write_compose "$FIXT/f14b-parent/kvendra-reference-stack/docker-compose.yml"
out="$(run_detect "$FIXT/f14b-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F14b: canonical subdir with compose but no up.sh does not resolve"
else
  fail "S1b-2 F14b: canonical subdir with compose but no up.sh (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f14c-parent/some-stack"
write_compose "$FIXT/f14c-parent/some-stack/docker-compose.yml"
out="$(run_detect "$FIXT/f14c-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F14c: subdir with compose but no up.sh is not offered as a CANDIDATE"
else
  fail "S1b-2 F14c: subdir with compose but no up.sh (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F15: MIRROR of F14 — up.sh WITHOUT a compose file ------------
# Without these, a mutant dropping the compose half of the predicate survives:
# every F14 fixture lacks up.sh, so an up.sh-only predicate still says "none".
mkdir -p "$FIXT/f15a-half"
write_up_sh "$FIXT/f15a-half"
out="$(run_detect "$FIXT/f15a-half")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F15a: cwd with scripts/up.sh but no compose does not resolve"
else
  fail "S1b-2 F15a: cwd with up.sh but no compose (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f15b-parent/kvendra-reference-stack"
write_up_sh "$FIXT/f15b-parent/kvendra-reference-stack"
out="$(run_detect "$FIXT/f15b-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F15b: canonical subdir with up.sh but no compose does not resolve"
else
  fail "S1b-2 F15b: canonical subdir with up.sh but no compose (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f15c-parent/some-stack"
write_up_sh "$FIXT/f15c-parent/some-stack"
out="$(run_detect "$FIXT/f15c-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F15c: subdir with up.sh but no compose is not offered as a CANDIDATE"
else
  fail "S1b-2 F15c: subdir with up.sh but no compose (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F16: BOTH files present, but no kvendra-platform service -----
# The dangerous shape: an ordinary project of the user that happens to ship a
# Compose file and a start script. Resolving it would make S2 execute THEIR
# up.sh with --with-ollama, with no confirmation (decision-tree rule 1).
mkdir -p "$FIXT/f16a-foreign"
write_foreign_compose "$FIXT/f16a-foreign/docker-compose.yml"
write_up_sh "$FIXT/f16a-foreign"
out="$(run_detect "$FIXT/f16a-foreign")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F16a: the user's own repo (compose + up.sh, no platform service) does not resolve"
else
  fail "S1b-2 F16a: foreign repo with compose + up.sh (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f16b-parent/kvendra-reference-stack"
write_foreign_compose "$FIXT/f16b-parent/kvendra-reference-stack/docker-compose.yml"
write_up_sh "$FIXT/f16b-parent/kvendra-reference-stack"
out="$(run_detect "$FIXT/f16b-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F16b: canonical subdir without the platform service does not resolve"
else
  fail "S1b-2 F16b: canonical subdir without the platform service (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

mkdir -p "$FIXT/f16c-parent/some-stack"
write_foreign_compose "$FIXT/f16c-parent/some-stack/docker-compose.yml"
write_up_sh "$FIXT/f16c-parent/some-stack"
out="$(run_detect "$FIXT/f16c-parent")"
if has_line "$out" "RESOLVED none" && [[ "$(count_lines "$out" '^CANDIDATE ')" -eq 0 ]]; then
  pass "S1b-2 F16c: subdir without the platform service is not offered as a CANDIDATE"
else
  fail "S1b-2 F16c: subdir without the platform service (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F17: SIBLING clone (the workspace-of-sibling-repos layout) ---
# cwd is the user's own repo; the clone lives next to it, not above and not
# below. Without the sibling branch this reports "none" and the wizard offers
# to clone a second copy under $HOME.
mkdir -p "$FIXT/f17-workspace/user-project"
mk_stack "$FIXT/f17-workspace/kvendra-reference-stack"
out="$(run_detect "$FIXT/f17-workspace/user-project")"
if has_line "$out" "RESOLVED $(phys "$FIXT/f17-workspace")/kvendra-reference-stack"; then
  pass "S1b-2 F17: sibling ../kvendra-reference-stack resolved (no second clone proposed)"
else
  fail "S1b-2 F17: sibling clone (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# The sibling branch must obey the SAME predicate: a sibling directory with the
# canonical name but a foreign compose must not be adopted.
mkdir -p "$FIXT/f17b-workspace/user-project"
mkdir -p "$FIXT/f17b-workspace/kvendra-reference-stack"
write_foreign_compose "$FIXT/f17b-workspace/kvendra-reference-stack/docker-compose.yml"
write_up_sh "$FIXT/f17b-workspace/kvendra-reference-stack"
out="$(run_detect "$FIXT/f17b-workspace/user-project")"
if has_line "$out" "RESOLVED none"; then
  pass "S1b-2 F17b: sibling with the canonical name but no platform service does not resolve"
else
  fail "S1b-2 F17b: sibling without the platform service (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F7: destination exists, not empty, not the stack ------------
mkdir -p "$FIXT/f7-dest"
: > "$FIXT/f7-dest/README.md"
out="$(run_validate "$FIXT/f7-dest")"
det="$(run_detect "$FIXT/f7-dest")"
if has_line "$out" "DEST exists-not-empty" \
   && ! printf '%s\n' "$out" | grep -q 'REJECT' \
   && has_line "$det" "RESOLVED none"; then
  pass "S1b-4 F7: existing non-empty non-stack destination -> exists-not-empty + predicate fails"
else
  fail "S1b-4 F7: existing non-empty non-stack destination (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F8: destination exists and IS the stack (idempotency) -------
mkdir -p "$FIXT/f8-parent"
mk_stack "$FIXT/f8-parent/kvendra-reference-stack"
out="$(run_validate "$FIXT/f8-parent/kvendra-reference-stack")"
det="$(run_detect "$FIXT/f8-parent/kvendra-reference-stack")"
if has_line "$out" "DEST exists-not-empty" \
   && has_line "$det" "RESOLVED $(phys "$FIXT/f8-parent")/kvendra-reference-stack"; then
  pass "S1b-4 F8: existing destination that IS the stack -> reused, never re-cloned"
else
  fail "S1b-4 F8: existing destination that IS the stack (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F9: destination exists and is empty -------------------------
mkdir -p "$FIXT/f9-parent/kvendra-reference-stack"
out="$(run_validate "$FIXT/f9-parent/kvendra-reference-stack")"
if has_line "$out" "DEST exists-empty" \
   && ! printf '%s\n' "$out" | grep -q 'REJECT' \
   && ! printf '%s\n' "$out" | grep -q 'WARN non-canonical-directory-name'; then
  pass "S1b-4 F9: empty canonical destination -> exists-empty, no REJECT, no WARN"
else
  fail "S1b-4 F9: empty canonical destination (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F10: REJECT destinations ------------------------------------
out="$(run_validate "/")"
if has_line "$out" "REJECT filesystem-root"; then
  pass "S1b-4 F10a: / rejected (filesystem-root)"
else
  fail "S1b-4 F10a: / rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_validate "$HOME")"
if has_line "$out" "REJECT home-directory-itself"; then
  pass "S1b-4 F10b: \$HOME rejected (home-directory-itself)"
else
  fail "S1b-4 F10b: \$HOME rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_validate "$HOME/.claude/plugins/kvendra-marketplace/kvendra-reference-stack")"
if has_line "$out" "REJECT read-only-plugin-cache"; then
  pass "S1b-4 F10c: path under ~/.claude/plugins rejected (read-only plugin cache)"
else
  fail "S1b-4 F10c: path under ~/.claude/plugins rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# F10d/F10e — trailing slash must not defeat the whole-string comparisons.
out="$(run_validate "$HOME/")"
if has_line "$out" "REJECT home-directory-itself"; then
  pass "S1b-4 F10d: \$HOME with a trailing slash still rejected (destination normalised)"
else
  fail "S1b-4 F10d: \$HOME with a trailing slash rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_validate "//")"
if has_line "$out" "REJECT filesystem-root"; then
  pass "S1b-4 F10e: a destination of only slashes still rejected (filesystem-root)"
else
  fail "S1b-4 F10e: only-slashes destination rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# F10f — macOS firmlinks: the PHYSICAL path of /var and /etc is /private/var
# and /private/etc, so a /var/* prefix alone leaves the real path uncovered.
for sysdest in /private/var/tmp/kvendra-reference-stack \
               /private/etc/kvendra-reference-stack \
               /Library/Caches/kvendra-reference-stack \
               /usr/local/kvendra-reference-stack; do
  out="$(run_validate "$sysdest")"
  if has_line "$out" "REJECT system-directory"; then
    pass "S1b-4 F10f: system destination rejected ($sysdest)"
  else
    fail "S1b-4 F10f: system destination rejected ($sysdest, got: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
done

# F10g — /opt is deliberately NOT a system directory: the stack is
# cross-platform and /opt/kvendra-reference-stack is a defensible destination on
# Linux. The case that matters (a parent the user cannot write) is caught by the
# writability probe with the right diagnosis, so this must not regress into a
# blanket REJECT.
out="$(run_validate "/opt/kvendra-reference-stack")"
if ! printf '%s\n' "$out" | grep -q 'REJECT system-directory'; then
  pass "S1b-4 F10g: /opt is not rejected as a system directory (cross-platform destination)"
else
  fail "S1b-4 F10g: /opt must not be rejected as a system directory (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- F11: parent without write permission ------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  skip "S1b-4 F11: non-writable parent (running as root: every path is writable)"
else
  mkdir -p "$FIXT/f11-parent"
  chmod 500 "$FIXT/f11-parent"
  out="$(run_validate "$FIXT/f11-parent/kvendra-reference-stack")"
  chmod 700 "$FIXT/f11-parent"
  if has_line "$out" "REJECT parent-not-writable" && has_line "$out" "DEST does-not-exist"; then
    pass "S1b-4 F11: non-writable parent rejected before any disk write"
  else
    fail "S1b-4 F11: non-writable parent rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
fi

# ---- F12: parent does not exist (mkdir -p path) ------------------
# The legitimate "create the parent chain" path must NOT emit any REJECT: rule 1
# stops the flow on any REJECT, and a probe that cannot tell this case apart
# from a genuinely unwritable ancestor carries no information at all.
out="$(run_validate "$FIXT/f12-missing/deeper/kvendra-reference-stack")"
if has_line "$out" "DEST does-not-exist" \
   && has_line "$out" "PARENT does-not-exist" \
   && ! printf '%s\n' "$out" | grep -q 'REJECT'; then
  pass "S1b-4 F12: missing parent reported WITHOUT a spurious REJECT (mkdir -p chain)"
else
  fail "S1b-4 F12: missing parent without spurious REJECT (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# F12b — the writability REJECT must still fire for a parent that EXISTS and is
# not writable, and must be distinguishable from F12 (different output).
if [[ "$(id -u)" -eq 0 ]]; then
  skip "S1b-4 F12b: missing-parent vs unwritable-parent distinguishable (running as root)"
else
  mkdir -p "$FIXT/f12b-locked"
  chmod 500 "$FIXT/f12b-locked"
  locked_out="$(run_validate "$FIXT/f12b-locked/kvendra-reference-stack")"
  chmod 700 "$FIXT/f12b-locked"
  if printf '%s\n' "$locked_out" | grep -q 'REJECT parent-not-writable' \
     && ! printf '%s\n' "$out" | grep -q 'REJECT parent-not-writable'; then
    pass "S1b-4 F12b: unwritable existing parent and missing parent produce DIFFERENT output"
  else
    fail "S1b-4 F12b: unwritable vs missing parent distinguishable (locked: $(printf '%s' "$locked_out" | tr '\n' '|'))"
  fi
fi

# ---- F13: cloud-synced + awkward-character warnings --------------
mkdir -p "$FIXT/f13/Dropbox"
out="$(run_validate "$FIXT/f13/Dropbox/kvendra-reference-stack")"
if has_line "$out" "WARN cloud-synced-path"; then
  pass "S1b-4 F13a: cloud-synced destination warns (Dropbox)"
else
  fail "S1b-4 F13a: cloud-synced destination warns (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_validate "$FIXT/f13/my stack/kvendra-reference-stack")"
if has_line "$out" "WARN awkward-path-characters"; then
  pass "S1b-4 F13b: awkward path characters warn (Compose project-name normalisation)"
else
  fail "S1b-4 F13b: awkward path characters warn (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_validate "$FIXT/f13/my-own-stack")"
if has_line "$out" "WARN non-canonical-directory-name"; then
  pass "S1b-4 F13c: non-canonical directory name warns (stack-collision link)"
else
  fail "S1b-4 F13c: non-canonical directory name warns (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

echo ""
echo "==== summary ===="
echo "passed: $PASS"
echo "failed: $FAIL"
echo "skipped: $SKIPPED"
if [[ $FAIL -gt 0 ]]; then
  echo "failed assertions: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
