---
name: env-check
description: Verify the environment is correctly configured — MCPs (kvendra-cloud KB + kvendra broker), tools, skills, CLAUDE.md, workspace marker, PreToolUse hook
user_invocable: true
---

# Env Check — Verify and repair the Kvendra environment

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Checks (in order)

### 1. MCP `kvendra-cloud` (KB) connected

```bash
claude mcp list 2>&1 | grep -E '^kvendra-cloud:|plugin.*kvendra-cloud'
```

Expected states:
- `✓ Connected` → OK.
- `! Needs authentication` → run `/mcp` from Claude Code and complete the OAuth flow.
- `✗ Failed to connect` → verify https://api.kvendra.cloud is reachable + check token TTL.

### 2. The 14 KB tools from `kvendra-cloud` available

Look in the registered tool list for the prefix
`mcp__plugin_kvendra-skills_kvendra-cloud__*`. Expected tools (14):

`entity_create, entity_update, entity_get, entity_query, entity_search,
entity_archive, entity_related, txn_create, txn_activate, txn_cancel,
txn_check_interrupted, whoami, config_get, help`

If you see `authenticate` / `complete_authentication` instead of the 14: the
MCP is not authenticated. Resolve with `/mcp` from Claude Code.

### 3. Real KB read test

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"PRJ", limit: 5 })
```

- Works → show the count of visible projects.
- Fails → check the JWT (Cognito access_token, not id_token — see `PAT-KVD-ENTERPRISE-015`).

### 4. MCP `kvendra` (local capabilities broker) connected

```bash
claude mcp list 2>&1 | grep -E '^kvendra:'
```

States:
- `✓ Connected` → OK, broker live.
- `✗ Failed to connect` → possible causes:
  - **Master password unavailable**: the MCP config should pass `--use-keychain`
    (recommended, macOS) or env var `KVENDRA_MCP_PASSWORD`. Stdio MCP cannot
    prompt interactively.
  - **Bug `session token store error: decode`** in versions 0.4.0-alpha.x: the
    file `~/.kvendra/sessions/<workspace>.token` is written as a JWT but read
    as JSON. Workaround: move `pro.token` to `.bak`, retry.
  - **Corrupt vault**: run `kvendra unlock` interactively from a terminal;
    if it fails, recover with the BIP-39 mnemonic.

### 5. The 7 broker primitives available

Expected tools (prefix `mcp__kvendra__*`):

`kvendra.git, kvendra.github, kvendra.aws, kvendra.npm, kvendra.pypi,
kvendra.http, kvendra.shell` (plus `kvendra.unsafe.raw_token` UNSAFE flag).

NOTE on sanitisation: Claude Code may transform the dot into an underscore
in the tool name (e.g. `mcp__kvendra__kvendra_git`). Verify with `/mcp` which
exact names are registered locally — the "External-execution rules" block
uses the canonical dotted name, the agent must resolve the exact MCP prefix
against the deferred tools list.

If a primitive is missing: the `kvendra` binary is out of date. Reinstall
via the project's release flow.

### 6. `CLAUDE.md` with Project Identity and KB routing declared

Read the `CLAUDE.md` of the current directory (if it exists). Verify:

```yaml
project_id: <value>
tier: <free|pro|team|enterprise>
```

- Without `project_id`: skills will not function. Suggest `/onboard-project`.
- Without `tier`: ambiguous routing. Suggest adding the line (see the
  canonical template `STD-KVD-CLAUDEMD-TEMPLATE` in the KB or the existing
  `CLAUDE.md` files of Kvendra projects as reference).

If all OK, validate that the PRJ exists in the KB:
```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"PRJ-<value>" })
```

### 7. Broker-policy marker in CWD or an ancestor

The canonical marker is `.kvendra-protected`. `.kvendra-workspace` is the
legacy marker of the transition window and is **no longer supported** by the
hook. Resolve both exactly as the hook does — walk up from the cwd, and let
the nearest `.kvendra-protected` win over any legacy marker found on the way:

```bash
DIR="$PWD"; PROT=""; LEGACY=""
while :; do
  [[ -z "$PROT"   && -f "$DIR/.kvendra-protected" ]] && PROT="$DIR/.kvendra-protected" && break
  [[ -z "$LEGACY" && -f "$DIR/.kvendra-workspace" ]] && LEGACY="$DIR/.kvendra-workspace"
  PARENT="$(dirname "$DIR")"; [[ "$PARENT" == "$DIR" ]] && break; DIR="$PARENT"
