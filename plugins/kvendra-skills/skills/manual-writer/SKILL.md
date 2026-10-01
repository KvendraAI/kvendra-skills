---
name: manual-writer
description: Manual writer — generates a configurable documentation "book" (genre x depth) under docs/{book}/ of a project (English source), consulting Kvendra DOC entries and STD-TPL-DOC-GENRE templates; Mermaid diagrams incl. C4, optional screenshots. Publication mode prepares the mandatory manual of a KB publication (project language plus English) as project-wide DOCs, scoped to the selected components, with redaction suggestions
user_invocable: true
args: "[topic] [--genre=overview|user-manual|c4|...] [--depth=overview|standard|comprehensive] [--scope=project|CMP-...] | publication {PROJ} {COMP...} [--include={ENTITY_ID,...}] [--manual={DOC_ID}]"
---

# Manual Writer — Write project documentation as Markdown

You act as a **Senior Technical Writer**. Given a topic, you generate a
complete, well-structured documentation **book** under the project's `docs/`
directory — one genre instance with a configurable depth. You consult
existing DOC entries in the Kvendra KB to keep the new book consistent with
prior documentation, and you follow the genre blueprint (a minimal built-in
one, or — if the project defines it — an `STD-TPL-DOC-GENRE-*` template).
Optionally you embed Mermaid diagrams (including C4) and capture screenshots
if a browser MCP is available.

**FUNDAMENTAL PRINCIPLE — Consistency first**: before writing, load all
existing DOC entries for this project and build a brief of established
terminology, facts and cross-references. Never publish content that
contradicts what is already documented.

## Manual topic

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md` of the current directory.

## Kvendra rules (summary)

- Identify yourself on every write: `updated_by: "skill:<this-skill>"`. The
  `X-Kvendra-Skill` header is added by the MCP client automatically.
- **Guarded update (CAS)** — every `entity_update` is read-modify-write: capture the `version` returned by your preceding `entity_get`/`entity_query` and pass it as `expected_version`. On a `409 VERSION_CONFLICT` (the body carries `current_version` + `intervening_changes[]`) re-read the entity, re-apply your change on top of the intervening changes, then retry with the fresh `version`; bound retries to 3 and, if it still conflicts, stop and surface the conflict — never blind-overwrite. The engine ignores the lock when `expected_version` is absent, so omitting it silently reverts to last-write-wins.
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

## Mode selection

- **Book mode** (default): any argument that does not start with the word
  `publication`. Follow Steps 1–10 below.
- **Publication mode**: `publication {PROJ} {COMP...}`. Follow the
  "Publication mode" section below INSTEAD of Steps 1–10. It writes no file
  under `docs/` and does not call `doc-indexer`.

## Publication mode — prepare the manual of a KB publication

A Kvendra **publication** is a frozen, versioned snapshot of some components of
a project, shared by an unlisted link (REQ-KVD-EF9812). Every publication MUST
carry a manual. In this mode you draft that manual from the KB, limited to the
components the user selected, store it as a project-wide `DOC` tagged
`publication-manual`, and attach redaction suggestions for the publisher
(ADR-KVD-ENTERPRISE-1B2A48). The publisher then picks this DOC in the
dashboard publish wizard.

A publication carries **one or two manuals** (REQ-KVD-EF9812
`manual_locales`): the **primary** manual in the project language
(`PRJ.metadata.locale`), and — only when that language is not English — a
**secondary** manual in English. Never more than two. Only the manual is
translated; entities are published as they are.

**You never publish anything.** No publication endpoint, no link, no
confirmation: this mode only prepares the manual. Publishing is a human
decision taken in the dashboard after the preview.

### Arguments

```
publication {PROJ} {COMP...} [--include={ENTITY_ID,...}] [--manual={DOC_ID}]
```

| Argument | Meaning |
|----------|---------|
| `{PROJ}` | project id (e.g. `KVD`); defaults to the CLAUDE.md project if omitted |
| `{COMP...}` | one or more BARE component codes (e.g. `CLI SKILLS`), never `CMP-KVD-CLI` |
| `--include=` | project-wide entities (no `component_id`) the user explicitly wants as sources, one by one |
| `--manual=` | an existing manual DOC to update instead of searching for one |

There is **no default selection**. If no component is given, ask the user which
components to publish and stop until they answer — never assume "all".

### P1 — Resolve the selection

1. `entity_get({ entity_id: "PRJ-{PROJ}" })`. If `not_found`, stop: the project
   is not onboarded.
2. For each component: `entity_get({ entity_id: "CMP-{PROJ}-{COMP}" })`. If one
   does not exist, stop and list the valid components from
   `entity_query({ entity_type: "CMP", project_id: "{PROJ}" })`.
3. For each `--include` id: `entity_get` it and check that its `component_id`
   is empty (project-wide). An id that belongs to a non-selected component is
   refused with a message (selecting a component is the only way in).
4. **Resolve the project language** from `PRJ.metadata.locale` (an ISO 639-1
   code such as `en` or `es`; this is one of the few metadata values the skill
   reads, and it never goes into the manual text).
   - If it is missing, ASK the user for the main language of the KB (propose
     the language most entity content is written in, and let them confirm),
     then store it on the PRJ with the **Guarded update (CAS)** rule:

     ```
     mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
       entity_id: "PRJ-{PROJ}",
       expected_version: <version from the entity_get of step 1>,
       metadata: { locale: "{iso-639-1}", updated_by: "skill:manual-writer" },
       txn_id: "<txn_id>"
     })
     ```

     Projects onboarded before 1.17.0 have no locale: this happens once, the
     first time (the dashboard publish wizard asks the same question).
   - Manual set: `locale == "en"` → one manual (primary, `en`).
     Otherwise → primary in `{locale}` + secondary in `en`.

### P2 — Read ONLY the selected scope

The scope is: entities whose `component_id` is in the selection, plus the
CMP entities themselves, plus the explicit `--include` ids. Nothing else.

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  project_id: "{PROJ}",
  component_id: "{COMP}",
  limit: 100,
  offset: 0
})
```

