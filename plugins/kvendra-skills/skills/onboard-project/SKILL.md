---
name: onboard-project
description: Onboard a new Kvendra project (or new component of an existing project) — interactive pipeline with auto tier detection, PRJ/CMP/GLO/STD entity creation, and CLAUDE.md generation
user_invocable: true
args: "[project_id (uppercase 3-6 chars) or 'add-component <component-name>' for existing project]"
---

# Onboard Project v2 — Bootstrap a Kvendra project end-to-end

Creates the full structure of a new project (or a new component for an existing project) in the Kvendra KB, generates a canonical `CLAUDE.md` from `STD-KVD-CLAUDEMD-TEMPLATE`, and applies the schema conventions documented in `help({topic:"workspace-layout"})`. Soft orchestrator — opens a TXN to bundle creates but does NOT delegate to other v3 subagents.

The skill **auto-detects** the engine tier via `whoami` and **does not ask the user** for information that can be inferred from the environment.

## Input

`$ARGUMENTS` may be:
- A bare uppercase project_id (3-6 chars) like `KVD` → new project mode.
- `add-component <name>` like `add-component DASHBOARD` → new component mode (existing project).
- Empty → interactive mode (prompt for mode + project_id).

## Step 0 — Initialization

Resolve `project_id` from `$ARGUMENTS` or from the current workspace `CLAUDE.md` (if onboarding a new component for an existing project).

Read `help({topic:"workspace-layout"})` to refresh the canonical metadata conventions before creating PRJ/CMP entities (forward-compatible if the schema evolves).

## Kvendra rules (summary)

- Identify in every write: `updated_by: "skill:onboard-project"`. The MCP client adds `X-Kvendra-Skill` automatically.
- Orchestrator → `txn_create` before creating entities, close with `txn_activate` (success) or `txn_cancel(reason)` (failure).
- Before opening a TXN: `txn_check_interrupted({project_id, component_id?})`. If an in-progress TXN exists: ask Resume / Cancel / Ignore.
- IDs are server-emitted. Exception: `PRJ`/`CMP`/`REL` require `force_id`.
- On any error with `error.help.topic`: call `help({topic})`. Topic list: `bootstrap, identity, naming, txn, validation, errors, embeddings, tools, examples, entity_types, workspace-layout, skill-playbooks, install, tier`.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

For new projects this skill materialises the seed `.kvendra-protected`
at the workspace root after creating the project's
`STD-<PROJECT>-BROKER-POLICY` entity (see Step 5 and Step 6).

## Step 1 — Auto-detect the tier (no user question)

Call `whoami`. Decide the mode based on the response:

| `whoami` response | Tier | Mode | MCP server |
|---|---|---|---|
| `tier:"pro"|"team"|"enterprise"`, `auth_mode:"jwt"`, `identity_source:"oidc"` | as returned | cloud | `kvendra-cloud` (Enterprise SaaS) |
| `tier:"free"`, `mode:"local"` or empty | `free` | local | `kvendra-platform` self-host |
| ambiguous / no response | — | ask user as fallback | — |

Record the resolved tier — it will be written to `CLAUDE.md` (section Project, `tier:` flag) verbatim. NEVER ask the user a tier that `whoami` already returned authoritatively.

If `whoami` does not return — or if the broker / MCP is unreachable — apply the fail-safe per `PAT-KVD-2CBB6D` L3: STOP and notify the user with the canonical message. Do NOT attempt to onboard without a live KB connection.

## Step 2 — Determine scope

Read `$ARGUMENTS`:

- Bare `<PROJECT_ID>` (uppercase 3-6 chars, e.g. `KVD`) → **new project mode**. Check it doesn't already exist:
  ```
  entity_get({ entity_id: "PRJ-<PROJECT_ID>" })
  ```
  If it exists, abort with a message — the user probably wants `add-component` mode.

