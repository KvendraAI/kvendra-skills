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
# Anchored to the S2 SECTION, not merely to the first `curl -fsS` line in the
# file: since 1.13.0 the wizard runs other curl-based steps (the S1c key probe),
# and a content-only anchor would capture whichever came first in the document.
# The Ollama block is deliberately the FIRST fenced block of S2, so this
# extractor lands on the branch that carries the flag.
BRINGUP_SNIPPET="$(awk '
  /^### S2/ { in_s2=1 }
  !in_s2 { next }
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

# ==================================================================
# 1.13.0 FIXTURES — S1c (embeddings key), the conditional S2 flag, document
# order and wording, the key probe, and the manifests.
#
# Same drift guard as everything above: the code under test is EXTRACTED from
# the shipped SKILL.md, never duplicated here. The extraction is FENCE-AWARE
# (the whole ```bash block that contains a distinctive marker) instead of
# line-prefix anchored, so a new step cannot silently steal another step's
# anchor the way a bare `^curl -fsS ` anchor could.
# ==================================================================
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

extract_block() {  # extract_block <awk-regex> : the fenced bash block containing it
  awk -v pat="$1" '
    /^```bash$/ { inb=1; buf=""; next }
    /^```$/ {
      if (inb && buf ~ pat) { printf "%s", buf; exit }
      inb=0; buf=""; next
    }
    inb { buf = buf $0 "\n" }
  ' "$SKILL_MD"
}

section() {  # section <start-regex> <end-regex> : lines of one SKILL.md section
  awk -v s="$1" -v e="$2" '
    $0 ~ s { inx=1; print; next }
    inx && $0 ~ e { exit }
    inx { print }
  ' "$SKILL_MD"
}

line_of() { grep -n -m1 -- "$1" "$SKILL_MD" | cut -d: -f1; }
has_str() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

ENVCREATE_SNIPPET="$(extract_block 'ENV exists-keep')"
ENVREWRITE_SNIPPET="$(extract_block 'kvd_is_ollama_wired')"
# Markers chosen to be UNIQUE to their block. `config -` would be wrong here:
# the S1b-2 detection block runs `git config --get remote.origin.url`, so it
# matches that substring and gets extracted instead of the probe.
PLACEHOLDER_SNIPPET="$(extract_block 'cut -c1-10')"
PROBE_SNIPPET="$(extract_block 'curl --config')"
SIGNUP_SNIPPET="$(extract_block 'KVD_SIGNUP_URL')"

# The literal placeholder line the wizard substitutes with the pasted key.
KEY_PLACEHOLDER="PASTE_THE_KEY_ON_A_LINE_OF_ITS_OWN"

# The literal placeholder every fenced block uses for the stack root resolved in
# S1b. Each Bash call is a fresh shell, so every block that references
# $STACK_ROOT has to declare it on its own first line; the runner substitutes
# that declaration with the temp stack root exactly as it substitutes the key.
# Substituting (instead of only pre-assigning STACK_ROOT around the eval) is
# what makes the extracted snippet run as SHIPPED — see T1q, the static
# assertion that guards the whole class.
ROOT_PLACEHOLDER="<absolute path resolved in S1b>"

# A faithful replica of the reference stack's .env.example. The comment block
# is NOT decoration: line "for you (in place, marked with ...)" QUOTES the
# Ollama marker inside prose, and it is the fixture that kills a substring-based
# detector (trap 1). Every T1 scenario is built from this.
write_env_example() {  # write_env_example <file>
  cat > "$1" <<'ENVEOF'
# --- Embeddings provider --------------------------------------------------
# Active defaults: Cloud mode (api.kvendra.cloud).
# Replace EMBEDDINGS_API_KEY with your real key from https://kvendra.cloud
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=https://api.kvendra.cloud/v1
EMBEDDINGS_MODEL=kvendra-embedding-v1
EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY

# --- Alternative mode: Ollama local ------------------------------------------
# Just run `./scripts/up.sh --with-ollama`: it starts the kvendra-ollama
# service AND rewrites the three EMBEDDINGS_* lines above to the values below
# for you (in place, marked with `# set by up.sh --with-ollama`). You do NOT
# need to uncomment these by hand.
# EMBEDDINGS_PROVIDER=openai-compatible
# EMBEDDINGS_BASE_URL=http://kvendra-ollama:11434/v1
# EMBEDDINGS_MODEL=mxbai-embed-large
# # No EMBEDDINGS_API_KEY needed for local Ollama.

EMBEDDINGS_TIMEOUT_MS=30000
PLATFORM_HOST_PORT=7777
ENVEOF
}

# What `up.sh --with-ollama` leaves behind: a standalone marker line plus the
# three rewired values.
write_env_ollama_wired() {  # write_env_ollama_wired <file>
  write_env_example "$1"
  awk '
    /^EMBEDDINGS_PROVIDER=/ { print "# set by up.sh --with-ollama"; print; next }
    /^EMBEDDINGS_BASE_URL=/ { print "EMBEDDINGS_BASE_URL=http://kvendra-ollama:11434/v1"; next }
    /^EMBEDDINGS_MODEL=/    { print "EMBEDDINGS_MODEL=mxbai-embed-large"; next }
    { print }
  ' "$1" > "$1.t" && mv "$1.t" "$1"
}

mk_env_stack() {  # mk_env_stack <dir> : stack dir carrying a .env.example
  mkdir -p "$1"
  write_env_example "$1/.env.example"
}

run_rewrite() {  # run_rewrite <stack_root> <key> : S1c-5 with both placeholders substituted
  (
    export PATH="$MOCK_BIN:$PATH"
    STACK_ROOT="$1"
    snippet="${ENVREWRITE_SNIPPET//$ROOT_PLACEHOLDER/$1}"
    snippet="${snippet//$KEY_PLACEHOLDER/$2}"
    eval "$snippet"
  ) 2>&1
}

run_envcreate() {  # run_envcreate <stack_root> : the S1c-4 block
  (
    export PATH="$MOCK_BIN:$PATH"
    STACK_ROOT="$1"
    eval "${ENVCREATE_SNIPPET//$ROOT_PLACEHOLDER/$1}"
  ) 2>&1
}

run_placeholder_check() {  # run_placeholder_check <stack_root> : the S1c-6 block
  (
    export PATH="$MOCK_BIN:$PATH"
    STACK_ROOT="$1"
    eval "${PLACEHOLDER_SNIPPET//$ROOT_PLACEHOLDER/$1}"
  ) 2>&1
}

