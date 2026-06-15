# Changelog

All notable changes to the `kvendra-skills` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-<VER>` entity in the
Kvendra KB with the same content plus traceability links.

## [1.8.0] — 2026-06-15 — Decision-key adoption in ADR/IF writer skills (Paso C)

### Added

- **Decision key for gated classes (ADR / IF)** (Paso C of the guarded-update rollout): the writer skills that create or update an `ADR` or `IF` (`planner`, `consultancy`, `onboard-project`, `interface-validator`, `updater`) now carry a canonical **Decision key for gated classes** rule in their `## Kvendra rules (summary)` — set `metadata.decision = {key, value}` (ADR: `<domain>.<topic>` → position taken; IF: `interface.<wire-name>` → wire version). With the flag ON the engine rejects a gated create/activate lacking `decision.key` (`decision_required`) and surfaces same-`key`/different-`value` clashes (`decision_conflict`). `GLO`/`REQ` are intentionally NOT gated (scope narrowed — see `ADR-KVD-ENTERPRISE-015CA8`). **Flag-OFF-safe**: the added metadata is inert until `KB_DECISION_GATE_REQUIRED` is flipped.

### Refs

- ISSUE: `ISSUE-KVD-SKILLS-8F1E0D` · ADR: `ADR-KVD-ENTERPRISE-015CA8` (gate rescope to ADR(accepted)+IF; GLO/REQ warn-only) · REQ: `REQ-KVD-ENTERPRISE-7EC119` (AC-DECISIONKEY-REQUIRED-1)
- Engine (rescope, shipped staging): `ISSUE-KVD-ENTERPRISE-F801E5` (commit `7b99d2f`, `UPDATE_COMPLETE`) · corpus backfill of 47 ADR + 12 IF done same session (consultancy 2026-06-15).
- Enables the flip of `KB_DECISION_GATE_REQUIRED` once this version is installed (`/plugin update`) and adoption is verified. Follow-up: a `lint-skill-md` decision-key adoption check (analogous to the 1.7.0 CAS check) is deferred.

## [1.7.0] — 2026-06-14 — Guarded-update CAS adoption in writer skills (Paso B)

### Added

- **Guarded update (CAS) adoption** (Paso B of the guarded-update rollout): the 7 writer skills that call `entity_update` (`updater`, `release-manager`, `to-do`, `onboard-project`, `incident-manager`, `doc-indexer`, `consultancy`) now carry a canonical **Guarded update (CAS)** rule in their `## Kvendra rules (summary)` — capture `version` from the preceding read, send it as `expected_version`, and reconcile + bounded-retry on `409 VERSION_CONFLICT`. Makes the engine's optimistic lock effective end-to-end (the lock is ignored when `expected_version` is absent → last-write-wins). Client side of `IF-KVD-ENTERPRISE-060D2B` v1.3.
- **`lint-skill-md` guarded-update CAS adoption check**: any `SKILL.md` issuing an `entity_update(` call must carry the canonical rule — keeps adoption at 100% as new writer skills are added (the verifiable equivalent of the adoption gate before flipping `KB_TEAM_CAS_REQUIRED`).

### Refs

- ISSUE: `ISSUE-KVD-SKILLS-F438CE` · REQ: `REQ-KVD-ENTERPRISE-7EC119` (Paso B / Fase 1a) · IF: `IF-KVD-ENTERPRISE-060D2B` v1.3
- Backend (Paso A, shipped): `ISSUE-KVD-ENTERPRISE-C16A4E` (commit `9451a50`) · TXN: `TXN-KVD-20260614-004`
- Enables the Paso C flip of `KB_TEAM_CAS_REQUIRED` once adoption is verified. Enforcement-scope follow-up (Pro/Team/Enterprise): `ISSUE-KVD-ENTERPRISE-9C1D6E`.

## [1.6.0] — 2026-06-11 — Pipeline-autonomy schema v2: zero-gate mode + /loop integration

### Highlights

