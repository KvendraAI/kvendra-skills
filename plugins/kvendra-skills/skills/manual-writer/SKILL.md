---
name: manual-writer
description: Manual writer — generates technical and user manuals with screenshots and diagrams, using the Kvendra KB for consistency
user_invocable: true
args: "[manual topic and destination project]"
---

# Manual Writer — Technical and user manual writer

You act as a **Senior Technical Writer**. You create complete, well-structured
and visually enriched manuals for Kvendra-related projects. You use the
browser (Playwright MCP) to capture screenshots and you generate Mermaid
diagrams to illustrate flows and architectures.

**FUNDAMENTAL PRINCIPLE**: Before writing, load ALL the existing
documentation (DOC entries in the Kvendra KB) to guarantee 100% consistency.

## Manual topic

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md` of the current directory.

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

The directory layouts, `info.json` / `index.json` schemas, locale folder
conventions and publishing scripts (e.g. `build-registry.js`,
`upload-private-content.sh`) referenced below are conventions of the
kvendra doc-portal stack. When a project formalises its doc-portal as a
CMP in the Kvendra KB, the authoritative recipe should live in
`STD-<DOC_PROJECT>-DOC-PORTAL-FORMAT` and
`STD-<DOC_PROJECT>-DOC-PORTAL-PUBLISH` per ADR-KVD-SKILLS-BB0E8A. Until
those STDs exist, the conventions remain inline as sensible defaults —
adapt to the actual project layout if it differs.

## Step 1 — Load project context

Load from the Kvendra KB:

- **Functional / architecture**:
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"REQ", project_id:<PROJ> })`
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"CMP", project_id:<PROJ> })`
- **UX (if user manual)**:
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"UX", project_id:<PROJ> })`

---

## Step 2 — Load existing documentation (CONSISTENCY)

This step is **CRITICAL**. Load all already-written documentation.

### 2.1 — Documentation related to the topic (cross-project)

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<manual topic>, entity_type:"DOC", limit:20 })
```

### 2.2 — All documentation for the current project

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"DOC", project_id:<PROJ>, limit:100 })
```

### 2.3 — Doc-portal documentation (if it exists)

```
# When the doc-portal is formalised as its own KB project, query its DOC entries.
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"DOC", project_id:<DOC-PROJECT>, limit:100 })
```

### 2.4 — CONSISTENCY BRIEF

Build:

```
### CONSISTENCY BRIEF
#### Existing documentation on this topic
- [DOC-...]: [summary] — in [manual/section]

#### Established facts (DO NOT contradict)
- [fact 1] — source: DOC-...

#### Official terminology (use these exact terms)
- **[term]**: [definition] — source: DOC-...

#### Related sections (potential cross-references)
- DOC-...: [title] — candidate for cross-link
```

**RULE**: If there are no (or almost no) DOC entries for this project,
suggest running `/doc-indexer` before continuing.

---

## Step 3 — Determine type, scope and visibility

### 3.1 — Manual type

| Type | Audience | Main content | Screenshots |
|------|----------|--------------|-------------|
| **user** | End users of the app | Step-by-step flows with screenshots | Required |
| **technical** | Developers | Architecture, APIs, code, setup | Diagrams required |
| **operations** | DevOps / SysAdmin | Deployment, configuration, monitoring | As needed |
| **functional** | Product owners / QA | Business rules, use cases | Recommended |

### 3.2 — Manual visibility

Ask the user what visibility level the manual has:

| Visibility | Who can see | Login required | Storage |
|------------|-------------|----------------|---------|
| **public** | Anyone, no login | No | `public/manuals/` (CloudFront) |
| **partners** | Partner users + sales + admins | Yes (auth provider) | Private S3 (API Gateway) |
| **internal** | Internal staff only | Yes (auth provider) | Private S3 (API Gateway) |

**RULE**: If the user does not indicate visibility, ask explicitly. Do not
assume `public`.

The visibility is recorded in `info.json`:

```json
{
  "id": "manual-id",
  "title": "Manual title",
  "visibility": "public|partners|internal"
}
```

---

## Step 4 — Define the manual structure

Generate the table of contents before writing. Present the TOC together
with the **CONSISTENCY BRIEF** and **wait for confirmation**.

In the presentation include:
1. Proposed index.
2. Consistency brief (facts, terminology, cross-references).
3. **Overlap alerts**: if a section covers a topic already documented,
   propose a cross-reference or a different angle by audience.

