#!/usr/bin/env bash
#
# run.sh — checks example ISSUEs against PIPELINE-CONTRACT.md.
#
# Each fixture is a directory under fixtures/<name>/ containing:
#   - issue.json — an ISSUE as entity_get returns it
#   - expect     — one line: `ok`, or the code of the first rule that must fail
#
# Rules, applied in order; the first failure wins:
#   1 no_part_of_road     relations has a part_of whose target starts with ROAD-
#   2 not_pipeline_ready  tags has pipeline:ready
#   3 bad_priority        exactly one priority: tag, valued critical|high|medium|low
#   4 bad_status          status is open or in-progress
#   5 bad_depends_on      metadata.pipeline.depends_on, if present, is an array of ^ISSUE-[A-Z0-9-]+$
#   6 bad_scope           metadata.pipeline.scope, if present, is a non-empty string
#
# Exit code: 0 if every fixture matches its expect, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

check() {
  jq -r '
    (if has("entity") then .entity + {relations: (.relations_outbound // .entity.relations // [])} else . end) as $i
    | ($i.relations // $i.relations_outbound // []) as $rels
    | ($i.tags // []) as $tags
    | ($tags | map(select(type == "string" and startswith("priority:")))) as $prio
    | ($i.metadata.pipeline // {}) as $p
    | if ([$rels[]? | select(.type == "part_of" and ((.target // "") | tostring | startswith("ROAD-")))] | length) == 0 then "no_part_of_road"
      elif ($tags | index("pipeline:ready")) == null then "not_pipeline_ready"
      elif ($prio | length) != 1 or ([$prio[0] | ltrimstr("priority:")] | inside(["critical","high","medium","low"]) | not) then "bad_priority"
      elif ($i.status != "open" and $i.status != "in-progress") then "bad_status"
      elif ($p | has("depends_on")) and (($p.depends_on | type) != "array" or ([$p.depends_on[] | select((type != "string") or (test("^ISSUE-[A-Z0-9-]+$") | not))] | length) > 0) then "bad_depends_on"
      elif ($p | has("scope")) and (($p.scope | type) != "string" or $p.scope == "") then "bad_scope"
      else "ok" end
  ' "$1" 2>/dev/null || echo "invalid_json"
}

pass=0
fail=0
for dir in "$FIXTURES_DIR"/*/; do
  name="$(basename "$dir")"
  expected="$(head -n1 "$dir/expect" | tr -d '[:space:]')"
  got="$(check "$dir/issue.json")"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name (esperado $expected, obtenido $got)"
    fail=$((fail + 1))
  fi
done

total=$((pass + fail))
echo "$pass/$total passed, $fail failed"
[[ $fail -eq 0 && $total -gt 0 ]]
