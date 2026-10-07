#!/usr/bin/env bash
#
# deny-vault-paths.sh — kvendra-skills PreToolUse hook for the file tools
# (Read, Edit, Write, MultiEdit, NotebookEdit, Glob, Grep).
#
# REQ-KVD-11F906 RF-SK-4, DOC-KVD-E49C6E D9. Denies any file-tool access to
# the local Kvendra vault directory (`~/.kvendra`, and `$KVENDRA_HOME` when
# set). Paths are normalised before comparing: `~` / `$HOME` / `${HOME}`
# expansion, relative paths against the session cwd, `.`/`..` folding,
# symlink resolution of the longest existing prefix, case-insensitive
# comparison (macOS file systems are case-insensitive by default).
#
# A brake (freno), not a control (STD-KVD-D31D54): a same-uid process can
# disable the plugin or read the files by other means, and Grep/Glob over an
# ancestor directory are only caught when their pattern names the vault. The
# vault's own encryption and the broker are what protect the values; the
# owner's `permissions.deny` entries (checked by /env-check) are the second
# brake.
#
# Portable: bash 3.2 + jq; no GNU coreutils (no `realpath`, no `readlink -f`).
# jq missing → fail-open with a warning.

set -euo pipefail

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "[kvendra-skills] deny-vault-paths: jq no disponible — hook desactivado (freno local)." >&2
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Read|Edit|Write|MultiEdit|NotebookEdit|Glob|Grep) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "$CWD" ]] && CWD="$PWD"
HOME_DIR="${HOME:-}"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Expand ~, $HOME, ${HOME}; make absolute against $CWD.
expand_path() {
  local p="$1"
  case "$p" in
    "~")         p="$HOME_DIR" ;;
    "~/"*)       p="$HOME_DIR/${p#\~/}" ;;
    '$HOME')     p="$HOME_DIR" ;;
    '$HOME/'*)   p="$HOME_DIR/${p#\$HOME/}" ;;
    '${HOME}')   p="$HOME_DIR" ;;
    '${HOME}/'*) p="$HOME_DIR/${p#\$\{HOME\}/}" ;;
  esac
  case "$p" in
    /*) : ;;
    *)  p="$CWD/$p" ;;
  esac
  printf '%s' "$p"
}

# Lexical normalisation: collapse //, drop ".", fold "..".
lexical() {
  local p="$1" out="" seg
  local IFS='/'
  # shellcheck disable=SC2086
  set -f; set -- $p; set +f
  local -a stack=()
  for seg in "$@"; do
    case "$seg" in
      ""|".") : ;;
      "..") [[ ${#stack[@]} -gt 0 ]] && unset "stack[$(( ${#stack[@]} - 1 ))]" ;;
      *) stack+=("$seg") ;;
    esac
  done
  for seg in ${stack[@]+"${stack[@]}"}; do out="$out/$seg"; done
  [[ -z "$out" ]] && out="/"
  printf '%s' "$out"
}

# Physical path: resolve the longest existing directory prefix with `cd -P`
# and append the non-existent remainder (portable realpath substitute).
physical() {
  local p dir rest="" base resolved
  p="$(lexical "$1")"
  if [[ -d "$p" ]]; then
    (cd -P -- "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
    return 0
  fi
  dir="$p"
  while [[ "$dir" != "/" && ! -d "$dir" ]]; do
    base="${dir##*/}"
    rest="/$base$rest"
    dir="${dir%/*}"; [[ -z "$dir" ]] && dir="/"
  done
  resolved="$(cd -P -- "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
  [[ "$resolved" == "/" ]] && resolved=""
  # A symlinked leaf (file) is resolved one level so ~/link → vault is caught.
  if [[ -L "$p" ]]; then
    local target
    target="$(readlink "$p" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then
      case "$target" in /*) : ;; *) target="${p%/*}/$target" ;; esac
      printf '%s' "$(lexical "$target")"
      return 0
    fi
  fi
  printf '%s' "$(lexical "${resolved}${rest}")"
}

# Vault roots (lexical + physical forms).
ROOTS=()
add_root() {
  local r="$1"
  [[ -z "$r" ]] && return 0
  ROOTS+=("$(lower "$(lexical "$r")")")
  ROOTS+=("$(lower "$(physical "$r")")")
}
[[ -n "$HOME_DIR" ]] && add_root "$HOME_DIR/.kvendra"
[[ -n "${KVENDRA_HOME:-}" ]] && add_root "$(expand_path "$KVENDRA_HOME")"
[[ ${#ROOTS[@]} -eq 0 ]] && exit 0

under_root() { # $1 = lower-cased absolute path
  local c="$1" r
  for r in "${ROOTS[@]}"; do
    [[ "$c" == "$r" || "$c" == "$r/"* ]] && return 0
  done
  return 1
}

ancestor_of_root() { # $1 = lower-cased absolute path
  local c="$1" r
  [[ "$c" == "/" ]] && return 0
  for r in "${ROOTS[@]}"; do
    [[ "$r" == "$c/"* ]] && return 0
  done
  return 1
}

hits_vault() {
  local raw="$1" abs
  [[ -z "$raw" ]] && return 1
  abs="$(expand_path "$raw")"
  under_root "$(lower "$(lexical "$abs")")" && return 0
  under_root "$(lower "$(physical "$abs")")" && return 0
  return 1
}

# A glob / pattern that names the vault directory as a path component.
names_vault() {
  local pat
  pat="$(lower "$1")"
  printf '%s' "$pat" | grep -qE '(^|/|\*)\.kvendra(/|$)'
}

deny() {
  local reason="Acceso denegado a la carpeta del vault de Kvendra ($1). Los valores locales y las credenciales viven ahí y el agente no debe leerlos ni tocarlos: usa \`kvendra vars status\` / \`kvendra vars list\` (sin valores) o pide al owner que lo haga en su terminal. Para ver un allowlist usa \`kvendra secret show-allowlist <profile_id>\` (CLI ≥ 0.7.0). (Freno local del plugin kvendra-skills; la protección real es el cifrado del vault y el broker.)"
  jq -nc --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

get() { printf '%s' "$INPUT" | jq -r ".tool_input.$1 // empty" 2>/dev/null || true; }

case "$TOOL_NAME" in
  Read|Edit|Write|MultiEdit)
    hits_vault "$(get file_path)" && deny "$TOOL_NAME"
    ;;
  NotebookEdit)
    hits_vault "$(get notebook_path)" && deny "$TOOL_NAME"
    ;;
  Glob)
    base="$(get path)"; pattern="$(get pattern)"
    [[ -z "$base" ]] && base="$CWD"
    hits_vault "$base" && deny "$TOOL_NAME"
    prefix="${pattern%%[*?\[{]*}"
    case "$pattern" in
      /*|"~"*|'$HOME'*|'${HOME}'*) hits_vault "$prefix" && deny "$TOOL_NAME" ;;
      *) [[ -n "$prefix" ]] && hits_vault "$(expand_path "$base")/$prefix" && deny "$TOOL_NAME" ;;
    esac
    if names_vault "$pattern" && ancestor_of_root "$(lower "$(physical "$(expand_path "$base")")")"; then
      deny "$TOOL_NAME"
    fi
    ;;
  Grep)
    base="$(get path)"; glob="$(get glob)"
    [[ -z "$base" ]] && base="$CWD"
    hits_vault "$base" && deny "$TOOL_NAME"
    if names_vault "$glob" && ancestor_of_root "$(lower "$(physical "$(expand_path "$base")")")"; then
      deny "$TOOL_NAME"
    fi
    ;;
esac

exit 0