### Base structure per type

**User manual:**
```
docs/
├── manual-<name>/
│   ├── README.md
│   ├── 01-introduction.md
│   ├── 02-access.md
│   ├── 03-<section>.md
│   ├── ...
│   ├── NN-faq.md
│   └── assets/
│       ├── screenshots/
│       └── diagrams/
```

**Technical manual:**
```
docs/
├── manual-<name>/
│   ├── README.md
│   ├── 01-architecture.md
│   ├── 02-data-model.md
│   ├── 03-api.md
│   ├── 04-flows.md
│   ├── ...
│   ├── NN-troubleshooting.md
│   └── assets/
│       ├── screenshots/
│       └── diagrams/
```

---

## Step 5 — Identify the destination directory

### 5.1 — Doc-portal manuals (project_id = <DOC-PROJECT>)

1. Source directory: `<workspace>/<doc-portal-root>/manuals/<manual-id>/`
2. Create: `sections/`, `sections/en/`, `sections/fr/`, `sections/de/`, `assets/screenshots/`
3. Create `info.json` (with `visibility`), `index.json`, `INDEX.md`

### 5.2 — Manuals from other projects

1. Read `project_id` from the CLAUDE.md.
2. Look for `docs/` in the repo. If it does not exist, create it.
3. Create `manual-<name>/` and `manual-<name>/assets/{screenshots,diagrams}/`.

### 5.3 — Publication in the doc-portal (MANDATORY if project_id=<DOC-PROJECT>)

The doc-portal uses **auto-discovery** via the registry script.

#### If the manual is `public`:

1. Copy to the public directory:
   ```
   cp -R manuals/<manual-id>/ public/manuals/<manual-id>/
   ```
2. Regenerate the registry: `node scripts/build-registry.js`.
3. Sync after translations (Step 9).

#### If `partners` or `internal`:

1. Do NOT copy to `public/`.
2. Regenerate the registry (adds metadata to `manuals-registry.json` and `private-content/manifest.json`).
3. Upload to private S3: `./scripts/upload-private-content.sh <env>`.

> **Warning:** A private manual in `public/` is reachable without auth. ALWAYS verify.

**Rule**: never overwrite existing documentation without confirmation.

---

## Step 6 — Capture screenshots (if applicable)

Use **Playwright MCP**. Load credentials from the KB:
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ENV", project_id:<PROJ>, tags_all:["env:dev"] })`

### Protocol

1. `browser_navigate(url)`.
2. If login is required, run the flow per the ENV.
3. For each screen:
   - Navigate to the section.
   - `browser_wait_for(state="networkidle")`.
   - Highlight elements if needed (`browser_evaluate`).
   - `browser_take_screenshot()`.
   - Save in `assets/screenshots/<NN>-<description>.png`.

### Naming conventions
```
assets/screenshots/
├── 01-login-screen.png
├── 02-dashboard-overview.png
├── 03-menu-navigation.png
└── ...
```

### Markdown reference — ABSOLUTE paths

> **IMPORTANT**: Images must use **absolute** paths from the site root.
> Relative paths do not resolve correctly when content is loaded via fetch
> from subdirectories.

**Correct**:
```markdown
![Description](/manuals/<manual-id>/assets/screenshots/01-login-screen.png)
*Figure 1: Login screen*
```

**INCORRECT**:
```markdown
![Description](./assets/screenshots/01-login-screen.png)
```

---

## Step 7 — Create diagrams (if applicable)

Diagrams embedded in markdown via **Mermaid**.

### Types

**User flow / process:**
````markdown
```mermaid
flowchart TD
    A[Start] --> B{Authenticated?}
    B -->|Yes| C[Dashboard]
    B -->|No| D[Login]
    D --> C
```
````

**Architecture:**
````markdown
```mermaid
graph LR
    subgraph Frontend
        A[App]
    end
    subgraph Backend
        B[API Gateway]
        C[Lambda]
        D[DynamoDB]
    end
    A --> B --> C --> D
```
````

**Sequence:**
````markdown
```mermaid
sequenceDiagram
    participant U as User
    participant F as Frontend
    participant B as Backend
    U->>F: Action
    F->>B: Request
    B-->>F: Response
    F-->>U: UI update
```
````

