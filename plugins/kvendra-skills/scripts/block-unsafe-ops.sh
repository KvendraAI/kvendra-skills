#!/usr/bin/env bash
#
# block-unsafe-ops.sh — kvendra-skills PreToolUse hook, v2 (policy-driven)
#
# Reads the local broker-policy YAML materialised at the workspace root
# (`.kvendra-protected`, synced from STD-<PROJECT>-BROKER-POLICY by the
# /sync-claudemd --policy-only skill action) and enforces it on every Bash
# tool invocation.
#
# Wire contract: IF-KVD-SKILLS-HOOK-CONTRACT v1.0.
# Policy schema:  IF-KVD-SKILLS-BROKER-POLICY v1.0.
# Source of truth: STD-KVD-BROKER-POLICY (and additive STD-KVD-<COMP>-BROKER-POLICY overrides).
#
# Modes:
#   strict     — any block_bash hit → exit 2.
#   permissive — block_bash hit → exit 2 ONLY if no allow_bash override.
#   hybrid     — block_bash hit; allow_bash overrides a block hit.
#
# Legacy marker:
#   If only the legacy `.kvendra-workspace` marker is present (no
#   `.kvendra-protected`), the hook exits 2 with a hard error pointing
#   to `/sync-claudemd --policy-only`. The hardcoded seed strict policy
#   that previously covered the transition window was removed in
#   v1.2.0-alpha.2.
#
# Fail-safe:
#   - stdin malformed / `tool_name` != Bash / no marker found → exit 0.
#   - YAML malformed / schema_version unsupported → exit 2 (fail-closed).
#   - jq / awk missing → exit 0 (fail-open with stderr warning).

set -euo pipefail

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "[kvendra-skills hook] jq not available — hook disabled (fail-open)." >&2
  exit 0
fi
if ! command -v awk >/dev/null 2>&1; then
  echo "[kvendra-skills hook] awk not available — hook disabled (fail-open)." >&2
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[[ -z "$CWD" ]] && CWD="$PWD"

# Walk up from $CWD looking first for .kvendra-protected, then legacy
# .kvendra-workspace. Resolution is session-cwd-scoped per PAT-KVD-C995E9 L2.
DIR="$CWD"
PROTECTED_PATH=""
LEGACY_PATH=""
MARKER_DIR=""
MARKER_KIND=""

while :; do
  if [[ -z "$PROTECTED_PATH" && -f "$DIR/.kvendra-protected" ]]; then
    PROTECTED_PATH="$DIR/.kvendra-protected"
    MARKER_DIR="$DIR"
    MARKER_KIND=".kvendra-protected"
    break
  fi
  if [[ -z "$LEGACY_PATH" && -f "$DIR/.kvendra-workspace" ]]; then
    LEGACY_PATH="$DIR/.kvendra-workspace"
    # Do not break yet — keep walking up in case a .kvendra-protected
    # exists higher in the tree. If we reach root without finding one,
    # we fall back to LEGACY_PATH below.
  fi
  PARENT="$(dirname "$DIR")"
  [[ "$PARENT" == "$DIR" ]] && break
  DIR="$PARENT"
done

# If we never found .kvendra-protected but did find a legacy marker,
# use the legacy marker (transition release).
if [[ -z "$PROTECTED_PATH" && -n "$LEGACY_PATH" ]]; then
  MARKER_DIR="$(dirname "$LEGACY_PATH")"
  MARKER_KIND=".kvendra-workspace"
fi

# No marker at all → not a Kvendra-protected workspace → allow.
[[ -z "$MARKER_DIR" ]] && exit 0

# ------------------------------------------------------------------
# Helper: emit canonical [KVD-PROTECTED] error to stderr + exit 2.
# Args: $1=matched_pattern, $2=std_id, $3=version, $4=mode, $5=primitive, $6=install_hint
# ------------------------------------------------------------------
emit_block() {
  local pattern="$1" std_id="$2" version="$3" mode="$4" primitive="$5" hint="$6"
  cat >&2 <<EOF
[KVD-PROTECTED] Bash op '${pattern}' blocked by policy '${std_id}' v${version} (mode: ${mode}). Use broker primitive '${primitive}' instead. Install hint: ${hint}

Workspace root: ${MARKER_DIR}
Marker:         ${MARKER_KIND}
Command:        ${COMMAND}

Read-only Bash (git status/log/diff, gh issue view, aws sts
get-caller-identity, etc.) IS allowed. The hook only blocks writes /
deploys that need credentialed broker primitives.
EOF
  exit 2
}

# Match a single regex against $COMMAND (extended regex). Returns 0 on hit.
match_re() {
  local re="$1"
  printf '%s' "$COMMAND" | grep -qE "$re"
}

