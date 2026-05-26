---
name: deploy
description: Deploy a Kvendra component (e.g. CMP-KVD-WEB, CMP-KVD-ENTERPRISE) by executing the canonical deploy playbook from the KB. Generic, model-agnostic, STD-driven — no tech specifics in this skill.
user_invocable: true
args: "<CMP-id or component-code>  e.g. /deploy CMP-KVD-WEB  or  /deploy enterprise"
---

# Deploy v1 — Generic STD-driven deploy orchestrator

Deploys a Kvendra component by reading its canonical deploy playbook (`STD-<PROJECT>-<COMPONENT>-DEPLOY-PROCESS`) from the KB and executing its steps via broker primitives. This skill is **thin and generic** — all tech-specific recipes (npm, sam, aws s3, cloudfront, etc.) live in the STD entity per `ADR-KVD-SKILLS-BB0E8A`. Discovery is tag-based per `PAT-KVD-577667` (no hardcoded entity ids).

The same skill orchestrates a `CMP-KVD-WEB` deploy or a `CMP-KVD-ENTERPRISE` staging deploy — what changes is the STD playbook the skill reads, not the skill itself. To onboard a new deployable component: create its `STD-<PROJECT>-<COMP>-DEPLOY-PROCESS` entity in the KB; this skill picks it up automatically next time.

## Input

`$ARGUMENTS` may be:
- A full CMP id (e.g. `CMP-KVD-WEB`) — preferred, unambiguous.
- A short component code (e.g. `WEB`, `ENTERPRISE`) — the skill resolves it against the current project's `PRJ.metadata` or asks for clarification.
- Empty → interactive mode (list deployable components from the project + let the user pick).

## Step 0 — Initialization + fail-safe

1. Resolve `project_id` + current `tier` from `<cwd>/CLAUDE.md` (per the canonical bootstrap protocol).
2. Verify the MCP for the project's tier responds. If `kvendra-cloud` (or Platform local for tier:free) is unreachable: STOP and surface the canonical fail-safe message per `PAT-KVD-2CBB6D` L3. NO Bash fallback for the deploy itself.
3. Verify the broker `kvendra` is connected (`mcp__kvendra__*` tools listed). If not: STOP — the deploy requires broker primitives for AWS/git/shell ops. Tell the user to reconnect.

## Kvendra rules (summary)

- Identify in every write: `updated_by: "skill:deploy"`. The MCP client adds `X-Kvendra-Skill` automatically.
- This skill does NOT open a TXN by default — a deploy is a runtime operation, not a structural change. Optional: open a TXN if the playbook itself creates KB entities (rare; only some `STD-*-DEPLOY-PROCESS` variants do this).
- On any error with `error.help.topic`: call `help({topic})`.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Step 1 — Resolve target component

Parse `$ARGUMENTS`:
- If it's a full CMP id: verify it exists via `entity_get`. If not found: STOP and ask the user.
- If it's a short code: combine with the resolved `project_id` from Step 0 → construct `CMP-<PROJECT>-<CODE>` and verify.
- If empty: list deployable components (those with a `STD-*-DEPLOY-PROCESS` entity in the KB — see Step 2 discovery) and let the user pick.

## Step 2 — Discover the canonical deploy playbook

Use **tag-based discovery** (NOT literal id lookup) per `PAT-KVD-577667`:

```
entity_query({
  entity_type: "STD",
  project_id: "<PROJECT>",
  component_id: "<PROJECT>-<COMP>",
  tags_all: ["scope:deploy", "scope:process"],
  status: "active",
  order_by: "updated_at_desc",
  limit: 1
})
```

- **1 result**: continue with that playbook.
- **0 results**: **FAIL-SAFE per `ADR-KVD-SKILLS-BB0E8A`**. Do NOT improvise the deploy steps from memory. Tell the user:

  > *"No `STD-<PROJECT>-<COMP>-DEPLOY-PROCESS` exists in the KB for `CMP-<PROJECT>-<COMP>`. I cannot deploy without an explicit playbook. Define it with `/requirements-analyst` or create the STD entity manually, then re-run me."*

- **>1 results** (duplicates): pick `[0]` (most recent), surface a WARNING that duplicates exist + recommend archiving the older ones.

If the broker side allows it, optionally also fetch via the existing well-known canonical (e.g., when running cross-project) — but the project-scoped query above is the primary source of truth.

## Step 3 — Parse the playbook + check pre-conditions

Extract from the STD entity:
- `content` → the markdown sections (Purpose, Pre-conditions, Steps, Post-conditions, Variables, Validation, Rollback).
- `metadata`:
  - `playbook_type` (should be `"deploy"`).
  - `autonomous` (boolean — does the playbook authorize end-to-end without per-step confirmation?).
  - `requires_confirmation` (array of step ids that need explicit user confirmation, if any).
  - `vault_profile_required` (the broker profile needed for `kvendra.*` calls).
  - `estimated_duration_minutes` (informational).

