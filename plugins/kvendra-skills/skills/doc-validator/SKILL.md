---
name: doc-validator
description: Documentation validator — verifies format, form and content of manuals (web + PDF) across all locales, with Kvendra KB context
user_invocable: false
args: "[optional manual-id + optional level: quick|complete|exhaustive]"
---

# Doc Validator — Integral documentation auditor

You act as a **Senior Documentation Auditor**. You verify that a project's
manuals are correct in **format** (structure), **form** (web and PDF
rendering) and **content** (consistency across locales). Subagent — does
NOT open a TXN.

## Validation scope

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

## Note on doc-portal conventions

The file conventions checked below (`info.json` schema, `index.json` schema,
`sections/<locale>/` layout, `/manuals/{manual-id}/assets/...` URL paths,
`localhost:3000` dev server, `npm run dev`, `public/pdfs/{manual-id}-{locale}.pdf`
naming) are the canonical conventions of the kvendra doc-portal stack. When
a project formalises its doc-portal as a CMP in the Kvendra KB, the
authoritative recipe should live in
`STD-<DOC_PROJECT>-DOC-PORTAL-FORMAT` per ADR-KVD-SKILLS-BB0E8A. Until then,
this skill uses these conventions as defaults — adapt to the actual project
layout if it differs.

## Step 1 — Load Kvendra context

1. **CMP of the doc-portal (workspace paths):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<DOC-PROJECT>, tags_all:["CMP-<DOC-PROJECT>-WEB"] })`
   (When `<DOC-PROJECT>` is not yet formalised in the KB, fall back to the
   project's own CMP plus the conventions described above.)

2. **Indexed DOC entries (content reference):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"DOC", project_id:<PROJ>, limit:100 })`

3. **Dev ENV (server URL):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ENV", project_id:<PROJ>, tags_all:["env:dev"] })`

## Step 2 — Determine scope and level

If the arguments specify `manual-id`, validate only that manual. Otherwise,
validate **all** doc-portal manuals.

Locate the manuals in:
- **Source**: `<workspace>/<doc-portal-root>/manuals/`
- **Public**: `<workspace>/<doc-portal-root>/public/manuals/`
- **PDFs**: `<workspace>/<doc-portal-root>/public/pdfs/`

Read the doc-portal's client module (e.g. `src/lib/manuals-client.ts`) to
obtain the registered `manualIds`.

Levels:
| Level | What it validates | Server required |
|-------|-------------------|-----------------|
| **quick** | Format only (files and static content) | No |
| **complete** | Format + form (web rendering via Playwright) | Yes (`npm run dev`) |
| **exhaustive** | Format + form + content consistency across locales | Yes |

Default: `complete`.

## Step 3 — FORMAT validation (all levels)

For each manual in the inventory:

### 3.1 Mandatory files (base)
- `info.json`: fields `id`, `title`, `description`, `category`, `version`, `locale`, `availableLocales`.
- `index.json`: JSON array with sections `id`, `title`, `order`, `file`.
- `sections/` directory.

### 3.2 Per-locale files
For each locale ≠ base:
- `info.{locale}.json` and `index.{locale}.json` valid.
- `sections/{locale}/` exists.
- Every section referenced in `index.{locale}.json` has its `.md`.

### 3.3 Section ↔ file correspondence
- Every `file` in `index.json` exists on disk.
- Inverse: every `.md` in `sections/` is referenced.
- Same sections (by `id` and `order`) across locales.

### 3.4 Image paths
- Absolute: `/manuals/{manual-id}/assets/screenshots/...`. NEVER relative.
- Referenced image exists in `public/manuals/{manual-id}/assets/screenshots/`.

### 3.5 Example formatting
- Structured-data examples use blockquotes (`> **Field**:`), NOT code blocks.
- Code blocks only for: commands, source code, URLs, JSON/YAML, Mermaid.

### 3.6 Mermaid diagrams
- Correct closing `\`\`\``.
- Valid type: `flowchart`, `graph`, `sequenceDiagram`, `erDiagram`, `stateDiagram-v2`, `pie`, `gantt`, `classDiagram`.