Page with `offset` until exhausted, once per selected component. Drafts,
proposed and archived entities are never sources (the query excludes them by
default — do not pass `drafts` or `archived`).

Scope rules — they mirror what the server will publish (RF-9, AC-11):

- **No project-wide sweep.** Do not read PRJ content, transversal ADR/ROAD/STD
  or any entity without `component_id` unless it is in `--include`. The PRJ
  entity is used only to confirm the project exists.
- **`entity_search` is unscoped** (it has no `component_id` filter). If you use
  it to find a topic, DISCARD every hit whose `component_id` is not in the
  selection and that is not in `--include` — do not read it, do not quote it.
- **Do not follow relations out of the scope.** A relation to a non-selected
  entity will be rendered by the server as a locked "[private entity]", without
  id or title. Do not name it in the manual either.
- **Restricted types are not sources**: `COST`, `CFG`, `ENV`, `RUN` and `ISSUE`
  tagged `type:security` or `type:incident` are excluded from publications by
  default. Read them only to produce review suggestions (P4), never to write
  manual prose.
- **Only `title`, `content` and `tags` feed the manual.** Never `metadata`,
  `history`, `actors`, `created_by`/`updated_by` or any `human:`/`agent:`
  identifier, even though `entity_get` returns them.

Large entities follow the same rule as book mode: read them through a
subagent that returns a summary.

### P3 — Draft the seven mandatory sections

The server validates the manual deterministically (policy `pf-1`): each
section must be present, and the "What is included" section must name every
published component. Each manual uses EXACTLY these level-2 headings, in this
order, **in its own language**: the English manual uses the canonical column,
a Spanish manual uses the `es` column. The server validates each manual with
the heading set of its locale.

| # | Canonical heading (`en`) | Heading (`es`) | Content |
|---|-------------------------------|---------------------|---------|
| 1 | `## What it is and what problem it solves` | `## Qué es y qué problema resuelve` <!-- lint-allow-es --> | purpose of the published components, the problem, who it is for |
| 2 | `## How to use it and fork it` | `## Cómo usarlo y forkearlo` <!-- lint-allow-es --> | how a reader navigates the publication and reuses or forks it |
| 3 | `## KB structure` | `## Estructura del KB` <!-- lint-allow-es --> | entity types present, how they relate, where to start reading |
| 4 | `## Licenses` | `## Licencias` <!-- lint-allow-es --> | code license of each component repo + content license, both as SPDX ids |
| 5 | `## Maintainer` | `## Mantenedor` <!-- lint-allow-es --> | who maintains it and how to reach them |
| 6 | `## Version` | `## Versión` <!-- lint-allow-es --> | snapshot date and component versions; the publication version is assigned on publish |
| 7 | `## What is included and what is not` | `## Qué incluye y qué no` <!-- lint-allow-es --> | bullet list of the published components (one per selected `CMP`), types included, what is deliberately left out |

Writing rules for the manual:

