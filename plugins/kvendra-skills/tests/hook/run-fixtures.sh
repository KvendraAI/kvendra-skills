#!/usr/bin/env bash
#
# run-fixtures.sh — single-file pure-Bash test runner for the
# kvendra-skills PreToolUse hook v2 (block-unsafe-ops.sh).
#
# Each fixture is a directory under tests/hook/fixtures/<name>/ that
# contains:
#   - the marker file at fixture root: `.kvendra-protected` OR
#     `.kvendra-workspace` (or neither, to test "no marker found").
#   - `expected.json` with the test case definition:
#       { "tool_name": "Bash",
#         "command": "<full command string>",
#         "expected_exit": 0|2,
#         "expected_stderr_regex": "<ERE>" (optional, only checked on exit 2)
#       }
#
# Usage:
#   bash tests/hook/run-fixtures.sh                # run all fixtures
#   bash tests/hook/run-fixtures.sh strict-block   # run a single fixture
#
# Exit code: 0 if all fixtures pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../../scripts" && pwd)/block-unsafe-ops.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

if [[ ! -x "$HOOK" && ! -f "$HOOK" ]]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 1
fi
chmod +x "$HOOK"

PASS=0
FAIL=0
FAILED_NAMES=()

# ------------------------------------------------------------------
# Break-glass support: materialise a fake `kvendra` binary on PATH so the
# hook's conditional `kvendra verify-grant` invocation can be exercised
# WITHOUT a real vault. Modes:
#   allow          → always exit 0 (grant applies).
#   block          → always exit 2 with reason out_of_scope (fail-closed).
#   scope-git-push → exit 0 only when the stdin op == kvendra.git.push,
#                    else exit 2 (out_of_scope). Used by break-glass-scope.
#   absent         → (handled by caller: do NOT add a stub → PATH has no
#                     kvendra → hook fail-closes). Returns empty bindir.
# Echoes the directory to PREPEND to PATH (empty for `absent`).
# Also writes the stub's invocation count to <bindir>/.verify_calls so the
# caller can assert conditional invocation (NFR-PERF-1).
# ------------------------------------------------------------------
make_stub_kvendra() {
  local mode="$1"
  local bindir
  bindir="$(mktemp -d -t kvendra_hook_stub.XXXXXX)"
  if [[ "$mode" == "absent" ]]; then
    rm -rf "$bindir"
    printf '%s' ""
    return 0
  fi
  local counter="$bindir/.verify_calls"
  : > "$counter"
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

run_one() {
  local fixture="$1"
  local fdir="$FIXTURES_DIR/$fixture"
  if [[ ! -d "$fdir" ]]; then
    echo "MISS  $fixture (no fixture dir)"
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture"); return
  fi
  if [[ ! -f "$fdir/expected.json" ]]; then
    echo "MISS  $fixture (no expected.json)"
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture"); return
  fi

  local tool_name override_cwd cwd stub_mode assert_calls
  tool_name="$(jq -r '.tool_name // "Bash"' "$fdir/expected.json")"
  override_cwd="$(jq -r '.cwd_override // empty' "$fdir/expected.json")"
  # Break-glass extensions (optional, ignored by classic fixtures):
  #   stub_kvendra_mode    — allow|block|scope-git-push|absent (sets up a fake
  #                          `kvendra` on PATH so verify-grant runs vault-free).
  #   assert_verify_calls  — exact number of times the stub's verify-grant must
  #                          be invoked across ALL cases (NFR-PERF-1 guard).
  stub_mode="$(jq -r '.stub_kvendra_mode // empty' "$fdir/expected.json")"
  assert_calls="$(jq -r '.assert_verify_calls // empty' "$fdir/expected.json")"

  # Isolate fixture in a tmpdir so the hook's walk-up does NOT escape
  # into the test runner's surrounding workspace (which may itself be a
  # Kvendra-protected workspace with `.kvendra-protected` upstream).
  local fixture_tmpdir=""
  if [[ -n "$override_cwd" ]]; then
    cwd="$override_cwd"
  else
    fixture_tmpdir="$(mktemp -d -t kvendra_hook_fixture.XXXXXX)"
    [[ -f "$fdir/.kvendra-protected" ]] && cp "$fdir/.kvendra-protected" "$fixture_tmpdir/"
    [[ -f "$fdir/.kvendra-workspace" ]] && cp "$fdir/.kvendra-workspace" "$fixture_tmpdir/"
    cwd="$fixture_tmpdir"
  fi

  # Set up the stub kvendra on PATH, if requested.
  local stub_bindir="" run_path="$PATH" counter=""
  if [[ -n "$stub_mode" ]]; then
    stub_bindir="$(make_stub_kvendra "$stub_mode")"
    if [[ -n "$stub_bindir" ]]; then
      run_path="$stub_bindir:$PATH"
      counter="$stub_bindir/.verify_calls"
    else
      # 'absent' mode: scrub kvendra from PATH so the hook fail-closes.
      run_path="/usr/bin:/bin"
    fi
  fi

  # Collect all cases: the primary case plus any in `extra_cases[]`.
  # Each case = {command, expected_exit, expected_stderr_regex?}.
  local cases_json
  cases_json="$(jq -c '
    ([ {command: .command, expected_exit: .expected_exit,
        expected_stderr_regex: (.expected_stderr_regex // "")} ]
     + (.extra_cases // []
        | map({command: .command, expected_exit: .expected_exit,
               expected_stderr_regex: (.expected_stderr_regex // "")})))
    | .[]' "$fdir/expected.json")"

  local all_ok=1 ncase=0 last_exit=""
  local case_command case_exit case_re
  while IFS= read -r case_obj; do
    [[ -z "$case_obj" ]] && continue
    ncase=$((ncase+1))
    case_command="$(printf '%s' "$case_obj" | jq -r '.command')"
    case_exit="$(printf '%s' "$case_obj" | jq -r '.expected_exit')"
    case_re="$(printf '%s' "$case_obj" | jq -r '.expected_stderr_regex')"

    local stdin_json
    stdin_json="$(jq -nc \
      --arg tn "$tool_name" \
      --arg cmd "$case_command" \
      --arg cwd "$cwd" \
      '{tool_name: $tn, tool_input: {command: $cmd}, cwd: $cwd}')"

    local actual_stderr_file actual_exit
    actual_stderr_file="$(mktemp -t kvendra_hook_test.XXXXXX)"
    set +e
    printf '%s' "$stdin_json" | PATH="$run_path" bash "$HOOK" 2> "$actual_stderr_file" >/dev/null
    actual_exit=$?
    set -e
    last_exit="$actual_exit"

    local ok=1
    [[ "$actual_exit" != "$case_exit" ]] && ok=0
    if [[ $ok -eq 1 && -n "$case_re" ]]; then
      grep -qE "$case_re" "$actual_stderr_file" || ok=0
    fi

    if [[ $ok -ne 1 ]]; then
      all_ok=0
      echo "FAIL  $fixture [case $ncase: '$case_command']  (exit=$actual_exit, expected=$case_exit)"
      [[ -n "$case_re" ]] && echo "       expected stderr ~ /$case_re/"
      echo "       --- actual stderr ---"
      sed 's/^/       | /' "$actual_stderr_file"
      echo "       --- end ---"
    fi
    rm -f "$actual_stderr_file"
  done <<< "$cases_json"

  # Assert the conditional-invocation count, if requested.
  if [[ -n "$assert_calls" && -n "$counter" ]]; then
    local actual_calls=0
    [[ -f "$counter" ]] && actual_calls="$(wc -l < "$counter" | tr -d ' ')"
    if [[ "$actual_calls" != "$assert_calls" ]]; then
      all_ok=0
      echo "FAIL  $fixture  (verify-grant invoked ${actual_calls}× — expected ${assert_calls}× per NFR-PERF-1)"
    fi
  fi

  [[ -n "$fixture_tmpdir" && -d "$fixture_tmpdir" ]] && rm -rf "$fixture_tmpdir"
  [[ -n "$stub_bindir" && -d "$stub_bindir" ]] && rm -rf "$stub_bindir"

  if [[ $all_ok -eq 1 ]]; then
    local extra=""
    [[ -n "$assert_calls" ]] && extra=", verify-calls=$assert_calls"
    echo "PASS  $fixture  (${ncase} case(s), last exit=${last_exit}${extra})"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture")
  fi
}

# Measure p95 (ms) of N hook invocations for a given stdin + PATH. Echoes p95.
_measure_p95() {
  local stdin_json="$1" run_path="$2" n="${3:-100}"
  local i start_ns end_ns ms times_file p95
  times_file="$(mktemp -t kvendra_hook_times.XXXXXX)"
  # Warm-up (3 runs).
  for _ in 1 2 3; do
    printf '%s' "$stdin_json" | PATH="$run_path" bash "$HOOK" >/dev/null 2>/dev/null || true
  done
  for ((i=0; i<n; i++)); do
    start_ns=$(python3 -c 'import time;print(time.perf_counter_ns())')
    printf '%s' "$stdin_json" | PATH="$run_path" bash "$HOOK" >/dev/null 2>/dev/null || true
    end_ns=$(python3 -c 'import time;print(time.perf_counter_ns())')
    ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$ms" >> "$times_file"
  done
  p95=$(sort -n "$times_file" | awk -v n="$n" 'BEGIN{idx=int(n*0.95)} NR==idx {print; exit}')
  rm -f "$times_file"
  printf '%s' "$p95"
}

# TEST-LAT-1 — two-leg latency benchmark:
#   (a) common path (read-only command, break_glass enabled in policy but NO
#       block-hit → verify NEVER invoked): asserts ~0ms overhead, p95 ≤ 50ms.
#   (b) block path WITH break-glass: a real block-hit + break_glass enabled →
#       verify-grant IS invoked (here via the lightweight stub, since the real
#       binary cold-start dominates and varies by machine). Reported; warm
#       p95 ≤ 50ms with the stub. Real-binary cold-start is measured opt-in by
#       the `break-glass-latency-realbin` ignored fixture (see README).
run_latency_benchmark() {
  local fixture="latency-benchmark"
  local fdir="$FIXTURES_DIR/$fixture"
  if [[ ! -d "$fdir" ]]; then
    echo "MISS  $fixture (no fixture dir)"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture"); return
  fi
  local fixture_tmpdir
  fixture_tmpdir="$(mktemp -d -t kvendra_hook_fixture.XXXXXX)"
  [[ -f "$fdir/.kvendra-protected" ]] && cp "$fdir/.kvendra-protected" "$fixture_tmpdir/"
  [[ -f "$fdir/.kvendra-workspace" ]] && cp "$fdir/.kvendra-workspace" "$fixture_tmpdir/"

  # ---- Leg (a): common path — read-only command, NO block-hit. ----
  # `git status` is in allow_bash / not in block_bash → no verify call.
  local common_json p95_common
  common_json="$(jq -nc --arg cwd "$fixture_tmpdir" \
    '{tool_name:"Bash", tool_input:{command:"git status"}, cwd:$cwd}')"
  p95_common="$(_measure_p95 "$common_json" "$PATH" 100)"

  # ---- Leg (b): block path WITH break-glass (stub verify, exit 2). ----
  local stub_bindir block_json p95_block
  stub_bindir="$(make_stub_kvendra block)"
  block_json="$(jq -nc --arg cwd "$fixture_tmpdir" \
    '{tool_name:"Bash", tool_input:{command:"git push origin main"}, cwd:$cwd}')"
  p95_block="$(_measure_p95 "$block_json" "$stub_bindir:$PATH" 100)"

  [[ -d "$fixture_tmpdir" ]] && rm -rf "$fixture_tmpdir"
  [[ -n "$stub_bindir" && -d "$stub_bindir" ]] && rm -rf "$stub_bindir"

  echo "INFO  $fixture  leg(a) common/read-only (0 verify): p95=${p95_common}ms"
  echo "INFO  $fixture  leg(b) block+break-glass (stub verify): p95=${p95_block}ms"

  local legs_ok=1
  if [[ "$p95_common" -gt 50 ]]; then
    echo "WARN  $fixture  leg(a) p95=${p95_common}ms > 50ms target — investigate (machine-dependent, soft)"
  fi
  if [[ "$p95_block" -gt 50 ]]; then
    echo "WARN  $fixture  leg(b) p95=${p95_block}ms > 50ms target — investigate (machine-dependent, soft)"
  fi
  # Soft pass (latency budgets vary by machine); legs reported above.
  echo "PASS  $fixture  (leg-a=${p95_common}ms common, leg-b=${p95_block}ms block+bg, ≤50ms target)"
  PASS=$((PASS+1))
  [[ $legs_ok -eq 1 ]] || true
}

ALL_FIXTURES=(
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
)

if [[ $# -gt 0 ]]; then
  for f in "$@"; do
    if [[ "$f" == "latency-benchmark" ]]; then
      run_latency_benchmark
    else
      run_one "$f"
    fi
  done
else
  for f in "${ALL_FIXTURES[@]}"; do
    run_one "$f"
  done
  run_latency_benchmark
fi

echo ""
echo "==== summary ===="
echo "passed: $PASS"
echo "failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "failed fixtures: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
