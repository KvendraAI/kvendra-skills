---
name: lint-claudemd
description: Verify a project's CLAUDE.md conforms to the canonical template — sections present, markers correct, manual_version + tier valid, project_id exists in KB. Warns on entity-ID drift smell.
user_invocable: true
args: "[<path> (optional, defaults to <cwd>/CLAUDE.md)]"
---

# Lint CLAUDE.md v1 — Verify conformance

Verifies that a project's `CLAUDE.md` conforms to the canonical tripartite model (per REQ-KVD-SKILLS-50F9E4 AC-CLAUDEMD-7). Reports structural defects (missing sections, broken markers, invalid tier) and **drift smells** (entity IDs in the Manual section, manual_version mismatch).

The skill is **read-only**: it does NOT modify files, does NOT touch the KB beyond verifying the project_id exists.

<!-- kvendra:kb-server v1 -->
## Kvendra server (canonical block — edit it in every carrier or in none)

Engine calls in this skill use the bare tool name (`entity_get(...)`, `txn_create(...)`). Your client adds its own prefix: call the tool of that name on the Kvendra server, the MCP server that exposes `whoami`, `help` and `entity_get`, whatever its name (`mcp__plugin_kvendra-skills_kvendra-cloud__*` from this plugin, `mcp__claude_ai_<connector>__*` from a claude.ai connector, `mcp__<name>__*` from `claude mcp add`, no prefix in other clients). Load its tools first if they are deferred. The local broker `kvendra` (`kvendra_git`, `kvendra_aws`…) is not the Kvendra server. If more than one server exposes them (for example the plugin server with a directory's `KVENDRA_WS` and a claude.ai connector on the default account), use the plugin server: it carries this directory's account. Without the plugin server, ask the user which one to use. Never mix two Kvendra servers in one task. If no server exposes those three tools, stop and tell the user the Kvendra environment is not available.
<!-- /kvendra:kb-server -->

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
- `## Particulars` heading (anywhere after the Project closing marker — section content can be empty). The legacy Spanish heading `## Particularidades` is an accepted variant for existing projects: report it as OK, never as drift. <!-- lint-allow-es -->

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

### Fail-safe canonical message (language)
The Manual section's `Canonical message:` line is the one line a project may
localise. Compare its meaning, never its language:
- The English template text (*"The Kvendra environment is not available.
  Reconnect before going on — working without Kvendra breaks more than it
  fixes."*) → OK.
- The same message in the project's own language (for example the Spanish
  variant, see `sync-claudemd` Step 2) → OK. Never report a localised message
  as drift or as a Manual edit.
- Line missing → WARNING ("fail-safe canonical message missing — run
  `/sync-claudemd`").

### Size smell
- File > 40 lines → WARNING ("CLAUDE.md exceeds canonical target — particularities inflation or markdown bloat. Consider extracting content to KB entities.").

## Step 7 — Validate Particularidades section

The Particulars section (legacy heading `## Particularidades`) is free-form by design. Validate only: <!-- lint-allow-es -->
- Section exists with an accepted heading: `## Particulars` (template) or `## Particularidades` (legacy, OK). <!-- lint-allow-es -->
- Content is NOT empty (if empty, INFO — "no particularidades; consider documenting any cross-cutting facts").

## Step 8 — Private-value references

A `CLAUDE.md` may contain private-value references (`{{cfg:<key>}}`): the
generating skills keep them unresolved on purpose, and the user resolves them
according to their role with `private_value_resolve` or the Kvendra dashboard.
A reference is never a defect, and this skill never resolves one.

- Scan for unescaped references: `{{cfg:` + a concrete key (grammar
  `[a-z0-9][a-z0-9._-]{0,127}`) + `}}`, not preceded by a backslash. The
  generic `{{cfg:<key>}}` inside the note itself does not count.
- None → OK.
- Found, and the `<!-- kvendra:private-refs … -->` note is present → INFO,
  listing the keys (never their values).
- Found, but the note is missing → WARNING ("file contains private-value
  references without the private-refs note — run `/sync-claudemd`").
- Note present but no reference left → INFO ("stale private-refs note").
- Local references (`{{lvr:<key>}}`, same key grammar, not preceded by a
  backslash) are per-machine values the `kvendra` broker substitutes from the
  owner's local vault. They are never a defect and need no note → INFO,
  listing the keys (this skill cannot read a value, and never tries).
- A literal home path (`/Users/<name>/…`, `/home/<name>/…`) → WARNING
  ("machine-specific path: use `~/`, a path relative to the workspace marker,
  or a `{{lvr:<key>}}` if the broker consumes it").

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
- Fail-safe message:              ✅ template (EN) | ✅ localised | ⚠️ missing

### Particulars
- Section present:               ✅ Particulars | ✅ Particularidades (legacy) <!-- lint-allow-es -->
- Has content:                   ✅ | ℹ️ empty

### Private values
- References:                    ✅ none | ℹ️ <N> kept (keys: <list>) | ⚠️ note missing
- Local references:              ✅ none | ℹ️ <N> (keys: <list>)
- Literal home paths:            ✅ none | ⚠️ <N> (lines: <list>)

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