Pipeline-autonomy **schema_version 2**: a project can now declare `gates.new-feature: none` and `gates.bug: none` (**zero-gate mode**) — zero mandatory conversation pauses. The orchestrator still runs the exact same gate evaluation as single-gate, but auto-resolves every REVIEW signal with the most conservative viable option and records it in an auditable **AUTONOMY_LOG** (progress output + PHASE 5b ISSUE under `## Autonomy log (zero-gate)`, or the `txn_cancel` reason). An **inviolable hard floor** pauses even in zero-gate mode: no-go-list ops (production deploy, real registry publish, vault/allowlist mutation, destructive git/AWS), recurring cost impact > 20% of budget, and security-tagged changes failing exhaustive validation.

New `backlog_chaining` key: with zero-gate + a declared backlog scope (milestone tag, ROAD id or ISSUE list), `/new-feature` chains the next open backlog item after each `txn_activate` — pairing with the harness `/loop` for unattended milestone sessions. Pacing belongs to the harness; the skill never busy-waits.

Opt-in and backwards compatible: v1 payloads are consumed unchanged; absent STD = dual-gate legacy behaviour; an unknown `gates.*` value resolves to the most conservative mode (forward compatibility).

### Added

- **Zero-gate mode** (`gates.new-feature: none`, schema v2) in `/new-feature`: AUTONOMY GATE RECORD replaces the consolidated gate (same PROCEED/REVIEW criteria, auto-resolve-and-log), early-escalation signals auto-resolve except the hard floor, `AUTONOMY GATE — auto-approved | auto-resolved: N signals | HARD FLOOR pause: <reason>` progress line.
- **Zero-gate mode for `/bug`** (`gates.bug: none`, schema v2): the three stop rules auto-resolve with documented conservative strategies (infra work → blocked ISSUE; multi-component fixes → component-by-component; newly-surfaced bugs → extra PHASE 3 analyzer items or follow-up ISSUE).
- **AUTONOMY_LOG** (`autonomy_log: true`, v2 default): one line per auto-resolved signal (`<signal> → <resolution> — <rationale>`), shown in progress output and persisted into the PHASE 5b ISSUE (or `txn_cancel` reason).
- **Hard floor (never configurable)**: no-go-list op required / recurring cost > 20% / security-tagged change failing exhaustive validation — pauses in every mode. Validation criterion failing 3× in zero-gate: blocked ISSUE + continue when non-core, `txn_cancel` when core.
- **`backlog_chaining`** in `/new-feature`: chain the next open item of the declared scope after `txn_activate` (fresh policy read, fresh TXN). Stops on empty scope, hard-floor pause, 2 consecutive blocked items, or budget exhaustion.
- **Patient-polling guidance in `/deploy`**: long external convergence waits (CloudFormation, CloudFront, DNS/cert) poll read-only with ≥30s backoff, never abort early, and delegate pacing to the harness when recurring scheduling (e.g. `/loop`) is available.
- **Autonomous-sessions section in `/user-help`**: zero-gate + `/loop` pattern documented (chaining inside a session, harness re-invocation across sessions).

### Changed

- Most-conservative-wins merge extended: `dual` beats `single` beats `none`; `default` beats `none` in `gates.bug`; `false` beats `true` in `backlog_chaining`; unknown gate values resolve to the most conservative mode.
- Progress header now reports `autonomy: zero-gate | single-gate | dual-gate (policy: <STD-id> v<N> | defaults)`.

### Refs

- REQ: `REQ-KVD-SKILLS-CB8D16` (sibling of `REQ-KVD-SKILLS-3C218A`) · ADR: `ADR-KVD-SKILLS-5B6BBD`
- ROAD: `ROAD-KVD-SKILLS-C20D24` · STD: `STD-KVD-18F1EB` v2 (STD-KVD-PIPELINE-AUTONOMY)
- TXN: `TXN-KVD-20260611-001` · First use case: M2.5 Team workspace views unattended test session

## [1.5.0] — 2026-06-09 — Declarative pipeline-autonomy mode

### Highlights

Declarative pipeline-autonomy mode for the orchestrators. A project can now opt in — via a `STD-<PROJ>-PIPELINE-AUTONOMY` policy entity discovered by tag (`scope:pipeline-autonomy`) — to a faster pipeline shape: a single consolidated gate for `/new-feature`, parallel execution lanes, pre-loaded subagent context (CONTEXT_PACK) and informational SLA reporting.