**Data model:**
````markdown
```mermaid
erDiagram
    ENTITY_A ||--o{ ENTITY_B : "relation"
    ENTITY_A {
        string id PK
        string name
    }
```
````

**State:**
````markdown
```mermaid
stateDiagram-v2
    [*] --> Created
    Created --> InProgress
    InProgress --> Completed
    InProgress --> Error
    Error --> InProgress: Retry
    Completed --> [*]
```
````

### Conventions

- Embed Mermaid directly (not as a separate image).
- Descriptive title before each diagram.
- Sub-diagrams if > 30 nodes.
- Node and relation labels in the manual's language.
- Brief explanation underneath.

---

## Step 8 — Write the content

### Consistency rules (MANDATORY)

Before writing each section, consult the **CONSISTENCY BRIEF**:

1. **Terminology**: use EXACTLY the same terms as the existing docs.
2. **Facts**: do not contradict established facts. If you need to update
   one, mark it as pending.
3. **Flows**: if you describe a flow already documented, reference that section.
4. **States and values**: same values and order.
5. **Roles and permissions**: same names and descriptions.

### Per-section check

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<section topic>, entity_type:"DOC", limit:10 })
```

If you find a DOC that covers the same topic:
- **Same project, same audience**: cross-reference, do not duplicate.
- **Same project, different audience**: adapt level but keep facts.
- **Different project**: verify shared facts are consistent.

### Style

- **Language**: project default (per CLAUDE.md).
- **Tone**: professional but accessible.
- **Voice**: second person formal ("Select…", "Configure…").
- **Paragraphs**: short (max 4-5 lines).
- **Lists** preferred over long paragraphs.

### Standard section format

```markdown
# Section Title

## Description
Brief explanation of the purpose (1-2 paragraphs).

## Prerequisites (if applicable)
- Requirement 1

## Main content
### Step 1 — Step name
Description of what must be done.

![Screenshot description](/manuals/<manual-id>/assets/screenshots/XX-name.png)
*Figure N: Description*

### Step 2 — Next step
...

## Important notes
> **Note:** Relevant additional information.

> **Warning:** Situations to avoid.
```

### Structured-data examples

**Use blockquotes with rich format**, NOT code blocks:

```markdown
> **Field 1:** Field value
>
> **Field 2:**
> - **Subfield A:** Value A
> - **Subfield B:** Value B
>
> **Field 3:** value@example.com
```

Code blocks ONLY for: commands, source code, URLs/paths, JSON/YAML, Mermaid.

### Elements to include

- **Tables** for comparisons, roles/permissions, configurations.
- **Blockquotes** with format for structured data.
- **Code blocks** only for commands/code.
- **Callouts** (blockquotes with bold) for notes and warnings.
- **Cross-references** between sections.
- **Mermaid diagrams** for flows and architecture.

---

## Step 9 — Generate the README.md index

```markdown
# [Manual title] — [Project]

[2-3 line description]

## Index

### 1. [Section](./01-section.md)
Brief description.

### 2. [Section](./02-section.md)
Brief description.

---

## Audience
[Who this manual is for]

## Prerequisites
[What is needed before]

## Related documentation
[Links to other manuals]

---

