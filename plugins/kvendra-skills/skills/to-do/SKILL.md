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
- **Guarded update (CAS)** — every `entity_update` is read-modify-write: capture the `version` returned by your preceding `entity_get`/`entity_query` and pass it as `expected_version`. On a `409 VERSION_CONFLICT` (the body carries `current_version` + `intervening_changes[]`) re-read the entity, re-apply your change on top of the intervening changes, then retry with the fresh `version`; bound retries to 3 and, if it still conflicts, stop and surface the conflict — never blind-overwrite. The engine ignores the lock when `expected_version` is absent, so omitting it silently reverts to last-write-wins.
- Orchestrator → `txn_create` before creating entities, close with
  `txn_activate` (success) or `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel(reason)` (failure).
  Subagent → receives `txn_id` via args and does NOT open/close the TXN.
- Before opening a TXN: `mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted(project_id, component_id?)`.
  If an in-progress TXN exists: Resume / Cancel / Ignore.
- Entity IDs are emitted by the server. Exception: `PRJ`/`CMP`/`REL` require `force_id`.
- If an error returns `error.help.topic`, call `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

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