- **Licenses**: the content license defaults to `CC-BY-4.0`. Take each code
  license from the component's `content`/`tags`; if it is not stated there,
  ASK — never guess a license. Always write SPDX identifiers.
- **Maintainer**: ask the user. Never derive it from actors or history.
- **What is not included**: say that other components of the project are not
  part of the publication, without naming them (their existence can be
  private). Name a non-selected component only if the user asks for it.
- **No entity ids of unpublished entities.** Prefer names and prose. Any id
  that is not in the publication is replaced by the server with
  "[private entity]", which reads badly in a manual.
- **Never** include secrets, credentials, vault profile names, account ids,
  personal paths, internal hostnames, customer names, prices, `metadata`
  values, history or actors. The server scans the manual with the same
  blocking scanner as the entities: a secret in the manual blocks the whole
  publication.
- **Do not invent data.** If a section lacks a source in the scope, ask the
  user. While the answer is pending, mark the gap with an explicit
  `TODO: <what is missing>` line naming the exact datum (e.g.
  `TODO: maintainer name and contact`, `TODO: code license of CLI`). A `TODO:`
  is a placeholder, never an acceptable final state: the server (`pf-1`)
  rejects a section that only contains a `TODO:` (reason `todo_only`), so the
  manual is not publishable until P7 clears every one.
- **Languages**: write the primary manual in the project locale first, then
  the English secondary (when required) as a faithful translation of the
  confirmed primary — same facts, same structure, nothing added or dropped.
  The secondary opens, right under its title, with the notice:
  `> Translated from the {primary language} manual. In case of discrepancy,
  the {primary language} version prevails.`
- **Locales without a heading set**: `pf-1` defines headings for `en` and `es`
  only. If the project locale is another language, write the primary body in
  that language but keep the canonical English headings, and tell the user
  (the server validates a locale it has no aliases for against `en`).
- Size: each manual must stay under 200,000 characters.
- Genre: if the project defines an `STD-TPL-DOC-GENRE-*` for genre
  `publication-manual`, follow its principles inside the seven sections
  (Tier-1 override, see Step 3); the seven headings are never removed.

### P4 — Review pass: redaction suggestions

Re-read the scoped entities (and your draft) looking for semantically
sensitive passages the deterministic scanner cannot see. These are
**suggestions** for the publisher — non-blocking, the publisher decides.

| `category` | Flag when the text… |
|------------|---------------------|
| `customer` | names a customer, prospect or partner, or describes a deal |
| `pricing` | states internal prices, margins, costs, discounts or revenue |
| `open-vulnerability` | describes an unfixed security weakness, attack path or open security ISSUE |
| `other` | anything else that looks private (internal people, incidents, contracts) |

Each suggestion is `{ entity_id, excerpt, category, reason }`:

- `entity_id` — the entity where the passage lives (use the manual DOC id, or
  the literal `"manual"` before the DOC exists, for passages in the manual).
  Review the primary manual and the entities; suggestions live on the
  primary manual DOC only (the secondary is a translation of it).
- `excerpt` — at most 200 characters, enough to locate the passage. If the
  passage contains a credential-shaped string, mask it (`AKIA****`) — never copy
  a secret into a suggestion.
- `reason` — one sentence: why it may be private.

An open `ISSUE` of type security in the selection is excluded by default; flag
it anyway if another included entity describes it in prose.

### P5 — Mandatory pause

Present, before writing anything to the KB:

1. The selection (components, `--include` ids) and the number of entities read
   per component.
2. The resolved locale and the manual set (primary only, or primary + `en`).
3. The full draft of the primary manual (the English secondary is produced
   after the primary is confirmed, and shown before writing).
4. The suggestions list.
5. The open questions: every `TODO:` line, each with the exact datum it needs
   (maintainer, code license per component, ...). Ask for them now; the
   answers usually remove the TODOs before anything is written.

**Wait for the user to confirm or edit.**

### P6 — Create or update the manual DOCs

