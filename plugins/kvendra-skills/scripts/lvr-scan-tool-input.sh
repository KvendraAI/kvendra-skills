#!/usr/bin/env bash
#
# lvr-scan-tool-input.sh — kvendra-skills PreToolUse hook for KB writes
# (`entity_create` / `entity_update` of the kvendra-cloud MCP).
#
# REQ-KVD-11F906 RF-CLI-8 (c), DOC-KVD-E49C6E D8(c). Joins every string leaf
# of `tool_input` and pipes it to `kvendra vars scan --stdin --json`. If the
# text contains the value of a local variable, the write is denied and the
# agent is told which KEY to reference instead — never the value.
#
# A brake (freno), not a control: the guarantee is in the broker. With the
# vault locked, without `kvendra`, or on any scan error the hook FAILS OPEN
# with a warning that says the scan was skipped (O3) — never that the text is
# clean. See lvr-scan-lib.sh for the full contract.

set -euo pipefail

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "[kvendra-skills] scan omitido: jq no disponible (freno local; la garantía está en el broker)" >&2
  exit 0
fi

# shellcheck source=lvr-scan-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lvr-scan-lib.sh"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL_NAME" in
  mcp__*kvendra-cloud__entity_create|mcp__*kvendra-cloud__entity_update) : ;;
  *) exit 0 ;;
esac

TEXT="$(printf '%s' "$INPUT" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null || true)"
[[ -z "$TEXT" ]] && exit 0

lvr_scan "$TEXT"

case "$LVR_STATE" in
  hits)
    refs="$(lvr_keys_as_refs "$LVR_KEYS")"
    if [[ -n "$LVR_KEYS" ]]; then
      what="el valor de la variable local ${LVR_KEYS}"
    else
      what="el valor de una variable local"
    fi
    reason="El texto contiene ${what}: usa ${refs}, ~/ o una ruta relativa al workspace, y reintenta. (Freno local del plugin kvendra-skills; la garantía está en el broker.)"
    jq -nc --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
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