perms_of() { ls -l "$1" | cut -c1-10; }
env_val() { grep -m1 "^$2=" "$1" | sed "s|^$2=||"; }

# ---- T0: every new snippet was actually extracted -----------------
for pair in "ENVCREATE_SNIPPET:S1c-4 .env creation" \
            "ENVREWRITE_SNIPPET:S1c-5 detect-and-rewrite" \
            "PLACEHOLDER_SNIPPET:S1c-6 placeholder check" \
            "PROBE_SNIPPET:S1c-7 key probe" \
            "SIGNUP_SNIPPET:S1c-2 signup accompaniment"; do
  var="${pair%%:*}"; label="${pair#*:}"
  if [[ -n "${!var}" ]]; then
    pass "T0: $label snippet extracted from SKILL.md"
  else
    fail "T0: $label snippet extracted from SKILL.md"
  fi
done

# ==================================================================
# T1 — the .env rewrite: four scenarios, the marker false positive,
# idempotency, permissions, portability, the gitignore gate and the
# placeholder check.
# ==================================================================
T1="$WORK_ROOT/t1"; mkdir -p "$T1"
TESTKEY="kvd_live_0123456789abcdefTESTKEY"

# ---- T1a: PRISTINE .env — only the key line changes ---------------
mk_env_stack "$T1/a"; cp "$T1/a/.env.example" "$T1/a/.env"
out="$(run_rewrite "$T1/a" "$TESTKEY")"
if has_str "$out" "ENV cloud-defaults-intact" \
   && [[ "$(env_val "$T1/a/.env" EMBEDDINGS_API_KEY)" == "$TESTKEY" ]] \
   && [[ "$(env_val "$T1/a/.env" EMBEDDINGS_BASE_URL)" == "https://api.kvendra.cloud/v1" ]] \
   && [[ "$(env_val "$T1/a/.env" EMBEDDINGS_MODEL)" == "kvendra-embedding-v1" ]] \
   && [[ "$(grep -c '^EMBEDDINGS_API_KEY=' "$T1/a/.env")" -eq 1 ]]; then
  pass "T1a: pristine .env -> only the key line rewritten, cloud values untouched"
else
  fail "T1a: pristine .env (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1b: THE MARKER FALSE POSITIVE -------------------------------
# .env.example QUOTES `# set by up.sh --with-ollama` inside a prose comment. A
# substring detector reads a pristine file as Ollama-wired and rewrites three
# lines that were already correct. Whole-line equality is the fix; this fixture
# is what fails if anyone reintroduces grep -F.
if has_str "$out" "ENV cloud-defaults-intact" && ! has_str "$out" "was-ollama-wired" \
   && grep -q 'marked with `# set by up.sh --with-ollama`' "$T1/a/.env"; then
  pass "T1b: the marker quoted inside a prose comment is NOT a wiring signal (no false positive)"
else
  fail "T1b: marker false positive (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1c: .env already holding a REAL key -------------------------
mk_env_stack "$T1/c"; cp "$T1/c/.env.example" "$T1/c/.env"
awk '/^EMBEDDINGS_API_KEY=/ { print "EMBEDDINGS_API_KEY=kvd_live_OLDKEY"; next } { print }' \
  "$T1/c/.env" > "$T1/c/.env.t" && mv "$T1/c/.env.t" "$T1/c/.env"
out="$(run_rewrite "$T1/c" "$TESTKEY")"
if [[ "$(env_val "$T1/c/.env" EMBEDDINGS_API_KEY)" == "$TESTKEY" ]] \
   && ! grep -q 'kvd_live_OLDKEY' "$T1/c/.env" \
   && [[ "$(grep -c '^EMBEDDINGS_API_KEY=' "$T1/c/.env")" -eq 1 ]]; then
  pass "T1c: an existing real key is replaced in place, not appended"
else
  fail "T1c: existing real key replaced (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1d: .env WIRED TO OLLAMA — three lines + the marker ---------
mk_env_stack "$T1/d"; write_env_ollama_wired "$T1/d/.env"
out="$(run_rewrite "$T1/d" "$TESTKEY")"
marker_lines="$(grep -cx '# set by up.sh --with-ollama' "$T1/d/.env" || true)"
if has_str "$out" "was-ollama-wired" \
   && [[ "$marker_lines" -eq 0 ]] \
   && [[ "$(env_val "$T1/d/.env" EMBEDDINGS_PROVIDER)" == "openai-compatible" ]] \
   && [[ "$(env_val "$T1/d/.env" EMBEDDINGS_BASE_URL)" == "https://api.kvendra.cloud/v1" ]] \
   && [[ "$(env_val "$T1/d/.env" EMBEDDINGS_MODEL)" == "kvendra-embedding-v1" ]] \
   && [[ "$(env_val "$T1/d/.env" EMBEDDINGS_API_KEY)" == "$TESTKEY" ]]; then
  pass "T1d: Ollama-wired .env -> marker dropped and all three cloud values restored"
else
  fail "T1d: Ollama-wired .env (marker lines=$marker_lines, got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# The prose comment must SURVIVE the marker drop: only the standalone line goes.
if grep -q 'marked with `# set by up.sh --with-ollama`' "$T1/d/.env"; then
  pass "T1d2: dropping the marker removes only the standalone line, not the prose comment"
else
  fail "T1d2: the prose comment quoting the marker was destroyed"
fi

# ---- T1e: NO .env at all (fresh clone) ----------------------------
mk_env_stack "$T1/e"
out="$(run_envcreate "$T1/e")"
if has_str "$out" "ENV created-from-example" && [[ -f "$T1/e/.env" ]] \
   && grep -q '^EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY' "$T1/e/.env"; then
  pass "T1e: a fresh clone with no .env gets one created from .env.example"
else
  fail "T1e: .env creation on a fresh clone (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1f: an existing .env is NEVER overwritten -------------------
mk_env_stack "$T1/f"
printf 'CUSTOM_MARKER=do-not-lose-me\nEMBEDDINGS_API_KEY=kvd_live_MINE\n' > "$T1/f/.env"
out="$(run_envcreate "$T1/f")"
if has_str "$out" "ENV exists-keep" && grep -q '^CUSTOM_MARKER=do-not-lose-me' "$T1/f/.env"; then
  pass "T1f: an existing .env is kept as-is (custom content preserved)"