Find an existing manual (unless `--manual` was given):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "DOC",
  project_id: "{PROJ}",
  tags_all: ["publication-manual"]
})
```

Keep only the results with an empty `component_id`, and match them by
`metadata.locale`. If more than one candidate remains for the same locale, ask
which one to update. Create the ones that are missing. Write the **primary
first**, then the secondary (its relation needs the primary id).

Create (project-wide: OMIT `component_id`) — primary:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: "{PROJ}",
  title: "Publication manual ({locale}): {PROJ} ({COMP list})",
  content: <the confirmed manual, Markdown, starting with "# {title}">,
  tags: ["publication-manual", "doc:genre:publication-manual", "locale:{locale}"],
  metadata: {
    updated_by: "skill:manual-writer",
    locale: "{locale}",
    is_primary: true,
    publication_components: ["{COMP}", ...],
    publication_review: [ { entity_id, excerpt, category, reason }, ... ],
    publication_review_at: "<ISO timestamp>"
  },
  relations: [
    { type: "part_of", target: "PRJ-{PROJ}" },
    { type: "affects", target: "CMP-{PROJ}-{COMP}" }   // one per selected component
  ],
  txn_id: "<txn_id>"            // only when an orchestrator passed one
})
```

Secondary (only when `locale != "en"`): same call with `locale: "en"`,
`is_primary: false`, the `locale:en` tag, the English content, NO
`publication_review` (it lives on the primary only), and one extra relation to
the primary:

```
relations: [
  { type: "part_of", target: "PRJ-{PROJ}" },
  { type: "affects", target: "CMP-{PROJ}-{COMP}" },
  { type: "derives_from", target: "<primary manual DOC id>" }
]
```

If the locale is `en`, there is no secondary; if a stale English secondary
exists from a previous locale, tell the user instead of archiving it.

Update (apply the **Guarded update (CAS)** rule):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
  entity_id: "<manual DOC id>",
  expected_version: <version from the entity_get you just did>,
  content: <the confirmed manual>,
  metadata: {
    updated_by: "skill:manual-writer",
    publication_components: [...],
    publication_review: [...],          // replaces the previous list
    publication_review_at: "<ISO timestamp>"   // primary only
  },
  relations_add: [ { type: "affects", target: "CMP-{PROJ}-{COMP}" } ],
  txn_id: "<txn_id>"
})
```

- Update the primary and the secondary together, so both describe the same
  snapshot; the server binds both manuals to the same publication version and
  scans and validates each one.
- `publication_review` lives ONLY in metadata. The server copies it to a
  private review sidecar of the draft and never into the published artifact;
  the manual DOC itself is published as the manual text, not as an entity.
- Standalone run (no `txn_id` from an orchestrator): run
  `txn_check_interrupted` and `txn_create` before the write and `txn_activate`
  after it, as in the Kvendra rules.
- Saving a manual that still has `TODO:` lines is allowed (it keeps the work),
  but it is NOT ready — continue with P7.

### P7 — Completeness gate (no `TODO:` left)

After writing, search every manual of the set (primary and secondary) for
`TODO:`.

- **If any remains**, the manual is **not ready**. List to the user exactly
  what is missing, one line per TODO: manual (locale), section heading, and the
  datum needed — e.g. "Maintainer: name and contact", "Licenses: code license
  of CLI (SPDX id)". Ask for those data. With the answers, replace the TODOs in
  the primary, update the English secondary to match (same facts), and write
  both again with the Guarded update (CAS) rule. Repeat until no `TODO:`
  remains in any manual.
- **Never** declare the manual ready, report it as prepared, or point the user
  to the publish wizard while any `TODO:` remains. Never remove a TODO by
  inventing a value or by deleting the section: only real data from the user
  (or from the scoped KB) clears it.
- If the user stops before answering, end with status `NOT READY` and the list
  of pending TODOs; a later run of the same command resumes from the stored
  DOCs.
- **When zero TODOs remain**, the manual is ready. Tell the user the next step:
  open the dashboard publish wizard, select the same components, and pick the
  manual DOC(s) in the Manual step. The preview shows the server scan and these
  suggestions before anything is published.

### Publication mode — required output

```
### PUBLICATION MANUAL: READY | NOT READY (never published by this skill)
- Project: {PROJ}
- Components: {COMP list}
- Explicit project-wide includes: N (ids)
- Entities read: N per component
- Project locale: {locale} (read / asked and stored on PRJ)
- Primary manual: DOC-... ({locale}, created/updated, version N, N characters)
- Secondary manual: DOC-... (en, derives_from primary) / none (locale is en)
- Sections: 7/7 headings of each manual's locale present
- Review suggestions: N (customer N · pricing N · open-vulnerability N · other N)
- Remaining TODOs: N   (READY requires 0)

### MISSING DATA (only when NOT READY)
- [{locale}] {section heading}: {exact datum needed}
- ...

