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

## Step 1.5 — Broker discovery (capabilities snapshot)

Empirically discover the local broker primitive surface so the onboarding can:
- Surface drift between local CLI and the KB-canonical `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST`.
- Warn early if the broker is missing, outdated, or pointing at a non-GitHub VCS.
- Persist a `broker_capabilities_seen` snapshot for future drift detection.

This step is **read-only**: zero broker calls beyond `kvendra --version` + `kvendra capabilities`, zero KB writes. The actual `.kvendra-protected` write happens in sub-step 1.5.f, and the STD metadata update in 1.5.g — both additive.

### 1.5.a — Detect CLI presence

Run `kvendra --version` via Bash (read-only, allowlisted by the hook). Capture stdout + exit code.

- **Exit 0**: parse semver from stdout (regex `kvendra (\d+\.\d+\.\d+)`). Continue to 1.5.b.
- **Non-zero / not found**: CLI is not installed. Go to 1.5.b option-set "not installed".

### 1.5.b — Branch on CLI presence

**If CLI installed → continue to 1.5.c**.

**If CLI NOT installed → present 3 explicit options to the owner**:

1. **Install now** (recommended for cloud tier). Print: `cargo install kvendra` (or point to the GitHub releases binary if cargo is unavailable). Wait for owner to confirm install, then re-run sub-step 1.5.a.
2. **Continue broker-less** (acceptable for `tier:free` local / docs-only projects). The onboarding proceeds but the resulting `STD-<PROJ>-BROKER-POLICY` will be seeded in `mode: "off"` and no `broker_capabilities_seen` block is written. Persist `metadata.broker_install_skipped: true` on the STD-BROKER-POLICY.
3. **Cancel onboarding**. Owner aborts; orchestrator calls `txn_cancel` if a TXN is already open (which at Step 1.5 it should NOT be — TXN opens at Step 4).

### 1.5.c — Detect GitHub remote (informational)

Run `git remote -v` and `git config --get remote.origin.url` via Bash (read-only). Capture output.

- If origin URL contains `github.com` → set local flag `non_github_vcs = false`.
- If origin URL exists but lacks `github.com` (gitlab.com / bitbucket.org / self-hosted) → set `non_github_vcs = true`.
- If `git remote -v` returns empty → set `no_remote = true`.

This flag drives the warnings in 1.5.h. Do NOT block the onboarding on either condition.

### 1.5.d — Run `kvendra capabilities`

Invoke `kvendra capabilities --pretty` via Bash (read-only, no vault unlock, no Cognito session needed per `AC-CLI-3` of REQ-KVD-ECDAE9). Capture stdout JSON.

- **Parse JSON** to memory. Expected root keys: `broker_version`, `schema_version`, `primitives[]`.
- **If parse fails** (malformed JSON, missing keys, schema_version != 1) → surface a structured error to the owner:
  ```
  ⚠ kvendra capabilities returned unparseable output.
     broker_version observed: <best-effort>
     stderr: <captured>
     Possible causes:
       (a) Broker too old (pre-0.5.0) — upgrade with `cargo install kvendra --force`.
       (b) Schema version mismatch (capabilities schema_version != 1) — orchestrator needs update.
       (c) Local fork drift.
     Onboarding will continue but `broker_capabilities_seen` will NOT be written.
  ```
  Set `capabilities_parse_failed = true`. Skip 1.5.e and 1.5.f. Continue to 1.5.g/1.5.h warnings.

### 1.5.e — Cloud-mode KB diff (Pro+ only)

If `tier ∈ {pro, team, enterprise}` from Step 1:

1. Query the KB for the existing per-project IF-MANIFEST:
   ```
   entity_query({
     entity_type: "IF",
     project_id: "<PROJECT_ID>",
     tags_all: ["scope:cli-capabilities-instance", "scope:per-project"]
   })
   ```
2. Branch:
   - **0 results** → first onboard for this project. Print: `ℹ No IF-MANIFEST yet for PRJ-<PROJ>. It will be auto-populated by release-manager on the next CMP-<PROJ>-CLI release.` (No write — that's `release-manager`'s job.)
   - **1 result** → diff the KB-stored `primitives[]` against the local `kvendra capabilities` output. Print a structured diff summary:
     ```
     KB IF-MANIFEST:    broker_version <KB_VER>, <N> primitives
     local capabilities: broker_version <LOCAL_VER>, <M> primitives
     Diff: <list added/removed/changed primitives>
     ```
     Do NOT block. Diff is informational — the owner decides if they upgrade or proceed.
   - **>1 results** → KB invariant violation. Surface error pointing to ISSUE-KVD-SKILLS-DUP-IF-MANIFEST (created on-demand). Continue with the most recent result.

If `tier == free` (local mode): skip the KB diff entirely (no MCP query needed; the IF-MANIFEST lives only in the Pro+ cloud KB or in the local Platform KB).

### 1.5.f — Persist `broker_capabilities_seen` to `.kvendra-protected`