else
  fail "T1f: existing .env preserved (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1g: IDEMPOTENCY — running the rewrite twice is a no-op ------
mk_env_stack "$T1/g"; write_env_ollama_wired "$T1/g/.env"
run_rewrite "$T1/g" "$TESTKEY" >/dev/null
cp "$T1/g/.env" "$T1/g/after-first"
run_rewrite "$T1/g" "$TESTKEY" >/dev/null
if cmp -s "$T1/g/after-first" "$T1/g/.env"; then
  pass "T1g: the rewrite is idempotent (second run produces a byte-identical .env)"
else
  fail "T1g: rewrite not idempotent ($(diff "$T1/g/after-first" "$T1/g/.env" | head -5 | tr '\n' '|'))"
fi

# ---- T1h: PERMISSIONS survive every mv ----------------------------
# `mv` replaces the file, so a single chmod at the end is not enough: each
# rewrite has to re-apply 600. The Ollama-wired path performs FIVE rewrites.
if [[ "$(perms_of "$T1/g/.env")" == "-rw-------" ]] \
   && [[ "$(perms_of "$T1/a/.env")" == "-rw-------" ]] \
   && [[ "$(perms_of "$T1/e/.env")" == "-rw-------" ]]; then
  pass "T1h: .env is 0600 after every rewrite path (creation, single-line, full rewire)"
else
  fail "T1h: .env permissions (rewired=$(perms_of "$T1/g/.env"), pristine=$(perms_of "$T1/a/.env"), created=$(perms_of "$T1/e/.env"))"
fi

# ---- T1i: no temp file is left behind -----------------------------
if [[ ! -e "$T1/g/.env.kvdtmp" && ! -e "$T1/a/.env.kvdtmp" ]]; then
  pass "T1i: the awk temp file is always moved, never left behind"
else
  fail "T1i: a .env.kvdtmp temp file survived the rewrite"
fi

# ---- T1j: PORTABILITY — no in-place sed anywhere in the skill -----
# BSD/macOS and GNU disagree on the argument of sed's in-place flag; the stack's
# own up.sh avoids it for exactly that reason.
sedi_hits="$(grep -nE "sed +-i" "$SKILL_MD" || true)"
if [[ -z "$sedi_hits" ]]; then
  pass "T1j: the skill never uses the in-place flag of sed (BSD/GNU portability)"
else
  fail "T1j: in-place sed found in SKILL.md ($(printf '%s' "$sedi_hits" | tr '\n' '|'))"
fi

# ---- T1k: the GITIGNORE gate --------------------------------------
if [[ -z "$GIT_BIN" ]]; then
  skip "T1k: gitignore gate (no working git binary on this machine)"
else
  mk_env_stack "$T1/k-ignored"
  ( export PATH="$MOCK_BIN:$PATH"; cd "$T1/k-ignored" && git init -q . ) >/dev/null 2>&1
  printf '.env\n' > "$T1/k-ignored/.gitignore"
  out_ok="$(run_envcreate "$T1/k-ignored")"

  mk_env_stack "$T1/k-tracked"
  ( export PATH="$MOCK_BIN:$PATH"; cd "$T1/k-tracked" && git init -q . ) >/dev/null 2>&1
  out_bad="$(run_envcreate "$T1/k-tracked")"

  mk_env_stack "$T1/k-tarball"
  out_tar="$(run_envcreate "$T1/k-tarball")"

  if has_str "$out_ok" "GITIGNORE ok" \
     && has_str "$out_bad" "REJECT env-not-gitignored" \
     && has_str "$out_tar" "GITIGNORE not-a-git-repo"; then
    pass "T1k: gitignore gate distinguishes ignored, TRACKED (REJECT) and non-git stacks"
  else
    fail "T1k: gitignore gate (ok='$out_ok' bad='$out_bad' tar='$out_tar')"
  fi
fi

# ---- T1l: the PLACEHOLDER is provably gone ------------------------
out="$(run_placeholder_check "$T1/d")"
ph_count="$(printf '%s\n' "$out" | sed -n 1p)"
cloud_count="$(printf '%s\n' "$out" | sed -n 2p)"
ph_perms="$(printf '%s\n' "$out" | sed -n 3p)"
if [[ "$ph_count" == "0" && "$cloud_count" == "1" && "$ph_perms" == "-rw-------" ]]; then
  pass "T1l: after S1c the placeholder count is 0 (up.sh's late warning is unreachable)"
else
  fail "T1l: placeholder check (placeholder=$ph_count cloud=$cloud_count perms=$ph_perms)"
fi

# The same check over an UNTOUCHED .env must report 1, or it proves nothing.
mk_env_stack "$T1/l-raw"; cp "$T1/l-raw/.env.example" "$T1/l-raw/.env"
out="$(run_placeholder_check "$T1/l-raw")"
if [[ "$(printf '%s\n' "$out" | sed -n 1p)" == "1" ]]; then
  pass "T1l2: the placeholder check reports 1 on an untouched .env (the assertion has teeth)"
else
  fail "T1l2: placeholder check on an untouched .env (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---- T1m: key FORM validation -------------------------------------
mk_env_stack "$T1/m"; cp "$T1/m/.env.example" "$T1/m/.env"
out="$(run_rewrite "$T1/m" "")"
if has_str "$out" "REJECT empty-key" && ! has_str "$out" "ENV key-written"; then
  pass "T1m1: an empty key is REJECTed and nothing is written"
else
  fail "T1m1: empty key rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_rewrite "$T1/m" "kvd_live_with space")"
if has_str "$out" "REJECT whitespace-or-newline-in-key" && ! has_str "$out" "ENV key-written"; then
  pass "T1m2: a key containing whitespace is REJECTed"
else
  fail "T1m2: whitespace key rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_rewrite "$T1/m" "$(printf 'kvd_live_a\nkvd_live_b')")"
if has_str "$out" "REJECT whitespace-or-newline-in-key" && ! has_str "$out" "ENV key-written"; then
  pass "T1m3: a multi-line paste is REJECTed"
else
  fail "T1m3: multi-line key rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_rewrite "$T1/m" "kvd_live_a=b")"
if has_str "$out" "REJECT equals-sign-in-key" && ! has_str "$out" "ENV key-written"; then
  pass "T1m4: a key containing = is REJECTed"
else
  fail "T1m4: equals-sign key rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_rewrite "$T1/m" "REPLACE_WITH_YOUR_KVENDRA_KEY")"
