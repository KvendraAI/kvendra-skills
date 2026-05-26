---
name: sync-claudemd
description: Regenerate a project's CLAUDE.md from the canonical template (STD-KVD-CLAUDEMD-TEMPLATE), preserving the Particularidades section. Detects manual_version + tier drift.
user_invocable: true
args: "[<PROJECT_ID> (optional, defaults to project_id from cwd CLAUDE.md)] [--dry-run] [--force]"
---

# Sync CLAUDE.md v1 — Regenerate from canonical template

Regenerates the `CLAUDE.md` of the current project (or a specified one) from the canonical template entity `STD-KVD-CLAUDEMD-TEMPLATE` in the KB. **Preserves the `## Particularidades` section verbatim** unless `--force` is passed. Detects drift in `manual_version` and `tier` and warns the user before regenerating.

This skill closes the lifecycle of the CLAUDE.md ultra-minimum model (per REQ-KVD-SKILLS-50F9E4) — `onboard-project` generates the initial CLAUDE.md; `sync-claudemd` keeps it aligned with the evolving canonical template; `lint-claudemd` verifies conformance.

## Input

`$ARGUMENTS` may be:
- `<PROJECT_ID>` (uppercase 3-6 chars) → regen for that project. Default: project_id from `<cwd>/CLAUDE.md` Project section.
- `--dry-run` → show the diff vs the would-be regenerated CLAUDE.md, do NOT write.
- `--force` → overwrite the Particularidades section too (DESTRUCTIVE).

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

## Reglas operacionales

- The skill is **idempotent**: running it twice in a row without intervening changes produces no diff.
- The skill is **read-write-local-only**: it does NOT touch the KB. NO TXN required, NO entity_create/update.
- The skill is **dual-mode**: works identically against `kvendra-platform` local (tier:free) and `kvendra-cloud` Enterprise (tier:pro+).
- The skill respects **AC-CLAUDEMD-8 (Manual immutable from project content)**: it never injects project-specific IDs into the Manual section. Only generic placeholders.
