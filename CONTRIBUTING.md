# Contributing to kvendra-skills

Thank you for considering a contribution to the `kvendra-skills` plugin.
This guide covers the conventions and templates used to keep skills
consistent, KB-driven and lint-passable.

## Source language

All `SKILL.md` files are written in **English**. The runtime agent
translates the output to the project's CLAUDE.md language at execution
time (per `ADR-KVD-SKILLS-244215`). Multi-locale source files are NOT
maintained — keeping one canonical English source eliminates drift.

If you need to include a Spanish (or any non-English) example for
legitimate reasons (e.g. quoting a user request), end the line with the
HTML comment `<!-- lint-allow-es -->` to whitelist it from the CI lint.

## Skill structure

Every skill lives in `plugins/kvendra-skills/skills/<slug>/SKILL.md`.

### Minimal `SKILL.md` template

````markdown
---
name: <slug>
description: <one-line English description, max 200 chars>
user_invocable: true | false
args: "[short arg description, optional]"
---

# <Title> — <one-line subtitle>

<Brief paragraph describing what the skill does and when to use it.>

## <Topic input parameter>

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` and `component_id` from the `CLAUDE.md` (where
applicable).

## Kvendra rules (summary)

- Identify yourself on every write: `updated_by: "skill:<this-skill>"`.
- Orchestrator → `txn_create` before creating entities, close with
  `txn_activate` (success) or `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel(reason)` (failure).
  Subagent → receives `txn_id` via args and does NOT open/close the TXN.
- Before opening a TXN: `mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted(project_id, component_id?)`.
- Entity IDs are emitted by the server. Exception: `PRJ`/`CMP`/`REL` require `force_id`.
- If an error returns `error.help.topic`, call `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`.

## External-execution rules (MANDATORY)

Any operation that uses credentials or leaves the local machine (git,
github, aws, npm, pypi, http with auth, shell commands) MUST be invoked
via primitives of the `kvendra` broker (local stdio MCP). NO direct Bash.

| Desired op | Primitive |
|---|---|
| git clone/push/pull/commit/tag | `kvendra.git` |
| GitHub REST/GraphQL | `kvendra.github` |
| AWS s3/cloudfront/lambda | `kvendra.aws` |
| npm publish/deprecate/read_metadata | `kvendra.npm` |
| PyPI upload/read_metadata | `kvendra.pypi` |
| HTTP with auth | `kvendra.http` |
| Shell with allowlisted binary (NOT `sh -c`) | `kvendra.shell` |

Each call requires a `profile_id` (workspace-bound vault credential).

**FORBIDDEN via Bash**: `git commit/push/tag/merge/reset --hard/checkout --`,
`gh release/pr create/api`, `aws s3 (sync|cp)/cloudfront/lambda`,
`npm publish`, `cargo publish`, `pip upload`/`twine upload`. Read-only
inspections (`git status`, `git log`, `gh issue view`,
`aws sts get-caller-identity`) ARE allowed via Bash.

If the `kvendra` broker is unavailable (failed to connect): STOP. NO
fallback to Bash.

Additionally enforced by the plugin's PreToolUse hook (active only inside
workspaces with a `.kvendra-workspace` marker).

## Step 1 — <Main action>

<Describe the main action of the skill. Use Kvendra KB queries to load
context, then perform the work.>

## Step 2 — <Optional next step>

...

## Output

```
<Show the canonical output format>
```

## Rules

- <Concise behavioural rule 1>
- <Rule 2>
````

### Frontmatter fields

| Field | Type | Purpose |
|---|---|---|
| `name` | string (kebab-case) | Unique slug within the plugin |
| `description` | string ≤ 200 chars | One-line English description used by Claude Code's catalogue |
| `user_invocable` | bool | `true` if the user can invoke `/name` directly; `false` for subagents only invoked by orchestrators |
| `args` | string (optional) | One-line description of expected arguments |

### Subagent vs orchestrator

- **Orchestrator** (`bug`, `new-feature`, `release-manager`, `incident-manager`): opens a `txn_create`, delegates to subagents via Agent, closes with `txn_activate` (or `txn_cancel` on failure). May coordinate multiple phases with explicit PAUSE points for user confirmation.
- **Subagent** (e.g. `planner`, `implementer`, `tester`, `validator`, `analyzer`, `updater`): receives `txn_id` via args, creates draft entities tagged with that TXN, returns a structured report to the orchestrator. Does NOT open or close TXNs.

The frontmatter `user_invocable` flag should be `true` for orchestrators and lifecycle managers (e.g. `release-manager`, `to-do`, `incident-manager`); `false` for pure subagents.

## STD playbook template

Project-specific recipes (deploy commands, release process, regression-suite execution rules, doc-portal layout, etc.) MUST live in `STD` entities of the Kvendra KB, not hardcoded in `SKILL.md`. The skill consumes the STD at runtime via tag-based discovery (`PAT-KVD-577667`).

### Minimal STD playbook structure

````markdown
# STD: <Title>

## Purpose
<1-2 paragraphs explaining what this playbook covers and when to invoke it.>

## Pre-conditions
- <required vault profile / credentials / env vars>
- <state assumptions: branch up-to-date, no in-progress TXN, etc.>

## Steps
1. <step description>
   - Command: `<exact command with {VAR} placeholders>`
   - Expected output: <pattern>
   - Failure mode: <what to do if fails>
2. <step>
...

## Post-conditions
- <verifiable outcomes: artifact published, dashboard green, etc.>

## Variables
| Name | Value | Notes |
|------|-------|-------|
| {VAR1} | <value or pointer to vault> | <when it changes> |

## Validation
- <how to verify the playbook ran correctly>

## Rollback
- <how to undo if needed>
````

### Naming convention

```
STD-<PROJECT>-<COMPONENT?>-<TOPIC>
```

- `<PROJECT>` ∈ {`KVD`, ...} — project_id, required.
- `<COMPONENT?>` — optional; omitted for cross-component recipes.
- `<TOPIC>` ∈ {`DEPLOY-PROCESS`, `RELEASE-PROCESS`, `TEST-PROCESS`, `REGRESSION-SUITE`, `DOC-PUBLISH`, `INCIDENT-RESPONSE`, ...}.

### Canonical metadata

```json
{
  "playbook_type": "deploy|release|test|regression|doc-publish|incident-response",
  "autonomous": true | false,
  "requires_confirmation": ["step-N", "..."],
  "vault_profile_required": "<profile_id>" | null,
  "estimated_duration_minutes": <number>
}
```

## CI checks

The CI workflow `.github/workflows/lint-skill-md.yml` runs on every PR
that touches `plugins/kvendra-skills/skills/**/SKILL.md`:

1. **EN-only check** — flags Spanish vocabulary, accented characters and
   Spanish-only punctuation. Whitelist a legitimate line with
   `<!-- lint-allow-es -->` at end-of-line.
2. **No-tech-specifics check** — flags bare command invocations
   (`` `aws s3 sync` ``, `` `sam deploy` ``, `` `npm publish` ``, etc.)
   outside fenced code blocks. The broker primitive table
   (`kvendra.<primitive>`) and the canonical `FORBIDDEN via Bash` block
   are whitelisted because they are skill-thin contracts, not direct
   invocations. Move new tech-specifics into STD entities of the KB.

Both checks must pass for the PR to be merged.

## Versioning

The plugin follows SemVer with the project convention
`^REL-[A-Z]+(-[A-Z0-9]+)?-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$` for the
KB release entity id.

- **Major bump (X.0.0)**: breaking changes that alter slugs, frontmatter
  schema or canonical output structure of multiple skills.
- **Minor bump (X.Y.0)**: new skills, behavioural enhancements,
  documentation overhauls.
- **Patch bump (X.Y.Z)**: bug fixes inside existing skills.
- **Hotfix segment (X.Y.Z.W)**: emergency fix on top of an already-tagged
  release.

For every release, create a `REL-KVD-SKILLS-<VER>` entity in the KB
(force_id required) with the release notes and the changelog.

## Pull-request checklist

- [ ] `SKILL.md` is in English (CI lint passes).
- [ ] No bare tech-specific commands inside the skill body (CI lint passes).
- [ ] Frontmatter has `name`, `description`, `user_invocable`; `args` if applicable.
- [ ] Subagent flag is correct (`user_invocable: false` for subagents).
- [ ] Broker-rules and FORBIDDEN-via-Bash block preserved (copy-paste verbatim).
- [ ] If you reference a project-specific recipe, point readers to the
      STD entity in the KB instead of inlining commands.
- [ ] If you added a new skill, update `user-help/SKILL.md` catalogue and
      `marketplace.json` description count.
- [ ] If you removed/renamed a skill, document the rationale in the
      PR description (and archive_reason if removing from the KB).

## License

The plugin is licensed under the MIT license (see `LICENSE`). By
contributing, you agree to license your contributions under the same
terms.
