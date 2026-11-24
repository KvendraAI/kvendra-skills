#!/usr/bin/env bash
#
# run.sh — checks PIPELINE-CONTRACT.md in two parts. Both parts always run.
#
# Part 1 — pipeline contract. Each fixture is a directory under fixtures/<name>/ with:
#   - issue.json — an ISSUE as entity_get returns it
#   - expect     — one line: ok, or the code of the first rule that must fail
#
# Rules, applied in order; the first failure wins:
#   1 part_of_road        relations has a part_of whose target starts with ROAD-
#   2 part_of_issue       relations has a part_of whose target starts with ISSUE-
#   3 no_part_of_spec     relations has no part_of whose target starts with REQ-
#   4 no_road_tag         not exactly one tag starting with road:, or that tag is not ^road:ROAD-[A-Z0-9-]+$
#   5 not_pipeline_ready  tags has no pipeline:ready
#   6 bad_priority        not exactly one priority: tag valued critical|high|medium|low
#   7 bad_status          status is not open or in-progress
#   8 bad_depends_on      metadata.pipeline.depends_on, if present, is not an array of ^ISSUE-[A-Z0-9-]+$
#   9 bad_scope           metadata.pipeline.scope, if present, is not a non-empty string
#
# Part 2 — skills contract, over plugins/kvendra-skills/skills/*/SKILL.md and over each
# skills-fixtures/<name>/skills/*/SKILL.md (its expect: ok, or the codes, one per line):
#   S1 work_cycle_block       a SKILL.md that contains "work({" carries the block of
#                             work-cycle-block.md, closed and byte-identical, and the next
#                             non-empty line after it is "## External-execution policy"; a
#                             SKILL.md without "work({" that carries the block keeps it identical
#   S2 gate_log               no SKILL.md contains "gate_log(" or GATE_LOG_UNAVAILABLE
#   S3 never_blocks           no SKILL.md says "never blocks", "never blocking" or "never blocked"
#                             (any case)
#   S4 rel_created_released   no entity_create( call (delimited by balancing ( ) from its opening
#                             parenthesis, quotes skipped) holds both "REL" and status "released"
#   S5 task_template_tag      no SKILL.md contains the string "type:task" with its quotes
#
# Output: PASS or FAIL per fixture and per rule, with file:line for each violation.
# Exit code: 0 only if every fixture and every rule passes, 1 otherwise.
# Needs bash 3.2 and jq only (no associative arrays, no mapfile).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
SKILLS_FIXTURES_DIR="$SCRIPT_DIR/skills-fixtures"
SKILLS_DIR="$(cd "$SCRIPT_DIR/../../skills" && pwd)"
BLOCK_REF="$SCRIPT_DIR/work-cycle-block.md"
BLOCK_OPEN='<!-- kvendra:work-cycle v1 -->'
BLOCK_CLOSE='<!-- /kvendra:work-cycle -->'
NEXT_HEADING='## External-execution policy'

fail_total=0

# ---------------------------------------------------------------- part 1

