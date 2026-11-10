#!/usr/bin/env bash
#
# communication-stop-check.sh — Stop hook (REQ-KVD-SKILLS-49224B, IF interface.communication-stop-hook 1.0).
#
# A quality BRAKE, not a control: it checks the observable form of the final assistant message
# in a session running a carrier skill of the canonical communication block (v3), and asks for
# one rewrite when it fails. It never judges meaning. It FAILS OPEN: no jq, a missing or
# incomplete data file, an unreadable transcript, no assistant text or any internal error ->
# exit 0 in silence. It never exits non-zero, never writes to stderr, never writes files and
# never calls kvendra, curl or the network.
#
#   (a) line 1 is not process narration (literal phrases of the data file);
#   (b) a message that ends with a numbered choice carries an approval line
#       (a label of the data file + the word reversible|irreversible).
#
# Fail and stop_hook_active != true -> {"decision":"block","reason":...}
# Fail and stop_hook_active == true -> {"systemMessage":...} (never blocks twice in a turn).
#
# Data: scripts/communication-check.tsv next to this script (COMMUNICATION_CHECK_TSV overrides
# it, for tests only). Portable to /bin/bash 3.2: only jq, grep, awk, tail, sed and cat.

set -u
exec 2>/dev/null
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0

case "${BASH_SOURCE[0]}" in
  */*) HERE="${BASH_SOURCE[0]%/*}" ;;
  *) HERE="." ;;
esac
DATA="${COMMUNICATION_CHECK_TSV:-$HERE/communication-check.tsv}"
[ -r "$DATA" ] || exit 0

# Line 1: the marker. Line 2: the carriers, space separated. Exit 1 when a kind is missing.
META="$(LC_ALL=C awk '
  { sub(/\r$/, "") }
  /^#/ || /^[ \t]*$/ { next }
  {
    t = index($0, "\t"); if (t == 0) next
    k = substr($0, 1, t - 1); v = substr($0, t + 1)
    if (v == "") next
    if (k == "marker") { m++; mk = v }
    else if (k == "carrier") { c++; cs = cs " " v }
    else if (k == "label") l++
    else if (k == "word") w++
    else if (k == "narration") n++
  }
  END { if (m != 1 || c < 1 || l < 1 || w < 1 || n < 1) exit 1; print mk; print cs " " }
' "$DATA")" || exit 0
MARKER="${META%%$'\n'*}"
CARRIERS="${META#*$'\n'}"
[ -n "$MARKER" ] || exit 0

INPUT="$(cat)"
TP="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty | strings')"
ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active == true')"
MSG="$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty | strings')"

# ---- Carrier gate: the most recent skill-load entry names a carrier and carries the marker.
[ -n "$TP" ] && [ -f "$TP" ] && [ -r "$TP" ] || exit 0
# One pass over the transcript for both patterns (C locale: byte search, faster on large files).
HITS="$(LC_ALL=C grep -nF -e 'Base directory for this skill:' -e '"compact_boundary"' -- "$TP")"
[ -n "$HITS" ] || exit 0
LOAD="$(printf '%s\n' "$HITS" | jq -rR --arg m "$MARKER" '
  try (
    (index(":")) as $i
    | (.[0:$i] | tonumber) as $n
    | (.[$i + 1:] | fromjson?) as $e
    | select(($e | type) == "object")
    | select($e.type == "user" and $e.isMeta == true and (($e.isSidechain // false) == false))
    | ($e.message.content
       | if type == "string" then .
         elif type == "array" then [ .[]? | select(type == "object" and .type == "text") | (.text // "") | strings ] | join("\n")
         else "" end) as $t
    | select($t | startswith("Base directory for this skill:"))
    | ($t | split("\n")[0] | ltrimstr("Base directory for this skill:")
          | gsub("^\\s+|[\\s/]+$"; "") | split("/") | last) as $name
    | "\($n)\t\($name)\t\(if ($t | contains($m)) then 1 else 0 end)"
  ) catch empty' | tail -n 1)"
[ -n "$LOAD" ] || exit 0
L="${LOAD%%$'\t'*}"; REST="${LOAD#*$'\t'}"
NAME="${REST%%$'\t'*}"; HASMARK="${REST#*$'\t'}"
[ "$HASMARK" = "1" ] || exit 0
case "$CARRIERS" in *" $NAME "*) ;; *) exit 0 ;; esac
LATER="$(printf '%s\n' "$HITS" | LC_ALL=C grep -F '"compact_boundary"' | LC_ALL=C awk -v L="$L" -F: '($1 + 0) > (L + 0)' | jq -rR '
  try ((index(":")) as $i | (.[$i + 1:] | fromjson?) | select(type == "object" and .subtype == "compact_boundary") | "x") catch empty' | tail -n 1)"
[ -z "$LATER" ] || exit 0

# ---- Message: last_assistant_message, else the last assistant text of the transcript tail.
if [ -z "$MSG" ]; then
  MSG="$(tail -n 400 -- "$TP" | jq -nrR '
    [ inputs | try (
        fromjson? | select(type == "object" and .type == "assistant" and ((.isSidechain // false) == false))
        | (.message.content
           | if type == "string" then .
             elif type == "array" then [ .[]? | select(type == "object" and .type == "text") | (.text // "") | strings ] | join("\n")
             else "" end)
        | select(length > 0)
      ) catch empty ] | last // empty')"
fi
[ -n "$MSG" ] || exit 0

# ---- Checks (one awk pass). Output line 1: "", "a", "b" or "ab". Line 2: line 1 of the message.
RES="$(printf '%s\n' "$MSG" | LC_ALL=C awk -v d="$DATA" -v apo="’" -v ell="…" -v emd="—" -v end="–" '
  function ind(x) { match(x, /^[ \t]*/); if (substr(x, 1, RLENGTH) ~ /\t/) return 2; return RLENGTH }
  function isnum(x) { return x ~ /^[ \t]*(>[ \t]*)?[0-9]+[.)][ \t]/ }
  function isbul(x) { return x ~ /^[ \t]*(>[ \t]*)?[-*+][ \t]/ }
  function istop(x) { return (isnum(x) || isbul(x)) && ind(x) < 2 }
  function blank(x) { return x !~ /[^ \t]/ }
  function iscont(x) { return !blank(x) && !istop(x) && (ind(x) >= 2 || x ~ /^[ \t]*>/) }
  function hasword(s, w,   off, i, b, a) {
    off = 0
    while ((i = index(substr(s, off + 1), w)) > 0) {
      i += off
      b = (i > 1) ? substr(s, i - 1, 1) : ""
      a = substr(s, i + length(w), 1)
      if (b !~ /[A-Za-z0-9_]/ && a !~ /[A-Za-z0-9_]/) return 1
      off = i
    }
    return 0
  }
  BEGIN {
    while ((getline ln < d) > 0) {
      sub(/\r$/, "", ln)
      if (ln ~ /^#/ || ln ~ /^[ \t]*$/) continue
      t = index(ln, "\t"); if (t == 0) continue
      k = substr(ln, 1, t - 1); v = substr(ln, t + 1)
      if (k == "label") lab[++nl] = tolower(v)
      else if (k == "word") wd[++nw] = tolower(v)
      else if (k == "narration") nar[++nn] = tolower(v)
    }
    close(d)
    inf = 0; mo = 0; n = 0
  }
  {
    line = $0; sub(/\r$/, "", line)
    t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (inf) { if (t ~ /^(`+|~+)$/ && substr(t, 1, 1) == mch && length(t) >= mlen) inf = 0; next }
    if (t == "<!-- kvendra:machine-output -->") { mo = 1; next }
    if (t == "<!-- /kvendra:machine-output -->") { mo = 0; next }
    if (t ~ /^(```|~~~)/) { match(t, /^(`+|~+)/); mlen = RLENGTH; mch = substr(t, 1, 1); inf = 1; next }
    if (mo) next
    gsub(apo, "\047", line)
    L[++n] = line
  }
  END {
    fa = 0; fb = 0; first = ""
    for (i = 1; i <= n; i++) if (!blank(L[i])) { first = L[i]; break }
    if (first != "") {
      s = first; sub(/^[ \t>#*_]+/, "", s); s = tolower(s)
      for (j = 1; j <= nn && !fa; j++) {
        p = nar[j]; lp = length(p)
        if (substr(s, 1, lp) != p) continue
        c = substr(s, lp + 1, 1); r = substr(s, lp + 1)
        if (c == "" || c ~ /[[:space:][:punct:]]/ || index(r, ell) == 1 || index(r, emd) == 1 || index(r, end) == 1) fa = 1
      }
      sub(/^[ \t]+/, "", first); sub(/[ \t]+$/, "", first)
    }
    K = 0
    for (i = n; i >= 1; i--) if (istop(L[i])) { K = i; break }
    if (K > 0 && isnum(L[K])) {
      tr = 0
      for (i = K + 1; i <= n; i++) if (!blank(L[i]) && !iscont(L[i])) tr++
      if (tr <= 3) {
        items = 0; F = K
        for (i = K; i >= 1; i--) {
          if (blank(L[i])) continue
          if (istop(L[i]) && isnum(L[i])) { items++; F = i; continue }
          if (iscont(L[i])) continue
          break
        }
        if (items >= 2) {
          z = F; cnt = 0
          for (i = F - 1; i >= 1 && cnt < 3; i--) if (!blank(L[i])) { cnt++; z = i }
          ok = 0
          for (i = z; i <= n && !ok; i++) {
            v = L[i]; sub(/^[ \t>]+/, "", v); sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", v); sub(/^[ \t]+/, "", v)
            v = tolower(v)
            for (j = 1; j <= nl && !ok; j++) {
              if (substr(v, 1, length(lab[j])) != lab[j]) continue
              rest = substr(v, length(lab[j]) + 1)
              for (q = 1; q <= nw && !ok; q++) if (hasword(rest, wd[q])) ok = 1
            }
          }
          if (!ok) fb = 1
        }
      }
    }
    print (fa ? "a" : "") (fb ? "b" : "")
    print first
  }')"
CODE="${RES%%$'\n'*}"
L1="${RES#*$'\n'}"
[ -n "$CODE" ] || exit 0

if [ "$ACTIVE" = "true" ]; then
  case "$CODE" in ab) W="a+b" ;; *) W="$CODE" ;; esac
  jq -cn --arg w "$W" '{systemMessage: ("kvendra communication: final message still fails " + $w + " after one rewrite; let through.")}'
  exit 0
fi
jq -cn --arg code "$CODE" --arg l1 "$L1" '
  ($l1 | if length > 80 then .[0:80] else . end) as $q
  | [ (if ($code | contains("a")) then "communication (block v3): line 1 is process narration (\"" + $q + "\"). Rewrite the final message starting with the answer or the point." else empty end),
      (if ($code | contains("b")) then "communication (block v3): this message ends with a choice but has no approval line. Add one closing line: **If you approve:** (or **Si apruebas:**) <what a yes approves>, reversible|irreversible, <what happens next>." else empty end) ]
  | {decision: "block", reason: join(" ")}'
exit 0