if has_str "$out" "REJECT placeholder-pasted" && ! has_str "$out" "ENV key-written"; then
  pass "T1m5: pasting the placeholder back is REJECTed"
else
  fail "T1m5: placeholder rejected (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# The .env must be untouched after every REJECT above.
if grep -q '^EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY' "$T1/m/.env"; then
  pass "T1m6: no REJECTed key ever reached the .env"
else
  fail "T1m6: a REJECTed key was written to .env"
fi

# WARN, never REJECT: the key format belongs to the hosted engine.
out="$(run_rewrite "$T1/m" "sk-someothervendorkey")"
if has_str "$out" "WARN unexpected-key-prefix" && has_str "$out" "ENV key-written" \
   && ! has_str "$out" "REJECT"; then
  pass "T1m7: an unexpected key prefix WARNs and still writes (never REJECT)"
else
  fail "T1m7: unexpected prefix warns but writes (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_rewrite "$T1/m" 'kvd_live_a#b$c')"
if has_str "$out" "WARN unsafe-characters-for-dotenv-sourcing" && has_str "$out" "ENV key-written"; then
  pass "T1m8: characters unsafe for a sourced .env WARN and still write"
else
  fail "T1m8: unsafe characters warn (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# The quoted heredoc delimiter is what keeps `$` and backticks literal.
if [[ "$(env_val "$T1/m/.env" EMBEDDINGS_API_KEY)" == 'kvd_live_a#b$c' ]]; then
  pass "T1m9: the quoted heredoc delimiter keeps \$ literal (no expansion of the secret)"
else
  fail "T1m9: secret expanded by the shell (got: '$(env_val "$T1/m/.env" EMBEDDINGS_API_KEY)')"
fi

# The non-secret values must travel as awk -v, the secret through ENVIRON.
if has_str "$ENVREWRITE_SNIPPET" 'ENVIRON["KVD_EMB_KEY"]' \
   && has_str "$ENVREWRITE_SNIPPET" 'export KVD_EMB_KEY=' \
   && has_str "$ENVREWRITE_SNIPPET" "<<'KVD_KEY_EOF'" \
   && has_str "$ENVREWRITE_SNIPPET" 'unset KVD_EMB_KEY'; then
  pass "T1n: the secret travels through ENVIRON with an explicit export and a quoted heredoc"
else
  fail "T1n: secret transport (ENVIRON + explicit export + quoted heredoc)"
fi

# Trap 2 as an executable assertion: no `VAR=value function` prefix form.
if ! printf '%s\n' "$ENVREWRITE_SNIPPET" | grep -qE '^[[:space:]]*KVD_EMB_KEY=[^ ]* +kvd_'; then
  pass "T1o: the secret is never passed as an assignment prefixing a function call (trap 2)"
else
  fail "T1o: an assignment-prefixed function call would leave ENVIRON empty"
fi

# Trap 3: one chmod per mv, not one at the end.
mv_count="$(printf '%s\n' "$ENVREWRITE_SNIPPET" | grep -c 'mv "\$ENV_FILE.kvdtmp"' | tr -d ' ')"
chmod_count="$(printf '%s\n' "$ENVREWRITE_SNIPPET" | grep -c 'chmod 600 "\$ENV_FILE"' | tr -d ' ')"
if [[ "$mv_count" -ge 3 && "$chmod_count" -eq "$mv_count" ]]; then
  pass "T1p: every mv ($mv_count) is followed by its own chmod 600 (trap 3)"
else
  fail "T1p: chmod per mv (mv=$mv_count chmod=$chmod_count)"
fi

# ---- T1q: every bash fence that USES $STACK_ROOT also DECLARES it ---------
# THE CLASS-LEVEL GUARD, not a fourth instance of a bug found four times.
#
# Every Bash call is a fresh shell — the skill says so itself: the stack root is
# "passed explicitly in every Bash call. Never rely on a `cd` from a previous
# call — it does not persist." A block that references $STACK_ROOT without
# assigning it therefore resolves it to the empty string: ENV_FILE becomes
# "/.env", the copy from .env.example fails, and the git-ignore gate answers
# `GITIGNORE not-a-git-repo`, which the skill classifies as "not a rejection" —
# so the wizard walks on with a broken .env and no diagnostic.
#
# Why this has to be a STATIC assertion over the SKILL.md text: the executable
# helpers above pre-assign STACK_ROOT around the `eval` and substitute
# $ROOT_PLACEHOLDER into the snippet, so no runtime fixture can ever observe a
# missing declaration. The defect class is invisible to execution by
# construction; only the text can testify.
#
# Scope is deliberately STACK_ROOT ONLY. S4 references ${TOKEN} without
# declaring it in the same fence — a pre-existing defect, identical in 1.12.0,
# outside this increment. Generalising this assertion to every variable would
# turn that red and widen the increment instead of guarding it.
stack_root_offenders="$(awk '
  /^```bash$/ { inb=1; uses=0; decl=0; start=NR; next }
  /^```$/ {
    if (inb && uses && !decl) printf("line %d ", start)
    inb=0; uses=0; decl=0; next
  }
  inb {
    if (index($0, "$STACK_ROOT") > 0 || index($0, "${STACK_ROOT}") > 0) uses = 1
    if ($0 ~ /^[[:space:]]*STACK_ROOT=/) decl = 1
  }
' "$SKILL_MD")"
stack_root_users="$(awk '
  /^```bash$/ { inb=1; uses=0; next }
  /^```$/ { if (inb && uses) n++; inb=0; uses=0; next }
  inb { if (index($0, "$STACK_ROOT") > 0 || index($0, "${STACK_ROOT}") > 0) uses = 1 }
  END { print n+0 }
' "$SKILL_MD")"
if [[ -z "$stack_root_offenders" && "$stack_root_users" -ge 8 ]]; then
  pass "T1q: all $stack_root_users bash fences that reference \$STACK_ROOT declare it in the same fence"
else
  fail "T1q: bash fence(s) reference \$STACK_ROOT without declaring it (opened at: ${stack_root_offenders:-none}; users=$stack_root_users)"
fi

# The declaration must be the SAME literal everywhere, or "declared" degrades
# into "assigned something": a fence that invents its own wording is a fence the
# runner cannot substitute and the reader cannot follow.
root_decl_total="$(grep -c '^STACK_ROOT=' "$SKILL_MD" | tr -d ' ')"
root_decl_canon="$(grep -cF "STACK_ROOT=\"$ROOT_PLACEHOLDER\"" "$SKILL_MD" | tr -d ' ')"
if [[ "$root_decl_total" -eq "$root_decl_canon" && "$root_decl_canon" -ge 8 ]]; then
  pass "T1r: every \$STACK_ROOT declaration uses the one canonical literal ($root_decl_canon of them)"
