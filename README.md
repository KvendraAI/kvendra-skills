# kvendra-skills

**Skills + remote MCP server** for the Kvendra hosted knowledge engine
(<https://api.kvendra.cloud/mcp>). Plugin for Claude Code,
installable through the native `/plugin` command.

## What's in this repo

| Slot | Content |
|---|---|
| `plugins/kvendra-skills/skills/<name>/SKILL.md` | 25 skills: orchestrators (`feature`, `bug`, `incident`, `release`, `regression`), subagents (`planner`, `implementer`, `validator`, `tester`, `updater`, `analyzer`, …), doc + reporting (`manual-writer`, `doc-indexer`, `doc-validator`, `translator`, `changelog`, `to-do`, `to-do-summary`, `user-help`), consultancy (`consultancy`, `requirements-analyst`, `interface-validator`) and environment (`env-check`). |
| `plugins/kvendra-skills/.claude-plugin/plugin.json` | Plugin manifest (`name`, `description`, `version`, author, repo). |
| `.claude-plugin/marketplace.json` | Marketplace listing at the repo root — so a user can do `/plugin marketplace add KvendraAI/kvendra-skills` and pick up the plugin via its `./plugins/kvendra-skills` source path. |
| `plugins/kvendra-skills/.mcp.json` | Declares the `kvendra` HTTP MCP server (`https://api.kvendra.cloud/mcp`). `/plugin install` adds it to the user's `~/.claude.json` automatically. |
| `INSTALL.md` | Step-by-step setup (signup → Pro tier → `/plugin marketplace add` → first OAuth dance). |

## Install

```text
/plugin marketplace add KvendraAI/kvendra-skills
/plugin install kvendra-skills@kvendra-marketplace
```

See [INSTALL.md](./INSTALL.md) for the full flow including how to get
on Pro tier and how the OAuth/PKCE dance against
`auth.kvendra.cloud` works.

## Architecture

```
Claude Code (local)              api.kvendra.cloud/mcp (Lambda)
    │                                  │
    │  POST /mcp                       │
    │  Authorization: Bearer …         │
    ├─────────────────────────────────►│  → routes JSON-RPC `tools/call`
    │                                  │    to the 14 KB engine handlers
    │  401 + WWW-Authenticate          │  → which talk to Aurora
    │◄─────────────────────────────────┤    (tenant_<id> schema)
    │
    │  /.well-known/oauth-authorization-server
    ├─────────────────────────────────►│  → metadata points to Cognito
    │                                  │
    │  OAuth/PKCE flow                 │  Cognito Hosted UI
    │  on auth.kvendra.cloud           │  (auth.kvendra.cloud/oauth2/*)
    │                                  │
    │  POST /mcp + Bearer token        │
    ├─────────────────────────────────►│
    │  ◄────── result ───────          │
```

The plugin does NOT bundle the Kvendra CLI Rust binary that handles
local primitives (`kvendra.git`, `kvendra.github`, `kvendra.aws`, …) —
those operate on your laptop's filesystem by construction and need to
run locally. The KB tools that the 25 skills invoke are 100% cloud and
work with just this plugin + a Pro account.

## Tools exposed

All 14 are wire-public (see `IF-KVD-ENTERPRISE-004` in the Kvendra KB):

| Tool | Purpose |
|---|---|
| `entity_get` | Lookup an entity by id. |
| `entity_create` | Create a typed entity (PRJ, CMP, IF, REQ, TEST, REG, ISSUE, REL, SLA, ROAD, GLO, STD, PAT, ADR, RUN, UX, DOC, ENV, COST, CFG). |
| `entity_update` | Read-modify-write. Requires `change_summary`. |
| `entity_archive` | Soft-archive an entity. |
| `entity_related` | Outbound + inbound relations. |
| `entity_query` | Boolean filter (tags_all, tags_any, status, dates, project, component). |
| `entity_search` | Semantic search (pgvector HNSW, cosine similarity). |
| `txn_create` / `txn_activate` / `txn_cancel` / `txn_check_interrupted` | Transactional grouping for drafts. |
| `whoami` | Identity + tier + role + auth_mode. |
| `config_get` | Per-user / per-project config. |
| `help` | Static protocol topics (`bootstrap`, `naming`, `txn`, `errors`, …). |

Two more tools (`txn_get`, `check_duplicates`) are referenced by a few
skills and will be added in a backend follow-up — they degrade
gracefully today.

## License

MIT — see [LICENSE](./LICENSE).

## Links

- Site: [kvendra.com](https://kvendra.com)
- App / dashboard: [app.kvendra.cloud](https://app.kvendra.cloud)
- API: [api.kvendra.cloud](https://api.kvendra.cloud)
- Org: [github.com/KvendraAI](https://github.com/KvendraAI)
- Contact: hello@kvendra.ai