Verify pre-conditions:
- Vault profile referenced by `metadata.vault_profile_required` exists (best-effort check — the broker enforces strictly at call time).
- The cwd is the expected workspace_subdir of the target CMP (per `CMP.metadata.workspace_subdir`). If not, change cwd or warn the user.
- If `metadata.autonomous: false` → ask the user for explicit go-ahead before continuing.

## Step 4 — Substitute variables

Read the `## Variables` table from the playbook content. Each row has `{NAME}` placeholder → value. Build a substitution map.

Walk the `## Steps` content and substitute every `{VAR}` placeholder with its value. Surface the substituted command(s) to the user **before** executing each one if `autonomous: false` or if any step is in `requires_confirmation`.

## Step 5 — Execute steps sequentially

For each step in `## Steps` (in order):

1. Identify the primitive needed (per the inline reference in the step):
   - "`kvendra.aws operation: s3_sync`" → call `mcp__kvendra__kvendra_aws` with the right args.
   - "`kvendra.shell exec`" → call `mcp__kvendra__kvendra_shell` with `binary` + `argv` + `accept_destructive: true`.
   - "`kvendra.git commit/push`" → call `mcp__kvendra__kvendra_git`.
   - `npm run build`, `cargo test`, etc. — Bash direct OK (no credentials).
2. Pass the substituted command + args + the `vault_profile_required` profile_id.
3. Capture exit code + stdout/stderr.
4. **Check expected output**: match against the playbook's "Expected output" line (substring match acceptable).
5. **On failure**: surface the playbook's "Failure mode" guidance + STOP. Do NOT continue subsequent steps. Do NOT roll back automatically — the playbook's `## Rollback` section documents the manual recovery path.
6. **On success**: continue to the next step.

Stream progress to the user (one line per step start + one line per completion).

## Step 6 — Post-write verification

After all steps complete:
1. Walk the `## Post-conditions` section. Each item is a verifiable check (e.g., "stack reaches UPDATE_COMPLETE", "curl returns HTTP 200").
2. Execute the check via read-only Bash or the appropriate primitive.
3. Report ✅ or ❌ per check.

## Step 7 — Optional: validate via the canonical Validation section

The `## Validation` section in the playbook lists smoke tests. Run them if `autonomous: true`, or ask the user.

## Output

```
## deploy: <CMP id>

### Playbook
<STD-id>  (tags: scope:deploy, scope:process, cmp:<CODE>)
manual_version: <not applicable — playbook entity, not template>
autonomous: <true|false>
estimated_duration: <N> min

### Pre-conditions
- <line per check>: ✅ | ❌

### Steps executed
1. <step name>: ✅ <durationMs>ms  | ❌ <error>
2. ...
N. <step name>: ✅ <durationMs>ms

### Post-conditions
- <line per check>: ✅ | ❌

### Validation (canonical smoke)
- <line per check>: ✅ | ❌  | (skipped — interactive mode)

### Result
<SUCCESS | FAILED at step <N> | ROLLED BACK | ABORTED BY USER>

### Total duration
<N> minutes

### Next steps
- <if SUCCESS>: deploy complete. Consider tagging the release if it's a stable version.
- <if FAILED>: see Failure mode of step <N> in <STD-id>. Manual recovery may be needed.
- <if rollback>: instructions from playbook's `## Rollback` section.
```

## Fail-safe rules (cross-cutting)

- **No improvisation**: every command is from the playbook, not the agent's memory.
- **STD missing**: STOP. NO partial deploy with guessed steps.
- **MCP / broker offline**: STOP per `PAT-KVD-2CBB6D` L3.
- **NO `--force` / `--no-verify`** unless explicitly in the playbook.
- **Production guard**: if any step references a production environment AND `autonomous: false` is set for that step, ALWAYS ask the user before executing.
- **Post-failure state**: leave the system in the state where it failed. Do not "try to recover" autonomously — surface to user with the playbook's Rollback section.

## Operational notes

- The skill is **idempotent** in spirit: re-running it after a failed step (after the user fixes the issue) should pick up correctly. The playbook's Pre-conditions section is checked at every invocation.
- The skill is **dual-mode**: works in cloud (tier:pro+, MCP `kvendra-cloud`) and local (tier:free, MCP Platform). The STD lookup uses the project's KB regardless.
- The skill is **modeloagnostic**: no LLM-specific assumptions. Any LLM that Claude Code supports can run it.
- The skill **does NOT publish** to public registries (`cargo publish`, `npm publish`, `pypi upload`) — those are explicit NO-GO per `STD-KVD-57DAE1` and require owner-only manual execution. <!-- lint-allow-tech -->