# Extract first matching pattern from a list (one regex per line), echo it on hit.
first_match() {
  local list="$1"
  while IFS= read -r re; do
    [[ -z "$re" ]] && continue
    if match_re "$re"; then
      printf '%s' "$re"
      return 0
    fi
  done <<< "$list"
  return 1
}

# Find the broker primitive bound to a matched op_pattern. Reads pairs lines:
#   op_pattern<TAB>primitive
# Returns the primitive on first op_pattern that matches $COMMAND.
lookup_primitive() {
  local pairs="$1"
  while IFS=$'\t' read -r op prim; do
    [[ -z "$op" ]] && continue
    if match_re "$op"; then
      printf '%s' "$prim"
      return 0
    fi
  done <<< "$pairs"
  printf '%s' "kvendra.shell"  # default fallback
}

# ------------------------------------------------------------------
# Path A — legacy .kvendra-workspace only (hard error, no fallback)
# ------------------------------------------------------------------
if [[ "$MARKER_KIND" == ".kvendra-workspace" ]]; then
  cat >&2 <<EOF
[KVD-PROTECTED] legacy marker .kvendra-workspace at ${MARKER_DIR} is no longer supported. Run /sync-claudemd --policy-only to materialise .kvendra-protected from STD-KVD-BROKER-POLICY, then retry. The hardcoded seed strict policy that covered the v1.2.0-alpha.1 transition window was removed in v1.2.0-alpha.2.

Command: ${COMMAND}
EOF
  exit 2
fi

# ------------------------------------------------------------------
# Path B — .kvendra-protected (canonical policy-driven path)
# ------------------------------------------------------------------

# Minimal pure-awk YAML reader. Supports:
#   - top-level scalar keys (mode, broker_install_hint, broker_min_version,
#     schema_version, std_id, synced_version)
#   - top-level list keys (block_bash, allow_bash) as sequences of `- '<re>'`
#     or `- "<re>"` lines
#   - top-level list of mappings (require_broker) where each item has
#     `op_pattern:` and `primitive:` keys
#
# Outputs key/value lines on stdout in the form:
#   SCALAR<TAB><key><TAB><value>
#   LIST<TAB><key><TAB><value>           (one line per array item)
#   PAIR<TAB><key><TAB><k1>=<v1>;<k2>=<v2>
#
# On parse error → prints `ERROR<TAB><line>:<col>:<reason>` on stderr and
# returns exit 1.

YAML_DUMP="$(awk '
  function strip_quotes(s,    n) {
    n = length(s)
    if (n >= 2) {
      if ((substr(s,1,1) == "\"" && substr(s,n,1) == "\"") ||
          (substr(s,1,1) == "'\''" && substr(s,n,1) == "'\''")) {
        return substr(s, 2, n-2)
      }
    }
    return s
  }
  function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
  }
  BEGIN { current_list = ""; in_pair = 0; pair_key = ""; pair_op = ""; pair_prim = "" }
  /^[[:space:]]*#/ { next }   # comment
  /^[[:space:]]*$/ { next }   # blank

  # Top-level scalar `key: value`
  /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
    # flush any pending mapping item
    if (in_pair) {
      print "PAIR\trequire_broker\t" "op_pattern=" pair_op ";primitive=" pair_prim
      in_pair = 0; pair_op = ""; pair_prim = ""
    }
    current_list = ""
    pos = index($0, ":")
    key = substr($0, 1, pos-1)
    val = trim(substr($0, pos+1))
    val = strip_quotes(val)
    print "SCALAR\t" key "\t" val
    next
  }

  # Top-level list opener `key:` (followed by indented `- ...` lines)
  /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
    if (in_pair) {
      print "PAIR\trequire_broker\t" "op_pattern=" pair_op ";primitive=" pair_prim
      in_pair = 0; pair_op = ""; pair_prim = ""
    }
    sub(/:[[:space:]]*$/, "", $0)
    current_list = $0
    next
  }

  # Sequence item under a list key
  /^[[:space:]]+-[[:space:]]+/ {
    if (current_list == "") { print "ERROR\t" NR ":1:sequence item without parent list" > "/dev/stderr"; exit 1 }
    item = $0
    sub(/^[[:space:]]+-[[:space:]]+/, "", item)
    # if this is a mapping item (e.g. `op_pattern: ...`)
    if (item ~ /^op_pattern:/) {
      # flush previous pair if any
      if (in_pair) {
        print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
      }
      in_pair = 1
      val = trim(substr(item, length("op_pattern:")+1))
      pair_op = strip_quotes(val)
      pair_prim = ""
      next
    }
    item = strip_quotes(item)
    print "LIST\t" current_list "\t" item
    next
  }

  # Continuation key under a sequence-of-mappings (e.g. `primitive: kvendra.git`)
  /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
    if (!in_pair) {
      print "ERROR\t" NR ":1:mapping continuation outside sequence item" > "/dev/stderr"
      exit 1
    }
    line = $0
    sub(/^[[:space:]]+/, "", line)
    pos = index(line, ":")
    k = substr(line, 1, pos-1)
    v = trim(substr(line, pos+1))
    v = strip_quotes(v)
    if (k == "primitive") {
      pair_prim = v
    }
    next
  }

  END {
    if (in_pair) {
      print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
    }
  }
