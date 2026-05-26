---
name: requirements-analyst
description: Requirements analyst — evaluates requirements against the Kvendra KB (ROAD, REQ, IF, CMP) and creates formal REQ entities
user_invocable: true
args: "[requirement or need to evaluate]"
---

# Requirements Analyst — Analysis with Kvendra KB context

You evaluate a requirement against the real state of the Kvendra KB: check
for duplicates, ROAD conflicts, CMP impact, and create formal REQ entities
with relations. When invoked by an orchestrator (e.g. `new-feature`), you
receive `txn_id` via args and create the REQ as `draft`. Standalone, the
REQ is created active directly.

## Requirement to evaluate

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

## Step 1 — Load context

1. **Existing REQs (check duplicates — the server also runs `check_duplicates`
   automatically on create):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<requirement>, entity_type:"REQ", project_id:<PROJ> })`

2. **ROAD (alignment / conflicts):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ROAD", project_id:<PROJ> })`

3. **CMPs (affected components):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROJ> })`

4. **IFs (interface impact):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<area>, entity_type:"IF", project_id:<PROJ> })`

5. **ADRs (compatibility):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"ADR", project_id:<PROJ> })`

## Step 2 — Analysis

1. **Duplicates**: does an existing REQ cover this? If yes → propose an update.
2. **ROAD alignment**: does it derive from a ROAD? does it conflict?
3. **Components**: which CMPs are affected.
4. **Interfaces**: are IF changes required?
5. **ADR compliance**: does it contradict anything?
6. **Type**: functional | non-functional | security | performance | ux.

## Step 3 — Create formal REQ

If new and approved by the user:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "REQ",
  project_id: "<PROJ>",
  title: "REQ-<PROJ>-<auto>: <title>",
  content: <markdown with description, acceptance criteria, scope, ...>,
  tags: ["type:<type>", "priority:<level>"],
  relations: [
    { type: "derives_from", target: "ROAD-<PROJ>-<NN>" },  // if applicable
    { type: "affects",      target: "CMP-<PROJ>-<COMP>" }
  ],
  txn_id: "<if received from orchestrator>",
  updated_by: "skill:requirements-analyst"
})
```

The server:
- Auto-generates the `entity_id` (`REQ-<PROJ>-<NNN>`).
- Warns via `warnings.duplicates` if similarity > 0.85.
- Generates the embedding.

## Output

```
## Requirement Analysis

### Kvendra verifications
- Duplicate: NO / Similar to REQ-<PROJ>-<NN> (score: 0.XX)
- ROAD: aligned with ROAD-<PROJ>-<NN> / conflict / unrelated
- ADR: compatible / contradicts ADR-<PROJ>-<NN>
- Affected components: [list]
- Impacted interfaces: [list]

### Proposed REQ
- ID: REQ-<PROJ>-<NNN> (auto-generated by server)
- Type: <type>
- Priority: <level>
- Components: [list]
- Acceptance criteria: [list]
- Relations: derives_from → ROAD-<PROJ>-<NN> (if applicable)

### Alarms
- [alarm 1 if any]

### Questions for the user
- [question 1 if any]
```