else
  fail "T1r: STACK_ROOT declarations drifted (total=$root_decl_total canonical=$root_decl_canon)"
fi

# ==================================================================
# T2 — S2: the Ollama flag is CONDITIONAL on the Q2 answer.
# The single highest-value fix of the increment: passing the flag on the cloud
# branch rewires the embeddings AND suppresses up.sh's placeholder warning, so
# the key written in S1c would sit there inert with no diagnostic at all.
# ==================================================================
S2_SECTION="$(section '^### S2 ' '^### S3 ')"
S2_OLLAMA="$(printf '%s\n' "$S2_SECTION" | awk '/\*\*Ollama branch/ { c=1 } /\*\*Cloud-embeddings branch/ { exit } c { print }')"
S2_CLOUD="$(printf '%s\n' "$S2_SECTION" | awk '/\*\*Cloud-embeddings branch/ { c=1 } c { print }')"

if [[ -n "$S2_OLLAMA" && -n "$S2_CLOUD" ]]; then
  pass "T2a: S2 has two distinct branch blocks (Ollama first, cloud second)"
else
  fail "T2a: S2 branch blocks (ollama=${#S2_OLLAMA} cloud=${#S2_CLOUD})"
fi

if has_str "$S2_OLLAMA" '|| "$STACK_ROOT/scripts/up.sh" --with-ollama'; then
  pass "T2b: the Ollama branch invokes the start script WITH the flag"
else
  fail "T2b: Ollama branch flag"
fi

cloud_flag_hits="$(printf '%s\n' "$S2_CLOUD" | grep -c 'with-ollama' | tr -d ' ')"
if [[ "$cloud_flag_hits" -eq 0 ]]; then
  pass "T2c: the cloud-embeddings branch of S2 mentions the Ollama flag ZERO times"
else
  fail "T2c: the cloud branch of S2 still carries the Ollama flag ($cloud_flag_hits hits)"
fi

if printf '%s\n' "$S2_CLOUD" | grep -qx '  || "\$STACK_ROOT/scripts/up.sh"'; then
  pass "T2d: the cloud branch invokes the start script BARE, by absolute \$STACK_ROOT path"
else
  fail "T2d: cloud branch bare invocation (got: $(printf '%s' "$S2_CLOUD" | grep 'up.sh' | tr '\n' '|'))"
fi

# The shipped 1.12.0 line "retry it as `bash ...up.sh --with-ollama`" sat OUTSIDE
# any conditional. Every remaining mention of the flag in S2 must be inside the
# Ollama block.
s2_flag_total="$(printf '%s\n' "$S2_SECTION" | grep -c -- '--with-ollama' | tr -d ' ')"
s2_flag_ollama="$(printf '%s\n' "$S2_OLLAMA" | grep -c -- '--with-ollama' | tr -d ' ')"
s2_flag_intro="$(printf '%s\n' "$S2_SECTION" | awk '/\*\*Ollama branch/ { exit } { print }' | grep -c -- '--with-ollama' | tr -d ' ')"
if [[ "$s2_flag_total" -eq $((s2_flag_ollama + s2_flag_intro)) && "$s2_flag_intro" -eq 0 ]]; then
  pass "T2e: every --with-ollama occurrence in S2 lives inside the Ollama conditional"
else
  fail "T2e: --with-ollama outside the Ollama conditional (total=$s2_flag_total ollama=$s2_flag_ollama intro=$s2_flag_intro)"
fi

# ==================================================================
# T3 — document order and the load-bearing wording.
# ==================================================================
l_s1b6="$(line_of '#### S1b-6')"
l_s1c="$(line_of '### S1c —')"
l_s2="$(line_of '### S2 —')"
if [[ -n "$l_s1b6" && -n "$l_s1c" && -n "$l_s2" && "$l_s1b6" -lt "$l_s1c" && "$l_s1c" -lt "$l_s2" ]]; then
  pass "T3a: S1c sits strictly between S1b-6 and S2 (S1b-6=$l_s1b6 S1c=$l_s1c S2=$l_s2)"
else
  fail "T3a: S1c ordering (S1b-6=$l_s1b6 S1c=$l_s1c S2=$l_s2)"
fi

prev=0; order_ok=1
for n in 1 2 3 4 5 6 7; do
  ln="$(line_of "#### S1c-$n")"
  if [[ -z "$ln" || "$ln" -le "$prev" ]]; then order_ok=0; break; fi
  prev="$ln"
done
if [[ "$order_ok" -eq 1 ]]; then
  pass "T3b: all seven S1c sub-steps are present and in order"
else
  fail "T3b: S1c sub-steps present and ordered (broke at S1c-${n:-?})"
fi

# Strings that MUST be gone.
gone_ok=1; gone_report=""
while IFS= read -r bad; do
  [[ -z "$bad" ]] && continue
  if grep -qF -- "$bad" "$SKILL_MD"; then gone_ok=0; gone_report="$gone_report|$bad"; fi
done <<'GONE'
Full key-rewire automation is a v1.1 follow-up
export it before bring-up
the read test is identical
## Self-hosted + local-embeddings automated flow
instructions only in this MVP
docs/SETUP-PRO.md
GONE
if [[ "$gone_ok" -eq 1 ]]; then
  pass "T3c: every superseded / factually wrong string is gone from the skill"
else
  fail "T3c: superseded strings still present ($gone_report)"
fi

# Strings that MUST be present.
need_ok=1; need_report=""
while IFS= read -r good; do
  [[ -z "$good" ]] && continue
  if ! grep -qF -- "$good" "$SKILL_MD"; then need_ok=0; need_report="$need_report|$good"; fi
done <<'NEED'
## Self-hosted automated flow
The cloud path performs no local registration
never visible to `ps` on your
it does appear once in this conversation's transcript
PASTED_BY_USER
mxbai-embed-large
kvendra-embedding-v1
1024-dim
403 forbidden_tier
https://kvendra.ai
https://kvendra.cloud
mcp__kvendra-platform__entity_query
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query
## External-execution policy
NEED
if [[ "$need_ok" -eq 1 ]]; then
  pass "T3d: every load-bearing string is present (escape hatch, both namespaces, both domains)"
