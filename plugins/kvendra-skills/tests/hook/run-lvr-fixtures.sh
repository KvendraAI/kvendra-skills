#!/usr/bin/env bash
#
# run-lvr-fixtures.sh — TEST-KVD-SKILLS-NEW-1 (AC-LVR-11, RF-SK-4).
#
# Exercises the RF-CLI-8 harness hooks of kvendra-skills:
#   - scripts/lvr-scan-tool-input.sh  (PreToolUse entity_create/entity_update)
#   - scripts/lvr-scan-subagent.sh    (SubagentStop)
#   - scripts/deny-vault-paths.sh     (PreToolUse file tools)
#
# Isolation (never the real binary, never the real home):
#   - a FAKE `kvendra` is materialised on a private PATH that contains only
#     the fake, a symlink to jq and /usr/bin:/bin. It simulates the exit codes
#     of `kvendra vars scan --stdin --json` (0 / 3 / 4 / 2) and reports a hit
#     when stdin contains the sentinel value below.
#   - HOME points at a throwaway directory; KVENDRA_HOME is unset unless a
#     case sets it to another throwaway directory.
# Every hook output is also checked to NEVER contain the sentinel value.
#
# Usage: bash tests/hook/run-lvr-fixtures.sh       Exit 0 = all pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../../scripts" && pwd)"
FIX="$SCRIPT_DIR/fixtures/lvr-subagent-transcript"
SENTINEL="/fixture-home/sentinel-workspace-7f3a"
SENTINEL_KEY="workspace.root"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  jq not available"; exit 0
fi

WORK="$(mktemp -d -t kvendra_lvr_hooks.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/work" "$FAKE_HOME/.kvendra/sessions"
: > "$FAKE_HOME/work/notes.txt"
: > "$FAKE_HOME/work/.kvendra-protected"
ln -s "$FAKE_HOME/.kvendra" "$FAKE_HOME/innocent-link"
OTHER_VAULT="$WORK/other-vault"; mkdir -p "$OTHER_VAULT"

TOOLS="$WORK/tools"; mkdir -p "$TOOLS"
ln -s "$(command -v jq)" "$TOOLS/jq"
STUB="$WORK/stub"; mkdir -p "$STUB"
CALLS="$WORK/calls"; : > "$CALLS"

# Fake kvendra. Mode comes from FAKE_KVENDRA_MODE:
#   scan     → exit 3 + hits if stdin contains the sentinel, else exit 0
#   locked   → exit 4 {"error":"vault_locked"} + literal stderr warning
#   novars   → exit 4 {"error":"no_local_vars"}
#   ratelim  → exit 2 {"error":"rate_limited"}
#   short    → exit 2 {"error":"input_too_short"}
#   large    → exit 2 {"error":"input_too_large"}
#   notutf8  → exit 2 {"error":"input_not_utf8"}
#   oldcli   → exit 2, clap usage error on stderr, no JSON (broker < 0.7.0)
#   badhits  → exit 3 with unreadable stdout
cat > "$STUB/kvendra" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
in="\$(cat)"
case "\${FAKE_KVENDRA_MODE:-scan}" in
  scan)
    if [[ "\$1 \$2 \$3 \$4" != "vars scan --stdin --json" ]]; then echo "bad argv" >&2; exit 64; fi
    case "\$in" in
      *"$SENTINEL"*) echo '{"hits":[{"key":"$SENTINEL_KEY","count":1}]}'; exit 3 ;;
      *) echo '{"hits":[]}'; exit 0 ;;
    esac ;;
  locked)  echo "scan omitido: vault bloqueado" >&2; echo '{"error":"vault_locked"}'; exit 4 ;;
  novars)  echo "scan omitido: sin variables locales en esta máquina" >&2; echo '{"error":"no_local_vars"}'; exit 4 ;;
  ratelim) echo '{"error":"rate_limited"}'; exit 2 ;;
  short)   echo '{"error":"input_too_short"}'; exit 2 ;;
  large)   echo '{"error":"input_too_large"}'; exit 2 ;;
  notutf8) echo '{"error":"input_not_utf8"}'; exit 2 ;;
  oldcli)  echo "error: unrecognized subcommand 'vars'" >&2; exit 2 ;;
  badhits) echo 'garbage'; exit 3 ;;
esac
STUB
chmod +x "$STUB/kvendra"

PATH_WITH="$STUB:$TOOLS:/usr/bin:/bin"
PATH_WITHOUT="$TOOLS:/usr/bin:/bin"
if PATH="$PATH_WITHOUT" command -v kvendra >/dev/null 2>&1; then
  echo "ERROR: a real kvendra is reachable on the isolated PATH — refusing to run" >&2
  exit 1
