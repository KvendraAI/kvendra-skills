# Changelog

All notable changes to the `kvendra-skills` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-<VER>` entity in the
Kvendra KB with the same content plus traceability links.

## [1.0.0] — 2026-05-26 — Marketplace v2 (REQ-629F77 Phase 5 closure)

### Highlights

First stable release of `kvendra-skills`. The plugin is now fully in
English source language, KB/STD-driven, and ships with a CI lint that
enforces these properties going forward. Phase 4 of REQ-KVD-SKILLS-629F77
already migrated the 23 in-scope skills across v0.5.0/v0.6.0/v0.7.0;
Phase 5 (this release) adds the lint workflow, `CONTRIBUTING.md`,
deprecation notice and IF cleanup, and closes ROAD-KVD-SKILLS-A32F3C.

### Added

- `.github/workflows/lint-skill-md.yml` — CI workflow that runs on every
  PR touching `plugins/kvendra-skills/skills/**/SKILL.md`:
  - **EN-only check**: flags Spanish vocabulary, accented characters and
    Spanish-only punctuation. Whitelist with `<!-- lint-allow-es -->`.
  - **No-tech-specifics check**: flags bare command invocations outside
    fenced code blocks. Whitelists the broker primitive table
    (`kvendra.<primitive>`) and the canonical `FORBIDDEN via Bash` block.
- `CONTRIBUTING.md` — contribution guide with skill + STD playbook
  templates, frontmatter schema, subagent vs orchestrator convention and
  the full pull-request checklist.

### Changed

- `IF-KVD-SKILLS-0B3776` (Skills Plugin Format) refactored:
  - Removed references to "cline", "kvendra-skills-community", "LLM ≤14B".
  - Re-titled to "Skills Plugin Format (Claude Code .claude-plugin) v1.0".
  - Bumped from v0.1 → v1.0.
  - Tags cleaned (removed `m2-spike`, `milestone:road-716183-m2`).
  - Status remains `active`.

### Archived (KB)

- `IF-KVD-SKILLS-0BD08E` (Orchestrator Runtime v0.1) — archived. Rationale:
  cross-orchestrator runtime contract no longer applicable post strategic
  shift of 2026-05-26 (PAT-KVD-4AF89B). Claude Code is the universal
  orchestrator with superset tools; cline track deprecated
  (ADR-KVD-SKILLS-552A8F superseded).

### Deprecation

- The v1 (Spanish, partially tech-specific) SKILL.md files are FULLY
  REPLACED in this release. There is no v1 ↔ v1.0.0 compatibility shim
  because slugs are unchanged: any `/<skill>` invocation continues to
  work, the only delta is the source language (which the runtime agent
  translates back to the project's CLAUDE.md language anyway).
- The `translator` skill was archived in v0.7.0 (Phase 4 Lot 3) per
  PAT-KVD-4AF89B (runtime translation makes a dedicated translator
  redundant). Its use case is covered by `manual-writer`'s Step 11.

### Plugin state after this release

- **28 active skills**, all in English source.
- Plugin manifest: `plugins/kvendra-skills/.claude-plugin/plugin.json`
  version `1.0.0`.
- Marketplace entry: `.claude-plugin/marketplace.json` version `1.0.0`.

## [0.7.0] — 2026-05-26 — Phase 4 Lot 3: low-impact skills EN + translator archive

11 low-impact skills migrated to English (`updater`, `env-check`,
`changelog`, `to-do`, `to-do-summary`, `user-help`, `interface-validator`,
`functional-expert`, `doc-indexer`, `doc-validator`, `manual-writer`).
The `translator` skill directory was removed per PAT-KVD-4AF89B.
`user-help` received a significant content cleanup: legacy "Winking Owl"
branding removed, legacy project codes replaced with `<PROJ>` placeholders,
obsolete skill names updated, post-Phase-2/3/4 skills catalogued.

KB: `REL-KVD-SKILLS-0.7.0`, `ISSUE-KVD-SKILLS-14043F`, `TEST-KVD-SKILLS-D89748`, `TXN-KVD-20260526-010`.

## [0.6.0] — 2026-05-26 — Phase 4 Lot 2: mid-impact skills EN

8 mid-impact skills migrated to English (`planner`, `requirements-analyst`,
`implementer`, `validator`, `tester`, `analyzer`, `regression`,
`incident-manager`). Zero STDs needed — all 8 are pure subagents / KB
lifecycle managers that consume STD/TEST/REG recipes at runtime.

KB: `REL-KVD-SKILLS-0.6.0`, `ISSUE-KVD-SKILLS-E8C8DD`, `TEST-KVD-SKILLS-56C49E`, `TXN-KVD-20260526-009`.

## [0.5.0] — 2026-05-26 — Phase 4 Lot 1: high-impact skills EN

4 high-impact skills migrated to English (`consultancy`, `new-feature`,
`bug`, `release-manager`). Zero STDs needed — all 4 are pure orchestrators
or KB lifecycle managers with no tech-specific recipes.

KB: `REL-KVD-SKILLS-0.5.0`, `ISSUE-KVD-SKILLS-86CD59`, `TEST-KVD-SKILLS-6D86C5`, `TXN-KVD-20260526-008`.

## [0.4.0] — 2026-05-26 — Release introspection

Added the `kvendra-skills:version` skill for fast install-state
introspection (reads `plugin.json` + queries `REL-KVD-SKILLS-*` entities).
Retroactive `REL-KVD-SKILLS-*` entities were created for 0.2.0, 0.2.1
and 0.3.0 so the new skill has data to query.

KB: `REL-KVD-SKILLS-0.4.0`, `TXN-KVD-20260526-007`.

## [0.3.0] — 2026-05-26 — REQ-629F77 Phase 3: STD-driven deploy pilot

`kvendra-skills:backend-deploy` renamed to `kvendra-skills:deploy` and
refactored to read `STD-<PROJECT>-<COMPONENT>-DEPLOY-PROCESS` at runtime
(`ADR-KVD-SKILLS-BB0E8A`). Validated empirically via `STD-KVD-WEB-A52498`
and `STD-KVD-ENTERPRISE-CD2D7A`.

KB: `REL-KVD-SKILLS-0.3.0`.

## [0.2.1] — 2026-05-26 — Patch: tag-based KB discovery

`sync-claudemd` and `lint-claudemd` use tag-based discovery
(`PAT-KVD-577667`) instead of literal-id lookup. `force_id` is restricted
to `PRJ`/`CMP`/`REL` on the server side, so well-known canonical entities
of other types must be discovered by their tag coordinates.

KB: `REL-KVD-SKILLS-0.2.1`.

## [0.2.0] — 2026-05-26 — DX Foundations (REQ-50F9E4)

Three foundational DX skills shipped:
- `kvendra-skills:onboard-project` — interactive onboarding pipeline with
  automatic tier detection via `whoami`, creates PRJ + CMPs + GLO + STDs.
- `kvendra-skills:sync-claudemd` — regenerates a project's `CLAUDE.md`
  from the canonical template, preserving the `Particularidades` section.
- `kvendra-skills:lint-claudemd` — validates a `CLAUDE.md` against the
  canonical template.

KB: `REL-KVD-SKILLS-0.2.0`.
