---
name: doc-indexer
description: Documentation indexer — reads .md files under a project's docs/ directory, creates one DOC entry per file (tagged by genre), and regenerates the docs/README.md library super-index
user_invocable: true
args: "[optional path under docs/ to limit the scope, e.g. docs/architecture-c4/]"
---

# Doc Indexer — Index project documentation into the Kvendra KB

You read all the Markdown files under a project's `docs/` directory and
create or update DOC entries in the Kvendra KB, one entry per file. Each
entry captures a short summary, the key facts the file states, the domain
terminology it uses, the book genre, and the relative file path so that
`manual-writer` and any future skill can consult prior documentation for
consistency before writing new content. You also regenerate the project
documentation **library super-index** (`docs/README.md`) so the books are
easy to navigate.

## Optional path scope

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md`. If the user passed a path
(e.g. `docs/architecture-c4/`), use it as the scope for the per-file
indexing; otherwise index every `.md` under `<project root>/docs/`. The
library super-index (Step 5) is ALWAYS regenerated from the full `docs/`
tree regardless of scope.

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
- **`component_id` is an explicit decision, never a guess.** Pass the bare
  component code — uppercase A-Z + digits, NO project prefix and NO hyphens
  (e.g. `"SKILLS"`, never `"KVD-SKILLS"`) — when the entity belongs to one
  specific component; **OMIT the key entirely** when it is genuinely
  project-wide (a cross-component ADR/ROAD, a project-level docs book, `PRJ`).
  Never invent a component to fill the field and never pass `null` (`null` is
  a hard 400 on `entity_query`); if the scope is not obvious from the work at
  hand, ask the user — `component_id` cannot be changed after creation, and an
  entity created without it never appears in the component's tabs.
- If an error returns `error.help.topic`, call `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Step 1 — Locate the Markdown files

Find every `.md` under the scope:

```bash
find docs -name '*.md' -type f
```

If a path scope is passed via args (e.g. `docs/architecture-c4/`), restrict
the per-file indexing to that subtree. Skip hidden directories. List the
files and report the total; ask the user to confirm if the count is
unexpectedly large (> 50 files).

## Step 2 — Read and analyze each file

For each `.md`:

1. Read the file fully.
2. If the file is a book `README.md`, read its YAML front-matter
   (`kvendra_doc: book`, `genre`, `audience`, `depth`, `source`, `title`).
3. Extract:
   - **Summary** — 2-3 sentences.
   - **Key facts** — concrete statements (entities, flows, states, roles, URLs, configs, rules).
   - **Terminology** — domain-specific terms with the definition as used in this file.
   - **Cross-references** — mentions of other files / sections (relative links inside `docs/`).
   - **Audience** — one of `user | technical | operations | functional | all`.
   - **Genre** — from the book front-matter (`genre`). If absent (legacy book),
     infer from content/path and flag it in the consistency report.
   - **Source** — `authored | kb-projection` from front-matter (default `authored`).

## Step 3 — Check for existing entries

