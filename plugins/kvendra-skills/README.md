# kvendra-skills

Claude Code plugin that drives the Kvendra hosted knowledge base (KB) with a set of skills (feature delivery, bug triage, releases, documentation and more). This page states what the plugin runs on your machine and what it sends. For installation and the skill catalogue, see the [repository README](../../README.md).

## Install

```
/plugin marketplace add KvendraAI/kvendra-skills
/plugin install kvendra-skills@kvendra-marketplace
```

## MCP server

The plugin declares one MCP server, `kvendra-cloud`, in `.mcp.json`. It connects over HTTP to `https://api.kvendra.cloud/mcp`. Sign-in uses OAuth 2.1 with PKCE against `auth.kvendra.cloud`. A Kvendra account (hosted KB, Pro tier or above) is required; without one the skills have nothing to talk to. The URL accepts an optional suffix from the `KVENDRA_WS` environment variable (for example `?ws=acme`) so that each directory can keep a separate OAuth credential per account. When the variable is unset, the URL is exactly the one above.

## Hooks

The hooks are declared in `hooks/hooks.json`; each runs a shell script from `scripts/`. They need `jq`; when it is missing, they do nothing (most print a warning to say so).

- **PreToolUse on Bash**: `block-unsafe-ops.sh` blocks commands that name the local vault directory (`~/.kvendra`). If the workspace has a `.kvendra-protected` policy file, it also blocks the commands that policy lists (writes and deploys that need credentials) and points to the Kvendra broker primitive to use instead. If a signed break-glass grant is enabled in that policy, it asks the local `kvendra` CLI to verify the grant.
- **PreToolUse on KB writes** (`entity_create`, `entity_update`): `lvr-scan-tool-input.sh` passes the text of the write to `kvendra vars scan` on your machine. If it contains the value of a local variable, the write is denied and the variable's key is named instead. It does nothing when the `kvendra` CLI is not installed.
- **PreToolUse on file tools** (Read, Edit, Write, MultiEdit, NotebookEdit, Glob, Grep): `deny-vault-paths.sh` denies access to the local vault directory (`~/.kvendra`, and `$KVENDRA_HOME` when set).
- **SubagentStop**: `lvr-scan-subagent.sh` runs the same local scan on a subagent's final report and, on a hit, asks the subagent to re-emit it with the variable reference instead of the value.
- **SessionStart and UserPromptSubmit**: `inbox-nudge.sh` runs `kvendra inbox status` and, when new coordination messages are waiting in the KB, adds one fixed sentence to the agent's context. Nothing read from the CLI or the server is added to the context except a count.
- **SessionStart (resume or compact)**: `session-resume-nudge.sh` adds one fixed sentence reminding the agent to read its resume pointer. It makes no network call and reads no files.
- **Stop**: `communication-stop-check.sh` checks the form of the final message (no process narration on the first line; an approval line when the message ends with a numbered choice) for sessions running the plugin's skills, and asks for one rewrite when it fails. It reads the session transcript and a local data file, and never writes files or uses the network.

These hooks are local safeguards, not security controls; the values themselves are protected by the vault and the broker in the `kvendra` CLI.

## Attribution

The skills that write a git commit, a pull request or a GitHub Release (`implementer`, `release-manager`, `bug`, `new-feature`, `deploy`) add a short Kvendra attribution: the commit trailer `Co-authored-by: Kvendra <hello@kvendra.ai>` after any existing trailers (the Anthropic / Claude Code trailer is left as it is), and one last line with a link to kvendra.com in pull request and release bodies. Nothing else is added to the target repository. It is on by default; turn it off at either level:

- **User**: set the environment variable `KVENDRA_ATTRIBUTION` to `0`, `false` or `off`, for example in the `env` of Claude Code `settings.json`: `{ "env": { "KVENDRA_ATTRIBUTION": "off" } }`.
- **Project**: set `metadata.attribution` to `false` on the project's `PRJ` entity in the KB; the skills read it at bootstrap.

## Data handling

The plugin sends nothing by itself. Data leaves your machine only through the `kvendra-cloud` MCP tools that the agent calls, and the skills use them to write what the agent explicitly writes to your Kvendra knowledge base: entities (requirements, issues, decisions, documents and similar) and their change history. The hooks are shell scripts that make no network calls themselves; they only call the local `kvendra` CLI (`vars scan`, `inbox status`, `verify-grant`), and `inbox status` is the one that may contact the Kvendra server (at most once a minute, answered from a local cache otherwise). See the Kvendra privacy policy: <https://kvendra.com/legal/privacy>.
