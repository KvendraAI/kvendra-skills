#!/usr/bin/env bash
# Checks that every carrier SKILL.md holds the canonical communication block verbatim, and that no fenced block outside a machine-output zone holds a ##/### line.
# Also checks that scripts/communication-check.tsv (the Stop hook's data) agrees with block.md and carriers.txt (data_file_drift), and runs the Stop hook fixtures.
# Usage: bash run.sh   (no arguments)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$HERE/block.md"
DATA="$HERE/../../scripts/communication-check.tsv"
# tsv_values <kind>: the values of one kind in the data file, one per line.
tsv_values() { [ -r "$DATA" ] && awk -v k="$1" '{ sub(/\r$/, "") } /^#/ { next } { t = index($0, "\t"); if (t && substr($0, 1, t - 1) == k && t < length($0)) print substr($0, t + 1) }' "$DATA"; }
OPEN="$(tsv_values marker | head -n1)"
CLOSE='<!-- /kvendra:communication -->'
ZONE_AWK='
BEGIN { inf = 0; mo = 0; mark = ""; rc = 0 }
rc { next }
!inf && $0 == "<!-- kvendra:machine-output -->" { if (mo) { print NR; rc = 3; next } mo = 1; next }
!inf && $0 == "<!-- /kvendra:machine-output -->" { if (!mo) { print NR; rc = 3; next } mo = 0; next }
!inf && /^[[:space:]]*(```|~~~)/ { s = $0; sub(/^[[:space:]]*/, "", s); match(s, /^(`+|~+)/); mlen = RLENGTH; mch = substr(s, 1, 1); inf = 1; next }
inf { t = $0; sub(/^[[:space:]]*/, "", t); sub(/[[:space:]]*$/, "", t); if (t ~ /^(`+|~+)$/ && substr(t, 1, 1) == mch && length(t) >= mlen) { inf = 0; next } }
inf && !mo && /^[[:space:]]*###?[[:space:]]/ { print NR; rc = 2; next }
END { if (!rc && mo) { print "EOF"; rc = 3 } exit rc }'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check <skills_dir> <carriers_file>
# Sets CODE (ok or failure code), BAD (skill name) and, for block_differs, DIFFOUT (path).
check() {
  local skills="$1" carriers="$2" name f n=0
  CODE=ok; BAD=; DIFFOUT=; NCARR=0; LINE=
  while IFS= read -r name || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    n=$((n + 1))
    f="$skills/$name/SKILL.md"
    if [ ! -f "$f" ] || ! grep -qxF -- "$OPEN" "$f"; then
      CODE=missing_block; BAD="$name"; return
    fi
  done < "$carriers"
  NCARR=$n
  local d
  for d in "$skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    f="${d}SKILL.md"
    grep -qxF -- "$OPEN" "$f" || continue
    name="$(basename "$d")"
    if ! awk -v o="$OPEN" -v c="$CLOSE" '$0==o{s=1;next} s&&$0==c{f=1} END{exit f?0:1}' "$f"; then
      CODE=unclosed_block; BAD="$name"; return
    fi
  done
  for d in "$skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    f="${d}SKILL.md"
    grep -qxF -- "$OPEN" "$f" || continue
    name="$(basename "$d")"
    awk -v o="$OPEN" -v c="$CLOSE" '$0==o&&!s{s=1} s{print} s&&$0==c{exit}' "$f" > "$TMP/extract"
    if ! cmp -s "$TMP/extract" "$BLOCK"; then
      CODE=block_differs; BAD="$name"
      diff "$BLOCK" "$TMP/extract" > "$TMP/diff" 2>&1
      DIFFOUT="$TMP/diff"
      return
    fi
  done
  for d in "$skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    f="${d}SKILL.md"
    grep -qxF -- "$OPEN" "$f" || continue
    name="$(basename "$d")"
    LINE="$(awk "$ZONE_AWK" "$f")"
    case $? in
      0) LINE= ;;
      2) CODE=chat_template; BAD="$name"; return ;;
      *) CODE=unclosed_machine_output; BAD="$name"; return ;;
    esac
  done
}

fail=0; total=0; passed=0

# Agreement between the data file, block.md and carriers.txt.
drift() { echo "FAIL data_file_drift ($1)"; fail=1; }
if [ -z "$OPEN" ]; then
  drift "no marker in $DATA"
else
  [ "$(head -n1 "$BLOCK")" = "$OPEN" ] || drift "line 1 of block.md is not the marker $OPEN"
  for kind in label word; do
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      grep -qF -- "$v" "$BLOCK" || drift "$kind '$v' not found in block.md"
    done <<EOF
$(tsv_values "$kind")
EOF
  done
  [ -n "$(tsv_values label)" ] || drift "no label in the data file"
  [ -n "$(tsv_values word)" ] || drift "no word in the data file"
  [ -n "$(tsv_values narration)" ] || drift "no narration phrase in the data file"
  if [ "$(tsv_values carrier | LC_ALL=C sort)" != "$(grep -v '^[[:space:]]*$' "$HERE/carriers.txt" | LC_ALL=C sort)" ]; then
    drift "carriers in the data file differ from carriers.txt"
  fi
fi
[ "$fail" -eq 0 ] && echo "PASS data file agrees with block.md and carriers.txt"
for fx in "$HERE"/fixtures/*/; do
  [ -d "$fx" ] || continue
  total=$((total + 1))
  fname="$(basename "$fx")"
  expect="$(head -n1 "$fx/expect")"
  check "$fx/skills" "$fx/carriers.txt"
  if [ "$CODE" = "$expect" ]; then
    echo "PASS $fname"; passed=$((passed + 1))
  else
    echo "FAIL $fname (expected $expect, got $CODE)"; fail=1
  fi
done

check "$HERE/../../skills" "$HERE/carriers.txt"
if [ "$CODE" = ok ]; then
  echo "PASS real ($NCARR carriers)"
else
  echo "FAIL real ($CODE in $BAD${LINE:+, line $LINE})"; fail=1
  [ "$CODE" = block_differs ] && cat "$DIFFOUT"
fi

echo "fixtures: $passed of $total passed; real: $([ "$CODE" = ok ] && echo pass || echo fail)"

bash "$HERE/../hook/run-stop-fixtures.sh" || fail=1
exit $fail