- `add-component <COMPONENT_CODE>` → **new component mode**. Read PRJ from cwd's CLAUDE.md, confirm it exists in the KB.

- Empty → ask the user interactively (Project ID + mode).

## Step 3 — Interactive questions to the owner

Ask ONLY what cannot be inferred. The auto-detected tier is NEVER re-asked.

### Common questions (both modes)

1. **Workspace layout** (only new project): `siblings` (default), `monorepo`, `mixed`, or custom string. Affects `PRJ.metadata.workspace_layout`.
2. **`owner_handle`**: pre-fill from `whoami.identity.preferred_username` if cloud + Track A available; ask as fallback (default = local OS user).

### Per-component questions

For each component to create:
- Component code (uppercase, e.g. `CLI`, `WEB`, `ENTERPRISE`).
- Title and 1-line description.
- `workspace_subdir`: relative path from workspace root to the component's clone (e.g. `kvendra-cli`). Validate that `<cwd>/<subdir>` exists or warn the user.
- `repo_url`: canonical Git remote of the component repo.
- License (Apache-2.0 / MIT / AGPL-3.0 / Proprietary / other).
- `tech_stack`: from auto-detection of `package.json`/`Cargo.toml`/`requirements.txt`/etc, plus confirmation.

### Operational policy (only new project)

5-7 questions covering the project's autonomy boundaries — these will be written to `STD-<PROJECT_ID>-DEPLOY-POLICY` content:

- Which deploys are autonomous (web/static, backend staging, backend prod)?
- Which Git operations are autonomous (push to main, tag, release)?
- Which publish operations require manual confirmation (npm, cargo, pypi)?
- Are there vault profiles already created? (List them.)
- Are there external accounts referenced (AWS account id, GitHub org, etc.)?

### Particularidades (only new project)

Free-form prompt: anything cross-cutting that affects the agent's reasoning and is NOT modelable as a KB entity. Examples:
- Multi-KB legacy migration in progress.
- Real (production) vault in use vs sandbox.
- Atypical operational constraints.
- Key contacts.

This goes verbatim under `## Particularidades` in the generated CLAUDE.md.

## Step 4 — Open a TXN

```
txn_check_interrupted({ project_id:<PROJECT_ID>, component_id:"<PROJECT_ID>-<COMP>" })
txn_create({
  type: "onboarding",
  project_id: "<PROJECT_ID>",
  component_id: "<PROJECT_ID>-<COMP>",   // only in add-component mode
  trigger: "Onboard <project|component name>",
  pipeline: [
    {step:1, name:"create-prj-or-cmp"},
    {step:2, name:"create-ifs-and-stds"},
    {step:3, name:"create-env-rel"},
    {step:4, name:"generate-claudemd"}
  ],
  started_by: "skill:onboard-project"
})
```

## Step 5 — Create entities (drafts inside the TXN)

### For a new project

1. **`PRJ-<PROJECT_ID>`** (`force_id`):
   ```
   entity_create({
     entity_type: "PRJ",
     project_id: "<PROJECT_ID>",
     force_id: "PRJ-<PROJECT_ID>",
     title, content,
     metadata: {
       bootstrap_extras: [
         "<STD-DEPLOY-POLICY entity_id from step 2>",
         "<STD-BROKER-POLICY entity_id from step 2b>"
       ],
       owner_handle: <whoami or asked>,
       workspace_layout: <answered>
     },
     txn_id, updated_by
   })
   ```
   Conventions per `help({topic:"workspace-layout"})`. The PRJ create happens AFTER steps 2 and 2b so the resolved entity_ids can be embedded in `bootstrap_extras`. Alternatively, create PRJ first with an empty `bootstrap_extras` then `entity_update` after steps 2 + 2b — pipeline-friendly inside the same TXN.

2. **`STD-<PROJECT_ID>-DEPLOY-POLICY`** (server-generated id):
   Content built from the operational-policy answers (Step 3). Schema per `help({topic:"skill-playbooks"})` (`playbook_type:"deploy-policy"`).

