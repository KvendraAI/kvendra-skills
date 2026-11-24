#!/usr/bin/env bash
#
# lvr-scan-tool-input.sh — kvendra-skills PreToolUse hook for KB writes
# (`entity_create` / `entity_update` / `work` of the Kvendra server, any client prefix).
# `work` writes text through start_work, fill, capture, record_decision, pause…
#
# REQ-KVD-11F906 RF-CLI-8 (c), DOC-KVD-E49C6E D8(c). Joins every string leaf
# of `tool_input` and pipes it to `kvendra vars scan --stdin --json`. If the
# text contains the value of a local variable, the write is denied and the
# agent is told which KEY to reference instead — never the value.
#
# A brake (freno), not a control: the guarantee is in the broker. Without
# `kvendra` on the PATH (CLI optional on Pro) or without local variables it
# passes in silence. With the vault locked or on any scan error it FAILS OPEN
# with a warning that says the scan was skipped (O3) — never that the text is
# clean. See lvr-scan-lib.sh for the full contract.

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

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# Any client prefix (plugin, claude.ai connector, `claude mcp add <name>`): match the tool
# suffix, then confirm the input has the Kvendra engine's required fields, so a homonymous
# tool of another MCP server is left alone. A Kvendra call without them is rejected by the
# engine (400) and writes nothing.
# The plugin's own server is Kvendra by construction: scan it without the shape check, so
# even an invalid call never leaves the machine with a local value in it.
case "$TOOL_NAME" in
  mcp__plugin_kvendra-skills_kvendra-cloud__entity_create|mcp__plugin_kvendra-skills_kvendra-cloud__entity_update|mcp__plugin_kvendra-skills_kvendra-cloud__work) shape='true' ;;
  mcp__*__entity_create) shape='(.tool_input.entity_type | type) == "string" and (.tool_input.title | type) == "string"' ;;
  mcp__*__entity_update) shape='(.tool_input.entity_id | type) == "string" and (.tool_input.change_summary | type) == "string"' ;;
  mcp__*__work) shape='(.tool_input.op | type) == "string" and (.tool_input.op as $o | ["what_now","start_work","fill","pause","finish","confirm","capture","record_decision","resolve_review","release","create_structure"] | index($o)) != null' ;;
  *) exit 0 ;;
esac
printf '%s' "$INPUT" | jq -e "$shape" >/dev/null 2>&1 || exit 0

TEXT="$(printf '%s' "$INPUT" | jq -r '[.tool_input | recurse | strings] | join("\n")' 2>/dev/null || true)"
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
