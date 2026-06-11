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

## Step 0.5 — Pipeline-autonomy policy (single query)

Discover the project's pipeline-autonomy policy with ONE tag query:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "STD",
  project_id: <PROJ>,
  tags_all: ["scope:pipeline-autonomy"],
  status: "active",
  order_by: "updated_at_desc",
  limit: 10
})
```

**0 results** → use the defaults: `gates.new-feature: dual`,
`parallelize.frontend_with_deploy: false`, `context_pack: false`,
`sla_report: false`, validator level `auto`. This is the byte-identical
legacy path — no error, no retry.

**1+ results** → take the PROJ-level row plus the optional CMP-scoped row
(when one matches the affected component) and merge per key with
most-conservative-wins: `dual` beats `single` beats `none`, `false`
beats `true` in `parallelize.*` and `backlog_chaining`, and the heavier
validator level wins. An unknown `gates.*` value resolves to `dual`
(most conservative — forward compatibility).

Schema v2 payloads (`schema_version: 2`) add: `gates.new-feature: none`,
`gates.bug: none`, `autonomy_log`, `backlog_chaining`. A v1 payload is
consumed unchanged with v1 semantics — absent v2 keys default to
`autonomy_log: true`, `backlog_chaining: false`.

Report the resolved mode in the progress header:

```
autonomy: zero-gate | single-gate | dual-gate (policy: <STD-id> v<N> | defaults)
```

### Zero-gate mode (gates.new-feature: none — schema v2 only)

With `gates.new-feature: none` the pipeline runs with ZERO mandatory
conversation pauses. The consolidated gate is replaced by an **AUTONOMY
GATE RECORD**: evaluate exactly the same PROCEED/REVIEW criteria as the
single-gate recommendation; on PROCEED continue silently; on REVIEW
auto-resolve each signal with the most conservative viable option and
log it instead of pausing.

**Hard floor (never configurable — pauses even in zero-gate mode):**
1. The pipeline would need an op on the deploy-policy no-go list
   (production deploy, real registry publish, vault/allowlist mutation,
   destructive git/AWS op) → show the consolidated report and wait.
2. Estimated recurring cost impact > 20% of the current budget.
3. A security-tagged change fails exhaustive validation.

This policy governs conversation gates ONLY (NFR-SAFE-1): broker
enforcement, the STD no-go list and hook fail-closed paths stay out of
its reach in every mode.

**AUTONOMY_LOG** (when `autonomy_log: true`, the v2 default): record
every auto-resolved signal as one line —
`<signal> → <resolution> — <one-line rationale>` — show the lines in
the progress output and persist them verbatim into the PHASE 5b ISSUE
content under `## Autonomy log (zero-gate)`. If the TXN is cancelled
before PHASE 5b, persist the log in the `txn_cancel` reason instead.

### CONTEXT_PACK (only when the resolved policy has context_pack: true)

Build one CONTEXT_PACK and prepend it to EVERY subagent launch. The pack
is a fenced block containing: `loaded_at` (ISO8601) + `txn_id` + digests
of PRJ / CMP (including `workspace_subdir`) / IF field tables verbatim /
GLO canonical terms verbatim / the resolved STD values, plus a `Sources:`
line of `entity_id@version` pairs. Introduce it with this exact sentence:

"A CONTEXT_PACK is included below. Treat it as your pre-loaded KB context:
skip your context-loading queries when the pack covers them; re-query only
what is missing or suspect — the pack is an optimization, not a cage."

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

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Delegation protocol

For each PHASE:
1. Read the subagent SKILL.md, substitute `$ARGUMENTS` with context + `txn_id`.
2. Launch via Agent.
3. Capture output.
4. Report progress.

On failure:
- `txn_cancel` with reason. Drafts → cancelled automatically.

---

## PHASE 0 — Requirements analysis

Launch `requirements-analyst` with the description + `txn_id` (+ the
CONTEXT_PACK when enabled). Capture **REQUIREMENTS_REPORT** and, if a REQ
is created, its id.

**Early-escalation check (dual and single modes)**: if the report
contains blocking alarms, a ROAD conflict, cost impact > 20% of current
budget, or data-model / existing-endpoint changes → PAUSE NOW (do NOT
launch the planner), show the report and wait for user decisions —
identical to today's behaviour.

**Gate mode `dual` (default — no policy STD, or `gates.new-feature: dual`)**:
**PAUSE**: Show report. Wait for user decisions.

**Gate mode `single`**: do NOT pause here. Proceed to PHASE 1 and present
both reports at the consolidated gate.

**Gate mode `none`**: do NOT pause. Run the same early-escalation
evaluation; only hard-floor signals pause (see Zero-gate mode). Every
other signal is auto-resolved with the most conservative viable option
and logged to the AUTONOMY_LOG before launching the planner.

## PHASE 1 — Spec design

Launch `planner` with ENRICHED_REQUIREMENT + `txn_id` (+ the CONTEXT_PACK
when enabled).

planner consults:
- ROAD → flags conflicts.
- IF → designs respecting contracts.
- SLA → does not degrade performance.
- COST → presents economic impact.
- ADR → does not contradict decisions.

