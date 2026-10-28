#!/usr/bin/env bash
#
# run.sh — finds the three attribution defects in SKILL.md files.
#
# Rules:
#   header_promised       the file mentions X-Kvendra-Skill, a header no component implements
#   top_level_updated_by  an entity_create( or entity_update( call passes updated_by as a
#                         top-level argument instead of inside metadata
#   updated_by_in_txn     a txn_activate( or txn_cancel( call passes updated_by at all
#
# Each call is delimited by balancing ( ) { } [ ] from its opening parenthesis, never line by
# line: a call whose updated_by sits several lines below the opening brace is still one call.
# An updated_by nested inside metadata: { ... } (or any other inner object) is correct.
#
# Modes:
#   run.sh --fixtures  each fixtures/<name>/ holds sample.md and expect (codes, one per line,
#                      or `ok`). Exit 0 if every fixture matches its expect, 1 otherwise.
#   run.sh             scans plugins/kvendra-skills/skills/**/SKILL.md and prints, per rule,
#                      the count and the file list. Exit 0 if clean, 1 if any violation.
#
# Needs bash 3.2 and jq only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SKILLS_DIR="$(cd "$SCRIPT_DIR/../../skills" && pwd)"

# Prints one line per violation: `<code> <line>`. Nothing if the file is clean.
check() {
  jq -Rsr '
    . as $s
    | ($s | explode) as $c
    | ($c | length) as $n
    | ("updated_by" | explode) as $ub
    | def word: (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or . == 95;
      def line($o): ($s[0:$o] | [match("\n"; "g")] | length) + 1;
      # Walks one call from its "(" at $i. Emits {end, top, any} once the parenthesis closes:
      # top = updated_by seen at the call'"'"'s own object level, any = seen at any depth.
      def walk($i):
        first(
          foreach range($i; ([$i + 8000, $n] | min)) as $j (
            {p: 0, b: 0, k: 0, q: false, top: false, any: false, done: false};
            $c[$j] as $ch
            | if .q then (if $ch == 34 then .q = false else . end)
              elif $ch == 34 then .q = true
              elif $ch == 40 then .p += 1
              elif $ch == 41 then .p -= 1 | (if .p == 0 then .done = true else . end)
              elif $ch == 123 then .b += 1
              elif $ch == 125 then .b -= 1
              elif $ch == 91 then .k += 1
              elif $ch == 93 then .k -= 1
              elif $ch == 117
                   and $c[$j:$j + 10] == $ub
                   and ($j == 0 or ($c[$j - 1] | word | not))
                   and ($j + 10 >= $n or ($c[$j + 10] | word | not))
              then .any = true
                   | (if .p == 1 and .k == 0 and (.b == 1 or .b == 0) then .top = true else . end)
              else . end;
            if .done then {top, any} else empty end
          )
        );
      [ ($s | test("X-Kvendra-Skill")) | select(.) | "header_promised \(line($s | index("X-Kvendra-Skill")))" ]
      + [ $s | match("(entity_create|entity_update|txn_activate|txn_cancel)\\s*\\("; "g")
          | . as $m
          | ($m.captures[0].string) as $name
          | (walk($m.offset + $m.length - 1) // empty) as $r
          | if ($name | startswith("txn_")) then
              (if $r.any then "updated_by_in_txn \(line($m.offset))" else empty end)
            else
              (if $r.top then "top_level_updated_by \(line($m.offset))" else empty end)
            end ]
      | .[]
  ' "$1"
}

run_fixtures() {
  local pass=0 fail=0 dir name expected got
  for dir in "$FIXTURES_DIR"/*/; do
    name="$(basename "$dir")"
    expected="$(grep -v '^[[:space:]]*$' "$dir/expect" | sed 's/[[:space:]]//g' | sort)"
    got="$(check "$dir/sample.md" | cut -d' ' -f1 | sort)"
    [ -z "$got" ] && got="ok"
    if [ "$got" = "$expected" ]; then
      echo "PASS $name"
      pass=$((pass + 1))
    else
      echo "FAIL $name (expected: $(echo $expected), got: $(echo $got))"
      fail=$((fail + 1))
    fi
  done
  echo "$pass/$((pass + fail)) passed, $fail failed"
  [ "$fail" -eq 0 ] && [ $((pass + fail)) -gt 0 ]
}

run_tree() {
  local out file code ln rule count files total=0
  out=""
  for file in $(find "$SKILLS_DIR" -name SKILL.md | sort); do
    rel="${file#$SKILLS_DIR/}"
    while read -r code ln; do
      [ -n "$code" ] && out="$out$code skills/$rel:$ln
"
    done <<CHECK
$(check "$file")
CHECK
  done
  for rule in header_promised top_level_updated_by updated_by_in_txn; do
    count="$(printf '%s' "$out" | grep -c "^$rule " || true)"
    files="$(printf '%s' "$out" | grep "^$rule " | cut -d' ' -f2 | cut -d: -f1 | sort -u)"
    total=$((total + count))
    echo "$rule: $count occurrence(s) in $(printf '%s' "$files" | grep -c . || true) file(s)"
    printf '%s' "$out" | grep "^$rule " | cut -d' ' -f2 | sed 's/^/  /'
  done
  [ "$total" -eq 0 ]
}

case "${1:-}" in
  --fixtures) run_fixtures ;;
  "") run_tree ;;
  *) echo "usage: $0 [--fixtures]" >&2; exit 2 ;;
esac
