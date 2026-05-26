---
name: regression
description: Regression suite runner — executes REG suites from the Kvendra KB, persists results as RUN entries, compares against SLAs and auto-generates ISSUE entities
user_invocable: true
args: "[component or REG suite to run]"
---

# Regression — Run regression suites from the Kvendra KB

You run regression suites (REG) defined in the Kvendra KB. You respect order
and dependencies between tests, persist results as RUN entries, compare
against SLA targets, and auto-generate ISSUE `type:bug` if any blocking
test fails.

## Component or suite

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` and `component_id` from the `CLAUDE.md` or args.

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

## Step 1 — Load the REG suite

1. **REG for the component:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REG", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`

   If a specific REG ID is provided:
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REG-<PROJ>-<COMP>-<SEQ>" })`

2. If no REG exists → report and ask whether to create one.

3. **Included tests (via `entity_related` or relations_outbound `part_of`):**
   For each `test_id` referenced: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id })`.

4. **SLA targets:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"SLA", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`

5. **Active REL (to associate results):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REL", project_id:<PROJ>, tags_all:["status:planning"] })`

## Step 2 — Verify preconditions

Verify that:
- Component is deployed to the target environment.
- Dependencies are reachable.
- Test data is available.

If any fails → result BLOCKED, do not execute.

## Step 3 — Execute tests in order

Rules:
1. **Order**: by each test's `order` field.
2. **Blocking**: if a test with `blocking: true` fails → suite fails.
3. **Parallel groups**: tests with the same `order` and `parallel_group` run in parallel.
4. **Smoke gate**: if test order:1 (smoke) fails, ABORT the suite.

For each test:
1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"TEST-..." })` — read the full entry.
2. Verify the test's preconditions.
3. Execute the steps as defined in the process.
4. Evaluate each validation.
5. Record result: pass | warning | fail | blocked.

## Step 4 — Evaluate global result

Apply the REG's `success_criteria`:
- **Pass**: all blocking tests pass.
- **Warning**: passes but some non-blocking failed.
- **Fail**: any blocking test fails.
- **Blocked**: smoke (order:1) fails.

Compare against SLA if available:
- `performance` tests → against SLA targets.
- If SLA is exceeded → warning (not fail, unless blocking).

## Step 5 — Persist RUN

Create a RUN entry (no embedding by default):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "RUN",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  title: "RUN-<PROJ>-<COMP>-<auto>: regression <REG-id> <date>",
  content: <markdown with per-test result, timings, evidence, SLA compliance>,
  metadata: {
    reg_id: "REG-<PROJ>-<COMP>-<SEQ>",
    started_at: "<ISO>",
    completed_at: "<ISO>",
    overall_result: "pass|warning|fail|blocked",
    test_results: [
      { test_id, result, duration_ms, validations: [...] }
    ],
    rel_id: "REL-<PROJ>-<VER>"   // if active
  },
  tags: ["result:<result>"],
  updated_by: "skill:regression"
})
```

(RUN does not accept relations in the Kvendra KB — `relations=no`. Traceability
goes in `metadata.reg_id` / `metadata.rel_id` and in tags.)

## Step 6 — Auto-generate an ISSUE if a blocking test failed

For each blocking test that failed:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  component_id: "<PROJ>-<COMP>",
  title: "ISSUE-<PROJ>-<COMP>-<auto>: Regression in <test_name>",
  content: <description with steps-to-reproduce from the TEST>,
  metadata: {
    type: "bug",
    severity: "major",
    priority: "high",
    found_in: "REG-<PROJ>-<COMP>-<SEQ>",
    test_id: "TEST-<PROJ>-<COMP>-<SEQ>"
  },
  tags: ["type:bug", "priority:high", "found-in:regression"],
  relations: [
    { type:"blocks", target:"REL-<PROJ>-<VER>" },     // if REL is active
    { type:"affects", target:"CMP-<PROJ>-<COMP>" }
  ],
  updated_by: "skill:regression"
})
```

## Step 7 — Output

```
## Regression suite — REG-<PROJ>-<COMP>-<SEQ>
Date: <ISO date>
Component: CMP-<PROJ>-<COMP>
Release: REL-<PROJ>-<VER> (if active)

### Global result: PASS / WARNING / FAIL / BLOCKED

### Duration: <total time>

### Executed tests
| # | Test ID | Type | Blocking | Result | Duration | Notes |
|---|---------|------|----------|--------|----------|-------|
| 1 | TEST-...-050 | smoke | yes | pass | 2s | |
| 2 | TEST-...-001 | functional | yes | pass | 45s | |
| 3 | TEST-...-020 | regression | yes | fail | 30s | V3 failed |
| 4 | TEST-...-060 | performance | no | warning | 120s | p95=33s, SLA=30s |

### SLA compliance
| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| latency_e2e | < 120s | 95s | OK |
| error_rate | < 5% | 0% | OK |

### Persisted RUN
- RUN-<PROJ>-<COMP>-<NNN> (overall_result: <result>)

### Auto-generated bugs
- ISSUE-<PROJ>-<COMP>-<NNN> (type: bug): Regression in TEST-...-020
  - Severity: major
  - Blocks: REL-<PROJ>-<VER>

### Release impact
- REL-<PROJ>-<VER>: BLOCKED by ISSUE-<PROJ>-<COMP>-<NNN>
  (or: gate OK — all blocking tests passed)
```