else
  fail "T3d: missing load-bearing strings ($need_report)"
fi

# The migration rationale names the MODELS and the dimension, never the vendor.
if ! grep -qiE '\b(titan|bedrock)\b' "$SKILL_MD"; then
  pass "T3e: the vector-space rationale names no embedding vendor (models and dimension only)"
else
  fail "T3e: an embedding vendor is named in the skill"
fi

# Open-core posture: no pricing anywhere. The pattern deliberately does NOT
# include a bare `$<digit>`: shell positional parameters and `$0 == m` would
# match it, which is noise, not a pricing leak.
PRICE_RE='pricing|price|per month|per user|USD|EUR|tier matrix|subscription|checkout'
if ! grep -qEi "$PRICE_RE" "$SKILL_MD"; then
  pass "T3f: no pricing or tier matrix leaked into the skill (open-core posture)"
else
  fail "T3f: pricing-like text found ($(grep -nEi "$PRICE_RE" "$SKILL_MD" | head -3 | tr '\n' '|'))"
fi

# The cloud path: two executable branches plus the no-authentication disclaimer.
CLOUD_SECTION="$(section '^### Cloud path' '^## Q2')"
if has_str "$CLOUD_SECTION" "**C1 —" && has_str "$CLOUD_SECTION" "**C2 —" \
   && has_str "$CLOUD_SECTION" "the wizard does not authenticate" \
   && has_str "$CLOUD_SECTION" "does not create the account"; then
  pass "T3g: the cloud path branches on Pro (C1/C2) and disclaims authenticating"
else
  fail "T3g: cloud path branches + disclaimer"
fi

# S1 branch (c) must route into a real rewire.
S1_SECTION="$(section '^### S1 —' '^### S1b')"
if has_str "$S1_SECTION" "re-enters" && has_str "$S1_SECTION" "S1c"; then
  pass "T3h: S1 branch (c) routes back into Q2 and S1c instead of promising nothing"
else
  fail "T3h: S1 branch (c) is still an empty promise"
fi

# The four traps must be documented in prose, not only encoded in the snippets.
S1C_SECTION="$(section '^### S1c ' '^### S2 ')"
if has_str "$S1C_SECTION" "FALSE POSITIVE" \
   && has_str "$S1C_SECTION" "does NOT export" \
   && has_str "$S1C_SECTION" "overwrites the destination's permissions" \
   && has_str "$S1C_SECTION" "in-place flag of \`sed\`"; then
  pass "T3i: all four traps are documented in the SKILL.md itself, not only in the code"
else
  fail "T3i: the four traps are not all documented in prose"
fi

# The probe ladder has FIVE states, not two.
ladder_rows="$(printf '%s\n' "$S1C_SECTION" | grep -c '^| `2xx`\|^| `401`\|^| `429`\|^| `403`\|^| `CURL_RC`' | tr -d ' ')"
if [[ "$ladder_rows" -eq 5 ]]; then
  pass "T3j: the probe ladder documents all five outcomes (2xx / 401 / 429 / other / transport)"
else
  fail "T3j: probe ladder rows (expected 5, saw $ladder_rows)"
fi

# S7 must be byte-identical to the shipped text.
S7_EXPECTED="$(cat <<'S7EOF'
### S7 — Migration guard (honest)

If the user later wants to move from self-hosted to cloud (or vice versa), be
honest about the cost: vectors are NOT portable across embedding models, so a
backend switch requires **re-embedding** the whole KB. The open-core build has
no export/import path for this. Point the user to https://kvendra.ai/docs for
the supported migration story. Do not present a fake one-click switch.
S7EOF
)"
S7_ACTUAL="$(section '^### S7 ' '^### S8 ' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')"
if [[ "$S7_ACTUAL" == "$S7_EXPECTED" ]]; then
  pass "T3k: S7 (migration guard) is untouched, word for word"
else
  fail "T3k: S7 drifted from the shipped text"
fi

# Required output gains exactly the three new rows.
if grep -q '^| Embeddings backend |' "$SKILL_MD" \
   && grep -q '^| Embeddings key | WIRED / KEPT_EXISTING / PASTED_BY_USER / SKIPPED |' "$SKILL_MD" \
   && grep -q '^| Key probe |' "$SKILL_MD"; then
  pass "T3l: Required output reports the embeddings backend, the key outcome and the probe"
else
  fail "T3l: Required output rows"
fi

# Invariant: /setup still performs no KB write.
if ! grep -q 'entity_update(' "$SKILL_MD" && ! grep -q 'entity_create(' "$SKILL_MD" \
   && ! grep -q 'txn_create(' "$SKILL_MD"; then
  pass "T3m: /setup still writes nothing to the KB (no entity_update / entity_create / txn_create)"
else
  fail "T3m: a KB write call appeared in /setup"
fi

# The signup accompaniment: best-effort open, URL ALWAYS printed, no polling.
if has_str "$SIGNUP_SNIPPET" 'echo "Free embeddings key' \
   && has_str "$SIGNUP_SNIPPET" 'command -v open' \
   && has_str "$SIGNUP_SNIPPET" 'command -v xdg-open' \
   && has_str "$S1C_SECTION" "No polling, no timeout"; then
  pass "T3n: S1c-2 opens the browser best-effort, always prints the URL, and never polls"
else
  fail "T3n: S1c-2 signup accompaniment"
fi

# ---- T3o (kills M5): S6 maps each namespace to the RIGHT branch ------------
# T3d only proves both namespace strings EXIST somewhere in the file, so
# swapping them between the two verify blocks leaves it green — and that
# mapping is the entire point of the S6 fix: the two MCP servers expose
# DIFFERENT tool namespaces, so verifying a self-hosted registration with the
# cloud namespace tests the wrong server, or fails confusingly.
S6_SECTION="$(section '^### S6 ' '^### S7 ')"
S6_SELF="$(printf '%s\n' "$S6_SECTION" | awk '/^Self-hosted path/ { c=1 } /^Cloud path/ { exit } c { print }')"
S6_CLOUD="$(printf '%s\n' "$S6_SECTION" | awk '/^Cloud path/ { c=1 } c && /^- / { exit } c { print }')"

if [[ -n "$S6_SELF" && -n "$S6_CLOUD" ]]; then
  pass "T3o1: S6 has two distinct verify blocks (self-hosted first, cloud second)"