### 3.7 PDFs
- `public/pdfs/{manual-id}-{locale}.pdf` exists and > 0 bytes.

### 3.8 Publication in public/
- `public/manuals/{manual-id}/` exists.
- `public/manuals/index.json` contains the manual-id.
- Manual-id in the `manualIds` array of the client module.

### 3.9 Content without TODOs
- Search for: `TODO`, `FIXME`, `XXX`, `PENDING`, `[PLACEHOLDER]`, `Lorem ipsum`.

## Step 4 — FORM validation via Playwright (complete / exhaustive)

Verify `http://localhost:3000` responds. If not, complete format only and
inform the user.

### 4.1 Manual library
Navigate to `http://localhost:3000`, take a snapshot, verify that ALL the
inventory manuals appear.

### 4.2 Manual load per locale
For each manual and each locale: navigate to
`http://localhost:3000/{locale}/manual/{manual-id}/`, verify title, sidebar,
content, no 404 errors in the console.

### 4.3 Navigation
Click 3 different sections, verify content changes. next/prev buttons work.
Page counter correct.

### 4.4 Table rendering
Tables render as `<table>`, not as text with `|`.

### 4.5 Mermaid rendering
There is rendered SVG or "Click to enlarge", not raw `flowchart TD` text.

### 4.6 Images
No broken images (`browser_evaluate` to detect `naturalWidth === 0`).

### 4.7 Language selector
Switch between locales and verify URL and content update.

### 4.8 PDF download
Button visible, HEAD fetch to `/pdfs/{manual-id}-{locale}.pdf` returns 200.

## Step 5 — CONTENT validation across locales (exhaustive)

### 5.1 Structural parity
Compare counts of headings, lists, tables, diagrams, images between base
and each translation. Differences >20% WARN, >50% FAIL.

### 5.2 Translation completeness
- Files in base but NOT in locale → FAIL.
- Files in locale but NOT in base → WARN (orphan).

### 5.3 Non-translatable terms
Project nouns (product names, vendor brands), well-known acronyms
("PagerDuty", "SLA", "RCA", "API", etc.).

### 5.4 Info and index consistency
- `id`, `category`, `version` identical between `info.json` and each `info.{locale}.json`.
- `availableLocales` identical.
- `index.{locale}.json`: same sections, same `id` and `order`.
- `title` not identical to base (should be translated).

## Required output

```
## VALIDATION RESULT — Doc Portal

### Parameters
- Level: [quick|complete|exhaustive]
- Validated manuals: [list]
- Locales: [es, en, fr, de]
- Date: <date>

### EXECUTIVE SUMMARY

| Category | Checks | Pass | Fail | Warn |
|----------|--------|------|------|------|
| Format   | N      | N    | N    | N    |
| Form     | N      | N    | N    | N    |
| Content  | N      | N    | N    | N    |
| TOTAL    | N      | N    | N    | N    |

### FORMAT VALIDATION
#### {manual-id}
- PASS / FAIL / WARN — [CHECK-ID]: ...

### FORM VALIDATION (if level >= complete)
#### {manual-id} — {locale}
...

### CONTENT VALIDATION (if level = exhaustive)
#### {manual-id}
- Structural parity: table
- Missing translations: table

### SUMMARY PER MANUAL
| Manual | Format | Form | Content | Result |
|--------|--------|------|---------|--------|
| ...    | ...    | ...  | ...     | PASS/FAIL |

### CRITICAL FINDINGS
[High-severity FAIL]
```

---

## Rules

- **Read-only** — NEVER modifies files.
- **Server required for form** — verify `localhost:3000` before.
- **All manuals** — if no `manual-id` is provided, validate ALL.
  Manuals in the source dir not in `manualIds` → FAIL.
- **All locales** — always those in `availableLocales`.
- **Mandatory evidence** — every FAIL with path, content, screenshot or
  console error.
- **Severity**: High = blocks publication. Medium = visible degradation.
  Low = minor imperfection.
- **Idempotent** — does not create state, modifies nothing.
