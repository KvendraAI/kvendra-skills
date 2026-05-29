---
name: sync-claudemd
description: Regenerate a project's CLAUDE.md from the canonical template (STD-KVD-CLAUDEMD-TEMPLATE), preserving the Particularidades section. Also materialises the broker policy at .kvendra-protected from STD-<PROJ>-BROKER-POLICY. Detects manual_version + tier drift.
user_invocable: true
args: "[<PROJECT_ID> (optional, defaults to project_id from cwd CLAUDE.md)] [--dry-run] [--force] [--policy-only] [--enable-break-glass]"
---

# Sync CLAUDE.md v1 — Regenerate from canonical template + materialise broker policy

Regenerates the `CLAUDE.md` of the current project (or a specified one) from the canonical template entity `STD-KVD-CLAUDEMD-TEMPLATE` in the KB AND materialises the project's broker policy as `.kvendra-protected` at the workspace root from `STD-<PROJECT>-BROKER-POLICY`. **Preserves the `## Particularidades` section verbatim** unless `--force` is passed. Detects drift in `manual_version`, `tier` and broker-policy `synced_version` and warns the user before regenerating.

This skill closes the lifecycle of the CLAUDE.md ultra-minimum model (per REQ-KVD-SKILLS-50F9E4) and the broker-policy materialisation lifecycle (per REQ-KVD-SKILLS-48062A) — `onboard-project` generates the initial CLAUDE.md + `.kvendra-protected`; `sync-claudemd` keeps both aligned with the evolving canonical sources; `lint-claudemd` verifies conformance.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Input

`$ARGUMENTS` may be:
- `<PROJECT_ID>` (uppercase 3-6 chars) → regen for that project. Default: project_id from `<cwd>/CLAUDE.md` Project section.
- `--dry-run` → show the diff vs the would-be regenerated CLAUDE.md AND `.kvendra-protected`, do NOT write.
- `--force` → overwrite the Particularidades section too (DESTRUCTIVE).
- `--policy-only` → write only `.kvendra-protected` (broker policy), leave `CLAUDE.md` untouched. Useful when the policy STD evolves independently of the CLAUDE.md template.
- `--enable-break-glass` → opt this project into the additive `break_glass:` block (IF-840EE9 1.1) even if the STD does not set `break_glass.enabled: true`. Pins the local `kvendra grant-pubkey` into `.kvendra-protected` (see Step 6.3b). No-op if the project is already opted in.

### Default action (no flags)

Syncs **both** `CLAUDE.md` AND `.kvendra-protected`. Each side is idempotent (no-op if local copy already matches its canonical KB source).

## Step 0 — Initialization + fail-safe

Identify `project_id` from `$ARGUMENTS` or from the current workspace `CLAUDE.md` (Project section, `project_id:` line).

If the MCP for the project's tier (read from current CLAUDE.md `tier:` line) does not respond, or the canonical template cannot be fetched, STOP and notify the user with the canonical message. NO Bash fallback to write the CLAUDE.md from memory.

## Kvendra rules

Standard rules apply (see `help({topic:"bootstrap"})` + `help({topic:"naming"})` + `help({topic:"txn"})`). This skill writes one file on disk — no KB entities created. NO TXN required.

## Step 1 — Load canonical template

The canonical template ships **bundled with the plugin** at `<plugin-root>/CLAUDE.md.template`. The KB STD entity is an optional discoverable mirror used for cross-session/cross-project audit and version comparison.

### Primary — local plugin file

Read `<plugin-root>/CLAUDE.md.template` (resolved via the cwd of the agent or the plugin cache path). This is the canonical source: ships atomically with the plugin version, never out-of-sync with itself.

Extract from the file:
- First HTML comment `<!-- manual_version: X.Y -->` → canonical version.
- Body content (everything after the version comment) → template body with placeholders.

If the file is missing or malformed: STOP and tell the user the plugin install is corrupted. Recommend `/plugin update kvendra-skills` to repair.

### Optional — KB STD mirror (best-effort)

Look up the canonical STD by **tags** (not by literal id — `force_id` is reserved for PRJ/CMP/REL in the KB, so the entity id is server-generated). Well-known coordinate:

```
entity_query({
  entity_type: "STD",
  project_id: "KVD",
  tags_all: ["scope:claudemd", "scope:template"],
  status: "active",
  order_by: "updated_at_desc",
  limit: 1
})
```

