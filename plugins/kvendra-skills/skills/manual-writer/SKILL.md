---
name: manual-writer
description: Manual writer — generates a configurable documentation "book" (genre x depth) under docs/{book}/ of a project (English source), consulting Kvendra DOC entries and STD-TPL-DOC-GENRE templates; Mermaid diagrams incl. C4, optional screenshots. KB book mode writes the mandatory English book of one component as DOC chapters in the KB, from the component's code and KB. Publication mode prepares the English card of a KB publication, scoped to the selected components, with redaction suggestions
user_invocable: true
args: "[topic] [--genre=overview|user-manual|c4|...] [--depth=overview|standard|comprehensive] [--scope=project|CMP-...] | book {PROJ} {COMP} [--from={repo-docs-dir}] [--no-pause] | publication {PROJ} {COMP...} [--include={ENTITY_ID,...}] [--manual={DOC_ID}]"
---

# Manual Writer — Write project documentation as Markdown

You act as a **Senior Technical Writer**. You work in one of three modes:

- **Docs mode** (default): you generate a complete, well-structured
  documentation **book** under the project's `docs/` directory — one genre
  instance with a configurable depth. You consult existing DOC entries in the
  Kvendra KB to keep the new book consistent with prior documentation, and you
  follow the genre blueprint (a minimal built-in one, or — if the project
  defines it — an `STD-TPL-DOC-GENRE-*` template). Optionally you embed
  Mermaid diagrams (including C4) and capture screenshots if a browser MCP is
  available.
- **KB book mode** (`book {PROJ} {COMP}`): you write the English **book of one
  component** — its real manual (architecture, flows, operation) — as DOC
  chapters stored in the KB, derived from the component's source code and its
  KB entities. Every component of a KB publication must have one.
- **Publication mode** (`publication {PROJ} {COMP...}`): you prepare the
  English **card** (cover page) of a KB publication.

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

- **Docs mode** (default): any argument whose first word is not `book` or
  `publication`. Follow Steps 1–10 below. Behaviour is unchanged from earlier
  releases.
- **KB book mode**: `book {PROJ} {COMP} ...`. Follow the "KB book mode"
  section INSTEAD of Steps 1–10. It writes no file under `docs/` and does not
  call `doc-indexer`.
- **Publication mode**: `publication {PROJ} {COMP...}`. Follow the
  "Publication mode" section INSTEAD of Steps 1–10. It writes no file under
  `docs/` and does not call `doc-indexer`.

Everything the KB book mode and the publication mode write is **English
only**. There is no project language, no second language and no translated
copy (ADR-KVD-ENTERPRISE-BC96E7): the publication engine rejects a card or a
book that is not in English. Entities are published as they are, in whatever
language they were written.

## KB book mode — write the English book of a component

A KB publication carries one **book per selected component**
(REQ-KVD-962E6E, ADR-KVD-ENTERPRISE-BC96E7). The book is the component's real
manual: what it is, how it is built, how its main flows work, how it is
operated and configured. It lives in the KB as a set of **DOC chapters** of
that component, so it belongs to the component — not to a publication — and
is reused, without duplication, by every publication and version that
includes the component.

The publication engine validates the book deterministically and refuses to
publish a component without a valid one. The rules below mirror that gate
(policy `pf-2`); follow them exactly.

**You never publish anything** in this mode. It only writes DOC chapters.

### Arguments

```
book {PROJ} {COMP} [--from={repo-docs-dir}] [--no-pause]
```

| Argument | Meaning |
|----------|---------|
| `{PROJ}` | project id (e.g. `KVD`); defaults to the CLAUDE.md project if omitted |
| `{COMP}` | ONE bare component code (e.g. `CLI`), never `CMP-KVD-CLI` |
| `--from=` | an existing manual directory of the component repo (e.g. `docs/manual-{name}`) to use as a source; it is rewritten in English, never copied as is |
| `--no-pause` | skip the plan pause (B4); only for orchestrated pipelines that run without gates |

One component per run. To cover several components, run the mode once per
component.

### Book identity (what the engine checks)

Each chapter is a `DOC` entity with:

| Field | Value | Rule |
|-------|-------|------|
| `component_id` | `{COMP}` | the component the book documents — never project-wide |
| `metadata.book` | book slug, e.g. `kvendra-cli` | `^[a-z0-9][a-z0-9-]{1,62}$`; the SAME slug in every chapter |
| `metadata.chapter` | integer `1`..`999` | unique inside the book; gaps allowed; no chapter `0` or index chapter (the reader renders the table of contents) |
| `metadata.locale` | `"en"` | mandatory in every chapter |
| `metadata.book_title` | human title of the book | optional, recommended (same value in every chapter) |
| `metadata.chapter_slug` | `[a-z0-9-]`, max 60 chars | optional; if absent the engine slugifies the title |
| `title` | `"{Book title} — {NN}. {Chapter title}"` | the chapter title shown to readers |
| tags | `book:{slug}`, `doc:genre:book-chapter`, `locale:en` | convenience only — the engine reads `metadata` |

- **Exactly one book per component.** Two different `metadata.book` slugs in
  the same component make the engine refuse the component (`book_ambiguous`).
- A chapter is never published as an entity and is never embedded; it is
  published as part of the book.
- Engine limits: at least 1 chapter; at most **200 chapters**; at most
  **200,000 characters per chapter**; at most **3,000,000 characters per
  book**. An empty chapter, or one that only holds `TODO:` lines, is refused
  (`chapter_todo_only`).
- **English is checked twice**: `metadata.locale` must be `"en"`
  (`book_locale_missing` / `book_not_english` otherwise), and the engine
  scores the prose (code blocks, Mermaid, inline code, URLs and entity ids are
  stripped first) with an English-stopword heuristic: a chapter clearly not in
  English **blocks** the publication even if it is declared `en`; a borderline
  one needs the publisher's confirmation. Write natural English prose; keep
  any non-English UI string or quote short and inside inline code.

### B1 — Resolve the component and its repository

1. `entity_get({ entity_id: "PRJ-{PROJ}" })`. If `not_found`, stop: the project
   is not onboarded.
2. `entity_get({ entity_id: "CMP-{PROJ}-{COMP}" })`. If it does not exist,
   stop and list the valid components from
   `entity_query({ entity_type: "CMP", project_id: "{PROJ}" })`.
3. Read `CMP.metadata.workspace_subdir` — the component repository, relative
   to the workspace root (the directory that holds the project `CLAUDE.md`;
   see `help({topic:"workspace-layout"})`).
   - **Present and checked out locally** → the book is derived from the code
     AND the KB. Record the repo (the `workspace_subdir` value) and its current
     commit (`git rev-parse HEAD`, a read-only inspection).
   - **Absent** → the book is still mandatory (the engine has no exception for
     components without a repository). Derive it from the KB only, and open
     chapter 1 with this sentence:
     `This book is derived from the KB only; no source repository is registered.`
   - **Declared but not found locally** → tell the user. Without `--no-pause`,
     ask whether to continue KB-only; with `--no-pause`, continue KB-only and
     open chapter 1 with:
     `This book is derived from the KB only; the source repository was not available when it was written.`
