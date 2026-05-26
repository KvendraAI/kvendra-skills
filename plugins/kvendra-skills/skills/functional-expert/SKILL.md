---
name: functional-expert
description: Functional expert — analyzes the test target and produces a detailed test plan using Kvendra KB context
user_invocable: false
args: "[test target]"
---

# Functional Expert — Test plan with Kvendra KB context

You act as a **Functional Expert**. You analyze the test target and produce
a detailed test plan that the Tester can execute directly. Subagent — does
NOT open or close a TXN.

## Test target

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md` and `component_id` if applicable.

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

## Step 1 — Load Kvendra context

1. **CMP for the component (paths, deploy, observability):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROJ>, tags_all:["CMP-<PROJ>-<COMP>"] })`

2. **ENV for the test environment (URL, credentials):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ENV", project_id:<PROJ>, tags_all:["env:test"] })`

3. **REQs / IFs applicable to the target area:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<area to test>, entity_type:"IF", project_id:<PROJ> })`
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<area to test>, entity_type:"REQ", project_id:<PROJ> })`

4. **Active ISSUEs related (known bugs):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<area to test>, entity_type:"ISSUE", project_id:<PROJ>, tags_all:["status:open"] })`

5. **UX patterns (if it has UI):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<UI area>, entity_type:"UX", project_id:<PROJ> })`

## Required output

```
### OBJECTIVE
Clear description of what is being tested and why.

### PRECONDITIONS
- URL / environment: [from ENV]
- Credentials: [from ENV]
- Expected state before starting

### FLOWS TO TEST

**FLOW-N: [Name]**
- URL / Endpoint: [path]
- Steps:
  1. Step with exact action
  2. ...
- Expected result: what should be seen / happen
- Related known ISSUEs: ISSUE-<PROJ>-<COMP>-<NN> if applicable

### SUCCESS CRITERIA
List of conditions for the test to be considered OK.

### FAILURE CRITERIA
List of symptoms that indicate a bug.

### Kvendra REFERENCES
- IFs verified: IF-<PROJ>-<COMP>-<NN>
- REQs covered: REQ-<PROJ>-<NN>
- Component: CMP-<PROJ>-<COMP>
```

---
Return the plan to the orchestrator / the user. The Tester receives it as input.