- If 1 result → compare `metadata.manual_version` with the local file's version (drift detection in Step 3).
- If 0 results → degraded mode. Continue using the local file alone. Log INFO ("canonical KB mirror not found; using local plugin file"), do NOT block.
- If broker / MCP unreachable → same degraded mode, continue.

## Step 2 — Read the current CLAUDE.md

Read `<cwd>/CLAUDE.md` (or compute the workspace_root for the target project from `PRJ-<PROJECT_ID>.metadata.workspace_layout` if `<cwd>` is not the project root).

If the file does not exist: tell the user to run `/onboard-project <PROJECT_ID>` first. Do NOT auto-onboard from this skill.

Parse the file structure:
- Extract `<!-- manual_version: X.Y -->` from the first HTML comment.
- Extract everything between `<!-- KVENDRA:MANUAL -->` and `<!-- /KVENDRA:MANUAL -->` (current Manual section).
- Extract everything between `<!-- KVENDRA:PROJECT -->` and `<!-- /KVENDRA:PROJECT -->` (current Project section, including current `tier:` value).
- Extract everything from `## Particularidades` heading to EOF (current Particularidades section).

If any marker is missing: tell the user the file is not conformant — recommend running `/lint-claudemd` first.

## Step 3 — Detect drift

### manual_version drift
- Local `manual_version` < canonical from STD → warn the user **before** applying. Show the diff between local Manual and canonical Manual.
- Local `manual_version` == canonical → Manual section unchanged. No regen needed for that section (but Project + Particularidades may still need updates).
- Local `manual_version` > canonical → suspicious (downgrade). Show the version mismatch and ask the user how to proceed.

### tier drift
Call `whoami` and compare its `tier` with the CLAUDE.md `tier:` line.

- Match → keep as is.
- Mismatch → warn the user:
  - Common case: project downgraded from `pro` → `free` (subscription change). Ask if the user wants to update the flag.
  - Edge case: `whoami` says `pro` but CLAUDE.md says `free` → likely the user upgraded and forgot. Suggest updating.

The user has the final say. The skill does NOT silently change `tier:`.

## Step 4 — Render and decide