4. Find the existing book of the component:

   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
     entity_type: "DOC",
     project_id: "{PROJ}",
     component_id: "{COMP}",
     limit: 100,
     offset: 0
   })
   ```

   Page with `offset` until exhausted and keep the DOCs that carry
   `metadata.book`.
   - **None** → new book. Propose a slug derived from the component name (e.g.
     `kvendra-cli`) and a book title (e.g. `Kvendra CLI`).
   - **One slug** → update that book: reuse its slug, title and chapter numbers.
   - **Two or more slugs** → STOP. Report the slugs and their chapter DOC ids
     (the engine refuses this as `book_ambiguous`) and ask the owner which one
     is the book. Never merge, delete or archive chapters on your own.

### B2 — Read the sources

**The component's code** (when a repository is available) — the code is the
detail, the KB is the skeleton:

- Structure: top-level layout, build manifests, the repo README.
- Entry points: binaries, handlers, commands, public APIs.
- Modules and their responsibilities; the main data model.
- Main flows end to end (follow the calls from an entry point to its effects).
- Configuration surface and how it is operated.
- Read large trees through subagents that return summaries; never pull a whole
  repository into the main context.
- Never read or quote secret material (`.env` files, credential stores, key
  files, vault blobs).

**The component's KB** — entities whose `component_id` is `{COMP}`, plus
`CMP-{PROJ}-{COMP}` itself:

| Type | Use |
|------|-----|
| `CMP` | purpose, stack, responsibilities, interfaces |
| `IF` | contracts: fields, versions, error codes |
| `ADR` | decisions and rejected alternatives (the why and why-not) |
| `REQ` | why features exist |
| `STD` | conventions and playbooks of the component |
| `GLO` | canonical terms |
| `DOC` | existing documentation (excluding the book chapters themselves, which you are rewriting) |

- **Never sources**: `COST`, `CFG`, `ENV`, `RUN`, and `ISSUE` tagged
  `type:security` or `type:incident`. Do not read them for prose.
- **Only `title`, `content` and `tags` feed the book.** Never `metadata`,
  `history`, `actors`, `created_by`/`updated_by` or any `human:`/`agent:`
  identifier.
- Large entities are read through a subagent that returns a summary.

**`--from` (existing repo manual)**: read it as a source to **rewrite in
English** — keep its facts and structure where they still hold, verify each
fact against the current code, and drop what the code contradicts (report the
contradictions). Never copy non-English text into a chapter.

### B3 — Plan the chapters

Recommended plan (adapt it to the component — this is guidance, not an engine
gate; if the project defines an `STD-TPL-DOC-GENRE-*` for genre
`book-chapter`, follow its principles):

| # | Chapter | Content |
|---|---------|---------|
| 1 | Overview | what the component is, the problem it solves, who uses it, how it fits in the project |
| 2 | Architecture | building blocks and their relations — C4 levels as Mermaid (see Step 6 rules) |
| 3..n | Main flows | one chapter per important flow, end to end, with sequence diagrams where useful |
| n+1 | Operation and configuration | install/run, configuration, environments in generic terms, troubleshooting |
| n+2 | Reference | commands, endpoints, contracts — terse, pointing to the `IF` entities |
| n+3 | Glossary | the component's terms, from `GLO` |

Writing rules:

- **English only**, teaching style for narrative chapters (build from zero,
  define terms before use, explain the why and why-not from `ADR`), terse
  style for reference chapters.
- **Cite entities by literal id** where they are the source of a fact
  (e.g. `ADR-KVD-...`, `IF-KVD-...`). Cite only ids of entities of this
  component (`component_id` = `{COMP}`, or `CMP-{PROJ}-{COMP}`) and ids of the
  book's own chapters: the reader links them. Any other id is replaced by the
  engine with a locked "[private entity]" if it is not published — describe
  those in prose instead.
- **No personal data**: no person names, emails, user handles or account
  names. The engine flags the publisher's and the team members' names, emails
  and handles (`publisher_identity`) in every chapter.
- **No infrastructure identifiers or private paths**: no home-directory paths,
  account ids, ARNs, internal hostnames, vault profile names, credentials,
  customer names or prices. The engine scans every chapter with the same
  blocking secret scanner as the entities.
- **Do not invent data.** If something is not in the code or the KB, ask the
  user. A `TODO: <exact datum>` line is a temporary marker inside a chapter
  that has real content; a chapter that would hold only `TODO:` lines is not
  written (the engine refuses it as `chapter_todo_only`).
- Respect the limits: chapter numbers 1..999 and unique, at most 200 chapters,
  200,000 characters per chapter, 3,000,000 per book. Split a chapter that
  grows too large.
- Each chapter's `content` starts with `# {NN}. {Chapter title}` and is
  self-contained Markdown (Mermaid allowed; follow the Mermaid hard rules of
  Step 6).

### B4 — Pause with the plan

Present, before writing anything to the KB:

1. Component, repository and commit (or "KB only"), and the `--from` source.
2. Book slug and title (new, or the existing one being updated).
3. The chapter plan: number, title, slug, sources (code paths and entity ids)
   and whether each chapter is created, updated or unchanged.