fi

PASS=0; FAIL=0; FAILED=()

# run_case <name> <hook> <stdin-json> <mode|absent> <expect> [extra-env]
# expect: deny | block | warn:<ERE> | silent | quiet | nocall
#   silent = no stdout;  quiet = no stdout AND no stderr (no warning at all)
run_case() {
  local name="$1" hook="$2" stdin="$3" mode="$4" expect="$5" extra="${6:-}"
  local path="$PATH_WITH" out err rc ok=1
  [[ "$mode" == "absent" ]] && path="$PATH_WITHOUT"
  : > "$CALLS"
  out="$WORK/out"; err="$WORK/err"
  printf '%s' "$stdin" | env -i PATH="$path" HOME="$FAKE_HOME" FAKE_KVENDRA_MODE="$mode" $extra \
    bash "$SCRIPTS/$hook" > "$out" 2> "$err"
  rc=$?
  [[ $rc -ne 0 ]] && ok=0
  if grep -qF "$SENTINEL" "$out" "$err"; then ok=0; echo "      leak: sentinel value in hook output"; fi
  case "$expect" in
    deny)
      [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out" 2>/dev/null)" == "deny" ]] || ok=0 ;;
    block)
      [[ "$(jq -r '.decision // empty' "$out" 2>/dev/null)" == "block" ]] || ok=0
      jq -r '.reason' "$out" | grep -qF "{{lvr:$SENTINEL_KEY}}" || ok=0 ;;
    warn:*)
      local re="${expect#warn:}"
      jq -r '.systemMessage // empty' "$out" 2>/dev/null | grep -qE "$re" || ok=0
      grep -qE "$re" "$err" || ok=0
      jq -e '.hookSpecificOutput.permissionDecision? // .decision? // empty' "$out" >/dev/null 2>&1 && ok=0 ;;
    silent)
      [[ -s "$out" ]] && ok=0 ;;
    quiet)
      [[ -s "$out" || -s "$err" ]] && ok=0 ;;
    nocall)
      [[ -s "$out" || -s "$CALLS" ]] && ok=0 ;;
  esac
  if [[ $ok -eq 1 ]]; then
    echo "PASS  $name"; PASS=$((PASS+1))
  else
    echo "FAIL  $name  (rc=$rc, expect=$expect)"
    sed 's/^/      out| /' "$out"; sed 's/^/      err| /' "$err"
    FAIL=$((FAIL+1)); FAILED+=("$name")
  fi
}

pre_kb() { # <tool> <content>
  jq -nc --arg t "mcp__plugin_kvendra-skills_kvendra-cloud__$1" --arg c "$2" --arg cwd "$FAKE_HOME/work" \
    '{hook_event_name:"PreToolUse", tool_name:$t, cwd:$cwd,
      tool_input:{entity_type:"PAT", project_id:"KVD", title:"Deploy note", content:$c,
                  metadata:{updated_by:"skill:implementer", nested:{paths:[$c]}}}}'
}
sub_msg() { # <message> <stop_hook_active>
  jq -nc --arg m "$1" --argjson a "$2" '{hook_event_name:"SubagentStop", stop_hook_active:$a, last_assistant_message:$m}'
}
sub_tr() { # <transcript>
  jq -nc --arg p "$1" '{hook_event_name:"SubagentStop", stop_hook_active:false, agent_transcript_path:$p, transcript_path:"/nonexistent/parent.jsonl"}'
}
file_tool() { # <tool> <json tool_input> [cwd]
  jq -nc --arg t "$1" --argjson i "$2" --arg cwd "${3:-$FAKE_HOME/work}" '{hook_event_name:"PreToolUse", tool_name:$t, tool_input:$i, cwd:$cwd}'
}

LEAK="Workspace lives at $SENTINEL/src, deploy from there."
CLEAN="Workspace lives at ~/work/src, deploy from the marker root."