Before creating, look up by path:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({
  query: "<file path>",
  entity_type: "DOC",
  project_id: <PROJ>,
  limit: 5
})
```

If a DOC entry exists with the same `file_path` in metadata → use
`entity_update` (apply the **Guarded update (CAS)** rule). Otherwise →
`entity_create`. Idempotent: re-running the skill on the same `docs/`
directory updates in place rather than duplicating.

## Step 3b — Resolve the relation targets from the KB

Do this ONCE, before the first create. Relation targets must be ids the KB
returned to you, never ids you assembled from `CLAUDE.md`, from a path
segment or from a book slug:

    mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id: "PRJ-<PROJ>" })
    mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type: "CMP", project_id: "<PROJ>" })

- If `entity_get` on the PRJ returns `not_found`: STOP and report that the
  project is not onboarded (run `/onboard-project` first). Do NOT index docs
  that have nowhere to attach.
- Map a file to a component ONLY when the mapping is unambiguous:
  1. the book `README.md` front-matter declares `scope: CMP-<PROJ>-<COMP>` and
     that id is in the CMP list returned above; or
  2. exactly one CMP code from that list matches a path segment or the book
     slug, case-insensitively.
  Otherwise the file is a project-level doc: no `component_id`, no `affects`.
  When a book's front-matter DECLARES a `scope:` that is not in the CMP list,
  do not fall back silently: index it as project-level AND flag it in the
  Step 6 consistency report, naming the book and the unresolved id. The
  author stated an intent the KB cannot honour — that is a finding, not a
  default.
- Keep the resolved ids verbatim in `relations[].target` — do not normalise,
  re-case or re-hyphenate them. This applies to full entity ids only:
  `component_id` is a separate field and takes the BARE component code out
  of that id (`CMP-KVD-SKILLS` -> `"SKILLS"`), never the id itself.

## Step 4 — Create or update the DOC entry

One entry per `.md` file:

Decide `component_id` ONCE per book, not per file: every `.md` under the same
`docs/<book>/` directory shares that book's scope. A book documenting one
component (e.g. `docs/api-ref/` of a single service) carries that component's
code; a project-wide book (e.g. `docs/project-overview/`) omits the key.

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: <PROJ>,
  component_id: <bare component code if the book documents one component; OMIT the key if project-wide>,
  title: "DOC: <relative file path>",
  content: <see format below>,
  metadata: {
    file_path: "<path relative to project root, e.g. docs/architecture-c4/01-context.md>",
    audience: "<user|technical|operations|functional|all>",
    genre: "<book genre, e.g. c4>",
    source: "<authored|kb-projection>",
    last_indexed: "<ISO date>"
  },
  tags: ["audience:<audience>", "doc:genre:<genre>", "<top-level topic>"],
  relations: [
    { type: "part_of", target: "<PRJ id from Step 3b>" },   // ALWAYS
    { type: "affects", target: "<CMP id from Step 3b>" }     // only when a component was resolved
  ],
  txn_id: "<txn_id>",            // only when an orchestrator passed one; omit for a standalone run
  updated_by: "skill:doc-indexer"
})
```

### Relations — required, not optional

Every DOC carries `part_of` to its PRJ. That is what gives the document a
place in the project tree the glossary defines: a DOC with no outbound edge is
an orphan, invisible to `entity_related` and to the Component "Docs" tab. When
Step 3b resolved a component, add `affects` to that CMP as well — `affects`
rather than `part_of`, because an architecture document legitimately crosses
several components and `part_of` would claim sole ownership.

Doc-to-doc cross-references stay in the `### Cross-references` content section
below. Do NOT turn them into relations during this pass: they point at files
whose DOC entries may not exist yet, and a missing target aborts the create
(see below). If you want them as edges, do a SECOND pass after every DOC of
the run exists, with `entity_update({ relations_add: [...] })` under the
Guarded update (CAS) rule, and `entity_get` each target first.

That `entity_get` per target is not belt-and-braces: on the UPDATE path a
missing relation target is **not** reported as the clean error below. Measured
2026-09-10: `entity_update({relations_add})` with an absent target returns an
unmapped `{"error":{"type":"internal_error","message":"Internal server
error"}}` — no `field`, no offending id, nothing you can act on. Nothing is
persisted (verified: no version bump, no history row, valid relations in the
same call are not added either), so integrity holds; but you cannot recover
from the message, only from having checked first. Tracked in
`ISSUE-KVD-ENTERPRISE-0773E5`.

**Relation-target failure — never degrade.** If a relation target does not
exist the engine rejects the whole call and creates NOTHING (the entity row
and its relations are one database transaction; the target check is the
foreign key). The response is verbatim:

    {"error":{"type":"invalid_request","message":"relations: relations target CMP-KVD-NOPE999 not found","field":"relations"}}