4. Existing chapters that are not in the new plan (they are never deleted or
   renumbered without the owner's decision).
5. Open questions and any contradiction found between code, KB and `--from`.

**Wait for the user to confirm or edit.** With `--no-pause`, skip the wait
and include this plan in the final report instead.

### B5 — Write or update the chapters

Standalone run (no `txn_id` from an orchestrator): run
`txn_check_interrupted` and `txn_create` before the first write and
`txn_activate` after the last one. Chapters written inside a TXN stay drafts
until it is activated (read them back with `include_drafts: true`).

Create a chapter (one call per chapter):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: "{PROJ}",
  component_id: "{COMP}",
  title: "{Book title} — {NN}. {Chapter title}",
  content: <the chapter, Markdown, starting with "# {NN}. {Chapter title}">,
  tags: ["book:{slug}", "doc:genre:book-chapter", "locale:en"],
  metadata: {
    book: "{slug}",
    book_title: "{Book title}",
    chapter: <integer>,
    chapter_slug: "{chapter-slug}",
    locale: "en",
    source: { repo: "{workspace_subdir}" | null, commit: "{sha}" | null, paths: ["src/...", ...] },
    updated_by: "skill:manual-writer"
  },
  relations: [
    { type: "part_of", target: "CMP-{PROJ}-{COMP}" },
    { type: "derives_from", target: "PRJ-{PROJ}" }
  ],
  txn_id: "<txn_id>"
})
```

Update an existing chapter — matched by `(component, book, chapter)` — with
the **Guarded update (CAS)** rule:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
  entity_id: "<chapter DOC id>",
  expected_version: <version from the entity_get you just did>,
  title: "{Book title} — {NN}. {Chapter title}",
  content: <the new chapter>,
  metadata: { book, book_title, chapter, chapter_slug, locale: "en", source, updated_by: "skill:manual-writer" },
  txn_id: "<txn_id>"
})
```

- **Idempotent**: a re-run updates the same chapters (same slug, same numbers)
  and skips a chapter whose content did not change. It never creates a second
  book.
- **Never delete, archive or renumber** chapters without the owner's explicit
  decision. A chapter that falls out of the plan is reported, not removed.
- `metadata.book`, `metadata.chapter` and `metadata.locale` are what the
  engine reads; the tags are a convenience and must agree with them.

### B6 — Verify the book

Re-read every chapter of the book (with `include_drafts: true` while the TXN
is open) and check what the engine will check:

1. One slug in the component; every chapter has an integer `chapter` in
   1..999, unique; `metadata.locale` is `"en"`.
2. No chapter empty or only `TODO:`; sizes within the limits.
3. Every chapter is written in English (no paragraph in another language).
4. Cited entity ids exist and belong to the component (or are chapters of the
   book).
5. No person names, emails, handles, home paths, account ids, hostnames or
   secrets.

The book is `READY` only when all checks pass and no `TODO:` line remains;
otherwise `NOT READY` with the exact list of what is missing.

### KB book mode — required output

```
### COMPONENT BOOK: READY | NOT READY (never published by this skill)
- Project: {PROJ} · Component: CMP-{PROJ}-{COMP}
- Source: repo {workspace_subdir} @ {commit} | KB only (reason)
- --from: {dir} | none
- Book: {slug} — "{Book title}" (new | updated)
- Chapters: N (created N · updated N · unchanged N) — numbers {list}
- Characters: N (max 3,000,000); largest chapter N (max 200,000)
- Entities cited: N (ids)
- Chapters out of the plan (kept, owner decision): {ids} | none
- Remaining TODOs: N   (READY requires 0)
- TXN: {txn_id} (own | orchestrator)

### CHAPTERS
| # | DOC id | Title | Characters | Status |

### MISSING DATA / CONTRADICTIONS (only when present)
- ...
```

## Publication mode — prepare the card of a KB publication

A Kvendra **publication** is a frozen, versioned snapshot of some components of
a project, shared by an unlisted link (REQ-KVD-EF9812, REQ-KVD-962E6E). Every
publication carries:

- **One card** — the cover page, in **English**, with seven mandatory
  sections. This mode drafts it.
- **One book per selected component** — written by KB book mode
  (`/manual-writer book {PROJ} {COMP}`). This mode only checks that each
  component has one.

