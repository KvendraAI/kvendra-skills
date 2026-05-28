---
name: release-manager
description: Release manager — creates, manages and closes REL entities with automatic changelog, regression gates and Kvendra KB traceability
user_invocable: true
args: "[action: create|status|add|gate-check|close] [arguments]"
writes_entity_types: [REL, IF, ISSUE]
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

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

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

## CLI capabilities manifest sync (post-release hook)

Per `REQ-KVD-ECDAE9` (Piece B'): when a release is closed for a CLI-type
component, refresh the per-project `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST`
entity in the KB from the freshly-built broker binary. The manifest is
the runtime discovery surface consumed by `onboard-project` Step 1.5 and
`lint-claudemd` primitive cross-check.

This step is **best-effort**: a failure here does NOT block the release.
Release publishing is the primary job — manifest sync is a secondary
synchronisation.

### When to run

Triggered as part of the CLOSE action when the released component
matches a CLI-type component, detected by either of:

- `CMP.metadata.component_type == "cli-binary"`, or
- `CMP.tags` contains `type:cli-binary`, or
- The REL `entity_id` matches the regex `^REL-[A-Z]+-CLI(-[A-Z]+)?-` and the
  released CMP exposes the `kvendra capabilities` subcommand.

For the KVD project this means `CMP-KVD-CLI` (today the only CLI-type
component). The hook is generic by design — adding a new CLI component
in any project will trigger it automatically.

### Steps

1. **Locate the binary**: resolve the workspace path from
   `CMP-<PROJ>-CLI.metadata.local_path` (or the equivalent monorepo
   subdir from `metadata.workspace_subdir` joined with the project
   workspace root). Append `target/release/<binary-name>` — for KVD,
   `kvendra`.
2. **Pre-check**: if the binary file does not exist or is not
   executable, log a structured warning and stop the hook (best-effort;
   release CLOSE already succeeded). Suggested follow-up: open an
   ISSUE with `type:task` so the owner can refresh the manifest
   manually.
3. **Run `kvendra capabilities --pretty`** via Bash (read-only,
   auth-less, no vault, no network — per AC-CLI-3 of REQ-KVD-ECDAE9).
   Capture stdout. This op does NOT need a broker primitive — it is
   already declared `allow_bash` in `STD-KVD-BROKER-POLICY` because it
   has no privileged side effects.
4. **Parse JSON to memory**. On parse error: log a structured warning
   with the raw stdout (truncated to 2 KB), do NOT abort the release.
5. **Validate schema_version**: assert `schema_version == 1`. If the
   binary reports a different schema_version, log a warning and stop
   (cross-version drift — needs a major REQ + IF-MANIFEST schema bump
   per AC-CLI-8). Do NOT write a manifest with an unrecognised
   schema_version.
6. **Look up existing IF-MANIFEST** for this project:
   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
     entity_type: "IF",
     project_id: "<PROJ>",
     tags_all: ["playbook-style:if-manifest","cmp:CLI"]
   })
   ```
7. **Upsert**:
   - If 0 results → `entity_create` a new IF-MANIFEST. Content:
     schema-doc preamble (mirror of `IF-KVD-CLI-PRIMITIVES-MANIFEST`
     reference) + the JSON payload in a fenced block. Metadata:
     `{ if_version:"1.0", schema_version: <observed>, broker_version_observed: <observed>, scope:"per-project-replicated", wire_public:true, synced_by:"skill:release-manager", synced_at:"<ISO8601>", primitives_count:<n>, ops_count_total:<n> }`.
     Tags: `["scope:if","scope:cli-capabilities","scope:per-project","version:1.0","status:active","playbook-style:if-manifest","cmp:CLI","source:capabilities-command","wire-public"]`.
     Relations: `derives_from → REQ-KVD-ECDAE9`, `affects → CMP-<PROJ>-CLI`, `part_of → PRJ-<PROJ>`.
     `updated_by: "skill:release-manager"`.
   - If 1 result → `entity_update` with new content + metadata,
     additive-merge any owner-added annotations (do NOT overwrite
     content sections marked `<!-- preserved -->`). `change_summary`:
     `"Updated by release-manager post REL-<PROJ>-<COMP>-<VER>: broker <X.Y.Z>, <P> primitives, <O> ops"`. Bump
     `metadata.synced_at` + `metadata.broker_version_observed`.
   - If >1 results → log a structured warning (duplicate manifests
     violate per-project replication invariant); do NOT pick one
     blindly. Suggest manual reconciliation.
8. **Append CHANGELOG entry to the REL**: `entity_update` the REL with a
   `change_summary` line: `"IF-MANIFEST refreshed to broker version <X.Y.Z> (<P> primitives, <O> ops)"`.
   The server records this in `entity_changelog`.
9. **Idempotence**: re-running on the same broker version is a no-op
   at the wire level — `entity_update` only changes
   `metadata.synced_at` (and re-embeds because content+JSON payload
   are byte-identical except for the synced_at marker if it is
   embedded in content; keep `synced_at` in metadata only to preserve
   idempotence).

### Failure modes (all best-effort)

| Failure | Behaviour |
|---------|-----------|
| Binary missing / not executable | Log warning + skip; release CLOSE remains successful. |
| `capabilities` subcommand absent (binary older than REL-CLI-0.5.0) | Log warning + skip; expected during the chained-REL transition window. |
| JSON parse error | Log warning with truncated stdout; skip; release CLOSE remains successful. |
| `schema_version != 1` | Log warning; skip; needs major-REQ reconciliation. |
| KB write error (`entity_create` / `entity_update`) | Log structured error + retry once; if still failing, skip; release CLOSE remains successful. Surface as suggested follow-up ISSUE. |
| Multiple IF-MANIFEST entities for the project | Log warning; skip (do not pick one blindly). |

### Trazabilidad

- Implementa: `REQ-KVD-ECDAE9` Piece B' + AC-REL-1..4.
- Ships in REL.1 of the 3-chained REL plan (the extension is dormant
  until the first CLI release post-0.5.0 triggers it).
- The first KVD instance — `IF-KVD-CLI-PRIMITIVES-MANIFEST` — is created
  in PHASE 2 (implementer, REL.1) as the schema-doc entity; the first
  per-project auto-populated content lands when `REL-KVD-CLI-0.5.0`
  closes via this hook.