Opt-in semantics: **no STD = byte-identical 1.4.0 behaviour**. The Step 0.5 discovery query returning 0 results selects the legacy defaults (dual gate, serial frontend/deploy, no context pack, no SLA report, validator level `auto`) with no error and no retry.

### Added

- **Single consolidated gate for `/new-feature`** via `gates.new-feature: single`: PHASE 0 no longer pauses (early-escalation signals still fire BEFORE the planner launches), and PHASE 1 presents REQUIREMENTS_REPORT + SPEC + a PROCEED/REVIEW recommendation in one mandatory pause covered by a single user decision.
- **STD-PIPELINE-AUTONOMY policy discovery (Step 0.5)** in `/new-feature` and `/bug`: one tag query, PROJ-level row + optional CMP-scoped row merged per key with most-conservative-wins.
- **Enforced multi-Agent parallel analyzers in `/bug` PHASE 3**: N bugs = N Agent calls in ONE single message; sequential launches are a protocol violation. `parallelize.analyzer_per_bug: false` forces serial execution (debug aid).
- **Optional frontend-parallel-to-deploy** in `/new-feature` PHASE 3/4a, gated by `parallelize.frontend_with_deploy: true` AND the planner's new `frontend_deploy_independent: yes` flag (new "Execution constraints" block in the SPEC output).
- **Context pack for subagents** (`context_pack: true`): one CONTEXT_PACK (loaded_at + txn_id + PRJ/CMP/IF/GLO/STD digests + Sources line of `entity_id@version` pairs) prepended to every subagent launch as pre-loaded KB context.
- **Validator level by change type**: precedence explicit user override > `validator_level_by_type` keyed by REQ/ISSUE type tags (hotfix → basic, feature → professional, security → exhaustive) > `validator_level_default` (`auto` = current heuristic). The `validator` skill honours the orchestrator-resolved level passed via args.
- **Non-blocking pipeline SLA report** (`sla_report: true`): wall-clock duration vs the pipeline SLA target after `txn_activate`, informational only; skips silently when no `scope:pipeline` SLA is found.

### Refs

- REQ: `REQ-KVD-SKILLS-3C218A` · ADRs: `ADR-KVD-SKILLS-BB0E8A`, `ADR-KVD-SKILLS-D0CC0A`
- ROAD: `ROAD-KVD-SKILLS-C20D24` M2.x
- STD: `STD-KVD-18F1EB` (STD-KVD-PIPELINE-AUTONOMY)
- SLAs: `SLA-KVD-SKILLS-27FE18` (/new-feature ≤45 min single-gate), `SLA-KVD-SKILLS-907E53` (/bug ≤30 min)

## [1.4.0] — 2026-05-29 — Break-glass bypass: hook v2 honors signed, scoped, expiring grants (REQ-KVD-SKILLS-41032D)

### Highlights

Operational break-glass valve for the PreToolUse hook. When a workspace opts in (`break_glass.enabled: true` in `.kvendra-protected`), an operator can grant a **signed, scoped, time-boxed bypass** of the broker enforcement via the CLI (`kvendra bypass --ttl <dur> --ops <prim.op>`), without breaking the zero-knowledge model. The broker remains the normal path for credentialed writes; the bypass is exceptional, cryptographically verifiable, fail-closed and audited.

Backwards-compatible by default: with `break_glass` absent or `enabled: false` the hook behaves **identically to 1.3.0** — zero overhead, no new code path exercised (NFR-COMPAT-1, asserted by the `break-glass-disabled` fixture with `verify-calls=0`).

### Added

