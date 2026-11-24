---
name: env-check
description: Verify the environment is correctly configured — MCPs (kvendra-cloud KB + kvendra broker), tools, skills, CLAUDE.md, workspace marker, plugin hooks, account routing (multi-account), local variables and vault deny rules
user_invocable: true
---

# Env Check — Verify and repair the Kvendra environment

<!-- kvendra:kb-server v1 -->
## Kvendra server (canonical block — edit it in every carrier or in none)

Engine calls in this skill use the bare tool name (`entity_get(...)`, `txn_create(...)`). Your client adds its own prefix: call the tool of that name on the Kvendra server, the MCP server that exposes `whoami`, `help` and `entity_get`, whatever its name (`mcp__plugin_kvendra-skills_kvendra-cloud__*` from this plugin, `mcp__claude_ai_<connector>__*` from a claude.ai connector, `mcp__<name>__*` from `claude mcp add`, no prefix in other clients). Load its tools first if they are deferred. The local broker `kvendra` (`kvendra_git`, `kvendra_aws`…) is not the Kvendra server. If more than one server exposes them (for example the plugin server with a directory's `KVENDRA_WS` and a claude.ai connector on the default account), use the plugin server: it carries this directory's account. Without the plugin server, ask the user which one to use. Never mix two Kvendra servers in one task. If no server exposes those three tools, stop and tell the user the Kvendra environment is not available.
<!-- /kvendra:kb-server -->

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Checks (in order)

### 1. Kvendra server (KB) connected

```bash
claude mcp list 2>&1 | grep -E 'api\.kvendra\.cloud/mcp'
```

Match by URL, not by name: the entry may be the plugin server
(`plugin:kvendra-skills:kvendra-cloud`), a claude.ai connector (`claude.ai <Name>`)
or a server added with `claude mcp add`.

More than one matching line (for example the plugin server with `?ws=<workspace>` and a
claude.ai connector on the default account) is not an error, but report it as a WARNING:
the skills use the plugin server, and both must be connected to the account you expect.

Only a claude.ai connector line, with no `plugin:kvendra-skills:kvendra-cloud` line while
the plugin is installed → WARNING (plugin server hidden): Claude Code hides the plugin
server when a claude.ai connector points at the same URL (typical in `claude -p`). The
skills then use the connector: the plugin's client header `X-Kvendra-Client` is not
sent, and `work` still works.

Expected states:
- `✓ Connected` → OK.
- `! Needs authentication` → run `/mcp` from Claude Code and complete the OAuth flow.
  With several Kvendra accounts this may just be a secondary account that has
  not signed in yet (see check 10) — it is not necessarily a defect. On the
  plugin server right after updating to kvendra-skills 2.0.0 it is expected
  once: run `/mcp` → kvendra-cloud → Authenticate (the new client header
  changes the stored credential).
- `✗ Failed to connect` → verify https://api.kvendra.cloud is reachable + check token TTL.

### 2. Essential tools of the Kvendra server, with `work`

Find the Kvendra server's tools (see **Kvendra server**). kvendra-skills 2.0.0
needs these:

`whoami, help, entity_get, entity_query, entity_create, entity_update,
txn_create, txn_activate, txn_cancel, txn_check_interrupted, work`

- All present, and `help({ topic:"work" })` returns the topic (the ops of
  `work` and their arguments), not an unknown-topic error → **OK**.
- `work` missing → **FAIL**. Report: "kvendra-skills 2.0.0 needs the Kvendra
  tool `work`, and this session does not list it. Restart Claude Code, or run
  /mcp and reconnect the Kvendra server; if your Kvendra server has no `work`,
  keep kvendra-skills 1.35.x." A session opened before the server gained
  `work` keeps its old tool list until it reconnects. A Kvendra server
  without `work` (for example an older self-hosted Kvendra Platform) stays on
  kvendra-skills 1.35.x: there is no 1.x fallback in 2.0.0.
- Another essential tool missing → **FAIL** with the list: reconnect with
  `/mcp`.

The other tools are used by some skills only. A missing one on hosted means
the MCP session predates the server update: report it as a **WARN** naming
what it affects, and reconnect with `/mcp`.
- `private_value_resolve` — skills that need a private value to operate
  (deploy, implementer). Also confirm `help({ topic:"private-values" })` is
  served (syntax, escaping, markers, `private_value_resolve`).
- `file_upload_init`, `file_complete`, `file_get_url`, `file_list`,
  `file_delete` — evidence attachments (hosted Pro and above only).
- `proposals_list`, `approve_proposal`, `reject_proposal` — governance
  proposals.
- `check_notifications`, `send_message`, `message_ack`, `message_status`,
  `message_block` — coordination messages.
- `k_note_submit`, `k_note_list` — only `/k-notes`.
- `task_context` — the implementer falls back to `entity_get`.

If you see `authenticate` / `complete_authentication` instead of the tools:
the MCP is not authenticated. Resolve with `/mcp` from Claude Code (right
after updating to 2.0.0 this is expected once, see check 1).

### 3. Real KB read test

```
entity_query({ entity_type:"PRJ", limit: 5 })
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
    session token file under the vault directory is written as a JWT but read
    as JSON. This is an **owner-manual** fix: the agent never reads, moves or
    edits files under the vault directory (the plugin hooks deny it). Ask the
    owner to upgrade the `kvendra` CLI; as a workaround, the owner renames the
    affected `.token` file under `sessions/` to `.bak` from their own terminal
    and retries.
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
  canonical template in the KB (found by `entity_query` for `entity_type: "STD"` with `tags_all: ["scope:claudemd", "playbook_type:doc-template"]`) or the existing
  `CLAUDE.md` files of Kvendra projects as reference).

If all OK, validate that the PRJ exists in the KB:
```
entity_get({ entity_id:"PRJ-<value>" })
```

If the PRJ is **not found**, run check 10 before concluding anything. The
most common cause is not a missing project but a session authenticated
against the wrong account. Never suggest `/onboard-project` while check 10
is not OK: it would create the project in the wrong tenant.

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
  entity_query({
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
# Look for the hook scripts in installed-plugin locations
find ~/.claude/plugins -path '*kvendra-skills*' \( -name block-unsafe-ops.sh \
  -o -name deny-vault-paths.sh -o -name 'lvr-scan-*.sh' \) 2>/dev/null
```

- **Found and executable** → hook active. From 1.21.0 the plugin ships four
  scripts: `block-unsafe-ops.sh` (Bash policy + built-in vault-path rule),
  `deny-vault-paths.sh` (file tools), `lvr-scan-tool-input.sh` (KB writes) and
  `lvr-scan-subagent.sh` (subagent reports). The last three are **brakes, not
  controls**: the guarantee that a local value never leaves the machine is in
  the `kvendra` broker. Missing `lvr-scan-*` on 1.21.0+ → WARN (reinstall).
- **Not found** → the `kvendra-skills` plugin is not installed or is
  incomplete. Reinstall with `/plugin install kvendra-skills` or equivalent.

### 9. Skills available

List the plugin's skills. Minimum:
`/kvendra, /to-do, /bug, /new-feature, /implementer, /updater, /validator,
/release-manager, /tester, /analyzer, /onboard-project, /deploy, /version`.

If any are missing: the plugin is not enabled or has not been refreshed
after install. Ask the user to run `/plugin list` and validate that
`kvendra-skills` appears as enabled.

### 10. Account routing (multi-account)

The plugin's MCP URL is `https://api.kvendra.cloud/mcp${KVENDRA_WS:-}`. A
user with several Kvendra accounts sets `env.KVENDRA_WS` (e.g. `?ws=acme`)
in the `.claude/settings.json` of each base directory; each distinct URL
keeps its own OAuth credential. The label is only a client-side
discriminator — the server ignores it and the account is whatever was
typed at sign-in (`PAT-KVD-SKILLS-CEDB12`). Always report what the session
is really connected to:

```
whoami({})
```

Then compare the variable with the URL the **installed** plugin declares:

```bash
echo "KVENDRA_WS=${KVENDRA_WS-<unset>}"
python3 - <<'EOF'
import json, os
reg = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
for inst in reg.get("plugins", reg).get("kvendra-skills@kvendra-marketplace", []):
    mcp = json.load(open(os.path.join(inst["installPath"], ".mcp.json")))
    print(inst["version"], mcp["mcpServers"]["kvendra-cloud"]["url"])
EOF
```

**Trial accounts.** `whoami` returns `trial_write_gated: true` on every
`tier: trial` caller. It means writes depend on the trial being active, and
the trial is checked at write time; it is not a sign that saving is blocked.
Treat it as **informational, never a warning**: report it as "Pro trial —
writes are enabled while the trial is active", and never say the account
"may not be able to save". A real write failure (a 403 with a trial or tier
error) is still reported as an error, with its message.

- `KVENDRA_WS` unset → **OK (single account)**. Report `tenant_id` and `tier`.
- `KVENDRA_WS` set and the installed URL contains `${KVENDRA_WS` → **OK**.
  Report the label next to `tenant_id` and `tier` so the user can confirm the
  pairing (the label cannot prove it).
- `KVENDRA_WS` set and the installed URL does **not** contain it → **ERROR
  (account fallback)**. The variable is ignored and this session is on the
  default account, whatever the directory says. Plugin versions before
  1.16.1 shipped the bare URL; a hand-patched cache is overwritten by every
  plugin update. Remediation: update the plugin to 1.16.1 or later
  (`/plugin`), then restart Claude Code from the directory that holds the
  settings. **Stop KB writes until it is fixed.**
- The file is read from disk, but the MCP connection keeps the URL it had
  when the session started. After updating the plugin (or if `whoami`
  shows a tenant that does not match the label), restart Claude Code before
  trusting an OK.
- The directory's `CLAUDE.md` project is not found (check 6) while this
  check is OK → ask the user which account the project lives in; the
  directory is probably labelled for another one.

Rules that explain most surprises: project settings apply only when
Claude Code is started from the exact directory that holds `.claude/` (no
inheritance into subdirectories); a `KVENDRA_WS` exported in the shell
overrides every directory's settings; `claude -p` ignores project
settings, so never verify this check with it.

### 11. Local variables (`{{lvr:<key>}}`)

**CLI gate (checks 11 and 12).** Run `command -v kvendra` once. The `kvendra`
CLI is **optional on Pro** and **mandatory on Team**. Without the CLI there is
no broker, so there are no local variables and no vault to protect: report
checks 11 and 12 as **N/A (no kvendra CLI)** — never as a failure or a
warning — and skip their steps. The plugin's lvr scan hooks stay silent in
that case too. On a **Team** workspace (tier from check 6/10) a missing CLI is
not "N/A" for the environment: it is the failure reported by check 4 (the CLI
is mandatory there), and checks 11 and 12 do apply once it is installed.

Compares the local variables the KB declares for this project with the ones
stored on this machine. **Value-free**: the agent never sees, asks for or
prints a value.

1. Declarations (CFG with `metadata.kind:"local_var"`, no value):
   ```
   entity_query({
     entity_type:"CFG", project_id:"<PROJECT>",
     tags_all:["cfg-kind:local_var"], limit:100 })
   ```
   Build `[{"key":<metadata.key>,"type":<metadata.type>}, …]`. None declared →
   **N/A** (the project uses no local variables).
2. Local status — pipe that JSON to the CLI (requires broker 0.7.0+):
   ```bash
   printf '%s' '<declared JSON>' | kvendra vars status --declared-stdin --json
   ```
   - exit 0 → stdout `{"vars":[{key, declared_type, present, stored_type,
     verified, type_ok}], "undeclared_local":[key…]}`.
   - exit 4 → vault locked → **WARN** ("vault locked — the owner runs
     `kvendra unlock` in their terminal"). Do not retry in a loop.
   - exit 2 or "unrecognized subcommand" → broker older than 0.7.0 → **WARN**
     (upgrade the CLI).
3. Classify, by key only:
   - `present:false` → **missing**.
   - `present:true, verified:false` → **unverified** (typical after a backup
     restore).
   - `type_ok:false` → **wrong type** (stored type differs from the declared
     one, or the value no longer validates).
   - `undeclared_local` → stored on this machine but not declared in the KB
     (INFO: declare it, or the owner removes it).
4. Remedy — always **owner-manual**, in the owner's own terminal (a real TTY
   and the master password are required; an agent cannot run them):
   `kvendra vars set <key> --type <type>` (missing / wrong type) and
   `kvendra vars verify <key>` (unverified). Save the handoff text with the
   pending item in the KB, not only in the chat.

OK = every declared key present, verified and `type_ok`; WARN otherwise.

### 12. Recommended `permissions.deny` entries (read-only)

Applies only when the `kvendra` CLI is installed (see the CLI gate in
check 11); without it → **N/A (no kvendra CLI)**.

A plugin cannot declare `permissions.deny`, so the plugin hooks
(`deny-vault-paths.sh` + the built-in rule of `block-unsafe-ops.sh`) are the
first brake and the owner's settings are the second. Check — **read only, never
edit** — that the user settings carry the recommended entries:

```bash
python3 - <<'EOF'
import json, os
want = ["Read(~/.kvendra/**)", "Edit(~/.kvendra/**)"]
p = os.path.expanduser("~/.claude/settings.json")
try:
    deny = json.load(open(p)).get("permissions", {}).get("deny", [])
except (OSError, ValueError):
    deny = []
for w in want:
    print(("present " if w in deny else "missing ") + w)
EOF
```

- Both present → **OK**.
- Any missing → **WARN** with the exact entries. The owner adds them by hand
  to `permissions.deny` in their user settings (`Edit` rules also cover
  Write, MultiEdit and NotebookEdit; Glob and Grep honour `Read` rules). Never
  write the settings file yourself.
- These entries, like the hooks, are a brake and not a control: the values
  are protected by the vault's encryption and the broker.

## Required output

```
## Environment status

| # | Component | Status | Detail |
|---|-----------|--------|--------|
| 1 | Kvendra server (KB) | OK / NEEDS_AUTH / FAIL / WARN (plugin server hidden) | <state> |
| 2 | Essential KB tools + `work` | OK / FAIL (no work) / FAIL (<missing>) / WARN (<optional tools missing, or no private-values topic>) | <missing list> |
| 3 | KB read test | OK / FAIL | <N projects / error> |
| 4 | MCP kvendra (broker) | OK / FAIL | <cause> |
| 5 | 7 broker primitives | OK / N/7 / N/A | <missing list> |
| 6 | CLAUDE.md + Project Identity | OK / PARTIAL / NONE | project_id: X, tier: Y |
| 7 | Broker-policy marker | OK / OK (broker-less) / WARN / ERROR (legacy) | <path or cause> |
| 8 | PreToolUse hook | INSTALLED / MISSING | <path> |
| 9 | Skills | OK / N skills | <list or missing> |
| 10 | Account routing | OK / OK (single account) / ERROR (account fallback) | tenant_id, tier, KVENDRA_WS, installed URL |
| 11 | Local variables | OK / WARN / N/A / N/A (no kvendra CLI) | missing, unverified, wrong type, undeclared (keys only, never values) |
| 12 | Vault `permissions.deny` | OK / WARN / N/A (no kvendra CLI) | missing entries |

### Detected problems
- [prioritised list]

### Recommended actions
- [<concrete action>]
```

## Rules

- **Do not modify anything without asking** — only diagnose and report.
- **Never touch the vault directory** (`~/.kvendra`): no read, move, edit or
  listing of its files. Every remedy there is owner-manual, in their terminal.
- **Never print a local value**: checks 11 and 12 report keys and entries only.
- **If all OK**, say: "Environment OK — ready to use /kvendra, /bug, /new-feature, etc."
- **Be specific** about errors: cite the failing command and how to fix it.
- **Never recommend creating KB content** (onboarding, fixes) while check 10
  is ERROR — the write would land in the wrong account.
- **Distinguish the three connections**: hosted KB (operational writes) vs
  local broker (external ops with audit) vs skills (local files).