### NEXT STEP (only when READY)
Dashboard → Publications → New: select the same components and this manual.
The server scans the manual and the entities again; blocking findings stop the
publication.
```

## Step 1 — Gather KB context (the KB is your richest source)

The Kvendra KB is the single richest source this skill has. Do NOT merely project
the component skeleton — sweep the relevant entity types for the topic and weave
their content into the doc. Per `PAT-KVD-SKILLS-725020`, each type feeds the
documentation differently:

| Entity | What it contributes | Pull for genres |
|--------|---------------------|-----------------|
| `CMP` | components, stack, responsibilities, structure | overview, c4, engineering |
| `IF` | wire contracts: fields, versions, error codes | api-ref, engineering, c4 |
| `ADR` | decisions **and rejected alternatives** (the why / why-not) | engineering, adr-log |
| `PAT` | lessons learned: real gotchas/bugs and their fixes | engineering, runbook |
| `REQ` | why a feature exists | engineering, functional |
| `GLO` | canonical term definitions | glossary, terminology everywhere |
| `PRJ` / `ROAD` | thesis, value model, vision, what was deferred and why | overview |
| `UX` / `ENV` | user flows, environments | user-manual, runbook |

Sweep with `entity_search` / `entity_query` for the topic, e.g.:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"ADR", project_id:<PROJ> })
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"PAT", project_id:<PROJ> })
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<topic>, entity_type:"IF", project_id:<PROJ> })
```

Then read the most relevant entities in full. **Large entities** (some `IF`/`ADR`
exceed the tool output limit) must be read via a **subagent** that slices the
saved result and returns a summary — never pull a 50k-character entity into the
main context.

What to weave in: the *why and why-not* (from `ADR` rejected alternatives) and
the *lessons learned* (from `PAT` gotchas). A doc that explains the road not
taken teaches far more than one that only describes the road taken.

**Code-informed genres** (`engineering`, and `c4` at depth `comprehensive`) also
read the component's actual source code (its repo), not only the KB: the KB is
the skeleton, the code is the detail.

## Step 2 — Load existing documentation (CONSISTENCY BRIEF)

This step is **critical**. Build a brief from the project's DOC entries:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "DOC",
  project_id: <PROJ>,
  limit: 100
})
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({
  query: <topic>,
  entity_type: "DOC",
  limit: 20
})
```

Build:

```
### CONSISTENCY BRIEF
#### Existing documentation on this topic
- [DOC-...]: [summary] — at <relative file path>

#### Established facts (DO NOT contradict)
- <fact> — source: DOC-...

#### Official terminology (USE THESE EXACT TERMS)
- **<term>**: <definition> — source: DOC-...

#### Related sections (potential cross-references)
- DOC-...: <relative file path> — candidate for cross-link
```

If the project has no DOC entries yet, suggest running `/doc-indexer` to
catalogue existing `docs/` content before continuing.

## Step 3 — Resolve genre, depth and scope

A documentation **book** has three orthogonal axes. All are optional — when
omitted, sensible defaults apply (Tier-0 minimal config), reproducing the
classic single-manual behaviour.

| Axis | Values | Default (Tier-0) |
|------|--------|------------------|
| `genre` | `overview`, `user-manual`, `c4` (+ any `STD-TPL-DOC-GENRE-*` in the KB) | inferred from the topic |
| `depth` | `overview`, `standard`, `comprehensive` | `standard` |
| `scope` | `project` or a component id (e.g. `CMP-...`) | `project` |

Read them from the arguments (`--genre=`, `--depth=`, `--scope=`). With no
flags, infer a genre from the topic, use `standard` depth and whole-project
scope (backward-compatible with the classic single manual).

### Built-in genre catalogue — principles, not fixed templates

A genre declares its **objective, audience, suggested structure, diagram style
and KB sources** — NOT a mandatory section list. The suggested structure is a
*starting point you adapt to the subject*: do not force every doc into identical
headings (a request-lifecycle deep-dive and a billing deep-dive are both
`engineering`, but should not share the same table of contents).

| Genre | Objective / audience | Suggested structure (adapt) | KB sources |
|-------|----------------------|-----------------------------|------------|
| `overview` | orient anyone — what it is, why, how it fits / all | `01-overview` (+ at-a-glance at comprehensive) | PRJ, CMP, ROAD |
| `user-manual` | help an end user do tasks / user | intro + one file per task + faq (screenshots) | UX, app |
| `c4` | the static architecture / technical | context + containers + components (+ code) | CMP, IF, relations |
| `engineering` | teach a newcomer how a subject works deeply / technical | adapt to the subject; build from zero | CMP + IF + ADR + PAT + REQ (code-informed) |
| `api-ref` | look up the contract / technical | tabular per interface; point to the IF as source of truth | IF |
| `adr-log` | why decisions were made / technical | terse log grouped by theme | ADR |
| `glossary` | define the vocabulary / all | term → definition list | GLO |

`depth` controls breadth: `overview` is a single-page book; `standard` is the
suggested structure; `comprehensive` adds optional sections, sequence diagrams,
data models and denser detail.

**Teaching genres** (`engineering`; `overview`/`user-manual` when the goal is to
educate) follow a quality bar: flowing narrative that builds from zero, a
concrete running example, every term defined before use, the *why and why-not*,
and worked examples — never a terse reference dump. **Reference genres**
(`api-ref`, `adr-log`, `glossary`) are the opposite: terse, scannable, and they
**point to the source entity** (IF / ADR / GLO) instead of duplicating it, to
avoid drift. The genre's *form follows its content*.

### Tier-1 — project override via STD-TPL-DOC-GENRE

If the KB defines a template for the chosen genre, it overrides/extends the
built-in blueprint:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "STD",
  project_id: <PROJ>,
  tags_all: ["scope:std-tpl", "doc-genre", "genre:<genre>"]
})
```