' "$PROTECTED_PATH" 2>&1)" || YAML_ERR=$?

if [[ "${YAML_ERR:-0}" -ne 0 ]]; then
  cat >&2 <<EOF
[KVD-PROTECTED] malformed .kvendra-protected at ${PROTECTED_PATH} — YAML parse error. Re-sync via /sync-claudemd --policy-only.
EOF
  exit 2
fi

# Extract policy fields.
MODE=""
INSTALL_HINT=""
STD_ID="STD-KVD-BROKER-POLICY"
SYNCED_VERSION="0"
SCHEMA_VERSION="1"
BLOCK_RES=""
ALLOW_RES=""
REQ_BROKER_PAIRS=""

while IFS=$'\t' read -r kind key val; do
  [[ -z "$kind" ]] && continue
  case "$kind" in
    SCALAR)
      case "$key" in
        mode) MODE="$val" ;;
        broker_install_hint) INSTALL_HINT="$val" ;;
        std_id) STD_ID="$val" ;;
        synced_version) SYNCED_VERSION="$val" ;;
        schema_version) SCHEMA_VERSION="$val" ;;
      esac
      ;;
    LIST)
      case "$key" in
        block_bash) BLOCK_RES="${BLOCK_RES}${val}"$'\n' ;;
        allow_bash) ALLOW_RES="${ALLOW_RES}${val}"$'\n' ;;
      esac
      ;;
    PAIR)
      if [[ "$key" == "require_broker" ]]; then
        op="${val#op_pattern=}"; op="${op%%;primitive=*}"
        prim="${val#*;primitive=}"
        REQ_BROKER_PAIRS="${REQ_BROKER_PAIRS}${op}"$'\t'"${prim}"$'\n'
      fi
      ;;
  esac
done <<< "$YAML_DUMP"

# Validate schema_version.
if [[ "$SCHEMA_VERSION" != "1" ]]; then
  cat >&2 <<EOF
[KVD-PROTECTED] unsupported schema_version '${SCHEMA_VERSION}' in ${PROTECTED_PATH}. Hook v2 supports schema_version 1. Upgrade kvendra-skills or re-sync.
EOF
  exit 2
fi

# Validate mode.
case "$MODE" in
  strict|permissive|hybrid) : ;;
  *)
    cat >&2 <<EOF
[KVD-PROTECTED] invalid mode '${MODE}' in ${PROTECTED_PATH}. Must be strict|permissive|hybrid. Re-sync via /sync-claudemd --policy-only.
EOF
    exit 2
    ;;
esac

# ------------------------------------------------------------------
# Mode dispatch
# ------------------------------------------------------------------
case "$MODE" in
  strict)
    if HIT="$(first_match "$BLOCK_RES")"; then
      PRIM="$(lookup_primitive "$REQ_BROKER_PAIRS")"
      emit_block "$HIT" "$STD_ID" "$SYNCED_VERSION" "$MODE" "$PRIM" "$INSTALL_HINT"
    fi
    exit 0
    ;;
  permissive)
    if HIT="$(first_match "$BLOCK_RES")"; then
      # Permissive: block only if NO allow_bash override matches.
      if first_match "$ALLOW_RES" >/dev/null; then
        exit 0
      fi
      PRIM="$(lookup_primitive "$REQ_BROKER_PAIRS")"
      emit_block "$HIT" "$STD_ID" "$SYNCED_VERSION" "$MODE" "$PRIM" "$INSTALL_HINT"
    fi
    exit 0
    ;;
  hybrid)
    if HIT="$(first_match "$BLOCK_RES")"; then
      # Hybrid: allow_bash can override a block hit.
      if first_match "$ALLOW_RES" >/dev/null; then
        exit 0
      fi
      PRIM="$(lookup_primitive "$REQ_BROKER_PAIRS")"
      emit_block "$HIT" "$STD_ID" "$SYNCED_VERSION" "$MODE" "$PRIM" "$INSTALL_HINT"
    fi
    exit 0
    ;;
esac
