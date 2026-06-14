---
name: incident-manager
description: Incident manager — creates ISSUE type:incident with RCA and postmortem in the Kvendra KB, and generates derived RUN/REQ/PAT entities
user_invocable: true
args: "[incident description or 'postmortem' to close an existing one]"
---

# Incident Manager — Kvendra incident lifecycle

You manage operational incidents (outages, degradation, production errors).
You create an ISSUE `type:incident` with impact, duration, RCA and postmortem.
You generate derived entities: RUN (new runbooks), REQ (improvements), PAT
(lessons).

Soft orchestrator — you open a TXN to group postmortem creations, but you do
not delegate to other subagents.

## Incident

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

## Step 1 — Search for similar incidents and runbooks

**IMPORTANT — embedding opt-in for incident ISSUEs**: so that semantic search
finds past incidents, this skill creates the ISSUE with `generate_embedding:
true`. This is the justified exception to the default opt-out.

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<problem description>, entity_type:"ISSUE", project_id:<PROJ>, limit:5 })
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<component or symptom>, entity_type:"RUN", project_id:<PROJ>, limit:3 })
```

If there is a RUN that covers this scenario → show it as a resolution guide.
If a similar past incident exists → show it for context.

## Step 2 — Open the incident TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted({ project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })
# if an in-progress TXN exists: Resume / Cancel / Ignore
```

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_create({
  type: "incident",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  trigger: "<short description>",
  pipeline: [
    { step: 1, name: "create-issue" },
    { step: 2, name: "lifecycle-updates" },
    { step: 3, name: "postmortem-derived-entities" }
  ],
  started_by: "skill:incident-manager"
})
```

Capture `txn_id`.

## Step 3 — Create the ISSUE type:incident

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  title: "<short description>",
  content: <markdown — see format below>,
  metadata: {
    type: "incident",
    severity: "critical|major|minor",
    detection_method: "alarm|user|monitoring",
    started_at: "<ISO>"
  },
  tags: ["type:incident", "severity:<...>"],
  txn_id: "<txn_id>",
  generate_embedding: true,
  updated_by: "skill:incident-manager"
})
```

### Content format

```markdown
# <title>

## Type: incident
## Status: detected → investigating → mitigating → resolved → postmortem-done
## Severity: critical | major | minor

## Impact
- What was affected: [services, users, features]
- Reach: [% users affected, lost volume]
- Duration: [from — to]

## Timeline
| Time | Event |
|------|-------|
| HH:MM | Detected: [how] |
| HH:MM | Investigating: [first actions] |
| HH:MM | Cause identified |
| HH:MM | Mitigation applied |
| HH:MM | Resolved |

## Detection
- Method: ...
- Time to detect: ...

## RCA (once identified)
[Root cause]

## Resolution
[What was done]

## Postmortem
### What went well
### What went wrong
### Derived actions
- RUN: ...
- REQ: ...
- PAT: ...
```

## Step 4 — Manage the lifecycle

As things progress, call `entity_update` with updated tags and `change_summary`:
1. `detected` → first state.
2. `investigating` → analyzing the cause.
3. `mitigating` → temporary solution applied.
4. `resolved` → service restored.
5. `postmortem-done` → RCA completed, derived entities created.

## Step 5 — Generate derived entities (at postmortem)

### 5a — RUN (if applicable)

If no runbook covers this scenario:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "RUN",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  title: "RUN-<PROJ>-<COMP>-<auto>: <description>",
  content: <resolution steps>,
  metadata: { origin_issue: "ISSUE-<PROJ>-<COMP>-<NN>" },
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

(RUN does not accept relations in the Kvendra KB — traceability lives in metadata.)

### 5b — REQ (if applicable)

If it reveals a need for improvement (alerting, monitoring, redundancy):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "REQ",
  project_id: "<PROJ>",
  title: "REQ-<PROJ>-<auto>: <improvement>",
  content: <description + acceptance criteria>,
  relations: [
    { type: "derives_from", target: "ISSUE-<PROJ>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

### 5c — PAT (if applicable)

If there is a generalisable lesson:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "PAT",
  project_id: "<PROJ>",
  title: "PAT-<PROJ>-<auto>: <lesson>",
  content: <markdown with the lesson + when to apply + example>,
  relations: [
    { type: "derives_from", target: "ISSUE-<PROJ>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

## Step 6 — Close the TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_activate({ txn_id, updated_by:"skill:incident-manager" })
```

Entities move from `draft` to `active` / `postmortem-done` as appropriate.

## Output

```
## Incident: ISSUE-<PROJ>-<COMP>-<NNN>
- Status: <status>
- Severity: <severity>
- Impact: <summary>
- Duration: <time>
- RCA: <summary>
- TXN: TXN-<PROJ>-<YYYYMMDD>-<NNN>

### Derived entities
- RUN-<PROJ>-<COMP>-<NNN>: runbook created
- REQ-<PROJ>-<NNN>: improvement proposed
- PAT-<PROJ>-<NNN>: lesson learned

### Kvendra updated
- ISSUE created (with embedding)
- TXN activated (drafts → active)
```