You draft the card from the KB, limited to the components the user selected,
store it as a project-wide `DOC` tagged `publication-manual` with
`metadata.locale: "en"`, and attach redaction suggestions for the publisher
(ADR-KVD-ENTERPRISE-1B2A48, ADR-KVD-ENTERPRISE-BC96E7). There is exactly one
card per publication and it is English only: no project language, no second
card, no translation notice.

**You never publish anything.** No publication endpoint, no link, no
confirmation: this mode only prepares the card. Publishing is a human
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
| `--manual=` | an existing card DOC to update instead of searching for one |

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
4. **Check the books.** For each component, query its DOCs (as in KB book mode
   B1.4) and keep those with `metadata.book`. Record per component: the book
   slug and title and its chapter count — or **missing** (no chapter) or
   **ambiguous** (two or more slugs). The engine refuses to publish a
   component with a missing, ambiguous, non-English or incomplete book. This
   mode does not write books: for each missing or ambiguous one, tell the user
   the command to run, `/manual-writer book {PROJ} {COMP}`.

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
  id or title. Do not name it in the card either.
- **Restricted types are not sources**: `COST`, `CFG`, `ENV`, `RUN` and `ISSUE`
  tagged `type:security` or `type:incident` are excluded from publications by
  default. Read them only to produce review suggestions (P4), never to write
  card prose.
- **Only `title`, `content` and `tags` feed the card.** Never `metadata`,
  `history`, `actors`, `created_by`/`updated_by` or any `human:`/`agent:`
  identifier, even though `entity_get` returns them.
- **Book chapters** (DOCs with `metadata.book`) are published as the books, not
  as entities. Read them for P4 (they are reviewed too), and to summarise each
  book in the card.

Large entities follow the same rule as Docs mode: read them through a
subagent that returns a summary.

### P3 — Draft the seven mandatory sections

The server validates the card deterministically (policy `pf-2`): each section
must be present with EXACTLY these level-2 English headings, in this order,
and the "What is included" section must name every published component.
Headings in any other language are refused (`card_invalid`).

| # | Heading | Content |
|---|---------|---------|
| 1 | `## What it is and what problem it solves` | purpose of the published components, the problem, who it is for |
| 2 | `## How to use it and fork it` | how a reader navigates the publication (card, books, entities) and reuses or forks it |
| 3 | `## KB structure` | entity types present, how they relate, where to start reading |
| 4 | `## Licenses` | code license of each component repo + content license, both as SPDX ids |
| 5 | `## Maintainer` | who maintains it and how to reach them |
| 6 | `## Version` | snapshot date and component versions; the publication version is assigned on publish |
| 7 | `## What is included and what is not` | bullet list of the published components (one per selected `CMP`) with the title of each component's book, types included, what is deliberately left out |

Writing rules for the card:

- **English only.** The engine checks `metadata.locale` and scores the prose
  with an English-stopword heuristic: a card clearly not in English is refused
  (`card_not_english`); a borderline one needs the publisher's confirmation.
  Never add a "Translated from ..." notice.
- **Licenses**: the content license defaults to `CC-BY-4.0`. Take each code
  license from the component's `content`/`tags`; if it is not stated there,
  ASK — never guess a license. Always write SPDX identifiers.
- **Maintainer**: ask the user. Never derive it from actors or history. Prefer
  a role or a public project contact over a person's name: the engine flags
  the publisher's and the team members' names, emails and handles
  (`publisher_identity`, confirmation required).
- **What is not included**: say that other components of the project are not
  part of the publication, without naming them (their existence can be
  private). Name a non-selected component only if the user asks for it.
- **No entity ids of unpublished entities.** Prefer names and prose. Any id
  that is not in the publication is replaced by the server with
  "[private entity]", which reads badly in a card.
- **Never** include secrets, credentials, vault profile names, account ids,
  personal paths, internal hostnames, customer names, prices, `metadata`
  values, history or actors. The server scans the card with the same
  blocking scanner as the entities: a secret in the card blocks the whole
  publication.
