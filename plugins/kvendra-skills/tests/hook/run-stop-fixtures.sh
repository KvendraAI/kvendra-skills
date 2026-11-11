#!/usr/bin/env bash
#
# run-stop-fixtures.sh — REQ-KVD-SKILLS-49224B AC-6..AC-12 (Stop hook communication-stop-check.sh).
#
# Runs the hook with a private PATH (a jq symlink, /usr/bin:/bin) and a throwaway HOME. A FAKE
# `kvendra` and a FAKE `curl` sit on the PATH and record any call: the hook must never call
# them. Each fixture in fixtures/stop/<name>/ holds transcript.jsonl, input.json (__DIR__ is
# replaced by the fixture directory) and expect (pass|silent|block:a|block:b|block:ab|warn);
# an optional `mode` file selects nojq (PATH without jq) or nodata (missing data file).
# Checks per case: exit 0, empty stderr, no stub call, the exact stdout keys and the checks the
# reason names. Then a performance case: a synthetic 20 MB transcript, 20 runs, p95 <= 500 ms.
#
# Usage: bash tests/hook/run-stop-fixtures.sh       Exit 0 = all pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../../scripts" && pwd)/communication-stop-check.sh"
# Claude Code always sets CLAUDE_PLUGIN_ROOT for plugin hooks and the hook never derives it.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/stop"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  jq not available"; exit 0
fi

WORK="$(mktemp -d -t kvendra_stop_hook.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
TOOLS="$WORK/tools"; mkdir -p "$TOOLS" "$WORK/home"
ln -s "$(command -v jq)" "$TOOLS/jq"
# Recent macOS ships /usr/bin/jq: the "no jq" case gets a PATH without /usr/bin.
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
for b in grep awk tail sed cat; do ln -s "$(command -v "$b")" "$NOJQ/$b"; done
STUB="$WORK/stub"; mkdir -p "$STUB"
CALLS="$WORK/calls"
for b in kvendra curl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$b" "$CALLS" > "$STUB/$b"
  chmod +x "$STUB/$b"
done

pass=0; fail=0
# run_hook <input-file> <mode>  -> sets OUT, RC; stderr in $WORK/stderr
run_hook() {
  local path="$STUB:$TOOLS:/usr/bin:/bin" root="$PLUGIN_ROOT"
  case "$2" in
    nojq) path="$STUB:$NOJQ" ;;
    nodata) root="$WORK/no-such-dir" ;;
  esac
  rm -f "$CALLS"
  OUT="$(env -i HOME="$WORK/home" PATH="$path" CLAUDE_PLUGIN_ROOT="$root" /bin/bash "$HOOK" < "$1" 2>"$WORK/stderr")"
  RC=$?
}

for d in "$FIX"/*/; do
  [ -d "$d" ] || continue
  d="${d%/}"; name="$(basename "$d")"
  expect="$(head -n1 "$d/expect")"
  mode=""; [ -f "$d/mode" ] && mode="$(head -n1 "$d/mode")"
  sed "s|__DIR__|$d|g" "$d/input.json" > "$WORK/input.json"
  run_hook "$WORK/input.json" "$mode"
  ok=1; why=""
  [ "$RC" -eq 0 ] || { ok=0; why="exit $RC"; }
  [ -s "$WORK/stderr" ] && { ok=0; why="$why stderr"; }
  [ -e "$CALLS" ] && { ok=0; why="$why stub-called"; }
  case "$expect" in
    pass|silent) [ -z "$OUT" ] || { ok=0; why="$why output"; } ;;
    block:*)
      want="${expect#block:}"
      [ "$(printf '%s' "$OUT" | jq -r 'keys|join(",")' 2>/dev/null)" = "decision,reason" ] || { ok=0; why="$why keys"; }
      [ "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" = "block" ] || { ok=0; why="$why decision"; }
      reason="$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)"
      got=""
      case "$reason" in *"line 1 is process narration"*) got="a" ;; esac
      case "$reason" in *"has no approval line"*) got="${got}b" ;; esac
      [ "$got" = "$want" ] || { ok=0; why="$why reason=$got"; } ;;
    warn)
      [ "$(printf '%s' "$OUT" | jq -r 'keys|join(",")' 2>/dev/null)" = "systemMessage" ] || { ok=0; why="$why keys"; }
      case "$(printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null)" in
        "kvendra communication: final message still fails "*" after one rewrite; let through.") ;;
        *) ok=0; why="$why message" ;;
      esac ;;
    *) ok=0; why="unknown expect $expect" ;;
  esac
  if [ $ok -eq 1 ]; then echo "PASS  $name ($expect)"; pass=$((pass+1)); else echo "FAIL  $name ($expect):$why -> [$OUT]"; fail=$((fail+1)); fi
done

# ---- Performance: synthetic 20 MB transcript, carrier load near the top, narration at the end,
# no last_assistant_message (the fallback path reads the tail).
BIG="$WORK/big.jsonl"
head -n 2 "$FIX/narration-es/transcript.jsonl" > "$BIG"
FILL="$(jq -cn --arg t "$(head -c 2000 /dev/zero | tr '\0' x)" '{type:"assistant",isSidechain:false,message:{role:"assistant",content:[{type:"text",text:$t}]}}')"
i=0; chunk=""
while [ $i -lt 100 ]; do chunk="$chunk$FILL"$'\n'; i=$((i+1)); done
i=0
while [ $i -lt 100 ]; do printf '%s' "$chunk" >> "$BIG"; i=$((i+1)); done
jq -cn '{type:"assistant",isSidechain:false,message:{role:"assistant",content:[{type:"text",text:"Voy a revisar el plan.\n\nLuego respondo."}]}}' >> "$BIG"
jq -cn --arg p "$BIG" '{hook_event_name:"Stop",stop_hook_active:false,transcript_path:$p}' > "$WORK/big-input.json"
size=$(wc -c < "$BIG" | tr -d ' ')
TIMES="$WORK/times"; : > "$TIMES"
TIMEFORMAT=%3R
perf_ok=1; i=0
while [ $i -lt 20 ]; do
  { time run_hook "$WORK/big-input.json" "" ; } 2>> "$TIMES"
  [ "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" = "block" ] || perf_ok=0
  i=$((i+1))
done
p95="$(tr ',' '.' < "$TIMES" | LC_ALL=C awk '{ printf "%d\n", $1 * 1000 }' | sort -n | awk '{ a[NR] = $1 } END { i = int(NR * 0.95 + 0.999); if (i > NR) i = NR; print a[i] }')"
if [ $perf_ok -eq 1 ] && [ "$size" -ge 20000000 ] && [ "$p95" -le 500 ]; then
  echo "PASS  perf 20 MB transcript ($size bytes, 20 runs, p95 ${p95} ms)"; pass=$((pass+1))
else
  echo "FAIL  perf 20 MB transcript ($size bytes, p95 ${p95} ms, blocked=$perf_ok)"; fail=$((fail+1))
fi

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
