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

  local command tool_name expected_exit expected_re override_cwd cwd
  tool_name="$(jq -r '.tool_name // "Bash"' "$fdir/expected.json")"
  command="$(jq -r '.command // empty' "$fdir/expected.json")"
  expected_exit="$(jq -r '.expected_exit' "$fdir/expected.json")"
  expected_re="$(jq -r '.expected_stderr_regex // empty' "$fdir/expected.json")"
  override_cwd="$(jq -r '.cwd_override // empty' "$fdir/expected.json")"

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

  # Build the stdin JSON the harness would send.
  local stdin_json
  stdin_json="$(jq -nc \
    --arg tn "$tool_name" \
    --arg cmd "$command" \
    --arg cwd "$cwd" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: $cwd}')"

  local actual_stderr_file actual_exit
  actual_stderr_file="$(mktemp -t kvendra_hook_test.XXXXXX)"
  set +e
  printf '%s' "$stdin_json" | bash "$HOOK" 2> "$actual_stderr_file" >/dev/null
  actual_exit=$?
  set -e

  [[ -n "$fixture_tmpdir" && -d "$fixture_tmpdir" ]] && rm -rf "$fixture_tmpdir"

  local ok=1
  if [[ "$actual_exit" != "$expected_exit" ]]; then
    ok=0
  fi
  if [[ $ok -eq 1 && -n "$expected_re" ]]; then
    if ! grep -qE "$expected_re" "$actual_stderr_file"; then
      ok=0
    fi
  fi

  if [[ $ok -eq 1 ]]; then
    echo "PASS  $fixture  (exit=$actual_exit)"
    PASS=$((PASS+1))
  else
    echo "FAIL  $fixture  (exit=$actual_exit, expected=$expected_exit)"
    if [[ -n "$expected_re" ]]; then
      echo "       expected stderr ~ /$expected_re/"
    fi
    echo "       --- actual stderr ---"
    sed 's/^/       | /' "$actual_stderr_file"
    echo "       --- end ---"
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture")
  fi
  rm -f "$actual_stderr_file"
}

run_latency_benchmark() {
  local fixture="latency-benchmark"
  local fdir="$FIXTURES_DIR/$fixture"
  if [[ ! -d "$fdir" ]]; then
    echo "MISS  $fixture (no fixture dir)"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$fixture"); return
  fi
  local command stdin_json fixture_tmpdir
  command="$(jq -r '.command' "$fdir/expected.json")"
  fixture_tmpdir="$(mktemp -d -t kvendra_hook_fixture.XXXXXX)"
  [[ -f "$fdir/.kvendra-protected" ]] && cp "$fdir/.kvendra-protected" "$fixture_tmpdir/"
  [[ -f "$fdir/.kvendra-workspace" ]] && cp "$fdir/.kvendra-workspace" "$fixture_tmpdir/"
  stdin_json="$(jq -nc \
    --arg cmd "$command" \
    --arg cwd "$fixture_tmpdir" \
    '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')"

  # Warm-up.
  for _ in 1 2 3; do
    printf '%s' "$stdin_json" | bash "$HOOK" >/dev/null 2>/dev/null || true
  done

  # 100 runs, capture per-run elapsed in milliseconds.
  local n=100
  local times_file
  times_file="$(mktemp -t kvendra_hook_times.XXXXXX)"
  local i
  for ((i=0; i<n; i++)); do
    local start_ns end_ns
    # Use python for portable ns-resolution timing (bash 'date %N' is GNU-only).
    start_ns=$(python3 -c 'import time;print(time.perf_counter_ns())')
    printf '%s' "$stdin_json" | bash "$HOOK" >/dev/null 2>/dev/null || true
    end_ns=$(python3 -c 'import time;print(time.perf_counter_ns())')
    local ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$ms" >> "$times_file"
  done

  # p95 = 95th percentile.
  local p95
  p95=$(sort -n "$times_file" | awk -v n="$n" 'BEGIN{idx=int(n*0.95)} NR==idx {print; exit}')
  rm -f "$times_file"
  [[ -d "$fixture_tmpdir" ]] && rm -rf "$fixture_tmpdir"

  if [[ "$p95" -le 50 ]]; then
    echo "PASS  $fixture  (p95=${p95}ms ≤ 50ms target)"
    PASS=$((PASS+1))
  else
    echo "WARN  $fixture  (p95=${p95}ms > 50ms target — investigate)"
    # Soft fail: latency budgets vary by machine. Report but do not fail CI.
    PASS=$((PASS+1))
  fi
}

ALL_FIXTURES=(
  strict-block
  strict-allow-readonly
  permissive-allow
  hybrid-override
  missing-policy-no-marker
  missing-policy-but-legacy-marker
  malformed-yaml
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