- **Do not invent data.** If a section lacks a source in the scope, ask the
  user. While the answer is pending, mark the gap with an explicit
  `TODO: <what is missing>` line naming the exact datum (e.g.
  `TODO: maintainer name and contact`, `TODO: code license of CLI`). A `TODO:`
  is a placeholder, never an acceptable final state: the server (`pf-2`)
  rejects a section that only contains a `TODO:` (reason `todo_only`), so the
  card is not publishable until P7 clears every one.
- Size: the card must stay under 200,000 characters.
- Genre: if the project defines an `STD-TPL-DOC-GENRE-*` for genre
  `publication-manual`, follow its principles inside the seven sections
  (Tier-1 override, see Step 3); the seven headings are never removed.

### P4 — Review pass: redaction suggestions

Re-read the scoped entities, the selected components' book chapters and your
draft, looking for semantically sensitive passages the deterministic scanner
cannot see. These are **suggestions** for the publisher — non-blocking, the
publisher decides.

| `category` | Flag when the text… |
|------------|---------------------|
| `customer` | names a customer, prospect or partner, or describes a deal |
| `pricing` | states internal prices, margins, costs, discounts or revenue |
| `open-vulnerability` | describes an unfixed security weakness, attack path or open security ISSUE |
| `other` | anything else that looks private (internal people, incidents, contracts) |

Each suggestion is `{ entity_id, excerpt, category, reason }`:

- `entity_id` — the entity where the passage lives: an entity id, a book
  chapter DOC id, or the card DOC id (the literal `"manual"` before the card
  DOC exists).
- `excerpt` — at most 200 characters, enough to locate the passage. If the
  passage contains a credential-shaped string, mask it (`AKIA****`) — never copy
  a secret into a suggestion.
- `reason` — one sentence: why it may be private.

An open `ISSUE` of type security in the selection is excluded by default; flag
it anyway if another included entity or a chapter describes it in prose.

### P5 — Mandatory pause

Present, before writing anything to the KB:

1. The selection (components, `--include` ids) and the number of entities read
   per component.
2. The book status per component (slug, chapters — or missing / ambiguous,
   with the `/manual-writer book` command to run).
3. The full draft of the card.
4. The suggestions list.
5. The open questions: every `TODO:` line, each with the exact datum it needs
   (maintainer, code license per component, ...). Ask for them now; the
   answers usually remove the TODOs before anything is written.

**Wait for the user to confirm or edit.**

### P6 — Create or update the card DOC

Find the existing card (unless `--manual` was given):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "DOC",
  project_id: "{PROJ}",
  tags_all: ["publication-manual"]
})
```

Keep only the results with an empty `component_id` and
`metadata.locale == "en"`. The engine resolves the card the same way when the
wizard does not name one, and refuses 0 (`card_missing`) or more than one
(`card_ambiguous`): if more than one remains, ask which one is the card.

Legacy manuals from kvendra-skills 1.17.0:

- An English manual (`locale: "en"`) becomes the card: update it in place —
  remove the "Translated from ..." notice, drop `metadata.is_primary` (send it
  as `null`), and keep the same entity.
- A manual in another language (`metadata.locale` other than `en`) is never
  the card and is never auto-resolved by the engine. Do not archive it: tell
  the user, and offer to mark it with `metadata.superseded_by: "<card DOC id>"`
  (Guarded update (CAS)). Archiving it is the owner's decision.

Create (project-wide: OMIT `component_id`):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: "{PROJ}",
  title: "Publication card: {PROJ} ({COMP list})",
  content: <the confirmed card, Markdown, starting with "# {title}">,
  tags: ["publication-manual", "doc:genre:publication-manual", "locale:en"],
  metadata: {
    updated_by: "skill:manual-writer",
    locale: "en",
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

Update (apply the **Guarded update (CAS)** rule):

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
  entity_id: "<card DOC id>",
  expected_version: <version from the entity_get you just did>,
  content: <the confirmed card>,
  metadata: {
    updated_by: "skill:manual-writer",
    locale: "en",
    publication_components: [...],
    publication_review: [...],          // replaces the previous list
    publication_review_at: "<ISO timestamp>"
  },
  relations_add: [ { type: "affects", target: "CMP-{PROJ}-{COMP}" } ],
  txn_id: "<txn_id>"
})
```