**Pre-condition**: `capabilities_parse_failed == false` AND Step 6.5 has materialised `.kvendra-protected` (so the file exists). If `.kvendra-protected` does NOT yet exist at this point in the pipeline (Step 1.5 runs BEFORE Step 6.5 — that's the ordering), buffer the snapshot in memory and write it during Step 6.5 right after the marker is materialised.

Add (or update, if already present) the following YAML block additively — do NOT rewrite the whole file from scratch. Load, merge, write atomically:

```yaml
broker_capabilities_seen:
  broker_version: "<from kvendra capabilities>"
  schema_version: <from kvendra capabilities>
  seen_at: "<ISO8601 UTC>"
  primitives_count: <int>
  ops_count_total: <int>
  checksum: "<sha256 of the JSON payload>"
```

Idempotency: if the existing block has the same `broker_version` + `checksum`, only update `seen_at` (no other field change). Per `NFR-CAP-7` (REQ-ECDAE9): adding this block does NOT break existing schema; hook v2 with defensive parser ignores unknown top-level keys.

**Note**: in **add-component mode** this step is SKIPPED — `.kvendra-protected` belongs to the workspace root, not the component subdir. Re-syncing is the job of `/sync-claudemd --policy-only`.

### 1.5.g — Update `STD-<PROJ>-BROKER-POLICY.metadata.capabilities_seen_version`

After 1.5.f succeeds (or after Step 6.5 deferred write), `entity_update` the `STD-<PROJ>-BROKER-POLICY` with:
```
metadata: { capabilities_seen_version: "<broker_version from capabilities>" }
```
`change_summary`: `"[skill:onboard-project] Record broker capabilities snapshot v<X.Y.Z>"`.

This closes the loop — both the workspace marker (`.kvendra-protected`) and the canonical KB STD reflect the observed broker surface.

### 1.5.h — Warnings (always surfaced, non-blocking)

Emit, in order, only the warnings that apply:

- If `non_github_vcs == true`:
  ```
  ⚠ Non-GitHub remote detected (gitlab/bitbucket/other).
    Only `github-*` primitives are available in the current broker (v<X.Y.Z>).
    Track future REQ for multi-host VCS support: ISSUE-KVD-SKILLS-REQ-FOLLOWUP-MULTI-VCS.
    Onboarding continues.
  ```
- If `no_remote == true`:
  ```
  ℹ No git remote detected. The `kvendra.github` primitive will be inert for this
    project until you run `git remote add origin <github-url>`. Onboarding continues.
  ```
- If `capabilities_parse_failed == true`:
  ```
  ⚠ capabilities snapshot was NOT written. Re-run /sync-claudemd --policy-only
    after fixing the broker to populate broker_capabilities_seen.
  ```

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

### Per-component archetype questions (D1/D2/D3)

For EACH component declared, ask three orthogonal-axis questions (per `PAT-KVD-819856` L1). These answers drive Step 5's STD-TPL clone flow — they decide WHICH canonical playbook to seed for the new component.

The three axes are kept independent. Asking D1 does not change D2's prompt; asking D2 does not gate D3 (with one exception: D3 is skipped if D1 = `none`).

#### D1 — Deploy target (single-select)

```
Where will CMP-<PROJ>-<COMP> deploy to?
  1. static-cdn         (S3 + CloudFront, like kvendra.com)
  2. serverless-aws     (SAM Lambda + API Gateway)
  3. container-registry (Docker push to Docker Hub / GHCR with cosign signing)
  4. k8s-cluster        (helm upgrade --install)                  [STRETCH — no template yet]
  5. package-publish    (no deploy — registry-only via D3 channels)
  6. vps-ssh            (SSH to a VPS, run install script)
  7. none               (no deploy — docs / library only)
  8. custom             (free-form steps the owner fills manually)
```

#### D2 — Test framework (single-select)

```
What test framework does CMP-<PROJ>-<COMP> use?
  1. cargo        2. jest         3. vitest       4. pytest
  5. playwright   6. mixed        7. none         8. custom
```

#### D3 — Publish channels (multi-select, conditional)

Ask D3 **only if** D1 ∈ {`container-registry`, `package-publish`} OR the orchestrator passed `--include-publish-prompt`. If D1 = `none`, skip D3.

```
Which channels does CMP-<PROJ>-<COMP> publish to? (multi-select)
  [ ] crates.io                    [ ] npm
  [ ] PyPI                         [ ] Docker Hub
  [ ] GHCR                         [ ] GitHub Releases
  [ ] Homebrew                     [ ] Claude plugin marketplace
  [ ] custom (free-form)
```

#### D1 → STD-TPL clone mapping

| D1 answer | STD-TPL cloned | Target STD ID created |
|-----------|----------------|------------------------|
| `static-cdn`         | `STD-TPL-DEPLOY-STATIC-S3-CDN`   | `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` |
| `serverless-aws`     | `STD-TPL-DEPLOY-SAM-LAMBDA`      | `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` |
| `container-registry` | `STD-TPL-DEPLOY-DOCKER-REGISTRY` | `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` |
| `k8s-cluster`        | DEFER — no template yet (STRETCH); inform owner and stub `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` as empty placeholder, tag `status:stub` + open ISSUE-KVD-SKILLS-REQ-FOLLOWUP-K8S-HELM-TPL |
| `package-publish`    | DEFER — publish templates are STRETCH; stub `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` empty placeholder (publish flow driven by D3 → future per-channel STD-TPL-PUBLISH-* clones) |
| `vps-ssh`            | Stub `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` empty placeholder + tag `status:stub`, `target:vps-ssh` |
| `none`               | Skip — do NOT create `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` |
| `custom`             | Ask owner for free-form steps; create `STD-<PROJ>-<COMP>-DEPLOY-PROCESS` with their content, tag `status:custom` |

#### D2 → STD-TPL clone mapping

| D2 answer | STD-TPL cloned | Target STD ID created |
|-----------|----------------|------------------------|
| `playwright`         | `STD-TPL-TEST-PLAYWRIGHT` | `STD-<PROJ>-<COMP>-TEST-PROCESS` |
| `cargo`              | `STD-TPL-TEST-CARGO`      | `STD-<PROJ>-<COMP>-TEST-PROCESS` |
| `pytest`             | DEFER — STRETCH; stub `STD-<PROJ>-<COMP>-TEST-PROCESS` empty placeholder |
| `jest` / `vitest`    | DEFER — no template yet; stub `STD-<PROJ>-<COMP>-TEST-PROCESS` empty placeholder |
| `mixed` / `custom`   | Stub with comment line listing the frameworks the owner specified |
| `none`               | Skip — do NOT create `STD-<PROJ>-<COMP>-TEST-PROCESS` |

#### D3 → STD-TPL clone mapping (multi)

For each channel selected, clone the corresponding `STD-TPL-PUBLISH-<CHANNEL>` if it exists; otherwise stub. As of REL.3 only `STD-TPL-PUBLISH-CARGO` and `STD-TPL-PUBLISH-CLAUDE-PLUGIN` are STRETCH targets and may NOT exist. If a publish channel is selected without a backing TPL: create `STD-<PROJ>-<COMP>-PUBLISH-<CHANNEL>` as an empty placeholder + ISSUE follow-up.

#### Clone substitution flow (per cloned STD-TPL)

This is the deterministic transform applied at Step 5 once the answers are known:

1. **Read the template**: `entity_get({entity_id: "STD-TPL-<NAME>"})` → capture `content`, `metadata`, `tags`.
2. **Extract `{PLACEHOLDER}` variables**: parse the `## Variables` table of the template. Each row defines a `{VAR}` token, a description, and (optionally) a default.
3. **Ask the owner for each `{VAR}`'s value**: prefer auto-fill from `CMP.metadata` (e.g. `{AWS_PROFILE}` → `PRJ-<PROJ>.metadata.aws_profile`, `{WORKSPACE_SUBDIR}` → `CMP.metadata.workspace_subdir`). For unfilled vars, prompt the owner with the default offered.
4. **Render the template**: string-replace every `{VAR}` token in the `content` field. Validate no unresolved `{...}` placeholders remain (regex `\{[A-Z_]+\}`) — if any remain, prompt the owner.
5. **Create the cloned STD entity**:
   ```
   entity_create({
     entity_type: "STD",
     project_id: "<PROJ>",
     component_id: "<PROJ>-<COMP>",
     title: "STD-<PROJ>-<COMP>-DEPLOY-PROCESS: <derived from D1>",
     content: <rendered content>,
     metadata: {
       cloned_from: "STD-TPL-<NAME>",
       template_version: <from template metadata>,
       playbook_type: "deploy" | "test" | "publish",
       autonomous: <from template, owner may override>,
       vault_profile_required: <from rendered VAR>,
       discovery_tags: ["scope:deploy","scope:process","cmp:<COMP>"]  // or test/publish
     },
     tags: [...template tags excluding "scope:template", "scope:std-tpl", "template:v*"]
            + ["scope:deploy","scope:process","cmp:<COMP>","cloned-from:STD-TPL-<NAME>"],
     relations: [
       { type: "derives_from", target: "STD-TPL-<NAME>" },
       { type: "affects",      target: "CMP-<PROJ>-<COMP>" },
       { type: "part_of",      target: "PRJ-<PROJ>" }
     ],
     txn_id, updated_by: "skill:onboard-project"
   })
   ```
6. **Stub case** (no TPL exists): the cloned entity is created with a minimal content placeholder:
   ```
   # STD-<PROJ>-<COMP>-DEPLOY-PROCESS — TODO
   <Auto-generated stub by onboard-project. No STD-TPL backed this archetype (D1=<answer>).
   Fill in Pre-conditions / Steps / Post-conditions / Variables / Validation / Rollback
   sections before running /deploy.>
   ```
   `metadata.status: "stub"`, `tags: [..., "status:stub"]`. The future `kvendra-skills:deploy` skill refuses to run against stub STDs.

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