else
  fail "T3o1: S6 verify blocks (self=${#S6_SELF} cloud=${#S6_CLOUD})"
fi

if has_str "$S6_SELF" 'mcp__kvendra-platform__entity_query' \
   && ! has_str "$S6_SELF" 'kvendra-cloud__'; then
  pass "T3o2: the self-hosted verify block uses the kvendra-platform namespace, and only that one"
else
  fail "T3o2: self-hosted verify namespace (got: $(printf '%s' "$S6_SELF" | grep 'mcp__' | tr '\n' '|'))"
fi

if has_str "$S6_CLOUD" 'mcp__plugin_kvendra-skills_kvendra-cloud__entity_query' \
   && ! has_str "$S6_CLOUD" 'mcp__kvendra-platform__'; then
  pass "T3o3: the cloud verify block uses the bundled kvendra-cloud namespace, and only that one"
else
  fail "T3o3: cloud verify namespace (got: $(printf '%s' "$S6_CLOUD" | grep 'mcp__' | tr '\n' '|'))"
fi

# ---- T3p (kills M6): the probe's endpoint and model are the real contract --
# Nothing else asserts WHAT the probe calls: rewriting the path to
# /v1/WRONG-ENDPOINT and the model to "WRONG-MODEL" leaves every other
# assertion green, because the curl mock answers whatever it is asked.
#
# CONTRACT OWNERSHIP: `POST /v1/embeddings` and the `kvendra-embedding-v1`
# model alias belong to IF-KVD-ENTERPRISE-25BF5A (CMP-KVD-ENTERPRISE), NOT to
# this repo. They can therefore drift from OUTSIDE this repo, with nothing here
# to notice. When this assertion fails, check the IF version before touching
# the skill: the skill may be the correct side.
if has_str "$PROBE_SNIPPET" "-X POST 'https://api.kvendra.cloud/v1/embeddings'"; then
  pass "T3p1: the probe posts to the contracted endpoint https://api.kvendra.cloud/v1/embeddings"
else
  fail "T3p1: probe endpoint drifted (got: $(printf '%s' "$PROBE_SNIPPET" | grep -i 'kvendra.cloud' | tr '\n' '|'))"
fi

if has_str "$PROBE_SNIPPET" '"model":"kvendra-embedding-v1"'; then
  pass "T3p2: the probe requests the contracted model kvendra-embedding-v1"
else
  fail "T3p2: probe model drifted (got: $(printf '%s' "$PROBE_SNIPPET" | grep -- '-d ' | tr '\n' '|'))"
fi

# ---- T3q (kills M7): the 401 row carries the NORMATIVE clause --------------
# T4g only proves a 401 is displayed. What makes the probe worth its tokens is
# the rule attached to it: 401 is the single outcome that stops the bring-up.
# Deleting that clause, or spreading it to another row, is invisible to every
# other assertion.
ladder_401="$(printf '%s\n' "$S1C_SECTION" | grep -m1 '^| `401`')"
if has_str "$ladder_401" "do NOT bring the stack up"; then
  pass "T3q1: the 401 row of the probe ladder forbids bringing the stack up"
else
  fail "T3q1: the 401 row lost its normative clause (row: '$ladder_401')"
fi

block_clause_rows="$(printf '%s\n' "$S1C_SECTION" | grep -c '^|.*do NOT bring the stack up' | tr -d ' ')"
if [[ "$block_clause_rows" -eq 1 ]]; then
  pass "T3q2: exactly ONE ladder row blocks the bring-up (429 and the inconclusive rows continue)"
else
  fail "T3q2: $block_clause_rows ladder rows block the bring-up (expected exactly 1)"
fi

if has_str "$S1C_SECTION" 'Only `401` blocks the bring-up'; then
  pass "T3q3: the ladder is closed by the explicit rule 'Only 401 blocks the bring-up'"
else
  fail "T3q3: the 'Only 401 blocks the bring-up' rule is missing from S1c"
fi

# ==================================================================
# T4 — the key probe, under a mocked curl. The load-bearing assertion is
# NEGATIVE: the key must not appear in the recorded argv.
# ==================================================================
CURL_ARGV_LOG="$STATE_DIR/curl_argv.log"
CURL_STDIN_LOG="$STATE_DIR/curl_stdin.log"
cat > "$MOCK_BIN/curl" <<'CURLMOCK'
#!/usr/bin/env bash
# Mock curl. Records argv and stdin, honours -o, and returns a scripted code.
for a in "$@"; do printf '%s\n' "$a"; done >> "$KVD_CURL_ARGV_LOG"
cat >> "$KVD_CURL_STDIN_LOG"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ -n "$out" ]] && printf '%s' "${MOCK_CURL_BODY:-mock-response-body}" > "$out"
printf '%s' "${MOCK_HTTP_CODE:-200}"
exit "${MOCK_CURL_RC:-0}"
CURLMOCK
chmod +x "$MOCK_BIN/curl"

PROBEKEY="kvd_live_PROBESECRET0123456789"
mk_env_stack "$T1/probe"; cp "$T1/probe/.env.example" "$T1/probe/.env"
run_rewrite "$T1/probe" "$PROBEKEY" >/dev/null

run_probe() {  # run_probe <http_code> <curl_rc>
  : > "$CURL_ARGV_LOG"; : > "$CURL_STDIN_LOG"
  (
    export PATH="$MOCK_BIN:$PATH"
    export KVD_CURL_ARGV_LOG="$CURL_ARGV_LOG" KVD_CURL_STDIN_LOG="$CURL_STDIN_LOG"
    export MOCK_HTTP_CODE="$1" MOCK_CURL_RC="$2"
    STACK_ROOT="$T1/probe"
    eval "${PROBE_SNIPPET//$ROOT_PLACEHOLDER/$T1/probe}"
  ) 2>&1
}

out="$(run_probe 200 0)"
if has_str "$out" "PROBE http=200 rc=0"; then
  pass "T4a: the probe reads the key back from .env and reports the HTTP code and rc"
else
  fail "T4a: probe 200 (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# THE assertion of this group: the secret must not be in the process argv.
if ! grep -qF "$PROBEKEY" "$CURL_ARGV_LOG"; then
  pass "T4b: the key does NOT appear in the recorded curl argv (invisible to ps)"
else
  fail "T4b: the key LEAKED into the curl argv ($(grep -nF "$PROBEKEY" "$CURL_ARGV_LOG" | head -2 | tr '\n' '|'))"
