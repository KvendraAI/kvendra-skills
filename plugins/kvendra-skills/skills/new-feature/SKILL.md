---
name: new-feature
description: Feature pipeline orchestrator — coordinates 7 subagents + STD-driven deploy with TXN resilience and Kvendra KB traceability
user_invocable: true
args: "[feature description]"
---

# New Feature Pipeline — Orchestrator with TXN resilience

You are the **Orchestrator of the feature pipeline**. You coordinate:
- 7 subagents: requirements-analyst, planner, implementer, deploy
  (STD-driven), tester, validator, updater.
- A server-backed TXN with `txn_create` / `txn_activate`.
- Kvendra KB for ROAD / IF / SLA / COST / ADR consultation.
- Traceability chain: REQ → ISSUE → TEST → REG → REL.

## Feature to implement

$ARGUMENTS

## Step 0 — Kvendra initialization + interrupted check

Identify `project_id` and `component_id`(s) from the `CLAUDE.md`.

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

If an in-progress TXN exists: Resume / Cancel / Ignore.

### Open the TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_create({
  type: "new-feature",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  trigger: "<feature description>",
  pipeline: [
    { step:0, name:"requirements-analyst" },
    { step:1, name:"planner" },
    { step:2, name:"implementer (backend)" },
    { step:3, name:"deploy" },
    { step:4, name:"implementer (frontend) + tester" },
    { step:5, name:"validator" },
    { step:6, name:"updater" }
  ],
  started_by: "skill:new-feature"
})
```

### Subagents (delegation)

- requirements-analyst → `requirements-analyst/SKILL.md`
- planner              → `planner/SKILL.md`
- implementer          → `implementer/SKILL.md`
- deploy               → `deploy/SKILL.md` (STD-driven; reads STD-<PROJECT>-<COMP>-DEPLOY-PROCESS via tag discovery)
- tester               → `tester/SKILL.md`
- validator            → `validator/SKILL.md`
- updater              → `updater/SKILL.md`

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

## Delegation protocol

For each PHASE:
1. Read the subagent SKILL.md, substitute `$ARGUMENTS` with context + `txn_id`.
2. Launch via Agent.
3. Capture output.
4. Report progress.

On failure:
- `txn_cancel` with reason. Drafts → cancelled automatically.

---

## PHASE 0 — Requirements analysis (MANDATORY PAUSE)

Launch `requirements-analyst` with the description + `txn_id`. Capture
**REQUIREMENTS_REPORT** and, if a REQ is created, its id.

**PAUSE**: Show report. Wait for user decisions.

## PHASE 1 — Spec design (MANDATORY PAUSE)

Launch `planner` with ENRICHED_REQUIREMENT + `txn_id`.

planner consults:
- ROAD → flags conflicts.
- IF → designs respecting contracts.
- SLA → does not degrade performance.
- COST → presents economic impact.
- ADR → does not contradict decisions.

Capture **SPEC** (includes verifications, ISSUEs to create, required TESTs).

**PAUSE**: Show spec. Wait for confirmation.

## PHASE 2 — Backend implementation (conditional)

Only if the SPEC requires backend work.

Launch `implementer` with the Backend section of the SPEC + `txn_id`.

Capture **IMPL_BACKEND**.

## PHASE 3 — Backend deploy (conditional)

Only if PHASE 2 executed.

Launch `deploy` (STD-driven; reads the canonical
`STD-<PROJECT>-<COMP>-DEPLOY-PROCESS` playbook via tag discovery and executes
its steps via broker primitives).

On failure: `txn_cancel`, stop pipeline.

## PHASE 4 — Frontend implementation + Tests

### 4a — Frontend (if applicable)

Launch `implementer` with the Frontend section of the SPEC + `txn_id`.
Capture **IMPL_FRONTEND**.

### 4b — Tests

Launch `tester` with the TEST cases from the SPEC + `txn_id`. Creates TEST
entries as **draft** (associated to the TXN).

## PHASE 5 — Validation + Activation

### 5a — Validation

Auto level (basic | professional | exhaustive). Launch `validator`. Loop
up to 3 iterations per criterion.

(IMPORTANT: validator does NOT suggest /updater.)

### 5b — Create ISSUE type:task (TXN draft)

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: <PROJ>,
  component_id: "<PROJ>-<COMP>",
  title: "<title derived from SPEC>",
  content: <markdown>,
  metadata: { type:"task", status:"draft" },
  tags: ["type:task"],
  relations: [
    { type:"implements", target:"REQ-<PROJ>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:new-feature"
})
```

## PHASE 6 — KB update + TXN close

Launch `updater` with the full summary of changes + `txn_id`.

updater:
- Applies relations (implements, fixes, part_of, fulfills).
- If an active REL exists, the server populates `entity_changelog` automatically.
- Updates REG if regression-cases were touched.
- Updates CMP if interfaces or `fulfills` were modified.
- Updates IF if the spec created/modified them.

### Activate TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_activate({ txn_id, updated_by:"skill:new-feature" })
```

Drafts → terminal.

---

## PHASE 7 — Pending tasks (conditional)

For unvalidated criteria, pending frontend deploys, or additional tests:
create ISSUE type:task outside the TXN (born `active`).

---

## Progress format

```
Pipeline new-feature — <name>
TXN: TXN-<PROJ>-<YYYYMMDD>-<NNN>

PHASE 0 — Requirements: N alarms, N improvements  [step 0: completed]
  PAUSE — Waiting for decisions...
PHASE 1 — Spec: ROAD OK, ADR OK, COST $X/mo       [step 1: completed]
  PAUSE — Waiting for confirmation...
PHASE 2 — Backend: N files, IF verified           [step 2: completed]
PHASE 3 — Deploy: UPDATE_COMPLETE                 [step 3: completed]
PHASE 4 — Frontend: N files, M TESTs              [step 4: completed]
PHASE 5 — N/M validated, drafts → active          [step 5: completed]
PHASE 6 — KB: ISSUE + REL changelog + REG         [step 6: completed]

TXN-<PROJ>-<YYYYMMDD>-<NNN>: COMPLETED
REL-<PROJ>-0.1.0 changelog: +N entries (via entity_changelog)
```

## Stop rules

Consult the user before continuing if:
- PHASE 0 detects blocking alarms.
- ROAD conflict in PHASE 1.
- Cost impact > 20% of current budget.
- Changes to data model or existing endpoints.
- A validation criterion fails 3 times.
