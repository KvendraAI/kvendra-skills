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
# Policy schema:  IF-KVD-SKILLS-BROKER-POLICY v1.1 (additive break_glass block).
# Source of truth: STD-KVD-BROKER-POLICY (and additive STD-KVD-<COMP>-BROKER-POLICY overrides).
#
# Modes:
#   strict     — any block_bash hit → exit 2.
#   permissive — block_bash hit → exit 2 ONLY if no allow_bash override.
#   hybrid     — block_bash hit; allow_bash overrides a block hit.
#
# Break-glass (IF-KVD-SKILLS-BROKER-POLICY 1.0 → 1.1, additive; schema_version
# NOT bumped — still `1`):
#   Optional top-level mapping `break_glass:` with keys:
#     enabled        (bool)   — master switch.
#     pubkey_ed25519 (string) — base64 ed25519 pubkey pinned by sync-claudemd.
#     grant_path     (string, optional) — informational; the CLI resolves the
#                                         grant from the active local session.
#   On a REAL block-hit, BEFORE emitting the block, if break_glass.enabled==true
#   and pubkey_ed25519 is present, the hook invokes `kvendra verify-grant`
#   (stdin JSON {workspace_root, op, pubkey}; exit 0 = grant applies → ALLOW,
#   exit !=0 = fail-closed → BLOCK with `Break-glass: <reason>` on line 1).
#   INVOCATION IS CONDITIONAL (NFR-PERF-1): the common read-only / no-break-glass
#   path NEVER spawns verify → 0ms overhead.
#   FAIL-CLOSED: if `kvendra` is not on PATH when verify is needed → BLOCK
#   (NOT fail-open, unlike jq/awk missing).
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
# Args: $1=matched_pattern, $2=std_id, $3=version, $4=mode, $5=primitive,
#       $6=install_hint, $7=break_glass_reason (optional)
#
# The first stderr line ALWAYS starts with `[KVD-PROTECTED]` (machine-parseable
# prefix per IF-KVD-SKILLS-HOOK-CONTRACT). When break-glass was evaluated and
# did not apply, the reason is appended to line 1 as `Break-glass: <reason>`.
# ------------------------------------------------------------------
emit_block() {
  local pattern="$1" std_id="$2" version="$3" mode="$4" primitive="$5" hint="$6" bg_reason="${7:-}"
  local bg_suffix=""
  [[ -n "$bg_reason" ]] && bg_suffix=" Break-glass: ${bg_reason}."
  cat >&2 <<EOF
[KVD-PROTECTED] Bash op '${pattern}' blocked by policy '${std_id}' v${version} (mode: ${mode}).${bg_suffix} Use broker primitive '${primitive}' instead. Install hint: ${hint}

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
# Break-glass (IF-KVD-SKILLS-BROKER-POLICY 1.1)
# ------------------------------------------------------------------

# Derive a concrete `<primitive>.<op>` token for the verify-grant request,
# matching the `kvendra bypass --ops` vocabulary (e.g. `kvendra.git.push`,
# `kvendra.aws.s3_sync`, `kvendra.npm.publish`). The op suffix is sniffed from
# the actual $COMMAND. Unknown verbs fall back to the bare primitive — the CLI's
# op-in-scope check then fails closed, which is the safe default.
# Args: $1=primitive (e.g. kvendra.git). Echoes the op token.
derive_op() {
  local primitive="$1" suffix=""
  case "$primitive" in
    kvendra.git)
      if   match_re 'git[[:space:]]+push';        then suffix="push"
      elif match_re 'git[[:space:]]+commit';      then suffix="commit"
      elif match_re 'git[[:space:]]+tag';         then suffix="tag"
      elif match_re 'git[[:space:]]+merge';       then suffix="merge"
      elif match_re 'git[[:space:]]+rebase';      then suffix="rebase"
      fi
      ;;
    kvendra.aws)
      if   match_re 'aws[[:space:]]+s3[[:space:]]+sync'; then suffix="s3_sync"
      elif match_re 'aws[[:space:]]+s3[[:space:]]+cp';   then suffix="s3_cp"
      elif match_re 'aws[[:space:]]+s3[[:space:]]+rm';   then suffix="s3_rm"
      elif match_re 'aws[[:space:]]+cloudfront';         then suffix="cloudfront"
      elif match_re 'aws[[:space:]]+lambda';             then suffix="lambda"
      elif match_re 'aws[[:space:]]+cloudformation';     then suffix="cloudformation"
      fi
      ;;
    kvendra.github)
      if   match_re 'gh[[:space:]]+release'; then suffix="release"
      elif match_re 'gh[[:space:]]+pr';      then suffix="pr"
      elif match_re 'gh[[:space:]]+issue';   then suffix="issue"
      fi
      ;;
    kvendra.npm)   match_re 'npm[[:space:]]+publish'   && suffix="publish" ;;
    kvendra.pypi)  match_re '(pip|twine)[[:space:]]+(upload|publish)' && suffix="upload" ;;
  esac
  if [[ -n "$suffix" ]]; then
    printf '%s.%s' "$primitive" "$suffix"
  else
    printf '%s' "$primitive"
  fi
}