echo "== lvr-scan-tool-input.sh (PreToolUse entity_create/entity_update) =="
run_case "kb-create-hit-deny"          lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  scan    deny
run_case "kb-update-hit-deny"          lvr-scan-tool-input.sh "$(pre_kb entity_update "$LEAK")"  scan    deny
run_case "kb-create-clean"             lvr-scan-tool-input.sh "$(pre_kb entity_create "$CLEAN")" scan    silent
run_case "kb-locked-failopen"          lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  locked  'warn:scan omitido: vault bloqueado'
run_case "kb-novars-quiet"             lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  novars  quiet
run_case "kb-ratelimit-failopen"       lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  ratelim 'warn:^\[kvendra-skills\] scan omitido: rate limit .*NO se ha revisado'
run_case "kb-short-failopen"           lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  short   'warn:scan omitido: entrada fuera de rango \(texto menor de 16 bytes\)'
run_case "kb-large-failopen"           lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  large   'warn:scan omitido: entrada fuera de rango \(texto mayor de 1 MiB\)'
run_case "kb-notutf8-failopen"         lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  notutf8 'warn:scan omitido: error de entrada \(input_not_utf8\)'
run_case "kb-oldcli-failopen"          lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  oldcli  'warn:scan omitido: error .*0\.7\.0'
for m in ratelim short large notutf8 oldcli locked; do
  printf '%s' "$(pre_kb entity_create "$LEAK")" | env -i PATH="$PATH_WITH" HOME="$FAKE_HOME" FAKE_KVENDRA_MODE="$m" \
    bash "$SCRIPTS/lvr-scan-tool-input.sh" > "$WORK/x.out" 2> "$WORK/x.err"
  msg="$(jq -r '.systemMessage // empty' "$WORK/x.out")"
  bad=0
  [[ "$m" == "ratelim" ]] && printf '%s' "$msg" | grep -q "fuera de rango" && bad=1
  [[ "$m" != "ratelim" ]] && printf '%s' "$msg" | grep -q "rate limit" && bad=1
  printf '%s' "$msg" | grep -qiE "limpio|clean|sin coincidencias" && bad=1
  printf '%s' "$msg" | grep -q "scan omitido" || bad=1
  if [[ $bad -eq 0 ]]; then echo "PASS  kb-exit2-cause-distinct-$m"; PASS=$((PASS+1));
  else echo "FAIL  kb-exit2-cause-distinct-$m: $msg"; FAIL=$((FAIL+1)); FAILED+=("kb-exit2-cause-distinct-$m"); fi
done
run_case "sub-ratelimit-failopen"      lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" ratelim 'warn:scan omitido: rate limit'
run_case "sub-large-failopen"          lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" large   'warn:scan omitido: entrada fuera de rango'
# No CLI (Pro without `kvendra`): no broker, no local values → total silence (1.21.1).
run_case "kb-nobinary-quiet"           lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  absent  quiet
run_case "kb-update-nobinary-quiet"    lvr-scan-tool-input.sh "$(pre_kb entity_update "$CLEAN")" absent  quiet
run_case "kb-unreadable-hits-deny"     lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  badhits deny
run_case "kb-other-tool-nocall"        lvr-scan-tool-input.sh "$(jq -nc '{tool_name:"mcp__plugin_kvendra-skills_kvendra-cloud__entity_get", tool_input:{entity_id:"PAT-KVD-1"}}')" scan nocall
run_case "kb-deny-reason-has-ref"      lvr-scan-tool-input.sh "$(pre_kb entity_create "$LEAK")"  scan    deny
grep -qF "{{lvr:$SENTINEL_KEY}}" "$WORK/out" || { echo "FAIL  kb-deny-reason-has-ref (no {{lvr:key}} in reason)"; FAIL=$((FAIL+1)); FAILED+=("kb-deny-reason-has-ref:ref"); }

echo "== lvr-scan-subagent.sh (SubagentStop) =="
run_case "sub-msg-hit-block"           lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" scan   block
run_case "sub-transcript-hit-block"    lvr-scan-subagent.sh "$(sub_tr "$FIX/agent-transcript.jsonl")" scan block
run_case "sub-transcript-clean"        lvr-scan-subagent.sh "$(sub_tr "$FIX/clean-transcript.jsonl")" scan silent
run_case "sub-loopguard-pass-warn"     lvr-scan-subagent.sh "$(sub_msg "$LEAK" true)"  scan   'warn:sigue conteniendo'
run_case "sub-locked-failopen"         lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" locked 'warn:scan omitido: vault bloqueado'
run_case "sub-nobinary-quiet"          lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" absent quiet
run_case "sub-loopguard-nobinary-quiet" lvr-scan-subagent.sh "$(sub_msg "$LEAK" true)" absent quiet
run_case "sub-transcript-nobinary-quiet" lvr-scan-subagent.sh "$(sub_tr "$FIX/agent-transcript.jsonl")" absent quiet
run_case "sub-novars-quiet"            lvr-scan-subagent.sh "$(sub_msg "$LEAK" false)" novars quiet
run_case "sub-no-report-nocall"        lvr-scan-subagent.sh '{"hook_event_name":"SubagentStop","stop_hook_active":false,"transcript_path":"/nonexistent/parent.jsonl"}' scan nocall

