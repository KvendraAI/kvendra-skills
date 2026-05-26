---
name: changelog
description: Change query tool — shows what changed, who, when and why, reading entity_history and entity_changelog from the Kvendra KB
user_invocable: true
args: "[filters: project, component, date, release, author, entity]"
---

# Changelog — Cross-entity change query

You query and present the changes recorded in the Kvendra KB, filtering
across multiple criteria. The server maintains `entity_history` (audit per
entity) and `entity_changelog` (per-REL) automatically. Here you present them.

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

## Step 1 — Parse filters

Parse the arguments:
- **Project**: project_id (default: from the CLAUDE.md).
- **Component**: short code.
- **Date**: range (last N days, from–to).
- **Release**: specific REL ID.
- **Author**: name or `skill:<name>`.
- **Entity**: type (IF, CMP, TEST, ...) or specific ID.

Examples:
- `/changelog KVD WEB last 7 days`
- `/changelog REL-KVD-SKILLS-0.5.0`
- `/changelog IF last 30 days`
- `/changelog` (recent general summary)

## Step 2 — Collect data

### Source 1: entity_history (per entity)

`mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id, include_related: false })` returns `history` (last 5).

If filtering by a specific entity, this is enough. If filtering by component
or type: first
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type, project_id, component_id, order_by: "updated_at_desc" })`
and then `entity_get` per entity.

### Source 2: entity_changelog (per REL)

For each REL in the filter, `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REL-..." })` — the
server returns the associated changelog in the bundle.

### Source 3: Recent TXNs

`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TXN", project_id:<PROJ>, order_by:"updated_at_desc", limit:10 })`

→ completed / cancelled steps, pipelines, durations.

## Step 3 — Present results

Sort chronologically (most recent first).

## Output

```
## Changelog — <filter description>
Period: <date range>

### Summary
- Total changes: N
- Modified entities: N
- Authors: [list]
- Affected releases: [list]

### Timeline

#### <date>
| Time | Author | Entity | Change | Trigger | Release |
|------|--------|--------|--------|---------|---------|
| 16:30 | skill:implementer | IF-<PROJ>-<COMP>-001 | +timeoutMs field | ISSUE-<PROJ>-<COMP>-019 | REL-<PROJ>-0.1.0 |
| 16:15 | skill:tester      | TEST-<PROJ>-<COMP>-001 | v1.1→1.2, +V5 | ISSUE-<PROJ>-<COMP>-019 | REL-<PROJ>-0.1.0 |
| 15:00 | <user>            | REQ-<PROJ>-006 | Initial creation | feature request | REL-<PROJ>-0.1.0 |

### By component
| Component | Changes | Last change |
|-----------|---------|-------------|
| <COMP> | 5 | 2026-04-16 |

### By entity type
| Type | Changes |
|------|---------|
| IF | 3 |
| TEST | 4 |
| ISSUE | 2 |
| REQ | 1 |
```
