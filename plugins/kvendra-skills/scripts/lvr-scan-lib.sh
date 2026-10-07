#!/usr/bin/env bash
#
# lvr-scan-lib.sh — shared helper for the kvendra-skills RF-CLI-8 hooks
# (REQ-KVD-11F906, DOC-KVD-E49C6E "F2 — Filtro de salida RF-CLI-8 en el
# harness"). Sourced by lvr-scan-tool-input.sh and lvr-scan-subagent.sh.
#
# WHAT THIS IS — AND IS NOT:
#   A brake (freno) at the harness boundary, NOT a control. A same-uid process
#   can disable the plugin or the hook, and with the vault locked the hook
#   cannot check anything. The guarantee that a local value never leaves the
#   machine lives in the `kvendra` broker (output filter of every primitive).
#   Messages emitted here never claim that content is clean.
#
# Contract consumed (IF-KVD-CLI-5D9FB5 `cli_commands_for_skills`):
#   kvendra vars scan --stdin --json
#     exit 0 → no hits   stdout {"hits":[]}
#     exit 3 → hits      stdout {"hits":[{"key","count"}]}   (never a value)
#     exit 4 → vault locked ({"error":"vault_locked"}) or no local variables
#              ({"error":"no_local_vars"})
#     exit 2 → {"error":"rate_limited"}                      → "rate limit"
#              {"error":"input_too_short"|"input_too_large"}  → "entrada
#                fuera de rango"
#              {"error":"input_not_utf8"|"stdin_unreadable"}  → "error de
#                entrada"
#              no JSON (clap usage error: CLI without `vars`) → "error"
#   Every non-hit outcome is FAIL-OPEN with a warning (decision O3).
#
# Portable: bash 3.2 + jq; no GNU coreutils (no `timeout`, no GNU realpath).

# Literal warning required by O3 — never "clean", always "skipped".
LVR_SKIPPED_LOCKED="scan omitido: vault bloqueado"

# lvr_scan <text>
# Sets:
#   LVR_STATE  hits | clean | skipped
#   LVR_KEYS   comma-separated keys with hits (only when LVR_STATE=hits; may
#              be empty if the CLI answer was unreadable — still a hit)
#   LVR_WARN   human warning when LVR_STATE=skipped ("" when the skip is a
#              non-event, e.g. no local variables on this machine)
lvr_scan() {
  local text="$1" out rc err
  LVR_STATE="skipped"; LVR_KEYS=""; LVR_WARN=""

  if ! command -v kvendra >/dev/null 2>&1; then
    LVR_WARN="scan omitido: kvendra no está en el PATH"
    return 0
  fi

  set +e
  out="$(printf '%s' "$text" | kvendra vars scan --stdin --json 2>/dev/null)"
  rc=$?
  set -e

  err="$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null || true)"
  case "$rc" in
    0)
      LVR_STATE="clean"
      ;;
    3)
      LVR_KEYS="$(printf '%s' "$out" | jq -r '[.hits[]?.key | select(type=="string")] | join(",")' 2>/dev/null || true)"
      LVR_STATE="hits"     # exit 3 is a hit even if the key list is unreadable
      ;;
    4)
      if [[ "$err" == "no_local_vars" ]]; then
        LVR_WARN=""          # nothing stored on this machine → nothing to filter
      else
        LVR_WARN="$LVR_SKIPPED_LOCKED"
      fi
      ;;
    2)
      # Exit 2 mixes three different causes; the JSON `.error` tells them
      # apart so a skipped scan is never read as a clean one (Seguridad
      # 2026-10-07). Each warning names its cause explicitly.
      case "$err" in
        rate_limited)
          LVR_WARN="scan omitido: rate limit (más de 60 scans por minuto); el texto NO se ha revisado" ;;
        input_too_short)
          LVR_WARN="scan omitido: entrada fuera de rango (texto menor de 16 bytes); el texto NO se ha revisado" ;;
        input_too_large)
          LVR_WARN="scan omitido: entrada fuera de rango (texto mayor de 1 MiB); el texto NO se ha revisado" ;;
        "")
          LVR_WARN="scan omitido: error — este kvendra no soporta 'vars scan' (requiere CLI ≥ 0.7.0); el texto NO se ha revisado" ;;
        *)
          LVR_WARN="scan omitido: error de entrada ($err); el texto NO se ha revisado" ;;
      esac
      ;;
    *)
      LVR_WARN="scan omitido: kvendra vars scan terminó con código $rc"
      ;;
  esac
  return 0
}

# lvr_warn_json <message> → stdout JSON with a user-visible systemMessage,
# plus the same line on stderr. Exit code stays 0 (fail-open).
lvr_warn_json() {
  local msg="[kvendra-skills] $1 (freno local; la garantía está en el broker)"
  printf '%s\n' "$msg" >&2
  jq -nc --arg m "$msg" '{systemMessage: $m}'
}

# lvr_keys_as_refs "a,b" → "{{lvr:a}}, {{lvr:b}}"  ("" → "{{lvr:<key>}}")
lvr_keys_as_refs() {
  [[ -z "$1" ]] && { printf '%s' '{{lvr:<key>}}'; return 0; }
  printf '%s' "$1" | awk -F, '{ for (i = 1; i <= NF; i++) printf "%s{{lvr:%s}}", (i > 1 ? ", " : ""), $i }'
}
