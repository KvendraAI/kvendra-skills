---
name: doc-indexer
description: Documentation indexer — reads existing manuals and creates DOC entries in the Kvendra KB to guarantee consistency
user_invocable: false
args: "[project and docs directory to index]"
---

# Doc Indexer — Index existing documentation

You act as a **Documentation Archivist**. You read all the existing manuals
of a project and create/update DOC entries in the Kvendra KB that summarise
what each section says, what facts it states, what terminology it uses and
where the original file lives. This allows `manual-writer` to consult prior
documentation before writing anything new.

## Objective

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

The directory layout and file conventions used in Step 1 and Step 4 below
(e.g. `docs/manual-*`, `info.json`, `sections/<locale>/`) are project-level
conventions. When a project formalises its doc-portal as a CMP in the
Kvendra KB, the canonical recipe should live in
`STD-<DOC_PROJECT>-DOC-PORTAL-FORMAT` per ADR-KVD-SKILLS-BB0E8A. While that
STD playbook does not yet exist, these conventions remain inline as
sensible defaults — the skill consumes whatever `info.json` / `index.json`
schema the project actually uses.

## Step 1 — Locate existing manuals

Look for:
1. `docs/` at the project root.
2. Subdirectories matching `manual-*` inside `docs/`.
3. Manuals in a doc-portal workspace (e.g. `<doc-portal-cmp>/manuals/`) if applicable.

If the user specifies a directory, use it directly.

List the `.md` files by name. Report the total and ask the user to confirm.

## Step 2 — Read and analyze each section

For each `.md`:
1. **Read** the file fully.
2. Extract:
   - **Summary**: 2-3 sentences.
   - **Key facts**: concrete claims (entities, flows, states, roles, URLs, configs, rules).
   - **Terminology**: domain-specific terms with the definition as used here.
   - **Cross-references**: mentions of other manuals / sections.
   - **Audience**: user / developer / operations / functional.

## Step 3 — Check existing entries

Before creating: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<section title>, entity_type:"DOC", project_id:<PROJ>, limit:5 })`.

If you find a DOC with the same `file_path` in metadata → `entity_update`.
Otherwise, `entity_create`.

## Step 4 — Create/update DOC entries

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: <PROJ>,
  title: "DOC-<manual_id>-<NN>: <section title>",
  content: <see format below>,
  metadata: {
    manual_id: "<manual-id>",
    section_number: "<NN>",
    file_path: "<path RELATIVE to the project>",
    audience: "<user|technical|operations|functional>",
    last_indexed: "<date>"
  },
  tags: ["<manual-type>", "<topic>", "<audience>"],
  updated_by: "skill:doc-indexer"
})
```

(DOC in the Kvendra KB does NOT accept relations — `relations=no` in ENTITY_CONFIG.
Cross-references go in `metadata.crossrefs` or in tags.)

### Content format

```markdown
## Manual: <name>
## Section: <title>
## Audience: <audience>
## File: <relative path>

### Summary
<2-3 sentences>

### Key facts
- <fact 1>
- <fact 2>

### Terminology
- **<term>**: <definition>

### Cross-references
- Related to: <sections>
- Depends on: <prerequisites>
```

### Tags

| Tag | When |
|-----|------|
| `manual-user` | End-user manual |
| `manual-technical` | Developer manual |
| `manual-operations` | DevOps / SRE manual |
| `manual-functional` | PO / QA manual |
| `<topic>` | Main topic |
| `<audience>` | Audience |

## Step 5 — Consistency report

1. Terms with divergent definitions.
2. Potentially contradictory facts.
3. Detected gaps.
4. Duplications.

## Output

```
### INDEXED DOCUMENTATION
- Project: <project_id>
- Manuals processed: N
- Sections indexed: N (new: X, updated: Y)
- DOC entries created in Kvendra: N

### MANUALS PROCESSED
| Manual | Type | Sections | Tags |
|--------|------|----------|------|

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

- **Read the actual content** — do not assume what a document says.
- **Do not modify the manuals** — only create DOC entries.
- **Be conservative with facts** — only verifiable statements.
- **Granularity by section** — one DOC entry per section.
- **Idempotent** — update if it already exists (same file_path).
- **NEVER absolute paths** — always relative to the repo.
