---
name: doc-indexer
description: Documentation indexer — reads .md files under a project's docs/ directory and creates DOC entries in the Kvendra KB (one entry per file)
user_invocable: true
args: "[optional path under docs/ to limit the scope, e.g. docs/onboarding/]"
---

# Doc Indexer — Index project documentation into the Kvendra KB

You read all the Markdown files under a project's `docs/` directory and
create or update DOC entries in the Kvendra KB, one entry per file. Each
entry captures a short summary, the key facts the file states, the
domain terminology it uses, and the relative file path so that
`manual-writer` and any future skill can consult prior documentation for
consistency before writing new content.

## Optional path scope

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md`. If the user passed a path
(e.g. `docs/onboarding/`), use it as the scope; otherwise index every
`.md` under `<project root>/docs/`.

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

## Step 1 — Locate the Markdown files

Find every `.md` under the scope:

```bash
find docs -name '*.md' -type f
```

If a path scope is passed via args (e.g. `docs/onboarding/`), restrict
the search to that subtree. Skip hidden directories. List the files and
report the total; ask the user to confirm if the count is unexpectedly
large (> 50 files).

## Step 2 — Read and analyze each file

For each `.md`:

1. Read the file fully.
2. Extract:
   - **Summary** — 2-3 sentences.
   - **Key facts** — concrete statements (entities, flows, states, roles, URLs, configs, rules).
   - **Terminology** — domain-specific terms with the definition as used in this file.
   - **Cross-references** — mentions of other files / sections (relative links inside `docs/`).
   - **Audience** — one of `user | technical | operations | functional`.

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
`entity_update`. Otherwise → `entity_create`. Idempotent: re-running the
skill on the same `docs/` directory updates in place rather than
duplicating.

## Step 4 — Create or update the DOC entry

One entry per `.md` file:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: <PROJ>,
  title: "DOC: <relative file path>",
  content: <see format below>,
  metadata: {
    file_path: "<path relative to project root, e.g. docs/onboarding/01-intro.md>",
    audience: "<user|technical|operations|functional>",
    last_indexed: "<ISO date>"
  },
  tags: ["<audience>", "<top-level topic>"],
  updated_by: "skill:doc-indexer"
})
```

(DOC in the Kvendra KB does NOT accept relations — `relations=no` in
ENTITY_CONFIG. Cross-references go in `metadata.crossrefs` or in tags.)

### Content format

```markdown
## File: <relative path>
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

## Step 5 — Consistency report

After all files are processed, report:

1. Terms with divergent definitions across files.
2. Potentially contradictory facts.
3. Detected gaps (e.g. a referenced cross-link that has no target file).
4. Duplications (two files covering the same topic for the same audience).

## Output

```
### INDEXED DOCUMENTATION
- Project: <project_id>
- Scope: docs/ (or `<path>` if scoped)
- Files processed: N
- DOC entries: N (new: X, updated: Y)

### FILES PROCESSED
| Path | Audience | Tags |
|------|----------|------|

### CONSISTENCY ANALYSIS
#### Divergent terms
- ...
#### Contradictory facts
- ...
#### Gaps
- ...
#### Duplications
- ...

### RECOMMENDED NEXT STEPS
- ...
```

## Rules

- **Read the actual content** — do not assume what a file says.
- **Do not modify the Markdown files** — only create / update DOC entries.
- **Be conservative with facts** — only verifiable statements.
- **One DOC entry per `.md` file** — no sub-section splitting.
- **Idempotent** — update if a DOC with the same `file_path` already
  exists. Re-running is safe.
- **Always relative paths** — `file_path` is relative to the project root.
- **English only** — the source files in `docs/` are English (per
  ADR-KVD-SKILLS-244215). DOC entries' content is English. The runtime
  agent translates output to the project's CLAUDE.md language.