*Last updated: <date>*
```

---

## Step 10 — Review and validation

Checklist:

1. Relative links between documents work.
2. Images exist in `assets/screenshots/` and use absolute paths.
3. Mermaid blocks have correct syntax.
4. Structured-data examples use formatted blockquotes (not code blocks).
5. Uniform style.
6. Every section in the index has its file.
7. Consistency with the CONSISTENCY BRIEF.

### Final consistency checklist

```
- [ ] Terminology: every term matches existing docs
- [ ] Facts: no fact contradicts existing docs
- [ ] Flows: shared flows referenced, not duplicated
- [ ] States/values: same names and order
- [ ] Roles: same names and descriptions
- [ ] Cross-references: links to related docs included
```

If you detect inconsistency, **inform the user** before finishing.

---

## Step 11 — Generate multi-locale versions

Supported locales: **en, es, fr, de** (en is default/fallback).

### 11.1 — File structure

**doc-portal** (`manuals/{manual-id}/`):
```
manuals/{manual-id}/
├── info.json              # locale: "es"
├── info.en.json           # English
├── info.fr.json           # French
├── info.de.json           # German
├── index.json             # base
├── index.en.json
├── index.fr.json
├── index.de.json
├── sections/
│   ├── introduction.md    # base
│   ├── ...
│   ├── en/
│   │   └── introduction.md
│   ├── fr/
│   │   └── introduction.md
│   └── de/
│       └── introduction.md
```

**Manuals in repos** (`docs/manual-{name}/`):
```
docs/manual-{name}/
├── README.md              # base
├── README.en.md
├── README.fr.md
├── README.de.md
├── 01-section.md          # base
├── en/
│   └── 01-section.md
├── fr/
│   └── 01-section.md
├── de/
│   └── 01-section.md
└── assets/                # shared
```

### 11.2 — Translation rules

1. Translate the content fully to the target language.
2. Keep the structure of headings, lists and Markdown format.
3. **Do not translate**:
   - Proper nouns (product / brand names).
   - Names of technical entities (Partner, Lead) — use the original with
     a translation in parentheses on first use: "Partners (socios)".
   - Code blocks and commands.
   - URLs and paths.
   - Names of app fields if the app is not localised in that language.
4. Adapt Mermaid diagrams: translate labels.
5. Keep references to screenshots (shared across locales).
6. **Absolute image paths** intact. Translate only alt text and figure caption.
7. **Structured-data examples**: keep the same markdown format (formatted blockquotes), do NOT convert to code blocks.

### 11.3 — Generate localised metadata

**info.{locale}.json** — translate `title` and `description`:
```json
{
  "id": "manual-id",
  "title": "Operations Manual",
  "description": "Complete operations manual",
  "category": "SaaS",
  "version": "1.0.0",
  "locale": "en",
  "availableLocales": ["es", "en", "fr", "de"]
}
```

**index.{locale}.json** — translate the `title` of each section. `id` and `file` do not change.

**Base info.json** — update `availableLocales`.

### 11.4 — Quality

- Same professional yet accessible tone across all locales.
- If a per-locale glossary exists in the KB, respect it.
- All sections translated (no fallback).
- After translation verify: valid Mermaid, absolute paths, blockquotes
  preserved, tables with the same structure.

### 11.5 — Generation order

1. Full manual in the base language.
2. English (en) — fallback, highest priority.
3. French (fr).
4. German (de).

```
Generating multi-locale versions:
es — Base completed (N sections)
en — Translation completed
fr — Translation completed
de — Translation completed
```

---

## Step 12 — Index the new manual in the Kvendra KB

After writing the manual, index every section in the Kvendra KB (DOC
entries) so future manuals have it as a reference.

### Subskill doc-indexer

Launch Agent reading `doc-indexer/SKILL.md`, replacing `$ARGUMENTS`:

```
Project: <project_id>
Directory: <path to the newly created manual>
Action: index the sections (base language only, not translations)
```

This registers the new manual in the Kvendra KB as DOC entries, available
as a reference for the next manual.

`Manual indexed in Kvendra — N DOC entries created`

---

## Required output

```
### MANUAL GENERATED
- Project: [project_id]
- Type: [user/technical/operations/functional]
- Directory: [path]
- Sections: N documents
- Screenshots: N captures
- Diagrams: N Mermaid diagrams

### CREATED FILE STRUCTURE
[tree]

### MANUAL INDEX
[README.md content]

### CONSISTENCY
- DOC entries consulted: N
- Verified facts: N
- Aligned terminology: N terms
- Cross-references added: N
- Detected inconsistencies: N (detail if > 0)

### MULTI-LOCALE
- Generated languages: es, en, fr, de
- Sections translated per language: N
- Localised info/index files: N
- availableLocales updated: OK

### Kvendra UPDATED
- DOC entries created: N

### NOTES
[Observations, pending sections, items to review]
```

---

## Important rules

- **MANDATORY PAUSE** after Step 4: do not write until the user approves
  the index AND the consistency brief.
- **Do not invent data**: if you need info that is not in the KB or in the
  code, ask the user.
- **Real screenshots only**: only captures of the actual application.
- **Reuse screenshots**: if one already exists in another manual of the
  same project, reference it.
- **Verifiable diagrams**: reflect the real architecture / flows.
- **Versioning**: include the last-updated date at the end.
- **CONSISTENCY ABOVE ALL**: if writing something new contradicts existing
  docs, STOP and consult. Never publish inconsistent content.
- **Suggest /doc-indexer**: if the Kvendra KB has no DOC entries for the
  project, suggest it before continuing.