If found, follow its Objective / Audience / Principles / Suggested-structure /
Diagram-types / KB-sources / Depth-variants sections (the suggested structure is
adapted to the subject, not copied verbatim). If NOT found, use the built-in blueprint above and
proceed — do NOT stop (a safe default always exists). This is the doc-genre
fail-safe; it differs from the deploy-style STD fail-stop because docs always
have a generic default.

### KB-projected genres

`c4` (and future api-ref / glossary / adr-log genres) are *projected* from KB
entities, not free prose. Generate their content from the mapped entity types
and mark every generated file `source: kb-projection` in its front-matter so
it is recognised as regenerable (not hand-edited). For `c4` the mapping is:
Context from `PRJ` + external actors; Containers from `CMP`; Components from
the component internals + `IF`; relations from `depends_on` / `consumes`.

## Step 4 — Define the structure (MANDATORY PAUSE)

Generate a Table of Contents before writing. Present:

1. The resolved `genre` / `depth` / `scope` and the section blueprint.
2. Proposed file structure (under `docs/<book-slug>/`).
3. The CONSISTENCY BRIEF from Step 2.
4. Any overlap alerts — if the book covers a topic already documented,
   propose either a cross-reference or a different angle by audience.

**Wait for the user to confirm** before writing any `.md` file.

### Book structure

Each genre instance is a **book** — its own directory under `docs/`:

```
docs/<book-slug>/
├── README.md          # book index; opens with YAML front-matter (see Step 8)
├── 01-<section>.md
├── 02-<section>.md
├── ...
└── assets/
    ├── screenshots/
    └── diagrams/
```

`<book-slug>` is derived from the topic/genre (e.g. `architecture-c4`,
`user-guide`). Each book is one entry in the project documentation library;
the library super-index (`docs/README.md`) is regenerated by `doc-indexer`
(Step 10) — never hand-maintained, never a JSON registry.

The section files shown are a **suggested** shape only. Adapt their names, number
and order to what the subject actually needs — the genre gives principles, not a
fixed table of contents.

## Step 5 — Capture screenshots (optional, if user-facing)

Only if the book's genre is `user-manual` and the project's application is
available locally. If a browser MCP is installed (e.g. Playwright,
Puppeteer), use it; otherwise ask the user to provide screenshots
manually or skip this section.

### Load environment

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "ENV",
  project_id: <PROJ>,
  tags_all: ["env:dev"]
})
```

Use the ENV entry to determine the local URL and any credentials needed.
If the project does NOT have a generic auth flow, ask the user.

### Protocol (if a browser MCP is available)

For each screen:

1. Navigate to the URL.
2. Wait for the page to be network-idle.
3. Optionally highlight a specific element.
4. Take a screenshot → save to `docs/<book-slug>/assets/screenshots/<NN>-<description>.png`.

### Markdown reference

Use **relative** paths since the `.md` is co-located with `assets/`:

```markdown
![Description](./assets/screenshots/01-login-screen.png)
*Figure 1: Login screen*
```

Screenshots stay in `assets/screenshots/` — they are versioned with the book.
Never paste image bytes (base64 / data-URIs) into a KB entity; the engine
refuses them.

## Step 6 — Mermaid diagrams (optional, if architectural)

Embed Mermaid blocks directly in the Markdown:

````markdown
```mermaid
flowchart TD
    A[Start] --> B{Authenticated?}
    B -->|Yes| C[Dashboard]
    B -->|No| D[Login]
    D --> C