Render the canonical template with substitutions:
- `{{PROJECT_ID}}` → project_id (verified from the existing CLAUDE.md or PRJ.entity_id).
- `{{TIER}}` → tier resolved in Step 3 (with user's confirmation if drift detected).
- `{{PARTICULARITIES}}` → existing Particularidades section verbatim (or empty placeholder if `--force` is passed).

### `--dry-run` mode
Print a unified diff between the existing CLAUDE.md and the would-be regenerated version. Exit without writing. No KB writes either.

### Default mode (no flags)
1. If only Manual + Project sections changed (i.e., Particularidades preserved verbatim): write the new CLAUDE.md and report the diff.
2. If `--force` was NOT passed and Particularidades would be affected by the regen: STOP and ask the user. Default refusal — protect user data.

### `--force` mode
Replace the entire file with the rendered template. Particularidades becomes empty (placeholder). DESTRUCTIVE — confirm one more time with the user before writing.

## Step 5 — Post-write verification

After writing, run the same checks `lint-claudemd` would run on the new file:
- Total line count ≤40 (NFR-CLAUDEMD-1).
- 3 sections present with markers.
- `manual_version` matches canonical.
- `tier` is valid enum.

If any check fails, the regen produced a malformed file. STOP and recommend rollback via `git checkout -- CLAUDE.md` (the user is expected to have committed before running this skill).

## Output

```
## sync-claudemd: <PROJECT_ID>

### Source of canonical template
STD-KVD-CLAUDEMD-TEMPLATE  manual_version: <canonical>

### Drift detected
- manual_version: <local> → <canonical>  (<no-drift|upgrade|downgrade|warning>)
- tier:            <local> → <whoami>     (<no-drift|change-confirmed|change-declined>)

### Diff (unified, --dry-run if applicable)
<diff>

### Result
<written | dry-run-only | aborted-by-user | failed-verification>

### Post-write verification
- Lines: <N> (≤40 target)
- 3 sections: <present|missing>
- manual_version: <X.Y>
- tier: <free|pro|team|enterprise>
- Particularidades: preserved

### Next steps
- Commit the regenerated CLAUDE.md if it's the intended result.
- Run /lint-claudemd to double-check conformance.
- If the regen revealed drift in canonical Manual content, take note — the project's onboarding model has evolved and may apply to other projects too.
```

## Step 6 — Materialise `.kvendra-protected` (broker policy)

This step runs in the default mode (no flags) AND in `--policy-only` mode. In `--policy-only` mode, Steps 1-5 (CLAUDE.md side) are skipped.

### Step 6.1 — Read the canonical broker-policy STD

Use **tag-based discovery** (per `PAT-KVD-577667`) — `force_id` only applies to PRJ/CMP/REL:

```
entity_query({
  entity_type: "STD",
  project_id: "<PROJECT>",
  tags_all: ["scope:broker-policy", "playbook_type:broker-policy"],
  status: "active",
  order_by: "updated_at_desc",
  limit: 1
})
```

- **0 results** → **FAIL-SAFE** per `ADR-KVD-SKILLS-BB0E8A`. STOP and surface the canonical message:

  > *"No `STD-<PROJECT>-BROKER-POLICY` exists. Run `/onboard-project` if this is a new project, or `/requirements-analyst` to define one."*

  No improvisation, no inlined default policy.

- **1 result** → continue. Record the STD's `entity_id` (will be written verbatim as `std_id` in the YAML payload) and `version` (will be written as `synced_version`).

- **>1 results** → pick `[0]` (most recent), surface a WARNING and recommend archiving older duplicates.

### Step 6.2 — Optionally merge a CMP-level override

If a component context is in scope (cwd inside a known `CMP.metadata.workspace_subdir`), also query:

```
entity_query({
  entity_type: "STD",
  project_id: "<PROJECT>",
  component_id: "<PROJECT>-<COMP>",
  tags_all: ["scope:broker-policy"],
  status: "active",
  order_by: "updated_at_desc",
  limit: 1
})
```

- If present, merge **additively** into the PROJ STD: CMP overrides MAY add new `block_bash` regex / `require_broker` entries; they MAY NOT remove or weaken PROJ-level entries.
- Track the merged STD ids in `cmp_overrides_applied[]` of the YAML provenance block.

### Step 6.3 — Render the YAML payload

Extract from the STD `content` the canonical YAML block under `## Steps` step 3 (the payload inside the fenced ```yaml … ``` block). Substitute provenance:

- `schema_version` ← `STD.metadata.schema_version` (or `1` default).
- `std_id` ← STD's `entity_id`.
- `synced_version` ← STD's `version` field.
- `synced_at` ← current ISO8601 UTC timestamp.
- `synced_by` ← `"skill:sync-claudemd"`.
- `cmp_overrides_applied` ← list of CMP STD ids merged in Step 6.2.
- `checksum` ← `sha256` hex of the canonical YAML body (everything below the provenance block, i.e. starting from `mode:`).

### Step 6.3b — Pin the break-glass pubkey (IF-840EE9 1.0 → 1.1)

The broker policy schema is extended **additively** with an optional
`break_glass:` mapping (IF-KVD-SKILLS-BROKER-POLICY `1.0 → 1.1`). This is a
purely additive block — **the `schema_version` field of `.kvendra-protected`
is NOT bumped** (it stays `1`); hook v2 reads `break_glass` when present and
ignores it when absent, so old and new files remain mutually compatible
(NFR-COMPAT-1).

A project **opts into break-glass** when its `STD-<PROJECT>-BROKER-POLICY`
declares `break_glass.enabled: true` in its canonical YAML payload (Step 6.3),
OR when the operator passes `--enable-break-glass` to this skill. If the
project does NOT opt in, skip this sub-step entirely and write the file with
no `break_glass:` block (byte-for-byte identical to the pre-1.1 output).

When the project opts in:

1. Obtain the local grant-signing **public** key (auth-less, no vault unlock,
   no master password):

   ```
   kvendra grant-pubkey
   ```

   - Stdout is the base64 ed25519 public key (44 chars). This is the key the
     hook pins and the CLI's `verify-grant` checks signatures against.
   - If `kvendra` is **not on PATH** → WARN and write the file with
     `break_glass.enabled: false` and an empty `pubkey_ed25519`. Do NOT block
     the whole sync; the hook fail-closes on a missing/empty pubkey anyway.
   - If `kvendra grant-pubkey` errors with *"no grant signing key — run
     `kvendra bypass …` once to generate it"*: the signing keypair has not been
     created yet. Surface that message to the operator (they must run a
     `kvendra bypass` once, from their own terminal, to generate it), and write
     `enabled: true` with an empty `pubkey_ed25519` so the hook fail-closes
     until the key exists. Re-run `/sync-claudemd --policy-only` after the first
     bypass to fill in the pubkey.

2. Populate the `break_glass:` block in the rendered YAML payload:

   ```yaml
   break_glass:
     enabled: true
     pubkey_ed25519: "<output of kvendra grant-pubkey>"
     grant_path: ".kvendra-grant"   # informational; the CLI resolves the
                                     # active grant from the local session.
   ```

   Place the block as a top-level mapping (siblings: `mode`, `block_bash`,
   `allow_bash`, `require_broker`). Keep `enabled` a bare YAML bool
   (`true`/`false`), `pubkey_ed25519` a double-quoted string.

3. **Idempotency**: pinning the pubkey is idempotent — `kvendra grant-pubkey`
   returns the same key across runs (it only changes if the operator runs
   `kvendra bypass --rotate-key`). Re-running the skill with an unchanged key
   produces no diff.

4. **Recompute the `checksum`** (Step 6.3) over the canonical YAML body
   INCLUDING the newly added `break_glass:` block, so Step 6.4's idempotency
   check stays accurate. The `break_glass` block is part of the body hashed by
   the checksum (everything from `mode:` down).

> Schema-change record (IF-KVD-SKILLS-BROKER-POLICY): version `1.0 → 1.1`,
> additive `break_glass: { enabled: bool, pubkey_ed25519: string, grant_path:
> string? }`. `schema_version` (file field) stays `1`. Consumers that predate
> 1.1 ignore the block; hook v2 honours it. Documented here per the change to
> ISSUE-KVD-SKILLS-924CAF.

### Step 6.4 — Idempotency check

Read existing `.kvendra-protected` if present. If:
- local `schema_version` == new `schema_version`, AND
- local `synced_version` == new `synced_version`, AND
- local `checksum` recomputes to itself (file body matches),

then **NO write** is performed (no-op). Report `policy: no-op (up to date)`.

### Step 6.5 — Validate the YAML payload before writing

- `mode` must be one of `strict|permissive|hybrid`.
- `block_bash`, `allow_bash`, `require_broker` must be arrays (possibly empty).
- Every regex in `block_bash` / `allow_bash` / `require_broker[].op_pattern` must compile under `grep -E` without error. Validate each pattern individually; on first failure, STOP and surface the offending pattern.
- `require_broker[].primitive` must be one of `kvendra.git|kvendra.github|kvendra.aws|kvendra.npm|kvendra.pypi|kvendra.http|kvendra.shell`.
- If a `break_glass:` block is present (IF-840EE9 1.1): `enabled` must be a bool; when `enabled: true`, `pubkey_ed25519` must be a non-empty base64 string (44 chars for ed25519) OR explicitly empty only in the deferred-key case of Step 6.3b (hook fail-closes on empty). `grant_path` is an optional string.

If any validation fails, STOP — do NOT write a broken policy file.

### Step 6.6 — Write `.kvendra-protected`

Write the YAML payload to the **workspace root** (resolved from `PRJ.metadata.workspace_layout` + `<cwd>`). Preserve the canonical header comment:

```
# synced from <std_id> (do not edit by hand — run /sync-claudemd --policy-only)
```

The file is rewritten atomically: write to `.kvendra-protected.new`, then `mv` over the existing one.

### Step 6.7 — Fail-safe

If the KB query in 6.1 errors (broker / MCP unreachable): STOP with the canonical message *"El entorno Kvendra no está disponible. Reconecta antes de avanzar — operar sin Kvendra rompe más de lo que arregla."*. Do NOT fall back to a hardcoded policy in this skill — the hook v2 has its own transition fallback for legacy markers. <!-- lint-allow-es -->

## Operational rules

- The skill is **idempotent**: running it twice in a row without intervening changes produces no diff (CLAUDE.md unchanged AND `.kvendra-protected` no-op per Step 6.4).
- The skill is **read-write-local-only**: it does NOT touch the KB. NO TXN required, NO entity_create/update.
- The skill is **dual-mode**: works identically against `kvendra-platform` local (tier:free) and `kvendra-cloud` Enterprise (tier:pro+).
- The skill respects **AC-CLAUDEMD-8 (Manual immutable from project content)**: it never injects project-specific IDs into the Manual section. Only generic placeholders.
- The `--policy-only` flag is the canonical surface for re-syncing `.kvendra-protected` independently of CLAUDE.md drift.