Capture **SPEC** (includes verifications, ISSUEs to create, required
TESTs, and the `frontend_deploy_independent` flag from its "Execution
constraints" section).

**Gate mode `dual`**: **PAUSE**: Show spec. Wait for confirmation.

**Gate mode `single` — CONSOLIDATED GATE (the only mandatory pause)**:
present, in this exact order:
1. REQUIREMENTS_REPORT (alarms and improvements FIRST).
2. SPEC (verifications, scope, implementation plan, TESTs).
3. Recommendation LAST — PROCEED only if ALL hold: zero blocking alarms,
   ROAD OK, ADR OK (no new ADR required), cost impact <= 20%, no
   data-model or existing-endpoint changes; otherwise REVIEW listing the
   exact signals.

**PAUSE**: wait for one user decision covering REQ + SPEC together. If
the REQ is rejected, discard the SPEC (accepted trade-off) and
`txn_cancel`.

**Gate mode `none` — AUTONOMY GATE RECORD (no pause)**: build the same
three-part summary internally and evaluate the same criteria. On
PROCEED: continue without pausing. On REVIEW: auto-resolve each signal
(most conservative viable option) and log it — unless a hard-floor
signal fires, in which case show the consolidated gate and wait exactly
as in single mode. Emit one progress line:

```
AUTONOMY GATE — auto-approved | auto-resolved: N signals | HARD FLOOR pause: <reason>
```

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

**Parallel mode**: when the resolved policy has
`parallelize.frontend_with_deploy: true` AND the SPEC declares
`frontend_deploy_independent: yes`, launch `deploy` and the frontend
`implementer` (PHASE 4a) in ONE single message with two Agent calls. If
either condition is absent → serial (current behaviour). On deploy
failure in parallel mode: `txn_cancel` as usual — the frontend output is
kept locally but no KB drafts survive.

## PHASE 4 — Frontend implementation + Tests

### 4a — Frontend (if applicable)

(Skip if already launched in parallel with PHASE 3 — consume its captured
output instead.)

Launch `implementer` with the Frontend section of the SPEC + `txn_id`.
Capture **IMPL_FRONTEND**.

### 4b — Tests

Launch `tester` with the TEST cases from the SPEC + `txn_id`. Creates TEST
entries as **draft** (associated to the TXN).

## PHASE 5 — Validation + Activation

### 5a — Validation

Resolve the validator level with this precedence: explicit user override >
policy `validator_level_by_type` keyed by the change type from the
REQ/ISSUE type tags (hotfix → basic, feature → professional, security →
exhaustive) > `validator_level_default` (`auto` = current heuristic).
Pass the resolved level in the validator args. Launch `validator`. Loop
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

In zero-gate mode with a non-empty AUTONOMY_LOG, append the log verbatim
to the ISSUE content under `## Autonomy log (zero-gate)`.

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

### SLA report (non-blocking — only when the policy has sla_report: true)

After `txn_activate`, compute the wall-clock duration = activation time
minus TXN creation time. Query the pipeline SLAs once:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "SLA",
  project_id: <PROJ>,
  tags_all: ["scope:pipeline"]
})
```

If 0 results and <PROJ> is not KVD, retry once with `project_id: "KVD"`.
Append one line to the progress output:

```
SLA: <duration> vs target <N> min — OK | EXCEEDED (informational)
```

Still 0 results, or query error → skip silently.

### Backlog chaining (zero-gate + backlog_chaining: true only)

After `txn_activate` (and the optional SLA line), when the resolved
policy has `gates.new-feature: none` AND `backlog_chaining: true` AND
the invocation declared a backlog scope (e.g. "work through milestone
M2.5", a ROAD id, or an explicit ISSUE/REQ list in $ARGUMENTS): query
the next open item —

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "ISSUE",   // and/or REQ, per the declared scope
  project_id: <PROJ>,
  tags_any: ["status:open"],
  tags_all: [<declared milestone/scope tags>],
  order_by: "updated_at_desc"
})
```

— announce it in one line and start the next pipeline iteration from
Step 0.5 (fresh policy read, fresh TXN). Stop chaining when: no items
remain in scope, a hard-floor pause fires, two consecutive items end
blocked, or the session/loop budget is exhausted. Pacing belongs to the
harness (`/loop` or wake-up scheduling), not to this skill: never
busy-wait between items, and let a recurring harness loop re-invoke the
pipeline when the scope outlives the session.

---

## PHASE 7 — Pending tasks (conditional)

For unvalidated criteria, pending frontend deploys, or additional tests:
create ISSUE type:task outside the TXN (born `active`).

---

## Progress format

```
Pipeline new-feature — <name>
TXN: TXN-<PROJ>-<YYYYMMDD>-<NNN>
autonomy: <mode> (policy: <source>)

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
SLA: <duration> vs target <N> min — OK (optional, sla_report: true only)
```

The two PAUSE lines appear only in dual mode. In single mode a single
`CONSOLIDATED GATE — Waiting for decision...` line (after PHASE 1)
replaces them. In zero-gate mode a single `AUTONOMY GATE — ...` line
(after PHASE 1) replaces them, plus one line per AUTONOMY_LOG entry.
The final `SLA:` line is optional (only when the policy has
`sla_report: true`).

## Stop rules

**Dual / single mode** — consult the user before continuing if:
- PHASE 0 detects blocking alarms.
- ROAD conflict in PHASE 1.
- Cost impact > 20% of current budget.
- Changes to data model or existing endpoints.
- A validation criterion fails 3 times.

In single-gate mode, the first four rules are evaluated at the end of
PHASE 0 and fire BEFORE the planner launches (early escalation).

**Zero-gate mode** — only the hard floor consults the user (no-go-list
op required, recurring cost impact > 20%, security-tagged change failing
exhaustive validation). Every other signal auto-resolves and logs. A
validation criterion failing 3 times does not consult: record it as a
blocked ISSUE (PHASE 7) and continue when it does not block the SPEC's
core acceptance criteria; `txn_cancel` (persisting the AUTONOMY_LOG in
the reason) when it does.
