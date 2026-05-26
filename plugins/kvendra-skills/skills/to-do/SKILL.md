---
name: to-do
description: Task manager — creates and manages ISSUE entities in the Kvendra KB with canonical naming, relations and traceability
user_invocable: true
args: "[action: create|update|close|list] [arguments]"
---

# To-Do — ISSUE management in the Kvendra KB

You manage work items (ISSUE) in the Kvendra KB: bugs, tasks and incidents
with standardised naming, relations and REQ/REL traceability.

## Action

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` and `component_id` from the `CLAUDE.md`.

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

## Actions

### CREATE — Create an ISSUE

1. Determine `type`: `bug | task | incident`.
2. Determine the component (or cross-component).
3. **Do not generate the ID manually** — the server emits it.
4. Build `content` with fields per type (reference: schema in the
   project's docs).
5. Determine relations: `implements → REQ`, `fixes → ISSUE`, `blocks → REL`.
6. Call:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",   // optional
  title: "<title>",
  content: <markdown>,
  metadata: { severity, priority },
  tags: ["type:<type>", "priority:<prio>"],
  relations: [
    { type:"implements", target:"REQ-<PROJ>-<NN>" },
    { type:"blocks",     target:"REL-<PROJ>-<VER>" }
  ],
  updated_by: "skill:to-do"
})
```

### UPDATE — Update an ISSUE

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
  entity_id: "ISSUE-<PROJ>-<COMP>-<NN>",
  content: <optional>,
  tags_add: ["status:in-progress"],     // if changing state
  tags_remove: ["status:new"],
  change_summary: "Assigned to @user, status in-progress",
  updated_by: "skill:to-do"
})
```

If there is an active REL, the server populates `entity_changelog` automatically.

### CLOSE — Close an ISSUE

1. Read ISSUE: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id })`.
2. Change status per type:
   - bug: `closed`
   - task: `done`
   - incident: `postmortem-done`
3. If bug: verify there is a regression-case TEST that covers it
   (`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TEST", tags_all:["type:regression-case", "ISSUE-..."] })`).
4. `entity_update` with updated tags and `change_summary`.

### LIST — List ISSUEs

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  component_id: "<if filtering>",
  tags_all: ["type:<type>"],     // optional
  status: "<status>",            // optional
  order_by: "updated_at_desc"
})
```

## Output

### For CREATE:
```
ISSUE created: ISSUE-<PROJ>-<COMP>-<NNN> (auto-generated)
- Type: bug | task | incident
- Priority: critical | high | medium | low
- Component: <COMP>
- Relations: implements REQ-..., blocks REL-...
```

### For LIST:
```
| ID | Type | Priority | Status | Component | Title |
|----|------|----------|--------|-----------|-------|
| ISSUE-<PROJ>-<COMP>-001 | bug | high | new | <COMP> | Timeout in callback |
| ISSUE-<PROJ>-042 | task | medium | in-progress | (cross) | Update docs |
```
