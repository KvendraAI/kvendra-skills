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
#
# The awk and jq programs live next to this script and are run by literal path (awk -f, jq -f),
# one command per line, so the portal validator can name every program this hook runs:
#   communication-stop-meta.awk    data-file summary (marker, carriers)
#   communication-stop-input-tp.jq      hook input: transcript_path
#   communication-stop-input-active.jq  hook input: stop_hook_active
#   communication-stop-input-msg.jq     hook input: last_assistant_message
#   communication-stop-load.jq     the most recent skill-load entry
#   communication-stop-after.awk   grep hits after the skill-load line
#   communication-stop-later.jq    compact boundaries after it
#   communication-stop-tail.jq     last assistant text of the transcript tail
#   communication-stop-checks.awk  checks (a) and (b)
#   communication-stop-block.jq    the block decision
#   communication-stop-system.jq   the let-through message (second failure in a turn)

set -u
exec 2>/dev/null
# Fail open: whatever happens, the hook exits 0.
stop_check_exit() { exit 0; }
trap stop_check_exit EXIT

command -v jq >/dev/null 2>&1 || exit 0

case "${BASH_SOURCE[0]}" in
  */*) HERE="${BASH_SOURCE[0]%/*}" ;;
  *) HERE="." ;;
esac
DATA="${COMMUNICATION_CHECK_TSV:-$HERE/communication-check.tsv}"
[ -r "$DATA" ] || exit 0
NL=$'\n'
TAB=$'\t'

# Line 1: the marker. Line 2: the carriers, space separated. Exit 1 when a kind is missing.
META="$(LC_ALL=C awk -f "$HERE/communication-stop-meta.awk" "$DATA")" || exit 0
MARKER="${META%%"$NL"*}"
CARRIERS="${META#*"$NL"}"
[ -n "$MARKER" ] || exit 0

INPUT="$(cat)"
TP="$(printf '%s' "$INPUT" | jq -r -f "$HERE/communication-stop-input-tp.jq")"
ACTIVE="$(printf '%s' "$INPUT" | jq -r -f "$HERE/communication-stop-input-active.jq")"
MSG="$(printf '%s' "$INPUT" | jq -r -f "$HERE/communication-stop-input-msg.jq")"

# ---- Carrier gate: the most recent skill-load entry names a carrier and carries the marker.
[ -n "$TP" ] && [ -f "$TP" ] && [ -r "$TP" ] || exit 0
# One pass over the transcript for both patterns (C locale: byte search, faster on large files).
HITS="$(LC_ALL=C grep -nF -e 'Base directory for this skill:' -e '"compact_boundary"' -- "$TP")"
[ -n "$HITS" ] || exit 0
LOADS="$(printf '%s\n' "$HITS" | jq -rR --arg m "$MARKER" -f "$HERE/communication-stop-load.jq")"
LOAD="$(printf '%s\n' "$LOADS" | tail -n 1)"
[ -n "$LOAD" ] || exit 0
L="${LOAD%%"$TAB"*}"
REST="${LOAD#*"$TAB"}"
NAME="${REST%%"$TAB"*}"
HASMARK="${REST#*"$TAB"}"
[ "$HASMARK" = "1" ] || exit 0
case "$CARRIERS" in *" $NAME "*) ;; *) exit 0 ;; esac
BOUNDS="$(printf '%s\n' "$HITS" | LC_ALL=C grep -F '"compact_boundary"')"
AFTER="$(printf '%s\n' "$BOUNDS" | LC_ALL=C awk -v L="$L" -f "$HERE/communication-stop-after.awk")"
LATERS="$(printf '%s\n' "$AFTER" | jq -rR -f "$HERE/communication-stop-later.jq")"
LATER="$(printf '%s\n' "$LATERS" | tail -n 1)"
[ -z "$LATER" ] || exit 0

# ---- Message: last_assistant_message, else the last assistant text of the transcript tail.
if [ -z "$MSG" ]; then
  MSG="$(tail -n 400 -- "$TP" | jq -nrR -f "$HERE/communication-stop-tail.jq")"
fi
[ -n "$MSG" ] || exit 0

# ---- Checks (one awk pass). Output line 1: "", "a", "b" or "ab". Line 2: line 1 of the message.
RES="$(printf '%s\n' "$MSG" | LC_ALL=C awk -v d="$DATA" -v apo="’" -v ell="…" -v emd="—" -v end="–" -f "$HERE/communication-stop-checks.awk")"
CODE="${RES%%"$NL"*}"
L1="${RES#*"$NL"}"
[ -n "$CODE" ] || exit 0

if [ "$ACTIVE" = "true" ]; then
  case "$CODE" in ab) W="a+b" ;; *) W="$CODE" ;; esac
  jq -cn --arg w "$W" -f "$HERE/communication-stop-system.jq"
  exit 0
fi
jq -cn --arg code "$CODE" --arg l1 "$L1" -f "$HERE/communication-stop-block.jq"
exit 0