- `publication_review` lives ONLY in metadata. The server copies it to a
  private review sidecar of the draft and never into the published artifact;
  the card DOC itself is published as the card text, not as an entity.
- Standalone run (no `txn_id` from an orchestrator): run
  `txn_check_interrupted` and `txn_create` before the write and `txn_activate`
  after it, as in the Kvendra rules.
- Saving a card that still has `TODO:` lines is allowed (it keeps the work),
  but it is NOT ready — continue with P7.

### P7 — Completeness gate (no `TODO:` left, every book present)

After writing, search the card for `TODO:`.

- **If any remains**, the card is **not ready**. List to the user exactly what
  is missing, one line per TODO: section heading and the datum needed — e.g.
  "Maintainer: name and contact", "Licenses: code license of CLI (SPDX id)".
  Ask for those data. With the answers, replace the TODOs and write the card
  again with the Guarded update (CAS) rule. Repeat until no `TODO:` remains.
- **Never** declare the card ready, report it as prepared, or point the user
  to the publish wizard while any `TODO:` remains. Never remove a TODO by
  inventing a value or by deleting the section: only real data from the user
  (or from the scoped KB) clears it.
- **Books**: the publication is not ready while a selected component has a
  missing or ambiguous book (P1.4). List the `/manual-writer book {PROJ} {COMP}`
  commands to run.
- If the user stops before answering, end with status `NOT READY` and the list
  of pending items; a later run of the same command resumes from the stored
  card.
- **When zero TODOs remain and every component has a book**, the publication
  is ready to be prepared in the dashboard. Tell the user the next step: open
  the dashboard publish wizard, select the same components; the "Card &
  books" step shows the card and the books, and the preview shows the server
  scan and these suggestions before anything is published.

### Publication mode — required output

```
### PUBLICATION CARD: READY | NOT READY (never published by this skill)
- Project: {PROJ}
- Components: {COMP list}
- Explicit project-wide includes: N (ids)
- Entities read: N per component
- Card: DOC-... (en, created/updated, version N, N characters)
- Sections: 7/7 English headings present
- Books: {COMP} → {slug} (N chapters) | MISSING | AMBIGUOUS — one line per component
- Review suggestions: N (customer N · pricing N · open-vulnerability N · other N)
- Remaining TODOs: N   (READY requires 0 and every book present)

### MISSING DATA (only when NOT READY)
- {section heading}: {exact datum needed}
- Book of {COMP}: run /manual-writer book {PROJ} {COMP}
- ...

### NEXT STEP (only when READY)
Dashboard → Publications → New: select the same components. The "Card &
books" step must show this card and one English book per component. The
server scans the card, the chapters and the entities again; blocking findings
stop the publication.
```

## Docs mode (default) — Steps 1–10

The steps below write a documentation book as Markdown files under
`docs/{book-slug}/` of the repository. They do not apply to KB book mode or
publication mode.

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

## Docs mode — required output

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
- **Single language: English (every mode).** No multi-locale generation. In
  Docs mode the runtime agent translates its chat output to the project's
  CLAUDE.md language; KB book chapters and the publication card are always
  English.
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
- **KB book mode writes one English book per component.** Chapters are DOCs
  of the component (`component_id`) with `metadata.book` (one slug per
  component), a unique integer `metadata.chapter` (1..999) and
  `metadata.locale: "en"`, derived from the component's code (when a
  repository is registered) and its KB, citing entities by id. Idempotent by
  `(component, book, chapter)` with the Guarded update (CAS) rule; never
  deletes, archives or renumbers chapters without the owner. No chapter is
  empty or only `TODO:`; limits 200 chapters, 200,000 characters per chapter,
  3,000,000 per book.
- **Publication mode is scoped and read-only towards the outside.** It reads
  only the selected components (plus explicit includes), writes ONE
  project-wide English card (`publication-manual` tag, `metadata.locale:
  "en"`), keeps redaction suggestions (covering entities and book chapters) in
  its `metadata.publication_review`, checks that every selected component has
  a book, and never publishes. The seven English headings are mandatory; the
  server validates them and scans the card. A card with any `TODO:` left, or a
  selection with a missing book, is NOT ready: ask for the missing data, or
  point to `/manual-writer book`, until nothing remains.
