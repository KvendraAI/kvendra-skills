---
name: tester
description: Tester — runs tests and persists results as TEST entries in the Kvendra KB with preconditions, process, validations and evidence
user_invocable: false
args: "[test plan, objective, or REQ/ISSUE to test]"
---

# Tester — Run tests with Kvendra KB persistence

You act as an **Automated Tester**. You run tests and persist the results
as TEST entries in the Kvendra KB (structure: preconditions, process,
postconditions, validations, data, evidence). Subagent — receives `txn_id`
via args; does NOT open a TXN; the created TEST entries are born `draft`.

## Test plan / Objective

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

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Step 1 — Load Kvendra context

1. **CMP of the component:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROJ>, tags_all:["CMP-<PROJ>-<COMP>"] })`

2. **IFs (to verify naming in tests):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"IF", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`

3. **REQ to validate** (if indicated):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REQ-<PROJ>-<NN>" })`

4. **ISSUE bug we cover** (if it's a regression-case):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"ISSUE-<PROJ>-<COMP>-<NN>" })`

5. **Existing tests** (to avoid duplicates — the server warns via
   `check_duplicates` automatically, but inspection is also useful):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TEST", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`

6. **SLA targets** (for performance tests):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"SLA", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`

## Step 2 — Design the TEST

Determine the type: `functional | integration | regression-case | smoke | performance | ux-validation`.

Design the structure:

### Preconditions
- Environment (ENV ID), data, prior state.

### Process (steps)
- Exact action, expected outcome, timeout, on_failure.

### Postconditions
- Expected state, cleanup.

### Validations (V1, V2, …)
- Description, type (assertion / format-check / performance / naming-check),
  severity (critical / warning), reference (IF / SLA).

### Test data
- Dataset, variants (happy_path / error_case / edge_case), parameterisable.

### Result criteria
- Pass / Warning / Fail / Blocked.

## Step 3 — Execute the test

1. Verify preconditions.
2. Run each step in order.
3. Capture evidence (logs, screenshots, responses).
4. Evaluate each validation.
5. Record the result per step.

## Step 4 — Persist TEST in the Kvendra KB

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "TEST",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  title: "TEST-<PROJ>-<COMP>-<auto>: <descriptive title>",
  content: <full markdown: preconditions / process / postconditions /
            validations / result / evidence>,
  tags: ["type:<type>", "comp:<COMP>"],
  relations: [
    { type: "fulfills", target: "REQ-<PROJ>-<NN>" },
    { type: "fixes",    target: "ISSUE-<PROJ>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id received from orchestrator>",
  updated_by: "skill:tester"
})
```

The server:
- Auto-generates the `entity_id` (`TEST-<PROJ>-<COMP>-<NNN>`).
- Forces `status='draft'` because of the TXN.
- Generates the embedding (TEST has embedding by default).

## Step 5 — Output

```
### EXECUTIVE SUMMARY
- Tests designed: N
- Tests executed: N
- Pass: N / Warning: N / Fail: N / Blocked: N

### TESTS CREATED IN KVENDRA (DRAFT)
**TEST-<PROJ>-<COMP>-<NNN>: [Title]**
- Type: <type>
- Result: PASS | WARNING | FAIL | BLOCKED
- Validations: V1 OK, V2 OK, V3 WARN (detail)
- Relations: fulfills → REQ-..., fixes → ISSUE-...
- KB entry: created (draft, txn_id=<txn>)

### BUGS FOUND
**ISSUE-NEW (type: bug): [Title]**
- Severity: critical | major | minor
- Found in: TEST-<PROJ>-<COMP>-<NNN>
- Steps to reproduce: ...
- Actual vs expected behavior
- Evidence: ...

### NOTES FOR THE UPDATER / ORCHESTRATOR
- Tests created: [list of IDs]
- Bugs found: [list]
- REGs that should include these tests: [suggestion]
- IFs verified: [list]
```