echo "== deny-vault-paths.sh (PreToolUse file tools) =="
H="$FAKE_HOME"
run_case "read-tilde-deny"        deny-vault-paths.sh "$(file_tool Read '{"file_path":"~/.kvendra/vars.blob"}')" scan deny
jq -r '.hookSpecificOutput.permissionDecisionReason' "$WORK/out" | grep -qF 'kvendra secret show-allowlist <profile_id>' \
  && { echo "PASS  read-deny-points-to-show-allowlist"; PASS=$((PASS+1)); } \
  || { echo "FAIL  read-deny-points-to-show-allowlist"; FAIL=$((FAIL+1)); FAILED+=("read-deny-points-to-show-allowlist"); }
run_case "read-nocli-still-deny"  deny-vault-paths.sh "$(file_tool Read '{"file_path":"~/.kvendra/vars.blob"}')" absent deny
run_case "read-dollar-home-deny"  deny-vault-paths.sh "$(file_tool Read '{"file_path":"$HOME/.kvendra/sessions/x.token"}')" scan deny
run_case "read-abs-deny"          deny-vault-paths.sh "$(file_tool Read "{\"file_path\":\"$H/.kvendra/allowlists/a.yaml\"}")" scan deny
run_case "read-dotdot-deny"       deny-vault-paths.sh "$(file_tool Read '{"file_path":"../.kvendra/vars.blob"}')" scan deny
run_case "read-symlink-deny"      deny-vault-paths.sh "$(file_tool Read "{\"file_path\":\"$H/innocent-link/vars.blob\"}")" scan deny
run_case "read-case-deny"         deny-vault-paths.sh "$(file_tool Read '{"file_path":"~/.KVENDRA/vars.blob"}')" scan deny
run_case "write-deny"             deny-vault-paths.sh "$(file_tool Write '{"file_path":"~/.kvendra/x","content":"y"}')" scan deny
run_case "edit-deny"              deny-vault-paths.sh "$(file_tool Edit '{"file_path":"~/.kvendra/config.toml","old_string":"a","new_string":"b"}')" scan deny
run_case "notebook-deny"          deny-vault-paths.sh "$(file_tool NotebookEdit '{"notebook_path":"~/.kvendra/n.ipynb","new_source":""}')" scan deny
run_case "glob-abs-pattern-deny"  deny-vault-paths.sh "$(file_tool Glob '{"pattern":"~/.kvendra/**"}')" scan deny
run_case "glob-rel-pattern-deny"  deny-vault-paths.sh "$(file_tool Glob "$(jq -nc --arg h "$H" '{pattern:".kvendra/**/*.yaml", path:$h}')")" scan deny
run_case "glob-dotdot-deny"       deny-vault-paths.sh "$(file_tool Glob '{"pattern":"../.kvendra/*"}')" scan deny
run_case "grep-path-deny"         deny-vault-paths.sh "$(file_tool Grep '{"pattern":"token","path":"~/.kvendra"}')" scan deny
run_case "grep-glob-deny"         deny-vault-paths.sh "$(file_tool Grep "$(jq -nc --arg h "$H" '{pattern:"x", path:$h, glob:".kvendra/**"}')")" scan deny
run_case "kvendra-home-deny"      deny-vault-paths.sh "$(file_tool Read "{\"file_path\":\"$OTHER_VAULT/vars.blob\"}")" scan deny "KVENDRA_HOME=$OTHER_VAULT"
run_case "read-workspace-allow"   deny-vault-paths.sh "$(file_tool Read '{"file_path":"notes.txt"}')" scan silent
run_case "read-marker-allow"      deny-vault-paths.sh "$(file_tool Read '{"file_path":".kvendra-protected"}')" scan silent
run_case "glob-workspace-allow"   deny-vault-paths.sh "$(file_tool Glob '{"pattern":"**/*.md"}')" scan silent
run_case "bash-ignored"           deny-vault-paths.sh "$(file_tool Bash '{"command":"ls ~/.kvendra"}')" scan silent
run_case "deny-no-kvendra-call"   deny-vault-paths.sh "$(file_tool Read '{"file_path":"~/.kvendra/vars.blob"}')" scan deny
[[ -s "$CALLS" ]] && { echo "FAIL  deny-no-kvendra-call (deny-vault-paths invoked kvendra)"; FAIL=$((FAIL+1)); FAILED+=("deny-no-kvendra-call:calls"); }

echo ""
echo "==== summary ===="
echo "passed: $PASS"
echo "failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "failed: ${FAILED[*]}"
  exit 1
fi
exit 0