- **Hook v2 conditional grant verification** (`scripts/block-unsafe-ops.sh`): after a real block-hit in `strict`/`hybrid` with `break_glass.enabled`, the hook invokes `kvendra verify-grant` (stdin JSON). Exit 0 → allow (with a `[KVD-PROTECTED] break-glass ACTIVE … Audited.` visibility line); exit ≠0 → block with the reason appended (`Break-glass: none|expired|out-of-scope|invalid-signature|unavailable`). **Conditional invocation** keeps the common path at 0ms overhead (p95 1–2ms measured).
- **Fail-closed when `kvendra` is absent** from PATH at the moment a verify is needed (unlike the `jq`/`awk`-missing transport which stays fail-open).
- **`break_glass` YAML reader**: the awk policy parser now reads the nested `break_glass: { enabled, pubkey_ed25519, grant_path }` mapping (additive; `schema_version` of the file unchanged — IF-KVD-SKILLS-BROKER-POLICY 1.0→1.1).
- **`sync-claudemd`**: pins the ed25519 public key into `.kvendra-protected.break_glass.pubkey_ed25519` from `kvendra grant-pubkey` and recomputes the checksum (Step 6.3b).
- **Hook test fixtures**: `break-glass-scope`, `break-glass-failclosed`, `break-glass-failclosed-nobin`, `break-glass-disabled`, plus a two-leg latency benchmark (TEST-LAT-1) and an opt-in real-binary e2e (`e2e-real-binary.sh`).

### Refs

- REQ: `REQ-KVD-SKILLS-41032D` · ADR: `ADR-KVD-SKILLS-D0CC0A`
- IFs: `IF-KVD-SKILLS-GRANT-VERIFY` v1.0 (new), `IF-KVD-SKILLS-BROKER-POLICY` 1.1, `IF-KVD-SKILLS-HOOK-CONTRACT` 1.1
- ROAD: `ROAD-KVD-SKILLS-C20D24` M2
- Sibling release: `REL-KVD-CLI-0.6.0` (CLI `bypass`/`protect`/`grant-pubkey`/`verify-grant` subcommands)
- Requires CLI ≥ 0.6.0 installed for the break-glass path; without it, opted-in workspaces fail-closed.

## [1.3.0] — 2026-05-28 — Capabilities discovery stable: onboard-project Step 1.5 + Step 3.x + STD-TPL library activated (REQ-ECDAE9 complete)

### Highlights

Stable consolidation of the `REQ-KVD-ECDAE9` (Capabilities discovery system) alpha line. Ships the runtime-consumer side of the architectural loop: the `onboard-project` skill now performs broker discovery (Step 1.5) and asks per-component archetype questions (Step 3.x D1/D2/D3) to drive deploy/test/publish playbook generation from the new STD-TPL library.

Combined with the alpha line (1.3.0-alpha.1 release-manager hook + IF-MANIFEST schema-doc; 1.3.0-alpha.2 version skill query fix), this REL closes the MVP scope of REQ-ECDAE9: any future Kvendra project can be onboarded with deploy/test archetype playbooks (S3+CDN, SAM-Lambda, Docker-Registry, Playwright, Cargo) without touching the plugin.

### Added

- **`onboard-project` Step 1.5 — broker discovery** (lines ~60-130, +90 LoC): runs `kvendra --version` to detect CLI presence; if installed, invokes `kvendra capabilities` and compares with the project's `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST`. Persists the snapshot to `.kvendra-protected.broker_capabilities_seen` (new YAML section, additive — backwards-compat with hook v2's NFR-POL-7 "ignore unknown top-level keys"). Three-option fail-safe when CLI is absent (install / continue broker-less / cancel).
- **`onboard-project` Step 3.x — archetype questionnaire** (lines ~225-380, +152 LoC): per-component D1 deploy target (8 enum), D2 test framework (8 enum), D3 publish channels (9 multi-select). Mapping tables D1/D2 → `STD-TPL-*` for automated playbook clone substitution. Stubs documented for archetypes without templates yet (k8s, package-publish, vps-ssh).
- **5 MVP STD-TPL entities** (previously created as drafts in TXN-005, now active in KB):
  - `STD-KVD-FF7978` — STD-TPL-DEPLOY-STATIC-S3-CDN (extracted from `STD-KVD-WEB-A52498`)
  - `STD-KVD-21C211` — STD-TPL-DEPLOY-SAM-LAMBDA (extracted from `STD-KVD-ENTERPRISE-CD2D7A`)
  - `STD-KVD-8C9365` — STD-TPL-DEPLOY-DOCKER-REGISTRY (extracted from kvendra-platform GHA workflow)
  - `STD-KVD-AD2507` — STD-TPL-TEST-PLAYWRIGHT
  - `STD-KVD-78D18B` — STD-TPL-TEST-CARGO