The `message` echoes the offending target id. On this error: re-read the
correct id from the KB and retry with the corrected target. Do NOT retry with
`relations` removed or shortened, and do NOT move the reference into
`metadata` instead — that recreates the orphan this rule exists to prevent. If
the target genuinely does not exist, STOP and report it.

### Content format

```markdown
## File: <relative path>
## Genre: <genre>
## Audience: <audience>

### Summary
<2-3 sentences>

### Key facts
- <fact 1>
- <fact 2>

### Terminology
- **<term>**: <definition>

### Cross-references
- Related: <relative file path or section>
- Depends on: <relative file path or section>
```

## Step 5 — Regenerate the library super-index

After indexing the files, (re)generate the project documentation **library**
index at `docs/README.md` so the project's books are easy to navigate.

1. **Discover books**: for every `docs/<book>/README.md`, read its YAML
   front-matter (`kvendra_doc: book`, `genre`, `audience`, `depth`,
   `source`, `title`). This convention IS the registry — do NOT create
   `index.json`, `build-registry.js`, or any generated manifest.
2. **Write `docs/README.md`**:

```markdown
# <Project> Documentation Library

| Book | Genre | Audience | Depth | Summary |
|------|-------|----------|-------|---------|
| [<title>](./<book>/README.md) | <genre> | <audience> | <depth> | <1-line summary> |
```

3. **Additive and idempotent**: the index is rebuilt from the set of
   discovered books on every run — adding a book appends a row, removing a
   book drops it. Do not hand-edit it.
4. **Register the catalog**: create/update `docs/README.md` as a DOC entry
   tagged `doc:catalog` (one per project), so the KB knows which DOC is the
   library index. Use the **Guarded update (CAS)** flow if it already exists.

If a book directory has no front-matter (legacy), infer `genre` from its
content/path, still list it, and flag it in the consistency report.

## Step 6 — Consistency report

After all files are processed, report:

1. Terms with divergent definitions across files.
2. Potentially contradictory facts.
3. Detected gaps (e.g. a referenced cross-link that has no target file).
4. Duplications (two files covering the same topic for the same audience).
5. Books missing front-matter (listed in the super-index by inference).

## Output

```
### INDEXED DOCUMENTATION
- Project: <project_id>
- Scope: docs/ (or `<path>` if scoped)
- Files processed: N
- DOC entries: N (new: X, updated: Y)
- Library super-index: docs/README.md regenerated (books: M)

### FILES PROCESSED
| Path | Genre | Audience | Tags |
|------|-------|----------|------|

### CONSISTENCY ANALYSIS
#### Divergent terms
- ...
#### Contradictory facts
- ...
#### Gaps
- ...
#### Duplications
- ...
#### Books missing front-matter
- ...

### RECOMMENDED NEXT STEPS
- ...
```

## Rules

- **Read the actual content** — do not assume what a file says.
- **Do not modify the source `.md` files** — the only file this skill writes
  to disk is the generated `docs/README.md` library super-index. Everything
  else is KB DOC entries.
- **Super-index is generated, never hand-edited** — `docs/README.md` is
  rebuilt from book front-matter on every run, additively. Never create a
  JSON registry / `build-registry.js` / `index.json` (ROAD-KVD-SKILLS-79272A
  "Still in force").
- **Tag the genre** — every DOC entry carries `doc:genre:<g>`; the library
  index DOC carries `doc:catalog`.
- **Be conservative with facts** — only verifiable statements.
- **One DOC entry per `.md` file** — no sub-section splitting.
- **Idempotent** — update if a DOC with the same `file_path` already
  exists. Re-running is safe.
- **Always relative paths** — `file_path` is relative to the project root.
- **English only** — the source files in `docs/` are English (per
  ADR-KVD-SKILLS-244215). DOC entries' content is English. The runtime
  agent translates output to the project's CLAUDE.md language.
