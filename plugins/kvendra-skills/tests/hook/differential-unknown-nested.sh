#!/usr/bin/env bash
#
# differential-unknown-nested.sh — invariant harness for ISSUE-KVD-SKILLS-A5ED0D.
#
# The point-fixtures under fixtures/unknown-nested-* pin a handful of concrete
# scenarios. This script pins the INVARIANT behind them:
#
#   Appending the additive `broker_capabilities_seen:` block that
#   onboard-project step 1.5.f writes must change NOTHING about the hook's
#   observable behaviour — not the exit code, not one byte of stderr, not the
#   number of `kvendra verify-grant` subprocesses spawned — for ANY policy.
#
# Two phases:
#
#   PHASE 1 (spec fence) — the YAML block is NOT copy-pasted here. It is
#     extracted at runtime, with awk, straight out of
#     skills/onboard-project/SKILL.md § 1.5.f, so the test and the spec cannot
#     drift apart. Placeholders (`"<...>"` / `<...>`) are substituted
#     generically, so a new field in the spec is picked up for free.
#     Asserts: a minimal strict policy + that fence still allows `git status`
#     (exit 0) and still blocks `git push` with the canonical policy message.
#
#   PHASE 2 (differential) — for every existing fixture that carries a
#     `.kvendra-protected`, run every case twice: once against the fixture as
#     committed, once against the same file with the spec fence appended.
#     (exit, stderr) must be byte-for-byte identical after normalising the
#     ephemeral workspace path.
#
# Usage:
#   bash tests/hook/differential-unknown-nested.sh
#   HOOK=/path/to/candidate/block-unsafe-ops.sh bash tests/hook/differential-unknown-nested.sh
#
# Exit 0 = all phases pass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$(cd "$SCRIPT_DIR/../../scripts" && pwd)/block-unsafe-ops.sh}"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SKILL_MD="$(cd "$SCRIPT_DIR/../../skills/onboard-project" && pwd)/SKILL.md"

[[ -f "$HOOK" ]]     || { echo "ERROR: hook not found at $HOOK" >&2; exit 1; }
[[ -f "$SKILL_MD" ]] || { echo "ERROR: SKILL.md not found at $SKILL_MD" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0
FAILED=()

echo "hook:     $HOOK"
echo "spec:     $SKILL_MD"
echo

# ------------------------------------------------------------------
# Extract the ```yaml fence that follows the `### 1.5.f` heading, then
# substitute the `<placeholder>` tokens. Generic on purpose: if 1.5.f grows a
# field, this test picks it up without an edit.
# ------------------------------------------------------------------
extract_spec_fence() {
  awk '
    /^### 1\.5\.f/ { in_section = 1; next }
    in_section && /^### / { exit }                 # next sub-step -> stop
    in_section && /^```yaml[[:space:]]*$/ { in_fence = 1; next }
    in_fence && /^```[[:space:]]*$/ { exit }
    in_fence { print }
  ' "$SKILL_MD" \
  | sed -e 's/"<[^>]*>"/"spec-fence-substituted"/g' \
        -e 's/:[[:space:]]*<[^>]*>[[:space:]]*$/: 1/'
}

SPEC_FENCE="$(extract_spec_fence)"

if [[ -z "$SPEC_FENCE" ]]; then
  echo "FAIL  spec-fence-extract  — no \`\`\`yaml fence found under '### 1.5.f' in $SKILL_MD"
  echo "      (spec drift: this harness is pinned to onboard-project § 1.5.f)"
  exit 1
fi
if ! printf '%s\n' "$SPEC_FENCE" | grep -q '^broker_capabilities_seen:[[:space:]]*$'; then
  echo "FAIL  spec-fence-extract  — extracted fence does not start with 'broker_capabilities_seen:'"
  printf '%s\n' "$SPEC_FENCE" | sed 's/^/      | /'
  exit 1
fi
if printf '%s\n' "$SPEC_FENCE" | grep -q '<'; then
  echo "FAIL  spec-fence-extract  — unsubstituted placeholder left in the fence"
  printf '%s\n' "$SPEC_FENCE" | sed 's/^/      | /'
  exit 1
fi

echo "--- spec fence extracted from § 1.5.f (placeholders substituted) ---"
printf '%s\n' "$SPEC_FENCE" | sed 's/^/    /'
echo "--------------------------------------------------------------------"
echo

# Optional oracle: the macOS system python3 is the one that ships PyYAML.
if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import yaml' 2>/dev/null; then
  if printf '%s\n' "$SPEC_FENCE" | /usr/bin/python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin)' 2>/dev/null; then
    echo "INFO  spec fence is valid YAML (PyYAML oracle)"
  else
    echo "FAIL  spec-fence-yaml  — the fence in § 1.5.f is not valid YAML"
    FAIL=$((FAIL+1)); FAILED+=("spec-fence-yaml")
  fi
else
  echo "INFO  PyYAML oracle unavailable — skipping the YAML validity cross-check"
fi
echo

