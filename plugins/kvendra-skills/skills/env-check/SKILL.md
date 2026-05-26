---
name: env-check
description: Verify the environment is correctly configured — MCPs (kvendra-cloud KB + kvendra broker), tools, skills, CLAUDE.md, workspace marker, PreToolUse hook
user_invocable: true
---

# Env Check — Verify and repair the Kvendra environment

## External-execution rules (MANDATORY)

Any operation that uses credentials or leaves the local machine (git, github,
aws, npm, pypi, http with auth, shell commands) MUST be invoked via primitives
of the `kvendra` broker (local stdio MCP). NO direct Bash.

| Desired op | Primitive |
|---|---|
| git clone/push/pull/commit/tag | `kvendra.git` |
| GitHub REST/GraphQL | `kvendra.github` |
| AWS s3/cloudfront/lambda | `kvendra.aws` |
| npm publish/deprecate/read_metadata | `kvendra.npm` |
| PyPI upload/read_metadata | `kvendra.pypi` |
| HTTP with auth | `kvendra.http` |
| Shell with allowlisted binary (NOT `sh -c`) | `kvendra.shell` |

Each call requires a `profile_id` (workspace-bound vault credential). Do not improvise.

**FORBIDDEN via Bash**: `git commit/push/tag/merge/reset --hard/checkout --`,
`gh release/pr create/api`, `aws s3 (sync|cp)/cloudfront/lambda`, `npm publish`,
`cargo publish`, `pip upload`/`twine upload`. Read-only inspections (`git status`,
`git log`, `gh issue view`, `aws sts get-caller-identity`) ARE allowed via Bash.

If the `kvendra` broker is unavailable (failed to connect): STOP. NO fallback to Bash.

Additionally enforced by the plugin's PreToolUse hook (active only inside
workspaces with a `.kvendra-workspace` marker).

---

You verify that everything is configured correctly to use the kvendra-skills
plugin + the hosted Kvendra KB + the capabilities broker. If something is
missing, diagnose and guide the user to the concrete fix.

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

### 7. `.kvendra-workspace` marker in CWD or an ancestor

```bash
DIR="$PWD"; while [[ "$DIR" != "/" ]]; do
  [[ -f "$DIR/.kvendra-workspace" ]] && echo "FOUND: $DIR/.kvendra-workspace" && break
  DIR="$(dirname "$DIR")"
done
```

- **FOUND** → PreToolUse hook active, will block Bash for external ops.
- **NOT FOUND** → hook does not activate in this directory. If intentional
  (project outside Kvendra), OK. Otherwise create the marker manually:
  `printf 'workspace: <name>\n' > .kvendra-workspace`.

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
| 7 | .kvendra-workspace marker | FOUND / NOT_FOUND | <path or NOT_FOUND> |
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
