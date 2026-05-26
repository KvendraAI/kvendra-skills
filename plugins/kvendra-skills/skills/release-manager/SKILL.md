---
name: release-manager
description: Release manager — creates, manages and closes REL entities with automatic changelog, regression gates and Kvendra KB traceability
user_invocable: true
args: "[action: create|status|add|gate-check|close] [arguments]"
---

# Release Manager — Kvendra release lifecycle

You manage the lifecycle of releases (REL): creation, attaching
ISSUEs/components, regression gates, automatic changelog (populated by the
server when an active REL exists), and closure.

## Action

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md`.

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

## Note on REL IDs — SemVer regex

REL uses **`force_id`** because its entity_id is SemVer, not sequential.

Regex format (project convention): `^REL-[A-Z]+(-[A-Z0-9]+)?-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$`

Valid examples:
- `REL-KVD-0.1.0` (project minor release)
- `REL-KVD-WEB-0.1.0` (component hotfix)
- `REL-KVD-SKILLS-1.0.0`
- `REL-KVD-CLI-1.0.0.1` (4 segments for hotfix)

Validate the format manually before creating. If it does not comply, the
server will reject with `INTEGRITY` + constraint `entities_entity_id_format`.

## Available actions

### CREATE — Create a new release

1. Determine the version (SemVer): read latest RELs to compute next:
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REL", project_id:<PROJ>, order_by:"updated_at_desc", limit:5 })`
2. Type: major | minor | patch | hotfix.
3. Component hotfix: `REL-<PROJ>-<COMP>-<VER>`.
4. Project release: `REL-<PROJ>-<VER>`.
5. Validate the id against the regex. If OK, create:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "REL",
  project_id: "<PROJ>",
  component_id: "<if component hotfix>",
  force_id: "REL-<PROJ>-<VER>",            // or REL-<PROJ>-<COMP>-<VER>
  title: "REL-<PROJ>-<VER>: <description>",
  content: <markdown with description, scope, target_date, regression_gate:pending>,
  version: "<VER>",
  tags: ["status:planning", "type:<minor|major|patch|hotfix>"],
  updated_by: "skill:release-manager"
})
```

### STATUS — View the state of a release

1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REL-<PROJ>-<VER>" })`.
2. List included ISSUEs: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ISSUE", project_id:<PROJ>, tags_all:["REL-<PROJ>-<VER>"] })`.
3. Verify regression gates: for each component with an ISSUE in the REL,
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REG", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`.
4. Show the changelog (returned automatically by `entity_get` — the server
   populates `entity_changelog` whenever there is an active REL).
5. Show blockers: ISSUEs with `relations_outbound: blocks → REL-<PROJ>-<VER>`.

### ADD — Add ISSUE/component to a release

1. Read the REL.
2. Verify the ISSUE exists and is in an appropriate status (`entity_get`).
3. Add the `part_of` relation from ISSUE to REL:
   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
     entity_id: "ISSUE-<PROJ>-<COMP>-<NN>",
     relations_add: [{ type:"part_of", target:"REL-<PROJ>-<VER>" }],
     tags_add: ["REL-<PROJ>-<VER>"],
     change_summary: "Added to REL-<PROJ>-<VER>",
     updated_by: "skill:release-manager"
   })
   ```
4. The server automatically records the entry in `entity_changelog`
   associated to the REL.

### GATE-CHECK — Verify regression gates

For each included component:
1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REG", project_id:<PROJ>, component_id:"<PROJ>-<COMP>" })`.
2. Verify the last run (in `metadata.execution_history` or read the latest
   associated RUN via `entity_related`).
3. Per-component result: PASS / BLOCKED (list bugs) / PENDING.
4. Global result: READY only if all gates are OK.

### CLOSE — Close the release

Prerequisites:
1. All regression gates PASS.
2. All included ISSUEs closed.

Process:
1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({ entity_id:"REL-<PROJ>-<VER>", status:"closed", change_summary:"Release closed", updated_by })`. (REL allows direct status change via update because it is NOT inside a TXN.)
2. **Freeze the changelog**: `entity_update` with `metadata.frozen: true`
   (the server honors `frozen` on `entity_changelog` to block later edits).
3. For each included ISSUE with status `done`/`closed`: verify it has a
   regression-case TEST.
4. Update ROAD if any item was completed: `entity_update` on the ROAD with `status:done`.
5. Set `metadata.deployed_date` on the REL.

## Output (varies per action)

### CREATE:
```
## Release created
- ID: REL-<PROJ>-<VER>
- Type: minor
- Status: planning
- Target: <date>
- Kvendra: created (force_id, validated against SemVer regex)
```

### STATUS:
```
## Release REL-<PROJ>-<VER>
- Status: <status>
- Target: <date>
- Included ISSUEs: N (M open, K closed)
- Regression gates: N/M pass

### Changelog
| Date | Author | Entity | Change | Trigger |
|------|--------|--------|--------|---------|

### Gates
| Component | REG | Last run | Result |
|-----------|-----|----------|--------|

### Blockers
- ISSUE-<PROJ>-<COMP>-<NN> (bug) blocks this release
```

### GATE-CHECK:
```
## Regression Gate Check — REL-<PROJ>-<VER>
- Result: READY / BLOCKED / PENDING

| Component | Gate | Status |
|-----------|------|--------|
```

### CLOSE:
```
## Release closed
- ID: REL-<PROJ>-<VER>
- Close date: <date>
- ISSUEs closed: N
- Regression TESTs verified: N
- ROADs updated: [list]
- Changelog: frozen
```
