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

## Step 4 — Create or update the DOC entry

One entry per `.md` file:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: <PROJ>,
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
  updated_by: "skill:doc-indexer"
})
```

(DOC in the Kvendra KB does NOT accept relations — `relations=no` in
ENTITY_CONFIG. Cross-references go in `metadata.crossrefs` or in tags.)

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
