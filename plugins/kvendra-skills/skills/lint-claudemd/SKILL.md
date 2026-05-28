---
name: lint-claudemd
description: Verify a project's CLAUDE.md conforms to the canonical template — sections present, markers correct, manual_version + tier valid, project_id exists in KB. Warns on entity-ID drift smell.
user_invocable: true
args: "[<path> (optional, defaults to <cwd>/CLAUDE.md)]"
---

# Lint CLAUDE.md v1 — Verify conformance

Verifies that a project's `CLAUDE.md` conforms to the canonical tripartite model (per REQ-KVD-SKILLS-50F9E4 AC-CLAUDEMD-7). Reports structural defects (missing sections, broken markers, invalid tier) and **drift smells** (entity IDs in the Manual section, manual_version mismatch).

The skill is **read-only**: it does NOT modify files, does NOT touch the KB beyond verifying the project_id exists.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Input

`$ARGUMENTS` may be:
- `<path>` → absolute or relative path to the CLAUDE.md to lint.
- Empty → defaults to `<cwd>/CLAUDE.md`.

## Step 0 — Initialization

If the MCP is unreachable, the project_id existence check (Step 5) is skipped with a warning, but structural checks still run. Lint is degraded but still useful — DO NOT STOP on broker absence for this skill (read-only, low blast radius).

## Step 1 — Read the file

Read the file. If it doesn't exist or is empty: fail with a clear message ("CLAUDE.md missing — run `/onboard-project <PROJECT_ID>` to bootstrap").

## Step 2 — Check three sections present

Required markers (case-sensitive):
- `<!-- manual_version: ` line (must be present somewhere in the file, conventionally line 1).
- `<!-- KVENDRA:MANUAL -->` and `<!-- /KVENDRA:MANUAL -->` (pair, in order).
- `<!-- KVENDRA:PROJECT -->` and `<!-- /KVENDRA:PROJECT -->` (pair, in order, AFTER Manual).
- `## Particularidades` heading (anywhere after the Project closing marker — section content can be empty).

Missing or mis-ordered markers → ERROR with the specific defect.

## Step 3 — Validate manual_version

Extract the version string from `<!-- manual_version: X.Y -->`.

- Must match regex `^\d+\.\d+$`. Otherwise ERROR.

Compare against the canonical version. The canonical source is the **plugin's bundled `CLAUDE.md.template`** at `<plugin-root>/CLAUDE.md.template` (read its first HTML comment for `manual_version`). The KB STD entity is an optional mirror.

- Local file (in workspace) `manual_version` == plugin template `manual_version` → OK.
- Local < plugin → WARNING ("canonical template has evolved — run `/sync-claudemd` to upgrade").
- Local > plugin → ERROR (shouldn't happen; suggests local edits to the marker — Manual is meant to be regenerated, not hand-edited).

### Optional — KB STD mirror cross-check (best-effort)

Look up the canonical STD by **tags** (not literal id — `force_id` is reserved for PRJ/CMP/REL, the entity id is server-generated):

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

- If 1 result and its `metadata.manual_version` matches the plugin file → OK.
- If 1 result but version differs from plugin file → INFO ("KB mirror is out of sync with plugin distribution — usually means the plugin was just updated and the KB mirror update is pending").
- If 0 results / broker offline → INFO ("KB mirror not found; lint uses plugin file as canonical"). NOT an error — local plugin file is the canonical source by design.

## Step 4 — Validate Project section

Extract the Project section content (between the markers). Parse:

- `project_id` line must match `^- \`project_id\`: \*\*[A-Z]{3,6}\*\*$`. Otherwise ERROR.
- `tier` line must match `^- \`tier\`: \*\*(free|pro|team|enterprise)\*\*$`. Otherwise ERROR.

Optionally, run `whoami` and compare its `tier` with the declared one — report mismatch as INFO (not an error; the user may have intentionally overridden it).

## Step 5 — Verify project_id exists in KB

```
entity_get({ entity_id: "PRJ-<PROJECT_ID>" })
```

- Found, status active → OK.
- Not found → ERROR ("declared project_id has no PRJ entity in the KB — typo, missing onboard, or wrong tier flag pointing at the wrong KB?").
- Found but archived → WARNING.
- MCP unreachable → INFO ("project_id existence not verified — broker offline").

## Step 6 — Drift smells in Manual section

Extract the Manual section content (between the markers). Apply heuristics for "drift toward logbook":

### Entity-ID smell
Scan for substrings that look like Kvendra entity IDs:
- Regex: `\b(REQ|ISSUE|REL|TXN|ROAD|ADR|PAT|CMP|STD|TEST|REG|SLA|GLO|RUN|UX|DOC|ENV|COST|CFG|IF|PRJ)-[A-Z0-9-]+\b`
- Exception: the literal `PRJ-{{PROJECT_ID}}` placeholder is OK (canonical template).
- Other matches → WARNING ("Manual section references specific entity IDs — should be regenerated from canonical template").

### Hardcoded tech-specific commands smell
Scan for known infra commands (sub-skill drift):
- Regex: `\b(aws |sam |cargo |npm publish|docker run|cloudfront )\b`
- Matches → INFO ("Manual section contains tech-specific commands — these should live in STD playbooks per ADR-KVD-SKILLS-BB0E8A").

### Size smell
- File > 40 lines → WARNING ("CLAUDE.md exceeds canonical target — particularities inflation or markdown bloat. Consider extracting content to KB entities.").

## Step 7 — Validate Particularidades section

The Particularidades section is free-form by design. Validate only:
- Section exists with the correct heading.
- Content is NOT empty (if empty, INFO — "no particularidades; consider documenting any cross-cutting facts").

## Output

```
## lint-claudemd: <path>

### Result
<PASS | WARN | ERROR>

### Structure
- 3 sections present:           ✅ | ❌ (<defect>)
- Markers correctly paired:     ✅ | ❌ (<defect>)
- manual_version: <X.Y>          ✅ | ❌ (<defect>)

### Project section
- project_id: <PROJECT_ID>       ✅ | ❌
- tier:       <tier>             ✅ | ❌
- whoami match:                  ✅ | ⚠️ (<local> vs <whoami>) | (skipped — broker offline)
- PRJ entity exists in KB:       ✅ | ⚠️ archived | ❌ not found | (skipped)

### Manual immutability checks
- No specific entity IDs:         ✅ | ⚠️ found <list>
- No tech-specific commands:      ✅ | ℹ️ found <list>
- Size ≤40 lines:                 ✅ <N> | ⚠️ <N> exceeds target

### Particularidades
- Section present:               ✅
- Has content:                   ✅ | ℹ️ empty

### Findings detail
<one bullet per finding with line number if applicable>

### Recommendations
- <action if any>
```

## Exit code semantics

- ERROR → at least one structural defect that breaks the model (missing markers, invalid tier, project_id not found). Skill should "fail" loudly so CI can integrate.
- WARN → drift smell, size exceeded, or recoverable inconsistency. Skill returns OK output but flags the warning.
- PASS → fully conformant.

## Operational rules

- **Read-only**: never modifies the file under inspection or any KB entity.
- **Degraded-mode tolerant**: most checks work without a live MCP. Only Step 5 (PRJ existence) is skipped when broker offline — flagged as INFO.
- **Idempotent**: same input → same output.
- **Composable**: can be invoked by `env-check` as part of a broader environment audit.
