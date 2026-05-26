---
name: to-do-summary
description: ISSUE summary — shows the state of Kvendra KB work items with filters by status, component, type and priority
user_invocable: true
args: "[optional filters: component, type, status, priority]"
---

# To-Do Summary — Kvendra KB ISSUE overview

You show a summary of work items (ISSUE) in the Kvendra KB filtered by
component, type, status and priority.

## Filters

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md`.

## Kvendra rules (summary)

- Identify yourself on every write: `updated_by: "skill:<this-skill>"`. The
  `X-Kvendra-Skill` header is added by the MCP client automatically.
- Orchestrator → `txn_create` before creating entities, close with
  `txn_activate` (success) or `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel(reason)` (failure).
  Subagent → receives `txn_id` via args and does NOT open/close the TXN.
- Before opening a TXN: `mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted(project_id, component_id?)`.
  If an in-progress TXN exists: Resume / Cancel / Ignore.
- Entity IDs are emitted by the server. Exception: `PRJ`/`CMP`/`REL` require `force_id`.
- If an error returns `error.help.topic`, call `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.

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

## Step 1 — Query ISSUEs

Apply filters from the arguments:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "ISSUE",
  project_id: <PROJ>,
  component_id: <optional>,
  status: ["new", "in-progress", "analyzing"],   // or array per filter
  tags_all: ["type:<type>", "priority:<level>"], // optional
  archived: false,
  drafts: false,
  order_by: "updated_at_desc",
  limit: 100
})
```

## Step 2 — Present results

```
## ISSUEs — <project> <applied filters>
Date: <date>

### Summary
- Total: N
- Bugs: N (M critical, K high)
- Tasks: N
- Incidents: N
- Release blockers: N

### By status
| Status | Count |
|--------|-------|
| new | N |
| in-progress | N |
| analyzing | N |
| fixing | N |
| blocked | N |

### Detail
| ID | Type | Prio. | Status | Comp. | Title | Release |
|----|------|-------|--------|-------|-------|---------|
| ISSUE-<PROJ>-<COMP>-001 | bug | high | fixing | <COMP> | Timeout callback | REL-<PROJ>-0.1.0 |
| ISSUE-<PROJ>-042 | task | medium | new | — | Update docs | — |

### Release blockers
For each ISSUE with an active `blocks → REL-...` relation:
| ISSUE | Blocks | Reason |
|-------|--------|--------|
| ISSUE-<PROJ>-<COMP>-050 | REL-<PROJ>-0.1.0 | Regression in TEST-<PROJ>-<COMP>-020 |
```

For each ISSUE in blockers, use
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id, include_related: false })`
and read `relations_outbound` to detect `blocks`.
