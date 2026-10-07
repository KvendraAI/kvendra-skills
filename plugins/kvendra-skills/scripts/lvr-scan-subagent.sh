#!/usr/bin/env bash
#
# lvr-scan-subagent.sh — kvendra-skills SubagentStop hook.
#
# REQ-KVD-11F906 RF-CLI-8 (c) / AC-LVR-11, DOC-KVD-E49C6E D8(c). Scans the
# subagent's final report with `kvendra vars scan --stdin --json` BEFORE it
# reaches the orchestrator. On a hit it blocks the stop and tells the
# subagent to re-emit the report with `{{lvr:<key>}}` in place of the value
# (a PostToolUse hook on the Agent tool cannot rewrite its output; making the
# subagent rewrite is the only lever the harness offers).
#
# Loop guard: when `stop_hook_active` is true (the subagent is already
# continuing because of a Stop hook) and the hit persists, the hook lets the
# report through with a warning instead of blocking again.
#
# A brake (freno), not a control: the guarantee is in the broker. Without
# `kvendra` on the PATH (CLI optional on Pro) or without local variables it
# passes in silence. With the vault locked or on any scan error it FAILS OPEN
# with a warning that the scan was skipped (O3) — never that the report is
# clean. See lvr-scan-lib.sh for the full contract.
#
# Report source, in order: `last_assistant_message` (when the Claude Code
# version provides it), else the last assistant text entry of
# `agent_transcript_path` (JSONL). `transcript_path` is the PARENT session's
# transcript, so it is never used: no subagent report → nothing to scan.

set -euo pipefail

INPUT="$(cat)"

# No `kvendra` CLI (optional on Pro): no broker, no local values → silent,
# even before the jq check (see lvr-scan-lib.sh).
command -v kvendra >/dev/null 2>&1 || exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "[kvendra-skills] scan omitido: jq no disponible (freno local; la garantía está en el broker)" >&2
  exit 0
fi

# shellcheck source=lvr-scan-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lvr-scan-lib.sh"

field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || true; }

STOP_ACTIVE="$(field '.stop_hook_active')"

# Last assistant text of a Claude Code JSONL transcript. Each entry is
# printed as one JSON string (`jq -c`) so a multi-line report stays on one
# line for `tail`, then decoded.
last_assistant_text() {
  local path="$1" last
  [[ -n "$path" && -f "$path" ]] || return 0
  last="$(jq -c '
      select(.type == "assistant")
      | (.message.content
         | if type == "string" then .
           elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
           else "" end)
      | select(length > 0)' "$path" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$last" ]] && printf '%s' "$last" | jq -r '.' 2>/dev/null || true
}

REPORT="$(field '.last_assistant_message')"
[[ -z "$REPORT" ]] && REPORT="$(last_assistant_text "$(field '.agent_transcript_path')")"
[[ -z "$REPORT" ]] && exit 0

lvr_scan "$REPORT"

case "$LVR_STATE" in
  hits)
    refs="$(lvr_keys_as_refs "$LVR_KEYS")"
    if [[ -n "$LVR_KEYS" ]]; then
      what="el valor de la variable local ${LVR_KEYS}"
    else
      what="el valor de una variable local"
    fi
    if [[ "$STOP_ACTIVE" == "true" ]]; then
      lvr_warn_json "el informe del subagente sigue conteniendo ${what} tras pedir su reescritura; se deja pasar para no entrar en bucle — revísalo antes de reutilizarlo"
      exit 0
    fi
    reason="Tu informe contiene ${what}. Re-emite el informe completo sustituyendo ese valor por ${refs} (o ~/ / una ruta relativa al workspace). No repitas el valor. (Freno local del plugin kvendra-skills; la garantía está en el broker.)"
    jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
    exit 0
    ;;
  skipped)
    [[ -n "$LVR_WARN" ]] && lvr_warn_json "$LVR_WARN"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