fi

if grep -qF "header = \"Authorization: Bearer $PROBEKEY\"" "$CURL_STDIN_LOG"; then
  pass "T4c: the Authorization header reaches curl on STDIN via --config -"
else
  fail "T4c: header on stdin (stdin log: $(tr '\n' '|' < "$CURL_STDIN_LOG"))"
fi

if grep -qx -- '--config' "$CURL_ARGV_LOG" \
   && ! grep -q '^Authorization:' "$CURL_ARGV_LOG"; then
  pass "T4d: curl is driven by --config, never by a -H Authorization argument"
else
  fail "T4d: --config used and no -H Authorization in argv"
fi

# The shell BUILTIN printf: an absolute path would spawn a real process whose
# argv carries the key, undoing T4b.
if has_str "$PROBE_SNIPPET" "printf 'header = " \
   && ! has_str "$PROBE_SNIPPET" "/usr/bin/printf"; then
  pass "T4e: the header is produced by the shell builtin printf, not /usr/bin/printf"
else
  fail "T4e: printf builtin used for the header"
fi

# The exit code must not be polluted by a 2>&1 merged into the same capture.
if ! printf '%s\n' "$PROBE_SNIPPET" | grep -q 'http_code.*2>&1'; then
  pass "T4f: the http_code capture does not mix 2>&1 into the exit-code path"
else
  fail "T4f: 2>&1 mixed into the http_code capture"
fi

out="$(run_probe 401 0)"
if has_str "$out" "PROBE http=401 rc=0"; then
  pass "T4g: a 401 is surfaced as such (the only outcome that blocks the bring-up)"
else
  fail "T4g: probe 401 (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_probe 429 0)"
if has_str "$out" "PROBE http=429 rc=0"; then
  pass "T4h: a 429 is surfaced (valid key, exhausted quota: warn and continue)"
else
  fail "T4h: probe 429 (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

out="$(run_probe 000 7)"
if has_str "$out" "rc=7"; then
  pass "T4i: a transport failure propagates its curl exit code (no verdict on the key)"
else
  fail "T4i: probe transport failure (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# The response body is captured BEFORE the temp file is removed, and the temp
# file does not survive.
export MOCK_CURL_BODY="forbidden_tier: upgrade required"
out="$(run_probe 403 0)"
unset MOCK_CURL_BODY
if has_str "$out" "PROBE http=403" && has_str "$out" "PROBE body=forbidden_tier: upgrade required"; then
  pass "T4j: the first bytes of the body are captured before the temp file is deleted"
else
  fail "T4j: body snippet captured (got: $(printf '%s' "$out" | tr '\n' '|'))"
fi

rm -f "$MOCK_BIN/curl"

# ==================================================================
# T5 — the public manifests.
# ==================================================================
MCP_JSON="$PLUGIN_DIR/.mcp.json"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKET_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]' \
       "$MCP_JSON" "$PLUGIN_JSON" "$MARKET_JSON" 2>/dev/null; then
    pass "T5a: .mcp.json, plugin.json and marketplace.json are all valid JSON"
  else
    fail "T5a: one of the manifests is not valid JSON"
  fi
else
  skip "T5a: JSON validity (no python3 on this machine)"
fi

if [[ "$(grep -c 'SETUP-PRO' "$MCP_JSON" || true)" -eq 0 ]] \
   && ! grep -qi 'aws' "$MCP_JSON"; then
  pass "T5b: .mcp.json no longer publishes the internal ops instruction or its broken reference"
else
  fail "T5b: .mcp.json still mentions SETUP-PRO or AWS"
fi

if grep -q '20 MCP tools' "$MCP_JSON" && ! grep -q '14 MCP tools' "$MCP_JSON"; then
  pass "T5c: .mcp.json declares the real tool count (20, not 14)"
else
  fail "T5c: .mcp.json tool count"
fi

if grep -q 'Pro tier required' "$MCP_JSON" && grep -q 'https://kvendra.ai' "$MCP_JSON"; then
  pass "T5d: 'Pro tier required' survives and points at kvendra.ai (AC-7 posture)"
else
  fail "T5d: Pro tier pointer in .mcp.json"
fi

if grep -qF 'scope precedence and Local > Plugin, so a same-name plugin server gets eclipsed silently' "$MCP_JSON"; then
  pass "T5e: the load-bearing server-naming note survives word for word"
else
  fail "T5e: the server-naming note was altered or dropped"
fi

if command -v python3 >/dev/null 2>&1; then
  mcp_shape="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))["mcpServers"]
s=d.get("kvendra-cloud",{})
print(len(d), s.get("type"), s.get("url"))
' "$MCP_JSON" 2>/dev/null)"
  if [[ "$mcp_shape" == "1 http https://api.kvendra.cloud/mcp" ]]; then
    pass "T5f: .mcp.json still declares exactly one server with the same type and url"
  else
    fail "T5f: .mcp.json shape changed (got: '$mcp_shape')"
  fi
else
  skip "T5f: .mcp.json shape (no python3 on this machine)"
fi

skill_count="$(find "$PLUGIN_DIR/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if grep -q '"version": "1.13.0"' "$PLUGIN_JSON" \
   && grep -q '"version": "1.13.0"' "$MARKET_JSON" \
   && grep -q "$skill_count skills" "$MARKET_JSON"; then
  pass "T5g: both manifests are at 1.13.0 and the marketplace states the real skill count ($skill_count)"
else
  fail "T5g: manifest versions / skill count (skills on disk=$skill_count)"
fi

if grep -q '^## \[1.13.0\]' "$REPO_ROOT/CHANGELOG.md"; then
  pass "T5h: the CHANGELOG carries a 1.13.0 entry"
else
  fail "T5h: CHANGELOG 1.13.0 entry"
fi

# The conditional-flag fix is a BUG FIX, not a feature: it belongs under Fixed.
changelog_113="$(awk '/^## \[1.13.0\]/ { c=1; next } c && /^## \[/ { exit } c { print }' "$REPO_ROOT/CHANGELOG.md")"
cl_fixed="$(printf '%s\n' "$changelog_113" | awk '/^### Fixed/ { c=1; next } c && /^### / { exit } c { print }')"
if has_str "$cl_fixed" "unconditionally"; then
  pass "T5i: the unconditional-flag regression is recorded under '### Fixed', not '### Added'"
else
  fail "T5i: the unconditional-flag fix is not under '### Fixed'"
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
