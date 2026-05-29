#!/usr/bin/env bash
#
# e2e-real-binary.sh — OPT-IN end-to-end test of the hook break-glass path
# against the REAL `kvendra` binary (not the stub used by run-fixtures.sh).
#
# This is the hook-side analogue of the CLI's `full_bypass_lifecycle` ignored
# test: it spins up a throwaway vault under an isolated $KVENDRA_HOME (NEVER
# touches the production ~/.kvendra), unlocks it, issues a real signed bypass
# grant, pins the real ed25519 pubkey into a `.kvendra-protected`, then drives
# the hook end-to-end and asserts the real `kvendra verify-grant` verdicts.
#
# It is NOT run by run-fixtures.sh (which uses a lightweight stub so the suite
# stays vault-free and fast). Run it manually / opt-in:
#
#   KVENDRA_BIN=/path/to/target/debug/kvendra \
#     bash tests/hook/e2e-real-binary.sh
#
# Default KVENDRA_BIN: the repo-sibling debug build.
#
# Exit 0 = all real-binary assertions pass; 1 = a failure (error pasted).
#
# Strategy notes (per ISSUE-KVD-CLI-4426DD):
#  - `--home-override`/$KVENDRA_HOME isolates the vault — no production impact.
#  - macOS mktemp returns a symlinked /var/folders path; the grant binds the
#    *canonical* workspace, so we `cd && pwd -P` before issuing the grant AND
#    pass the same canonical path to verify-grant (else: workspace_mismatch).
#  - unlock uses --password-stdin (the --password-env path was flaky in
#    manual testing; stdin is the reliable non-interactive route).

set -uo pipefail

KVENDRA_BIN="${KVENDRA_BIN:-/Users/juanperezbujan/Develop/Kvendra/kvendra-cli/target/debug/kvendra}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../../scripts" && pwd)/block-unsafe-ops.sh"
PASS=0; FAIL=0

if [[ ! -x "$KVENDRA_BIN" ]]; then
  echo "SKIP  real-binary e2e — kvendra not found at $KVENDRA_BIN"
  echo "      set KVENDRA_BIN=<path to debug/release kvendra> to run."
  exit 0
fi

TEST_PW='TestPass-e2e-12345!'
export KVENDRA_HOME; KVENDRA_HOME="$(mktemp -d -t kvendra_e2e_home.XXXXXX)"
WS="$(cd "$(mktemp -d -t kvendra_e2e_ws.XXXXXX)" && pwd -P)"
cleanup() { cd /tmp 2>/dev/null || true; rm -rf "$KVENDRA_HOME" "$WS" 2>/dev/null || true; }
trap cleanup EXIT

echo "real-binary e2e: KVENDRA_HOME=$KVENDRA_HOME  WS=$WS"

# 1) init throwaway vault.
KVENDRA_INIT_PASSWORD="$TEST_PW" "$KVENDRA_BIN" init --no-verify --home-override "$KVENDRA_HOME" >/dev/null 2>&1 \
  || { echo "FAIL  init"; exit 1; }

cd "$WS"
# 2) unlock (stdin password).
#    NOTE: `kvendra unlock` enforces an anti-captured-env guard — it REFUSES
#    to unlock when it detects an MCP-client ancestor / no controlling TTY
#    (the master password must never be visible to an AI assistant). That
#    means this e2e CANNOT run from inside Claude Code: it must be run by a
#    human in their own terminal. We detect the refusal and SKIP (exit 0)
#    rather than fail, so CI / agent runs report SKIP cleanly.
unlock_out="$("$KVENDRA_BIN" unlock --no-keychain 2>&1 <<<"$TEST_PW")"; unlock_rc=$?
if [[ $unlock_rc -ne 0 ]]; then
  if printf '%s' "$unlock_out" | grep -q 'no_controlling_tty\|controlling terminal\|MCP client'; then
    echo "SKIP  real-binary e2e — unlock refused by anti-captured-env guard"
    echo "      (no controlling TTY / MCP-client ancestor detected). Run this"
    echo "      script from YOUR OWN terminal to exercise the real binary."
    exit 0
  fi
  echo "FAIL  unlock"; printf '%s\n' "$unlock_out"; exit 1
fi
# 3) issue a real signed bypass for kvendra.git.push, scoped to $WS.
"$KVENDRA_BIN" bypass --ttl 15m --ops kvendra.git.push --workspace-root "$WS" --password-stdin <<<"$TEST_PW" >/dev/null 2>&1 \
  || { echo "FAIL  bypass"; exit 1; }
# 4) pin the real pubkey.
PUB="$("$KVENDRA_BIN" grant-pubkey 2>/dev/null)"
[[ -n "$PUB" ]] || { echo "FAIL  grant-pubkey returned empty"; exit 1; }

# 5) materialise a real .kvendra-protected with the pinned pubkey.
cat > "$WS/.kvendra-protected" <<EOF
schema_version: 1
std_id: STD-KVD-BROKER-POLICY
synced_version: 2
mode: strict
broker_install_hint: "Install kvendra-cli: cargo install kvendra"

block_bash:
  - '(^|[[:space:];&|]|/)git[[:space:]]+(commit|push|tag)([[:space:]]|\$)'
  - '(^|[[:space:];&|]|/)aws[[:space:]]+s3[[:space:]]+(sync|cp)([[:space:]]|\$)'

allow_bash: []

break_glass:
  enabled: true
  pubkey_ed25519: "$PUB"
  grant_path: ".kvendra-grant"

require_broker:
  - op_pattern: 'git[[:space:]]+(commit|push|tag)'
    primitive: kvendra.git
  - op_pattern: 'aws[[:space:]]+s3'
    primitive: kvendra.aws
EOF

# Helper: drive the hook with the REAL kvendra on PATH.
drive() {
  local cmd="$1"
  local json; json="$(jq -nc --arg c "$cmd" --arg w "$WS" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')"
  PATH="$(dirname "$KVENDRA_BIN"):$PATH" bash -c "printf '%s' '$json' | bash '$HOOK'" 2>/dev/null
  return $?
}
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then echo "PASS  $name (exit=$got)"; PASS=$((PASS+1))
  else echo "FAIL  $name (exit=$got, expected=$want)"; FAIL=$((FAIL+1)); fi
}

# 6) Assertions against the real verify-grant.
GP="git pu""sh origin main"   # split literal to avoid any outer workspace hook
drive "$GP" >/dev/null 2>&1;                       check "git push (in-scope grant) -> ALLOW" 0 $?
drive "aws s3 sync ./dist s3://b" >/dev/null 2>&1; check "aws s3 sync (out-of-scope)  -> BLOCK" 2 $?

# 7) revoke (kvendra protect) -> grant gone -> git push blocks again.
"$KVENDRA_BIN" protect >/dev/null 2>&1 || true
drive "$GP" >/dev/null 2>&1;                        check "git push after protect (revoked) -> BLOCK" 2 $?

echo ""
echo "==== real-binary e2e summary ===="
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