check_issue() {
  jq -r '
    (if has("entity") then .entity + {relations: (.relations_outbound // .entity.relations // [])} else . end) as $i
    | ($i.relations // $i.relations_outbound // []) as $rels
    | [$rels[]? | select(.type == "part_of") | ((.target // "") | tostring)] as $parents
    | ($i.tags // []) as $tags
    | ($tags | map(select(type == "string" and startswith("road:")))) as $road
    | ($tags | map(select(type == "string" and startswith("priority:")))) as $prio
    | ($i.metadata.pipeline // {}) as $p
    | if ([$parents[] | select(startswith("ROAD-"))] | length) > 0 then "part_of_road"
      elif ([$parents[] | select(startswith("ISSUE-"))] | length) > 0 then "part_of_issue"
      elif ([$parents[] | select(startswith("REQ-"))] | length) == 0 then "no_part_of_spec"
      elif ($road | length) != 1 or (($road[0] | test("^road:ROAD-[A-Z0-9-]+$")) | not) then "no_road_tag"
      elif ($tags | index("pipeline:ready")) == null then "not_pipeline_ready"
      elif ($prio | length) != 1 or ((["critical","high","medium","low"] | index($prio[0] | ltrimstr("priority:"))) == null) then "bad_priority"
      elif ($i.status != "open" and $i.status != "in-progress") then "bad_status"
      elif ($p | has("depends_on")) and (($p.depends_on | type) != "array" or ([$p.depends_on[] | select((type != "string") or (test("^ISSUE-[A-Z0-9-]+$") | not))] | length) > 0) then "bad_depends_on"
      elif ($p | has("scope")) and (($p.scope | type) != "string" or $p.scope == "") then "bad_scope"
      else "ok" end
  ' "$1" 2>/dev/null || echo "invalid_json"
}

echo "== Pipeline contract (fixtures/)"
pass=0
fail=0
for dir in "$FIXTURES_DIR"/*/; do
  name="$(basename "$dir")"
  expected="$(head -n1 "$dir/expect" | tr -d '[:space:]')"
  got="$(check_issue "$dir/issue.json")"
  if [ "$got" = "$expected" ]; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name (expected $expected, got $got)"
    fail=$((fail + 1))
  fi
done
echo "$pass/$((pass + fail)) contract fixtures passed, $fail failed"
if [ "$fail" -ne 0 ] || [ $((pass + fail)) -eq 0 ]; then fail_total=$((fail_total + 1)); fi

# ---------------------------------------------------------------- part 2

# Prints one line per S4 violation in a file: the line number of the entity_create( call.
rel_released_lines() {
  jq -Rsr '
    . as $s
    | ($s | explode) as $c
    | ($c | length) as $n
    | def line($o): ($s[0:$o] | [match("\n"; "g")] | length) + 1;
      # The end offset of the call whose "(" is at $i (parentheses balanced, quotes skipped).
      def call_end($i):
        first(
          foreach range($i; ([$i + 8000, $n] | min)) as $j (
            {p: 0, q: false, end: null};
            $c[$j] as $ch
            | if .q then (if $ch == 34 then .q = false else . end)
              elif $ch == 34 then .q = true
              elif $ch == 40 then .p += 1
              elif $ch == 41 then .p -= 1 | (if .p == 0 then .end = $j else . end)
              else . end;
            if .end != null then .end else empty end
          )
        );
      $s | match("entity_create\\s*\\("; "g")
      | . as $m
      | (call_end($m.offset + $m.length - 1) // ($n - 1)) as $e
      | $s[$m.offset:$e + 1] as $call
      | select(($call | test("\"REL\"")) and ($call | test("status\\s*:\\s*\"released\"")))
      | line($m.offset)
  ' "$1"
}

# Prints the S1 violation of a file, if any: "<line> <reason>".
work_cycle_violation() {
  local f="$1" has_work=0 open_ln close_ln next_line
  grep -qF 'work({' "$f" && has_work=1
  open_ln="$(grep -nxF "$BLOCK_OPEN" "$f" | head -n1 | cut -d: -f1)"
  if [ -z "$open_ln" ]; then
    if [ "$has_work" -eq 1 ]; then
      echo "$(grep -nF 'work({' "$f" | head -n1 | cut -d: -f1) missing block (the file calls work)"
    elif grep -qF 'kvendra:work-cycle' "$f"; then
      echo "$(grep -nF 'kvendra:work-cycle' "$f" | head -n1 | cut -d: -f1) block marker changed"
    fi
    return 0
  fi
  if ! awk -v o="$BLOCK_OPEN" -v c="$BLOCK_CLOSE" '$0==o{on=1} on{print} $0==c{on=0}' "$f" | cmp -s - "$BLOCK_REF"; then
    echo "$open_ln block differs from work-cycle-block.md (or is not closed)"
    return 0
  fi
  close_ln="$(grep -nxF "$BLOCK_CLOSE" "$f" | head -n1 | cut -d: -f1)"
  next_line="$(awk -v s="$close_ln" 'NR>s && $0 !~ /^[[:space:]]*$/ {print; exit}' "$f")"
  if [ "$next_line" != "$NEXT_HEADING" ]; then
    echo "$close_ln block is not right before the line '$NEXT_HEADING'"
  fi
  return 0
}

# Prints one line per violation under a skills directory: "<code> <relative file>:<line> <detail>".
skills_check() {
  local dir="$1" f rel v ln
  for f in $(find "$dir" -name SKILL.md | sort); do
    rel="${f#$dir/}"
    v="$(work_cycle_violation "$f")"
    [ -n "$v" ] && echo "work_cycle_block $rel:${v%% *} ${v#* }"
    grep -nE 'gate_log\(|GATE_LOG_UNAVAILABLE' "$f" | cut -d: -f1 | while read -r ln; do
      echo "gate_log $rel:$ln"
    done
    grep -niE 'never block(s|ing|ed)' "$f" | cut -d: -f1 | while read -r ln; do
      echo "never_blocks $rel:$ln"
    done
    rel_released_lines "$f" | while read -r ln; do
      [ -n "$ln" ] && echo "rel_created_released $rel:$ln"
    done
    grep -nF '"type:task"' "$f" | cut -d: -f1 | while read -r ln; do
      echo "task_template_tag $rel:$ln"
    done
  done
}

echo "== Skills contract fixtures (skills-fixtures/)"
pass=0
fail=0
for dir in "$SKILLS_FIXTURES_DIR"/*/; do
  name="$(basename "$dir")"
  expected="$(grep -v '^[[:space:]]*$' "$dir/expect" | sed 's/[[:space:]]//g' | sort -u | tr '\n' ' ')"
  got="$(skills_check "$dir/skills" | cut -d' ' -f1 | sort -u | tr '\n' ' ')"
  [ -z "$got" ] && got="ok "
  if [ "$got" = "$expected" ]; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name (expected: $expected, got: $got)"
    fail=$((fail + 1))
  fi
done
echo "$pass/$((pass + fail)) skills fixtures passed, $fail failed"
if [ "$fail" -ne 0 ] || [ $((pass + fail)) -eq 0 ]; then fail_total=$((fail_total + 1)); fi

echo "== Skills contract (skills/*/SKILL.md)"
tree_out="$(skills_check "$SKILLS_DIR")"
for rule in work_cycle_block gate_log never_blocks rel_created_released task_template_tag; do
  hits="$(printf '%s\n' "$tree_out" | grep "^$rule " || true)"
  if [ -z "$hits" ]; then
    echo "PASS $rule"
  else
    echo "FAIL $rule ($(printf '%s\n' "$hits" | grep -c .) violation(s))"
    printf '%s\n' "$hits" | cut -d' ' -f2- | sed 's/^/  skills\//'
    fail_total=$((fail_total + 1))
  fi
done

if [ "$fail_total" -eq 0 ]; then
  echo "pipeline-contract: all checks passed"
  exit 0
fi
echo "pipeline-contract: $fail_total part(s) failed"
exit 1