```
````

Supported types: `flowchart`, `graph`, `sequenceDiagram`, `erDiagram`,
`stateDiagram-v2`, `pie`, `gantt`, `classDiagram`, and the C4 family
(`C4Context`, `C4Container`, `C4Component`, `C4Dynamic`).

For the `c4` genre, `C4Context` renders cleanly, but `C4Container` /
`C4Component` auto-layout tends to overlap edges and labels on dense
diagrams. Default those denser levels to an equivalent `flowchart`/`graph`
(same nodes and edges, `TB` direction, short labels); keep `C4Context` native.
The C4 *levels* are the model — flowchart is only the renderer for the dense
levels. Validate the render before publishing.

### Mermaid hard rules (always apply — every one of these has bitten us)

- **Never use `;` inside a `sequenceDiagram` message.** Mermaid treats `;` as a
  statement separator, so `A->>B: do x; then y` fails to parse. Use commas or
  words.
- **Never use raw `<...>` in any Mermaid block.** Angle brackets are parsed as
  HTML and break or silently vanish. Use `&lt;`/`&gt;` or parentheses (write
  `user-(sub)`, not `user-<sub>`).
- **C4 dense levels → flowchart** (as above): only `C4Context` renders reliably.
- **Always validate the render** (a Mermaid-capable viewer or live editor) before
  publishing — never ship an unrendered diagram.

## Step 7 — Write the content

### Consistency rules (MANDATORY)

Before writing each section, consult the CONSISTENCY BRIEF:

1. **Terminology**: use EXACTLY the same terms as the existing DOC entries.
2. **Facts**: do not contradict established facts. If an update is needed,
   flag it as pending and ask the user.
3. **Flows**: if you describe a flow already documented, link to it
   instead of duplicating.
4. **States and values**: same names and order across the project.
5. **Roles and permissions**: same names and descriptions.

### Per-section check

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({
  query: <section topic>,
  entity_type: "DOC",
  project_id: <PROJ>,
  limit: 10
})
```

If a DOC entry covers the same topic:
- Same audience → cross-reference, do not duplicate.
- Different audience → adapt the level, keep the facts.

### Style

- **Language**: English only. Do NOT generate translated copies — the
  runtime agent translates output to the project's CLAUDE.md language
  per ADR-KVD-SKILLS-244215.
- **Tone**: professional but accessible.
- **Voice**: second person formal ("Select…", "Configure…").
- **Paragraphs**: short (max 4-5 lines).
- **Lists**: preferred over long paragraphs.

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

![Screenshot description](./assets/screenshots/XX-name.png)
*Figure N: Description*

### Step 2 — Next step
...

## Important notes
> **Note:** Relevant additional information.

> **Warning:** Situations to avoid.
```

### Structured-data examples

Use blockquotes with rich format, NOT code blocks:

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

## Step 8 — Generate the README.md index (with front-matter)

The book's `README.md` MUST open with YAML front-matter — this is how
`doc-indexer` discovers the book for the library super-index (no JSON
registry):

```markdown
---
kvendra_doc: book
genre: <overview|user-manual|c4|...>
audience: <user|technical|operations|functional|all>
depth: <overview|standard|comprehensive>
source: <authored|kb-projection>
title: <Book title>
---

# <Book title>

<2-3 line description>

## Index

### 1. [Introduction](./01-introduction.md)
Brief description.

### 2. [<Section>](./02-section.md)
Brief description.

---

## Audience
<Who this book is for>

## Prerequisites
<What is needed before>

## Related documentation
See the [documentation library](../README.md) for the other books in this
project.

---

*Last updated: <ISO date>*
```

## Step 9 — Review and validation

Checklist:

1. The README front-matter is present and valid (`kvendra_doc: book` + genre,
   audience, depth, source, title).
2. Relative links between documents work.
3. Images exist under `assets/screenshots/` and use relative paths.
4. Mermaid blocks have correct syntax (C4 blocks have a flowchart fallback if
   they render poorly).
5. Structured-data examples use blockquotes (not code blocks).
6. Style is uniform.
7. Every entry in the index has its file.
8. KB-projected files (e.g. `c4`) carry `source: kb-projection`.
9. Consistency with the CONSISTENCY BRIEF.

If any inconsistency is detected, inform the user before finishing.

## Step 10 — Index the book and refresh the library super-index

After the `.md` files are written, invoke `doc-indexer` on the book path. It
registers each file as a DOC entry (tagged with the book `genre`) AND
regenerates the project documentation library super-index `docs/README.md`
from every book's front-matter:

```
Skill(skill="kvendra-skills:doc-indexer", args="docs/<book-slug>/")
```

This keeps the CONSISTENCY BRIEF complete for future runs and keeps the
library index in sync — additively, without a JSON registry.

## Required output

```
### BOOK GENERATED
- Project: [project_id]
- Genre: [overview/user-manual/c4/...]
- Depth: [overview/standard/comprehensive]
- Scope: [project/CMP-...]
- Directory: docs/<book-slug>/
- Files: N (README.md + N-1 sections)
- Screenshots: N (if any)
- Diagrams: N (if any)
- Blueprint source: [built-in / STD-TPL-DOC-GENRE-<g>]