# Evaluate break-glass for a real block-hit.
# Sets global BG_VERDICT to one of: allow | none | <verify-reason> (e.g.
# expired, out-of-scope, invalid-signature, unavailable, malformed).
# Returns 0 (ALLOW) only when the grant applies; returns 1 otherwise.
# CONDITIONAL: only ever called on a confirmed block-hit, and only spawns the
# `kvendra verify-grant` subprocess when break-glass is enabled + a pubkey is
# pinned. FAIL-CLOSED: `kvendra` missing on PATH → reason `unavailable`, BLOCK.
# Args: $1=primitive (resolved via lookup_primitive).
maybe_break_glass() {
  local primitive="$1"
  BG_VERDICT="none"

  # Not opted in → no break-glass, no subprocess (0ms overhead even on block).
  [[ "$BG_ENABLED" != "true" ]] && return 1
  [[ -z "$BG_PUBKEY" ]] && return 1

  # Fail-closed: verify is needed but the CLI is absent.
  if ! command -v kvendra >/dev/null 2>&1; then
    BG_VERDICT="unavailable"
    return 1
  fi

  local op req verdict reason rc
  op="$(derive_op "$primitive")"
  req="$(jq -nc \
    --arg ws "$MARKER_DIR" \
    --arg op "$op" \
    --arg pk "$BG_PUBKEY" \
    '{workspace_root: $ws, op: $op, pubkey: $pk}')"

  set +e
  verdict="$(printf '%s' "$req" | kvendra verify-grant 2>/dev/null)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    BG_VERDICT="allow"
    return 0
  fi

  # Map the CLI's machine reason to a stable hook reason, best-effort.
  reason="$(printf '%s' "$verdict" | jq -r '.reason // empty' 2>/dev/null)"
  case "$reason" in
    expired)             BG_VERDICT="expired" ;;
    out_of_scope|*scope*) BG_VERDICT="out-of-scope" ;;
    signature_invalid|*signature*) BG_VERDICT="invalid-signature" ;;
    no_session|*session*) BG_VERDICT="no-session" ;;
    key_mismatch|*key*)  BG_VERDICT="invalid-signature" ;;
    workspace*)          BG_VERDICT="workspace-mismatch" ;;
    "")                  BG_VERDICT="invalid-signature" ;;
    *)                   BG_VERDICT="$reason" ;;
  esac
  return 1
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
  # OR a nested key under the `break_glass:` mapping (e.g. `enabled: true`).
  /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
    # Nested keys under the break_glass mapping (not a sequence item).
    if (current_list == "break_glass" && !in_pair) {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      pos = index(line, ":")
      k = substr(line, 1, pos-1)
      v = trim(substr(line, pos+1))
      v = strip_quotes(v)
      print "BG\t" k "\t" v
      next
    }
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
# break_glass sub-mapping (IF-KVD-SKILLS-BROKER-POLICY 1.1, additive).
BG_ENABLED=""
BG_PUBKEY=""
BG_GRANT_PATH=""

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
    BG)
      case "$key" in
        enabled) BG_ENABLED="$val" ;;
        pubkey_ed25519) BG_PUBKEY="$val" ;;
        grant_path) BG_GRANT_PATH="$val" ;;
      esac
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
# Decide on a confirmed block-hit (after allow-override ruled out):
# try break-glass first, otherwise emit the block. Shared by all modes so
# the conditional-verify invariant lives in exactly one place.
#
# NFR-PERF-1: maybe_break_glass() only spawns `kvendra verify-grant` when
# break_glass.enabled==true AND a pubkey is pinned. The common path
# (read-only / no break-glass) never reaches here at all (no block-hit), and
# even a block-hit with break-glass disabled does NOT spawn verify.
# ------------------------------------------------------------------
decide_block() {
  local hit="$1"
  local prim
  prim="$(lookup_primitive "$REQ_BROKER_PAIRS")"
  if maybe_break_glass "$prim"; then
    # Grant applies → ALLOW, with an auditable visibility line.
    echo "[KVD-PROTECTED] break-glass ACTIVE: '${hit}' permitted under signed grant (op '$(derive_op "$prim")', workspace '${MARKER_DIR}'). Audited." >&2
    exit 0
  fi
  # No grant → block. Only annotate the block with a `Break-glass: <reason>`
  # when break-glass was actually opted into (enabled). When break-glass is
  # disabled/absent the output is byte-for-byte identical to today (NFR-COMPAT-1).
  local bg_reason=""
  [[ "$BG_ENABLED" == "true" ]] && bg_reason="$BG_VERDICT"
  emit_block "$hit" "$STD_ID" "$SYNCED_VERSION" "$MODE" "$prim" "$INSTALL_HINT" "$bg_reason"
}

# ------------------------------------------------------------------
# Mode dispatch
# ------------------------------------------------------------------
case "$MODE" in
  strict)
    if HIT="$(first_match "$BLOCK_RES")"; then
      decide_block "$HIT"
    fi
    exit 0
    ;;
  permissive)
    if HIT="$(first_match "$BLOCK_RES")"; then
      # Permissive: block only if NO allow_bash override matches.
      if first_match "$ALLOW_RES" >/dev/null; then
        exit 0
      fi
      decide_block "$HIT"
    fi
    exit 0
    ;;
  hybrid)
    if HIT="$(first_match "$BLOCK_RES")"; then
      # Hybrid: allow_bash can override a block hit.
      if first_match "$ALLOW_RES" >/dev/null; then
        exit 0
      fi
      decide_block "$HIT"
    fi
    exit 0
    ;;
esac