2b. **`STD-<PROJECT_ID>-BROKER-POLICY`** (server-generated id):
   Seed broker-policy playbook with **strict** mode + canonical production blocklist (cloned from the schema documented at `help({topic:"broker-policy"})` and from `STD-KVD-BROKER-POLICY` as the reference instance). Schema per `help({topic:"broker-policy"})` (`playbook_type:"broker-policy"`).
   - `metadata.playbook_type = "broker-policy"`, `metadata.mode = "strict"`, `metadata.schema_version = 1`, `metadata.broker_min_version = "0.4.0"`, `metadata.broker_install_hint = "Install kvendra-cli: cargo install kvendra (or see https://github.com/KvendraAI/kvendra-cli)"`.
   - Content includes the canonical YAML payload (mode + block_bash[] + allow_bash[] + require_broker[] + broker_install_hint + broker_min_version), pre-populated with the canonical Kvendra blocklist as the default seed.
   - Tags: `playbook_type:broker-policy`, `mode:strict`, `scope:broker-policy`.
   - Relations: `derives_from → ADR-KVD-SKILLS-BB0E8A`, `part_of → PRJ-<PROJECT_ID>`.

3. **`GLO-<PROJECT_ID>-001`** (`force_id`):
   Domain terms + component codes.

4. **`ENV-<PROJECT_ID>-<auto>`** for each environment (dev/test/prod).

5. **`REL-<PROJECT_ID>-0.1.0`** (`force_id`):
   Baseline release entity, status `planning`.

6. For each component declared: run the "new component" subroutine below.

### For a new component

1. **`CMP-<PROJECT_ID>-<COMP>`** (`force_id`):
   ```
   entity_create({
     entity_type: "CMP",
     project_id: "<PROJECT_ID>",
     component_id: "<PROJECT_ID>-<COMP>",
     force_id: "CMP-<PROJECT_ID>-<COMP>",
     title, content,
     metadata: {
       component_type, tech_stack, license,
       workspace_subdir: "<answered>",
       repo_url: "<answered>"
     },
     relations: [{type:"part_of", target:"PRJ-<PROJECT_ID>"}],
     txn_id, updated_by
   })
   ```

2. **`IF-<PROJECT_ID>-<COMP>-<auto>`** for each interface auto-detected from the component's source tree (endpoints, SQS topics, DynamoDB tables, exported APIs, webhooks).

3. **Initial STD-DEPLOY-PROCESS stub** (optional, recommended for backend/frontend components):
   `STD-<PROJECT_ID>-<COMP>-DEPLOY-PROCESS` with a placeholder Steps section the owner fills later. Without it, the future `kvendra-skills:deploy` skill (REQ-KVD-SKILLS-629F77 Fase 3) cannot run for that component.

## Step 6 — Generate CLAUDE.md from the canonical template

1. Read `STD-KVD-CLAUDEMD-TEMPLATE` from the KB (or read the local file `kvendra-skills/plugins/kvendra-skills/CLAUDE.md.template` if running offline against Platform self-host).
2. Render with substitutions:
   - `{{PROJECT_ID}}` → uppercase project_id.
   - `{{TIER}}` → tier from Step 1 (free|pro|team|enterprise).
   - `{{PARTICULARITIES}}` → answer from Step 3 (or an empty placeholder comment if no particularities).
3. Write the resulting file to `<cwd>/CLAUDE.md` (only in new-project mode — in add-component mode the existing CLAUDE.md is preserved).
4. **Do NOT overwrite** an existing CLAUDE.md without `--force`. If one exists, show the diff and ask the user.

## Step 6.5 — Materialise `.kvendra-protected` (broker policy)

Only in **new project mode**. After the seed `STD-<PROJECT_ID>-BROKER-POLICY` is created in Step 2b:

1. Read the freshly-created STD (the txn-scoped entity_id is known from Step 2b).
2. Extract the canonical YAML body from `## Steps` step 3 (the fenced ```yaml … ``` block).
3. Compute provenance: `schema_version`, `std_id = <created entity_id>`, `synced_version = STD.version (1 at creation)`, `synced_at = current ISO8601 UTC`, `synced_by = "skill:onboard-project"`, `cmp_overrides_applied = []`, `checksum = sha256(canonical body)`.
4. Validate the payload (each regex must compile under `grep -E`; `mode` valid; `require_broker[].primitive` in the 7-value enum).
5. Write the file atomically to `<workspace_root>/.kvendra-protected` with the canonical header comment:
   ```
   # synced from <std_id> (do not edit by hand — run /sync-claudemd --policy-only)
   ```
6. If `.kvendra-protected` already exists at workspace root, prompt the user before overwriting. The default is **DO NOT overwrite** an existing file (protects manual edits / prior project tenants).
7. Best-effort cleanup of legacy `.kvendra-workspace` if it exists in the same directory: leave it in place (do NOT delete), but log an INFO line recommending the user remove it after one release.

**Add-component mode**: this step is SKIPPED — `.kvendra-protected` belongs to the workspace root, not the component subdir. Re-syncing on existing projects is the job of `/sync-claudemd --policy-only`.

## Step 7 — Validate completeness

Verify the component profile (`component_type` → required entities):
- `backend` / `adapter`: CMP + at least 1 IF (interfaces_defined).
- `frontend`: CMP + at least 1 IF (interfaces_consumed).
- `infra` / `docs`: CMP only.

Run a smoke verification of the rendered CLAUDE.md:
- File size ≤40 lines.
- 3 sections present with markers (`KVENDRA:MANUAL`, `KVENDRA:PROJECT`, Particularidades unmarked).
- `tier` flag is valid (free|pro|team|enterprise).
- `manual_version` matches `STD-KVD-CLAUDEMD-TEMPLATE.metadata.manual_version`.

## Step 8 — Activate or cancel the TXN

If all checks pass:
```
txn_activate({ txn_id, updated_by:"skill:onboard-project" })
```

If anything failed or the user cancels:
```
txn_cancel({ txn_id, reason:"<motive>", updated_by:"skill:onboard-project" })
```

## Output

```
## Onboarding completed: <project or component name>

### TXN
TXN-<PROJECT_ID>-<YYYYMMDD>-<NNN>: COMPLETED

### Tier (auto-detected)
tier:<free|pro|team|enterprise>  (via whoami)

### Entities created
| Entity ID | Type | Title |
|-----------|------|-------|
| PRJ-<PROJECT_ID> | PRJ | ... |
| GLO-<PROJECT_ID>-001 | GLO | ... |
| ENV-<PROJECT_ID>-<NN> | ENV | ... |
| REL-<PROJECT_ID>-0.1.0 | REL | ... |
| STD-<PROJECT_ID>-DEPLOY-POLICY | STD | autonomy boundaries |
| CMP-<PROJECT_ID>-<COMP> | CMP | ... |
| IF-<PROJECT_ID>-<COMP>-001 | IF | ... |

### CLAUDE.md generated
- Path: <cwd>/CLAUDE.md
- Lines: <N> (target ≤40)
- Sections: 3/3 (Manual marked, Project marked, Particularidades present)
- manual_version: 1.0
- tier: <tier>

### Verified against GLO
- New terms: N
- Conflicts: 0/N

### Next steps
- Open the first REQ for the project: `/requirements-analyst <description>`
- Sync the CLAUDE.md whenever the canonical template evolves: `/sync-claudemd <PROJECT_ID>`
- Lint the CLAUDE.md for conformance: `/lint-claudemd`
- (Add-component mode only) Define STD-DEPLOY-PROCESS for the new component so the generic deploy skill can run.
```