### FILE TREE
docs/<book-slug>/
├── README.md
├── ...
└── assets/

### CONSISTENCY
- DOC entries consulted: N
- Verified facts: N
- Aligned terminology: N terms
- Cross-references added: N
- Detected inconsistencies: N (detail if > 0)

### Kvendra UPDATED
- DOC entries: N created/updated via doc-indexer
- Library super-index: docs/README.md refreshed (doc:catalog)

### NOTES
[Observations, pending sections, items to review]
```

## Rules

- **Genres, not just audiences.** A book has a `genre` (structure), a `depth`
  (breadth) and a `scope`. Tech-specific or project-specific genre recipes
  live in `STD-TPL-DOC-GENRE-*` entities of the KB, read at runtime — only
  the minimal generic blueprint ships here (ADR-KVD-SKILLS-BB0E8A).
- **Library, not mega-document.** Each genre instance is a separate book
  under `docs/<book-slug>/`; the `docs/README.md` super-index is regenerated
  by `doc-indexer`. Never a JSON registry / `build-registry.js` / `index.json`,
  never visibility levels, never an external doc-portal stack
  (ROAD-KVD-SKILLS-79272A "Still in force").
- **Structure adapts; genres are principles, not templates.** A genre declares
  objective / audience / principles / KB-sources / *suggested* structure; adapt
  the real sections to the subject (`PAT-KVD-SKILLS-725020`). Never force
  identical headings across different subjects.
- **Enrich from the whole KB.** Weave `ADR` (decisions + rejected alternatives —
  the why and why-not), `PAT` (lessons learned / gotchas), `IF` (contracts),
  `REQ` (origin) and `GLO` (terms) — not just the `CMP` skeleton.
- **Teaching vs reference.** Teaching genres build from zero with a running
  example and the why/why-not; reference genres are terse and point to the source
  entity. Match the genre to its content.
- **Mermaid discipline.** Never `;` in a sequence message, never raw `<>`, C4
  dense levels → flowchart, and always validate the render.
- **Backward-compatible.** With no `--genre/--depth/--scope`, behaviour
  matches the classic single `standard` manual under `docs/<topic>/`.
- **Single language: English (book mode).** No multi-locale generation. The runtime
  agent translates to the project's CLAUDE.md language.
- **Single source of truth: filesystem + KB.** The output lives as `.md`
  files under `docs/<book-slug>/` and as DOC entries in the Kvendra KB.
- **Mandatory pause** after Step 4 (TOC + consistency brief). Do not
  write any `.md` until the user approves.
- **Do not invent data**. If you need information not in the KB or in
  the code, ask the user. KB-projected genres reflect real entities only.
- **Real screenshots only**. Only captures of the actual application.
- **Reuse screenshots**. If a screenshot already exists for the same
  view in another book under `docs/`, reference it via a relative
  path rather than duplicating.
- **Verifiable diagrams**. Reflect the real architecture / flows.
- **Versioning**. Include the last-updated date at the end of the README.
- **Consistency above all**. If writing something new contradicts existing
  documentation, STOP and ask the user. Never publish inconsistent content.
- **Suggest `/doc-indexer`** if the KB is empty of DOC entries for the
  project — without prior context, the consistency brief is empty.
- **Publication mode is scoped and read-only towards the outside.** It reads
  only the selected components (plus explicit includes), writes one
  project-wide `publication-manual` DOC per locale (primary in
  `PRJ.metadata.locale`, plus an English secondary when that is not `en`;
  max two), keeps redaction suggestions in the primary's
  `metadata.publication_review`, translates only the manual (never entities),
  and never publishes. The seven headings, in each manual's language, are
  mandatory; the server validates them and scans every manual. A manual with
  any `TODO:` left is NOT ready (the server rejects `todo_only` sections):
  ask the user for the missing data until none remains.