# ------------------------------------------------------------------
# Stub `kvendra` on PATH (same contract as run-fixtures.sh).
# ------------------------------------------------------------------
make_stub_kvendra() {
  local mode="$1" bindir
  bindir="$(mktemp -d -t kvendra_diff_stub.XXXXXX)"
  if [[ "$mode" == "absent" ]]; then rm -rf "$bindir"; printf '%s' ""; return 0; fi
  local counter="$bindir/.verify_calls"; : > "$counter"
  case "$mode" in
    allow)
      cat > "$bindir/kvendra" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "verify-grant" ]] && echo x >> "$counter"
cat >/dev/null
echo '{"applies":true}'
exit 0
STUB
      ;;
    block)
      cat > "$bindir/kvendra" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "verify-grant" ]] && echo x >> "$counter"
cat >/dev/null
echo '{"applies":false,"reason":"out_of_scope"}'
exit 2
STUB
      ;;
    scope-git-push)
      cat > "$bindir/kvendra" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "verify-grant" ]] && echo x >> "$counter"
req="\$(cat)"
op="\$(printf '%s' "\$req" | jq -r '.op')"
if [[ "\$op" == "kvendra.git.push" ]]; then echo '{"applies":true}'; exit 0; fi
echo '{"applies":false,"reason":"out_of_scope"}'
exit 2
STUB
      ;;
    *)
      cat > "$bindir/kvendra" <<STUB
#!/usr/bin/env bash
cat >/dev/null
echo '{"applies":false,"reason":"malformed"}'
exit 2
STUB
      ;;
  esac
  chmod +x "$bindir/kvendra"
  printf '%s' "$bindir"
}

# run_hook <cwd> <tool_name> <command> <PATH>
# Sets the globals RUN_RC (exit code) and RUN_STDERR (stderr with the ephemeral
# workspace path normalised to <WS> so two tmpdirs compare byte-for-byte).
# NOT called through $(...) on purpose — a subshell would lose the globals.
RUN_STDERR=""
RUN_RC=""
run_hook() {
  local cwd="$1"
  local tool="$2"
  local cmd="$3"
  local rpath="$4"
  local payload errf
  payload="$(jq -nc --arg tn "$tool" --arg c "$cmd" --arg w "$cwd" \
    '{tool_name:$tn, tool_input:{command:$c}, cwd:$w}')"
  errf="$(mktemp -t kvendra_diff_err.XXXXXX)"
  printf '%s' "$payload" | PATH="$rpath" bash "$HOOK" >/dev/null 2>"$errf"
  RUN_RC=$?
  RUN_STDERR="$(sed "s|$cwd|<WS>|g" "$errf")"
  rm -f "$errf"
}

# ------------------------------------------------------------------
# PHASE 1 — the spec fence on a minimal strict policy.
# ------------------------------------------------------------------
phase1() {
  local ws
  ws="$(mktemp -d -t kvendra_diff_spec.XXXXXX)"
  {
    cat <<'YAML'
schema_version: 1
std_id: STD-KVD-BROKER-POLICY
synced_version: 1
mode: strict
broker_install_hint: "Install kvendra-cli: cargo install kvendra"

block_bash:
  - '(^|[[:space:];&|]|/)git[[:space:]]+(commit|push|tag)([[:space:]]|$)'

allow_bash: []

require_broker:
  - op_pattern: 'git[[:space:]]+(commit|push|tag)'
    primitive: kvendra.git

YAML
    printf '%s\n' "$SPEC_FENCE"
  } > "$ws/.kvendra-protected"

  local ok=1
  run_hook "$ws" Bash "git status" "$PATH"
  if [[ "$RUN_RC" != "0" ]]; then
    ok=0
    echo "FAIL  spec-fence [git status]  (exit=$RUN_RC, expected=0)"
    printf '%s\n' "$RUN_STDERR" | sed 's/^/      | /'
  fi

  run_hook "$ws" Bash "git push origin main" "$PATH"
  local rc="$RUN_RC"
  if [[ "$rc" != "2" ]] || \
     ! printf '%s\n' "$RUN_STDERR" | grep -qE "^\[KVD-PROTECTED\] Bash op .* blocked by policy 'STD-KVD-BROKER-POLICY' v1 \(mode: strict\)\. Use broker primitive 'kvendra\.git' instead"; then
    ok=0
    echo "FAIL  spec-fence [git push]  (exit=$rc, expected=2 + canonical policy block)"
    printf '%s\n' "$RUN_STDERR" | sed 's/^/      | /'
  fi

  rm -rf "$ws"
  if [[ $ok -eq 1 ]]; then
    echo "PASS  spec-fence  (§ 1.5.f block from SKILL.md is a no-op: read-only allowed, write still blocked)"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED+=("spec-fence")
  fi
}

