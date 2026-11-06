#!/usr/bin/env bash
# Checks that every carrier SKILL.md holds the canonical communication block verbatim, and that no fenced block outside a machine-output zone holds a ##/### line.
# Usage: bash run.sh   (no arguments)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$HERE/block.md"
OPEN='<!-- kvendra:communication v2 -->'
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
exit $fail
