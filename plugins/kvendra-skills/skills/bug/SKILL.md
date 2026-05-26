---
name: bug
description: Bug-testing pipeline orchestrator — coordinates 6 subagents with TXN, draft/active entities, and Kvendra KB traceability
user_invocable: true
args: "[area or functionality to test]"
---

# Bug Pipeline — Orchestrator with TXN resilience

You are the **Orchestrator of the bug-testing pipeline**. You coordinate 6
subagents (functional-expert, tester, analyzer, implementer, validator,
updater) with:
- **Server-backed TXN**: `txn_create` + `txn_activate` / `txn_cancel`.
- **Draft → Active** automatic on TXN activation.
- **Kvendra KB**: structured traceability via the 12 entity tools.

## Target to test

$ARGUMENTS

## Step 0 — Kvendra initialization + interrupted check

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

### Interrupted check

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted({ project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })
```

If an in-progress TXN exists:
- Show the user: txn_id, type, started_at, pipeline (status per step).
- Options: **Resume** / **Cancel** / **Ignore**.
  - Resume: read the TXN, infer the last completed step, continue.
  - Cancel: `txn_cancel` with reason.
  - Ignore: leave the TXN alive (not recommended — would conflict when
    opening another for the same scope).

### Open the TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_create({
  type: "bug",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  trigger: "<target to test>",
  pipeline: [
    { step:1, name:"functional-expert" },
    { step:2, name:"tester" },
    { step:3, name:"analyzer" },
    { step:4, name:"implementer" },
    { step:5, name:"validator" },
    { step:6, name:"updater" }
  ],
  started_by: "skill:bug"
})
```

Capture `txn_id`.

### Subagents (delegation)

Directory: `~/.claude/plugins/marketplaces/kvendra-marketplace/plugins/kvendra-skills/skills/`
- functional-expert → `functional-expert/SKILL.md`
- tester            → `tester/SKILL.md`
- analyzer          → `analyzer/SKILL.md`
- implementer       → `implementer/SKILL.md`
- validator         → `validator/SKILL.md`
- updater           → `updater/SKILL.md`

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Delegation protocol

For each PHASE:
1. Read the subagent's `SKILL.md`.
2. Substitute `$ARGUMENTS` with context + `txn_id`.
3. Launch via Agent.
4. Capture output.
5. Report progress to the user.

If a phase fails:
- `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel({ txn_id, reason, updated_by })`.
- Drafts → cancelled automatically.
- Notify the user.

---

## PHASE 1 — Test plan

Launch `functional-expert` with the target. Capture **TEST_PLAN**.

If 0 flows to test → `txn_activate` (degenerate case, no drafts).

## PHASE 2 — Execution and TEST entry creation

Launch `tester` with the TEST_PLAN + `txn_id`. Creates TEST entries as
**draft** (associated to the TXN).

Capture **BUG_REPORT** + list of created TEST IDs.

If 0 bugs → jump to PHASE 5b (no new ISSUE), then activate the TXN.

## PHASE 3 — Per-bug analysis (parallel)

For each bug, launch an independent `analyzer` in parallel. Consolidate
into **BUG_ANALYSIS**.

## PHASE 4 — Fix

Launch `implementer` with BUG_ANALYSIS + `txn_id`. The skill verifies
naming against IF and GLO. Capture **FIX_SUMMARY**.

## PHASE 5 — Validation loop

### 5a — Validation

Auto level (basic / professional / exhaustive) based on severity.

Launch `validator`. Loop up to 3 iterations per bug. If validation fails,
re-iterate with analyzer + implementer.

Capture **VALIDATED_BUGS** and **BLOCKED_BUGS**.

(IMPORTANT: validator does NOT suggest /updater — that step is decided by
THIS orchestrator.)

### 5b — Create one ISSUE per confirmed bug (drafts in the TXN)

For each confirmed bug:
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"ISSUE", ..., txn_id })`. The server assigns the auto id.

## PHASE 6 — KB update + TXN activation

Launch `updater` with VALIDATED_BUGS + FIX_SUMMARY + list of TEST IDs.

updater applies:
- Relations: ISSUE→implements REQ, TEST→fixes ISSUE, IF/CMP→part_of, etc.
- CMP.fulfills update if it's a feature.
- REG.tests update if regression-cases were created.

### Activate TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_activate({ txn_id, updated_by:"skill:bug" })
```

Drafts → terminal automatically. The server populates `entity_changelog`
for every activated entity that has an active REL.

---

## PHASE 7 — Create pending tasks (conditional)

If there are blocked bugs (3 failed iterations) or pending work:
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"ISSUE", ... })` with `status:open` or `status:blocked`. NOTE: these ISSUEs are
created outside the TXN because the pipeline TXN was already activated.
Creating them NOW means they are born `active`.

---

## Progress format

```
Pipeline bug started — Target: <target>
TXN: TXN-<PROJ>-<YYYYMMDD>-<NNN>

PHASE 1 — Plan: N flows                       [step 1: completed]
PHASE 2 — N bugs, M TEST entries (draft)       [step 2: completed]
PHASE 3 — N analyses (parallel)                [step 3: completed]
PHASE 4 — N fixes (IF/GLO verified)            [step 4: completed]
PHASE 5 — N/M validated, K blocked             [step 5: completed]
         TXN drafts → active
PHASE 6 — KB updated                           [step 6: completed]

TXN-<PROJ>-<YYYYMMDD>-<NNN>: COMPLETED
```

## Stop rules

Consult the user before continuing if:
- A change requires infrastructure work (e.g. template.yaml).
- The fix affects multiple critical components.
- A previously-unforeseen new bug surfaces during validation.