done
echo "protected: ${PROT:-NONE}"; echo "legacy: ${LEGACY:-NONE}"
```

- **`.kvendra-protected` found** → **OK**. Enforcement is active from that
  workspace root down. Report the path. A legacy marker sitting alongside it
  is inert; mention it as an INFO line and suggest removing it.

- **Only `.kvendra-workspace` found** → **ERROR**, not OK. The hook rejects
  the legacy marker outright and fails closed: **every** Bash call in this
  workspace exits 2, read-only ones included. Remediation: run
  `/sync-claudemd --policy-only` to materialise `.kvendra-protected` from
  `STD-<PROJ>-BROKER-POLICY`, then delete the legacy file. Never hand-write a
  marker: an unsigned or hand-made file is what bricks the workspace.

- **Neither found** → no enforcement in this directory. Two very different
  causes, so distinguish them before reporting. Read the project's
  broker-policy STD:
  ```
  mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
    entity_type:"STD", project_id:"<PROJECT>",
    tags_all:["scope:broker-policy"], status:"active", limit:1 })
  ```
  - STD exists with `metadata.broker_install_skipped: true` → **OK
    (broker-less)**. A missing marker is the documented no-enforcement state
    of the contract, not a defect. No action. Enforcement starts once the
    broker is installed, the flag is cleared on the STD, and
    `/sync-claudemd --policy-only` is run.
  - STD exists without that flag → **WARN**: the KB contract says the policy
    should be materialised and it is not. Remediation:
    `/sync-claudemd --policy-only`.
  - No STD, or no `project_id` in `CLAUDE.md` → the project was never
    onboarded. Suggest `/onboard-project`. If the directory is intentionally
    outside Kvendra, this is expected — report it as informational.

### 8. PreToolUse hook from the plugin installed

```bash
# Look for the hook script in installed-plugin locations
find ~/.claude/plugins -name block-unsafe-ops.sh -path '*kvendra-skills*' 2>/dev/null
```

- **Found and executable** → hook active.
- **Not found** → the `kvendra-skills` plugin is not installed or is
  incomplete. Reinstall with `/plugin install kvendra-skills` or equivalent.

### 9. Skills available

List the plugin's skills. Minimum:
`/consultancy, /to-do, /bug, /new-feature, /implementer, /updater, /validator,
/release-manager, /tester, /analyzer, /onboard-project, /deploy, /version`.

If any are missing: the plugin is not enabled or has not been refreshed
after install. Ask the user to run `/plugin list` and validate that
`kvendra-skills` appears as enabled.

## Required output

```
## Environment status

| # | Component | Status | Detail |
|---|-----------|--------|--------|
| 1 | MCP kvendra-cloud (KB) | OK / NEEDS_AUTH / FAIL | <state> |
| 2 | 14 KB tools | OK / N/14 / N/A | <missing list> |
| 3 | KB read test | OK / FAIL | <N projects / error> |
| 4 | MCP kvendra (broker) | OK / FAIL | <cause> |
| 5 | 7 broker primitives | OK / N/7 / N/A | <missing list> |
| 6 | CLAUDE.md + Project Identity | OK / PARTIAL / NONE | project_id: X, tier: Y |
| 7 | Broker-policy marker | OK / OK (broker-less) / WARN / ERROR (legacy) | <path or cause> |
| 8 | PreToolUse hook | INSTALLED / MISSING | <path> |
| 9 | Skills | OK / N skills | <list or missing> |

### Detected problems
- [prioritised list]

### Recommended actions
- [<concrete action>]
```

## Rules

- **Do not modify anything without asking** — only diagnose and report.
- **If all OK**, say: "Environment OK — ready to use /consultancy, /bug, /new-feature, etc."
- **Be specific** about errors: cite the failing command and how to fix it.
- **Distinguish the three connections**: hosted KB (operational writes) vs
  local broker (external ops with audit) vs skills (local files).
