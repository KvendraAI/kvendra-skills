---
name: interface-validator
description: Interface validator — verifies field naming in code against IF and GLO entities from the Kvendra KB
user_invocable: false
args: "[component to validate or 'all' for all components]"
---

# Interface Validator — Verify naming against the Kvendra KB

You scan a component's source code and verify that the field names used
match the interface (IF) contracts and the glossary (GLO) defined in the
Kvendra KB. You detect naming discrepancies that cause integration bugs.
Subagent — does NOT open a TXN.

## Component to validate

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

## Step 1 — Load reference contracts

1. **Project-wide GLO (source of truth for naming):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"GLO", project_id:<PROJ>, tags_all:["domain-terms"] })`
   → each term with its canonical forms (camelCase, snake_case) and never_use list.

2. **Component code table (if a GLO with component-codes exists):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"GLO", project_id:<PROJ>, tags_all:["component-codes"] })`

3. **CMP for the component (interfaces_defined / interfaces_consumed):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROJ>, tags_all:["CMP-<PROJ>-<COMP>"] })`

4. **Defined and consumed IFs:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"IF", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`
   For each IF consumed from another component, `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"IF-<...>" })`.

## Step 2 — Scan source code

For the component directory (from CMP.implementation_paths or GLO):

1. **Search for `never_use` terms from the glossary** in the code (Grep).
   - Match → VIOLATION
2. **Verify canonical naming per IF.field**:
   - Python: snake_case (e.g. `route_id`).
   - TypeScript: camelCase (e.g. `routeId`).
   - Wrong match → VIOLATION
3. **Look for suspicious hardcoded field names**:
   - String literals (e.g. `"rutaId"`, `"session_ID"`).
   - Compare against GLO and IF.

## Step 3 — Classify results

- **VIOLATION**: incorrect name that MUST be fixed.
- **WARNING**: possible inconsistency to review.
- **INFO**: observation about naming with no error.

## Required output

```
## Interface Validation Report
Component: CMP-<PROJ>-<COMP>
Date: <date>

### Summary
- Files scanned: N
- Violations: N
- Warnings: N
- Info: N

### VIOLATIONS

**V-001: <file>:<line>**
- Found: `rutaId`
- Canonical: `routeId` (camelCase) / `route_id` (snake_case)
- Reference: GLO-<PROJ>-001 (route), IF-<PROJ>-<COMP>-001
- Impact: field will not be recognised by consuming adapter

### WARNINGS
... (same format)

### VERIFIED INTERFACES
| IF ID | Fields verified | Violations | Status |
|-------|-----------------|------------|--------|
| IF-<PROJ>-<COMP>-001 | 7/7 | 0 | OK |
| IF-<PROJ>-<COMP>-002 | 12/12 | 1 | FAIL |

### VERIFIED GLO TERMS
| Term | Canonical forms | never_use violations | Status |
|------|-----------------|----------------------|--------|
| route | routeId/route_id | 0 | OK |

### RECOMMENDATIONS
1. Fix V-001 ...
```

---
Return the report. Do NOT suggest calling other skills — the orchestrator
or the user decides whether to invoke `implementer` to apply fixes.