# ------------------------------------------------------------------
# PHASE 2 — differential over the committed fixtures.
# ------------------------------------------------------------------
diff_one() {
  local fixture="$1"
  local fdir="$FIXTURES_DIR/$fixture"

  if [[ ! -f "$fdir/expected.json" ]]; then
    echo "SKIP  $fixture  (no expected.json)"; SKIP=$((SKIP+1)); return
  fi
  if [[ ! -f "$fdir/.kvendra-protected" ]]; then
    echo "SKIP  $fixture  (marker-absence scenario — no .kvendra-protected to append to)"
    SKIP=$((SKIP+1)); return
  fi
  if [[ -n "$(jq -r '.cwd_override // empty' "$fdir/expected.json")" ]]; then
    echo "SKIP  $fixture  (cwd_override — policy file is not the one under test)"
    SKIP=$((SKIP+1)); return
  fi

  local tool_name stub_mode
  tool_name="$(jq -r '.tool_name // "Bash"' "$fdir/expected.json")"
  stub_mode="$(jq -r '.stub_kvendra_mode // empty' "$fdir/expected.json")"

  local wsA wsB
  wsA="$(mktemp -d -t kvendra_diff_a.XXXXXX)"
  wsB="$(mktemp -d -t kvendra_diff_b.XXXXXX)"
  cp "$fdir/.kvendra-protected" "$wsA/"
  cp "$fdir/.kvendra-protected" "$wsB/"
  { echo ""; printf '%s\n' "$SPEC_FENCE"; } >> "$wsB/.kvendra-protected"

  local binA="" binB="" pathA="$PATH" pathB="$PATH"
  if [[ -n "$stub_mode" ]]; then
    binA="$(make_stub_kvendra "$stub_mode")"
    binB="$(make_stub_kvendra "$stub_mode")"
    if [[ -n "$binA" ]]; then pathA="$binA:$PATH"; pathB="$binB:$PATH"
    else pathA="/usr/bin:/bin"; pathB="/usr/bin:/bin"; fi
  fi

  local cases_json
  cases_json="$(jq -c '([{command: .command}] + (.extra_cases // [] | map({command: .command}))) | .[]' "$fdir/expected.json")"

  local ok=1 n=0 cmd rcA rcB errA errB
  while IFS= read -r case_obj; do
    [[ -z "$case_obj" ]] && continue
    n=$((n+1))
    cmd="$(printf '%s' "$case_obj" | jq -r '.command')"

    run_hook "$wsA" "$tool_name" "$cmd" "$pathA"; rcA="$RUN_RC"; errA="$RUN_STDERR"
    run_hook "$wsB" "$tool_name" "$cmd" "$pathB"; rcB="$RUN_RC"; errB="$RUN_STDERR"

    if [[ "$rcA" != "$rcB" ]]; then
      ok=0
      echo "FAIL  $fixture [case $n: '$cmd']  exit drift: baseline=$rcA  +1.5.f=$rcB"
    fi
    if [[ "$errA" != "$errB" ]]; then
      ok=0
      echo "FAIL  $fixture [case $n: '$cmd']  stderr drift:"
      diff <(printf '%s\n' "$errA") <(printf '%s\n' "$errB") | sed 's/^/      | /'
    fi
  done <<< "$cases_json"

  # verify-grant subprocess count must match too (NFR-PERF-1).
  if [[ -n "$binA" && -n "$binB" ]]; then
    local cA=0 cB=0
    [[ -f "$binA/.verify_calls" ]] && cA="$(wc -l < "$binA/.verify_calls" | tr -d ' ')"
    [[ -f "$binB/.verify_calls" ]] && cB="$(wc -l < "$binB/.verify_calls" | tr -d ' ')"
    if [[ "$cA" != "$cB" ]]; then
      ok=0
      echo "FAIL  $fixture  verify-grant call drift: baseline=${cA}x  +1.5.f=${cB}x"
    fi
  fi

  rm -rf "$wsA" "$wsB"
  [[ -n "$binA" && -d "$binA" ]] && rm -rf "$binA"
  [[ -n "$binB" && -d "$binB" ]] && rm -rf "$binB"

  if [[ $ok -eq 1 ]]; then
    echo "PASS  $fixture  (${n} case(s) — exit + stderr byte-identical with and without § 1.5.f)"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED+=("$fixture")
  fi
}

# The 11 fixtures of ALL_FIXTURES as of ISSUE-KVD-SKILLS-A5ED0D, plus the
# latency-benchmark policy (a 12th policy file worth differentiating).
DIFF_FIXTURES=(
  strict-block
  strict-allow-readonly
  permissive-allow
  hybrid-override
  missing-policy-no-marker
  missing-policy-but-legacy-marker
  malformed-yaml
  break-glass-scope
  break-glass-failclosed
  break-glass-failclosed-nobin
  break-glass-disabled
  latency-benchmark
)

echo "==== PHASE 1 — spec fence (onboard-project § 1.5.f) ===="
phase1
echo
echo "==== PHASE 2 — differential: every fixture, with vs without § 1.5.f ===="
if [[ $# -gt 0 ]]; then
  for f in "$@"; do diff_one "$f"; done
else
  for f in "${DIFF_FIXTURES[@]}"; do diff_one "$f"; done
fi

echo ""
echo "==== summary ===="
echo "passed:  $PASS"
echo "failed:  $FAIL"
echo "skipped: $SKIP"
if [[ $FAIL -gt 0 ]]; then
  echo "failed: ${FAILED[*]}"
  exit 1
fi
exit 0