### Consolidation (from the alpha line)

- **alpha.1**: release-manager skill extended with the post-release hook that auto-populates `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST` after every CLI release.
- **alpha.2**: `version` skill query corrected (`tags_any: ["release","status:released"]` + drop `status: "active"` filter).
- **alpha.1 + alpha.2 + 1.3.0** together cover all MVP ACs of REQ-ECDAE9 (29/29). STRETCH (4 additional STD-TPLs + AC-LINT-2 + AC-IF-4) deferred to a follow-up REQ.

### Refs

- REQ: `REQ-KVD-ECDAE9` (MVP complete)
- ROAD: `ROAD-KVD-SKILLS-C20D24` M2 (first tracked item DONE)
- Predecessor stable: `REL-KVD-SKILLS-1.2.0` line (REQ-48062A broker-policy foundation)
- Sibling release: `REL-KVD-CLI-0.5.0` (the producer-side `kvendra capabilities` subcommand on crates.io)

## [1.3.0-alpha.2] — 2026-05-28 — version skill query fix: capture status:released RELs + drop status:active filter (REQ-ECDAE9 alpha.2)

### Fixed

- **`version` skill query** — replaced `tags_all: ["release", "scope:skills"]` + `status: "active"` filter with `tags_any: ["release", "status:released"]`. Captures RELs that follow the newer `status:released` tag convention (used by `release-manager`'s post-1.2.0 RELs) in addition to the legacy `release` tag convention. Also drops the `status: "active"` filter that was hiding RELs whose `status` field is `released` (the canonical post-publish state). Side fix: `component_id: "KVD-SKILLS"` → `"SKILLS"` (server normalises the project prefix; passing it explicitly was a no-op or warning depending on the server release).
- **KB hygiene**: 3 existing RELs (`REL-KVD-SKILLS-1.2.0.1`, `1.2.0.2`, `1.3.0-alpha.1`) backfilled with the canonical `release` tag so the broader ecosystem (any tool filtering by `tags_all: ["release"]`) sees them too.

### Refs

- Origin: owner consultancy 2026-05-28 (other-session `/version` listing missed the 1.2.0.x + 1.3.0-alpha.1 RELs).
- REQ: `REQ-KVD-ECDAE9` (alpha.2 — pulido cosmético, no AC formal pendiente; mejora DX del propio skill `version`).

## [1.3.0-alpha.1] — 2026-05-28 — release-manager CLI capabilities sync hook + IF-MANIFEST schema-doc (REQ-ECDAE9 alpha.1)

### Highlights

First incremental alpha of `REQ-KVD-SKILLS-ECDAE9` (Capabilities discovery system). Extends the `release-manager` skill with a post-release hook that detects releases of CLI-type components, runs `kvendra capabilities` locally, and upserts the per-project `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST` entity in the Kvendra KB. Also declares the canonical IF schema-doc (`IF-KVD-CLI-PRIMITIVES-MANIFEST v1.0`, wire_public, per-project replicated) that consumers reference.

Closes the architectural loop for `ADR-KVD-SKILLS-BB0E8A`: skills can now reason at runtime about which broker primitives exist without touching the binary. The matching CLI 0.5.0 release (with the `kvendra capabilities` subcommand) ships separately as `REL-KVD-CLI-0.5.0`.

### Added

- **`release-manager` SKILL.md** — new section "CLI capabilities manifest sync (post-release hook)" (lines 188–291). On any release of a `CMP-KVD-CLI` (or component with `component_type: cli-binary`), the skill runs `kvendra capabilities --pretty`, parses the JSON, and upserts `IF-<PROJ>-CLI-PRIMITIVES-MANIFEST` per-project. Best-effort: failures are logged as warnings and do not block the release.
- **`writes_entity_types: [REL, IF, ISSUE]`** added to `release-manager` SKILL.md frontmatter so `updater` picks up the new write surface.
- **KB schema-doc**: `IF-KVD-SKILLS-108EDC` (canonical title `IF-KVD-CLI-PRIMITIVES-MANIFEST v1.0`) declared as wire-public, per-project replicated. Validates the contract `STD-<PROJ>-BROKER-POLICY.require_broker[].primitive ⊆ primitives[].id`.

### Refs

- REQ: `REQ-KVD-ECDAE9`
- ROAD: `ROAD-KVD-SKILLS-C20D24` M2 (first tracked item)
- ADR: `ADR-KVD-SKILLS-BB0E8A` (STD playbook schema extends to capabilities discovery)
- TXN: `TXN-KVD-20260528-005`

## [1.2.0-alpha.2] — 2026-05-28 — Legacy marker drop + manual-writer agnostic (REQ-48062A second incremental alpha)

### Highlights

Second incremental alpha of `REQ-KVD-SKILLS-48062A`. Removes the
hardcoded seed strict policy + legacy marker transition fallback that
v1.2.0-alpha.1 carried for one release window. From this release the
PreToolUse hook v2 is exclusively policy-driven via `.kvendra-protected`
materialised from `STD-KVD-BROKER-POLICY`. Also folds in a small
cosmetic chore on the `manual-writer` skill to align it with the
toolchain-agnostic design used by every other skill in the catalog.

### ⚠️ Breaking advisory (legacy marker)

Workspaces that still carry only the legacy `.kvendra-workspace` empty
marker (no `.kvendra-protected`) **no longer get any enforcement
fallback**. The hook now exits 2 with a canonical `[KVD-PROTECTED]`
hard error pointing to `/sync-claudemd --policy-only`.

**Migration**: run `/sync-claudemd --policy-only` from any project root
that still relies on the legacy marker. The skill reads
`STD-<PROJECT>-BROKER-POLICY` from the Kvendra KB and writes a valid
`.kvendra-protected` to the workspace root. Verified empirically on
2026-05-26 via `ISSUE-KVD-SKILLS-571C2F` (SYNC-4, 9/9 validations PASS).

Workspaces that never carried any marker (`.kvendra-workspace` or
`.kvendra-protected`) are unaffected — the hook continues to exit 0
when no marker is found anywhere up the path.

### Changed

- **Hook v2** — removed the seed strict policy block (`SEED_BLOCK_RE`,
  `SEED_INSTALL_HINT`, `SEED_STD_ID`) and the entire Path A legacy
  transition branch. Replaced with a single 5-line hard-error path that
  emits the canonical `[KVD-PROTECTED]` message + `/sync-claudemd
  --policy-only` migration hint when only `.kvendra-workspace` is
  found. Net diff: ~−33 / +12 LoC.
- **`manual-writer` SKILL.md** — generalized the browser-MCP reference
  in Step 5: "Use Playwright MCP if installed" → "If a browser MCP is
  installed (e.g. Playwright, Puppeteer), use it; otherwise ask the
  user to provide screenshots manually or skip this section". Protocol
  rewritten in neutral prose (navigate → wait → highlight → screenshot)
  rather than `browser_*` tool-specific commands. Frontmatter intro
  description aligned the same way. Refs: `ISSUE-KVD-SKILLS-2D377E`.

### Tests

- Fixture `missing-policy-but-legacy-marker/expected.json` updated to
  assert the new hard-error stderr (`[KVD-PROTECTED] legacy marker .*
  no longer supported.*/sync-claudemd --policy-only`).
- **`run-fixtures.sh` isolation fix**: each fixture is now executed
  inside a fresh tmpdir into which the fixture's marker files are
  copied, so the hook's walk-up cannot escape into the surrounding
  workspace's own `.kvendra-protected`. Pre-fix, the test suite was
  silently fragile in any environment where the runner happened to live
  inside a Kvendra-protected workspace (which is now the canonical
  setup post-SYNC-4). No behavioural change for end users.
- All 8 fixtures + latency benchmark continue to pass (p95 = 1 ms).

### Acceptance criteria closed (this alpha)

- **AC-MARKER-4** (`REQ-48062A` Item 2) — hook reads ONLY
  `.kvendra-protected`; legacy marker triggers hard error pointing to
  the sync skill. ✅
- **AC-CLEAN-4** (`REQ-48062A` Item 6) — smoke without `kvendra-cli`
  still applies: workspaces without `.kvendra-protected` get hard error
  with broker install hint embedded by the sync skill at materialisation
  time (not hardcoded in the hook). ✅

### Traceability

- **REQ**: `REQ-KVD-SKILLS-48062A` v2 (Items 2 + 6 incremental closure).
- **ROAD anchor**: `ROAD-KVD-SKILLS-C20D24` M1.
- **Predecessor REL**: `REL-KVD-SKILLS-1.2.0.1` (broker-policy foundation).
- **Empirical pre-requisite**: `ISSUE-KVD-SKILLS-571C2F` (SYNC-4) done
  2026-05-26 — `.kvendra-protected` materialisation verified live on
  workspace KVD before the seed removal.

---

## [1.2.0-alpha.1] — 2026-05-26 — Broker-policy foundation (REQ-48062A — first incremental alpha)

### Highlights

First incremental alpha of the v1.2.0 "broker-agnostic + policy-driven
hook" iteration tracked by `REQ-KVD-SKILLS-48062A` /
`ROAD-KVD-SKILLS-C20D24` M1. Lays the **foundation** for decoupling the
27 skills from a hard `kvendra-cli` install dependency by extracting the
external-execution policy out of every `SKILL.md` and the hardcoded hook
blocklist into a first-class KB STD entity materialised locally as
`.kvendra-protected`.

This release is **non-breaking** for current users:
- Workspaces that still carry only the legacy `.kvendra-workspace`
  empty marker continue to be enforced under a hardcoded seed strict
  policy identical to the v1 hook blocklist. A deprecation warning is
  emitted on every Bash invocation in this state. The seed is removed
  in the next release.
- Workspaces that have been migrated via `/sync-claudemd --policy-only`
  (or fresh `/onboard-project`) carry `.kvendra-protected` and run
  under the policy-driven hook v2.

### Added

- `STD-KVD-BROKER-POLICY` entity (KB) — canonical external-execution
  policy playbook for Kvendra workspaces (subclass of
  `ADR-KVD-SKILLS-BB0E8A` with `playbook_type: "broker-policy"`, mode
  strict, schema_version 1).
- `IF-KVD-SKILLS-BROKER-POLICY` v1.0 (KB) — wire-public schema of the
  `.kvendra-protected` YAML payload.
- `IF-KVD-SKILLS-HOOK-CONTRACT` v1.0 (KB) — wire-public stdin/exit-code
  contract of the PreToolUse hook + canonical stderr format.
- `STD-KVD-BROKER-POLICY` appended to `PRJ-KVD.metadata.bootstrap_extras`
  alongside `STD-KVD-8F3BFB` and `STD-KVD-57DAE1`, so the policy is part
  of the session context.
- `tests/hook/` — fixture-driven unit-test suite for `block-unsafe-ops.sh`
  (≥8 scenarios incl. p95 latency benchmark).
- `help({topic:"broker-policy"})` topic declared in
  `kvendra-platform/src/tools/help.ts` (canonical schema, modes, drift
  semantics).

### Changed (foundational refactor)

- `scripts/block-unsafe-ops.sh` — full refactor to **hook v2**:
  policy-driven (reads `.kvendra-protected` YAML on every invocation),
  three modes (strict / permissive / hybrid), canonical
  `[KVD-PROTECTED]` stderr format, transition fallback for legacy
  `.kvendra-workspace` empty marker (one-line deprecation warning +
  seed strict policy identical to v1 blocklist). Pure-bash awk YAML
  reader, single pass, p95 ≤50 ms warm.
- `sync-claudemd` — extended with `--policy-only` flag. Default action
  now syncs both CLAUDE.md AND `.kvendra-protected`. Step 6 documents
  the broker-policy materialisation flow + idempotency + validation.
- `onboard-project` — creates `STD-<PROJECT>-BROKER-POLICY` as part of
  the seed entities (alongside `STD-<PROJECT>-DEPLOY-POLICY`), appends
  it to `PRJ.metadata.bootstrap_extras`, and materialises
  `.kvendra-protected` at the workspace root (Step 6.5).
- All 27 SKILL.md files — replaced the duplicated
  `## External-execution rules (MANDATORY)` block (broker primitives
  table + FORBIDDEN list + "if broker unavailable: STOP" line) with
  a 6-line canonical `## External-execution policy` pointer
  referencing `help({topic:"broker-policy"})`. Net diff ≈ -550 LoC
  across the 27 files combined.
- `.github/workflows/lint-skill-md.yml` — added
  `no-mandatory-broker-block` lint step. Negative check rejects any
  SKILL.md that reintroduces the legacy MANDATORY block; positive
  check enforces presence of the canonical pointer in every SKILL.md.

### Migration notes

- Existing workspaces continue to work — the hook v2 transition
  fallback enforces the same blocklist as v1 when only the legacy
  marker is present.
- To migrate a workspace to policy-driven mode: run
  `/sync-claudemd --policy-only` (after upgrading to v1.2.0-alpha.1).
  This materialises `.kvendra-protected` from the project's
  `STD-<PROJECT>-BROKER-POLICY`. If the STD does not exist yet, the
  skill stops with a canonical fail-safe message — define the STD
  via `/requirements-analyst` or run a fresh `/onboard-project`.
- The legacy `.kvendra-workspace` empty marker is preserved for 1
  release. It will be removed in v1.2.0-alpha.2+ once the canonical
  marker is widespread.

### KB traceability

- `REQ-KVD-SKILLS-48062A` (29 ACs) — driver REQ.
- `ROAD-KVD-SKILLS-C20D24` — v2.x hardening roadmap, M1.
- `TXN-KVD-20260526-014` — pipeline TXN.
- New STDs / IFs: `STD-KVD-D31D54` (BROKER-POLICY),
  `IF-KVD-SKILLS-840EE9` (broker-policy wire schema),
  `IF-KVD-SKILLS-2AD807` (hook contract).

## [1.1.0] — 2026-05-26 — Doc skills simplified (doc-portal heritage removed)

### Highlights

Post-REQ-629F77 cleanup driven by owner consultancy. The three documentation
skills inherited via `winking-owl-skills` (Jarvis) carried assumptions of a
custom "doc-portal" stack (multi-locale folders, `info.json`/`index.json`
schemas, `build-registry.js`, private-S3 visibility flow, Playwright login).
That stack is out-of-scope for Kvendra. This release strips it out.

### Changed (simplified)

- `doc-indexer` — full rewrite. Walks `<project>/docs/*.md` and writes one DOC
  entry per file. Idempotent (update when `metadata.file_path` matches).
  Optional path-scope argument (e.g. `docs/onboarding/`).
- `manual-writer` — full rewrite. English-source only — no multi-locale folder
  generation. Output is `docs/<topic>/README.md` + numbered section files +
  `assets/screenshots/` + Mermaid inline diagrams. Step 4 (TOC + CONSISTENCY
  BRIEF) is the mandatory pause point. Step 10 invokes `doc-indexer` to register
  the new files as DOC entries.
- `user-help` — catalogue updated: `/doc-validator` removed; `/manual-writer`
  description tightened to "English, docs/<topic>/"; `/doc-indexer` promoted
  to the DOCUMENTATION section.

### Archived

- `doc-validator` — `plugins/kvendra-skills/skills/doc-validator/` directory
  deleted. Same precedent as `translator` in REL-0.7.0: without the doc-portal
  stack the residual checks (markdown validity, DOC-entry presence, no TODOs)
  are trivially covered by standard tooling and by `doc-indexer` itself.
  Rationale captured in `PAT-KVD-E9A0E3`.

### Plugin state

- **27 active skills** (down from 28). Two archived total: `translator` (REL-0.7.0)
  + `doc-validator` (this release). Plugin manifest at `1.1.0`.

### Closed follow-up

- The "3 doc-portal STDs deferred" recorded in `ISSUE-KVD-SKILLS-14043F` (Lot 3
  tracker) is formally cancelled — the STDs will not be authored under that
  scope because the doc-portal will never be formalised as a CMP in the Kvendra
  KB.

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
