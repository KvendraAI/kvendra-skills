---
name: version
description: Show the installed kvendra-skills plugin version + recent releases with their capabilities. Use to verify /plugin update applied, or to discover what shipped in each release.
user_invocable: true
args: "[--history] [--skills]  empty = brief summary; --history = full release history; --skills = list available skills"
---

# Version v1 — Show installed plugin state + release history

Fast introspection of the `kvendra-skills` plugin install state. Answers three common questions:

1. **What version do I have installed?** — reads `plugin.json` (local source of truth).
2. **What did each release ship?** — queries KB `REL-KVD-SKILLS-*` entities for capabilities + commit/tag info.
3. **Which skills are available?** — lists all loaded skills with descriptions (`--skills` flag).

Useful when:
- Verifying `/plugin update kvendra-skills` actually applied (compare installed vs. latest in KB).
- Quickly checking if a recently-announced capability is present locally.
- Onboarding a new contributor: shows the release timeline at a glance.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Input

`$ARGUMENTS` may be:
- Empty → brief summary (installed version + latest 3 releases + capabilities one-liner each).
- `--history` → full release history from KB (all `REL-KVD-SKILLS-*` entities).
- `--skills` → enumerate available skills + descriptions (reads plugin filesystem).
- `--skills --history` (or `--history --skills`) → combined view.

## Step 0 — Initialization + fail-safe

This skill is **read-only and degraded-mode tolerant**:
- Plugin file read is always available (local filesystem). Always works.
- KB query for RELs is best-effort — if MCP unreachable, fall back to showing only the installed version with a note.

## Step 1 — Read installed version

Read `<plugin-root>/.claude-plugin/plugin.json` to get `version`. The plugin root is typically `~/.claude/plugins/cache/kvendra-marketplace/kvendra-skills/<version>/` for marketplace installs, or the developer's repo clone for source installs.

If the file is missing or malformed: surface an ERROR with the file path tried. Recommend `/plugin update kvendra-skills` to repair.

## Step 2 — Read KB releases (best-effort)

```
entity_query({
  entity_type: "REL",
  project_id: "KVD",
  component_id: "KVD-SKILLS",
  tags_all: ["release", "scope:skills"],
  status: "active",
  order_by: "entity_id_asc",
  limit: 50
})
```

Then reverse to get descending order (latest first). REL `entity_id` pattern is `REL-KVD-SKILLS-<X.Y.Z>` (sortable alphabetically when versions follow semver). For non-semver suffix RELs (e.g. `0.2.0-alpha.1`), the per-segment sort is still correct.

If query fails (MCP offline, network) → continue with empty list + degraded notice in output.

## Step 3 — Detect drift between installed and latest

Compare:
- Installed: from Step 1 (`plugin.json.version`).
- Latest in KB: first item from Step 2 result (highest version).

Outcomes:
- **Match**: ✅ — your install is up to date.
- **Installed < latest in KB**: ⚠️ — `/plugin update kvendra-skills` to upgrade. Show what's in the gap.
- **Installed > latest in KB**: ℹ️ — your install is ahead of the published KB record (rare; suggests local dev install or KB out of sync). NOT an error.
- **No KB data**: ℹ️ — KB unavailable; cannot detect drift. Continue with what we have.

## Step 4 — Brief summary (default — no flags)

```
## kvendra-skills — installed v<installed_version>

<drift indicator: ✅ up to date | ⚠️ <N> versions behind | ℹ️ ahead | ℹ️ KB unavailable>

### Latest releases (3 most recent)
| Version | Released   | Name                  | Key capabilities              |
|---------|------------|-----------------------|-------------------------------|
| 0.4.0   | 2026-05-26 | Release introspection | /version skill + retro RELs   |
| 0.3.0   | 2026-05-26 | Pilot deploy          | /deploy STD-driven + 2 STDs   |
| 0.2.1   | 2026-05-26 | Patch                 | tag-based KB discovery (PAT-577667) |

### How to upgrade
`/plugin update kvendra-skills`  (or restart Claude Code)

### Full history
Run `/version --history`
```

## Step 5 — `--history` (expanded history)

Show all RELs (filtered to non-archived, status active). For each:
- Version + release name.
- Released date.
- Commit + tag.
- Capabilities (extract from REL content's "## Capabilities new in this version" section, max 3 bullets).
- Origin REQ (if any).

Format suggestion (vertical card layout):

```
v<version>  —  <name>  (released <date>)
─────────────────────────────────────────
Commit:        <hash>
Tag:           <tag>
Origin:        <REQ-id | "owner-suggestion" | other>
Capabilities:
  - <bullet 1>
  - <bullet 2>
  - <bullet 3>
─────────────────────────────────────────
```

## Step 6 — `--skills` (skill enumeration)

Walk `<plugin-root>/skills/*/SKILL.md`. For each:
- Parse the YAML frontmatter (`name`, `description`).
- Skip dirs without SKILL.md.

Show as a sorted table:

```
| Skill                         | User-invocable | Description                        |
|-------------------------------|----------------|------------------------------------|
| kvendra-skills:bug            | yes            | Orquestador de testing v3 ...      |
| kvendra-skills:deploy         | yes            | Deploy a Kvendra component ...     |
| ...                           |                |                                    |
```

(`user-invocable` reflects the `user_invocable: true` flag in frontmatter — false / missing = subagent-only.)

## Operational notes

- **Read-only**: this skill never writes to disk, never creates KB entities.
- **No TXN required**.
- **Mode-agnostic**: works in cloud (Pro+) and local (Free).
- **Fast**: typical execution <2s in cloud, <1s local (only one KB query, indexed by entity_id).
- **Caching**: not needed at the skill layer — KB query is cheap.

## Output examples

### Empty args (brief)

```
## kvendra-skills — installed v0.4.0

✅ Up to date (latest KB record is v0.4.0).

### Latest releases (3 most recent)
| Version | Released   | Name                  | Key capabilities                    |
|---------|------------|-----------------------|-------------------------------------|
| 0.4.0   | 2026-05-26 | Release introspection | /version skill + retro RELs         |
| 0.3.0   | 2026-05-26 | Pilot deploy          | /deploy STD-driven + 2 STDs         |
| 0.2.1   | 2026-05-26 | Patch                 | tag-based KB discovery (PAT-577667) |

### How to upgrade
Already on latest. Run `/version --history` to see all releases or `/version --skills` to list available skills.
```

### `--history` (expanded)

Detailed multi-card output showing every REL in the KB.

### `--skills`

Tabular skill enumeration.

## Trazabilidad

- Origin: owner DX suggestion 2026-05-26.
- TXN: TXN-KVD-20260526-007 (this release).
- REL: REL-KVD-SKILLS-0.4.0.
- Materializes the convention "RELs in KB = canonical changelog" — first time we use this pattern systematically for kvendra-skills.
