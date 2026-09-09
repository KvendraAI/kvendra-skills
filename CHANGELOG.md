# Changelog

All notable changes to the `kvendra-skills` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-<VER>` entity in the
Kvendra KB with the same content plus traceability links.

## [1.14.0] — 2026-09-10 — the hook stops bricking workspaces its own skills configured

### Fixed

- **A nested mapping in `.kvendra-protected` disabled Bash entirely.** The
  marker parser accepted an indented key only inside a `require_broker`
  sequence item or under `break_glass`; anything else aborted with a YAML
  parse error, and the caller turned that into exit 2 for **every** Bash
  invocation in the workspace — reads included. The file was valid YAML;
  what could not read it was our own minimal parser.

  The failure mode is what makes this severe rather than annoying. It is
  fail-closed and global, so the agent loses the very tool it would use to
  repair the file, and the only escape left to the user is deleting the
  marker or switching the hook off in settings — a permanently permissive
  surface. A policy error should never make disabling the policy the
  cheapest way out.

  Worse, the workspace was configured that way **by us**: sub-step 1.5.f of
  `/onboard-project` instructs writing a nested `broker_capabilities_seen:`
  block, and asserted that the hook "ignores unknown top-level keys". That
  claim was true for unknown *scalars* and false for unknown *mappings*, so
  following the skill to the letter bricked the workspace. Reproducible on
  every new onboarding that reached that step.

  The parser now ignores unknown top-level containers and whatever nests
  under them. Tolerance means **ignored, never promoted**: a key nested
  under an unknown container does not become policy even when it is named
  `mode`, `allow_bash` or `break_glass`. Known containers — `block_bash`,
  `allow_bash`, `require_broker` — and an orphan indented key with no parent
  at all still fail hard, because degrading a known list into an empty one
  would weaken enforcement without any noise: `require_broker` would fall
  through to its default primitive and hand the operator a wrong remediation
  for a real block. Two fixtures exist for the sole purpose of killing a
  naive version of this fix that drops the distinction.

- **Unknown containers shaped like a sequence were promoted to
  `require_broker`.** Both flush sites printed that key hardcoded while the
  `END` block printed the current one. Pre-existing and low severity —
  `require_broker` only drives the remediation text, never the block
  decision — but the tolerance above turns the path into a sanctioned one,
  so it is fixed in the same release. The new fixture covers both sites
  separately, so a future regression names which one broke.

- **`/env-check` told users to brick their workspace.** Check 7 looked for
  the *legacy* `.kvendra-workspace` marker, which the hook explicitly
  rejects. It therefore reported a healthy project as NOT FOUND, reported
  hook-active for a marker that fails closed on every call, and recommended
  creating that marker by hand. This is the skill people run precisely when
  their environment is broken. It now looks for `.kvendra-protected` first,
  reports the legacy marker as an ERROR with the correct remediation, and
  distinguishes a legitimately broker-less project from one that was never
  onboarded. The hand-rolled marker recommendation is gone.

- **`/onboard-project` seeded a mode that does not exist.** The broker-less
  branch wrote `mode: "off"`, and the hook accepts only
  `strict|permissive|hybrid` — a second brick with the same blast radius and
  a different cause. A project with no broker now writes no marker at all,
  which is the contract's documented no-enforcement state, and records
  `broker_install_skipped` plus `policy_materialised: false` on its
  broker-policy STD instead. `/sync-claudemd` honours the same flag and will
  not recreate the file.

- **`/sync-claudemd` silently destroyed the capabilities snapshot.** Step 6.6
  renders the marker from the STD payload, so a re-sync erased any block the
  STD does not produce — including the one 1.5.f had just written. The block
  is now preserved verbatim across re-syncs and excluded from the provenance
  checksum, so refreshing local telemetry never reads as policy drift. Only
  that one key is carried over: preserving arbitrary unknown keys would let
  a hand-edited `allow_bash` outlive every sync and quietly outrank the KB
  contract.

  The related claim that re-running `--policy-only` "populates"
  the snapshot was false in a second way that survives the fix: that skill
  never runs broker discovery, so it can preserve a snapshot but cannot
  create a missing one. The text now says so rather than promising a
  refresh surface that does not exist.

### Changed

- Tolerance of unknown top-level keys is now documented as a **versioned**
  guarantee floored at this release, not an unconditional property. The
  marker file is shared by everyone working in a workspace, so the floor is
  a fleet property: a teammate on an older plugin still fails closed on a
  block someone else wrote. Producers of additive blocks must check the
  floor declared on the broker-policy contract before writing one.

### Refs

- `ISSUE-KVD-SKILLS-A5ED0D` — root cause, live reproduction and the three
  candidate fixes considered.
- Reducing the blast radius of a parse error (so a broken policy blocks only
  what it can still parse, instead of everything) was **deliberately not**
  done here. Fail-closed buys nothing against an adversary — anyone able to
  write the marker writes a well-formed permissive one, and the hook never
  verifies the checksum — so its only victim is the legitimate user. But the
  variant proposed in the issue would resurrect the hardcoded seed policy
  removed on purpose in 1.2.0-alpha.2. It needs its own design, and with the
  parser fixed a parse error is no longer the common route into the brick.

## [1.13.1] — 2026-09-09 — honest warning: a free account cannot mint an embeddings key yet

### Fixed

- **`/setup` no longer walks free users into a wall.** 1.13.0 taught the wizard
  to accompany the cloud free-tier signup and wire the resulting
  `EMBEDDINGS_API_KEY` into the stack's `.env`. Verifying that path end-to-end
  against the live API showed the premise is false today: a free account gets
  `403 forbidden_tier` from `POST /v1/auth/api-keys` — *"This endpoint requires
  Pro tier"*. The free embeddings quota itself works (a free session token
  computes a 1024-dim vector fine), but the STATIC key a Docker `.env` needs
  cannot be issued, and a container cannot refresh a session token.
  `Q2` and `S1c` now state the blocker up front and steer users to Ollama, which
  is fully automated and needs no account. The cloud branch is offered only to
  someone who already holds a key or is on Pro.

  This is a backend gate, not a wizard bug, and the gate is CORRECT as it
  stands: the API-key authorizer hardcodes `tier: 'pro'` for every key, so
  simply letting free users mint one would grant 50x the quota they are
  entitled to. The real fix is per-key tier resolution in the authorizer.
  Tracked in `ISSUE-KVD-ENTERPRISE-A0182E`.

### Refs

- `ISSUE-KVD-ENTERPRISE-A0182E` — root cause, live evidence and the fix that is
  actually needed.
- Materialises risk **R7** raised while planning 1.13.0: *"confirmed by
  contract, not verified live; if false, the whole increment is pointless."*
  It was verified, and it was false.

## [1.13.0] — 2026-09-08 — /setup wires the embeddings key before bring-up, and the cloud path branches on Pro

### Added

- **`/setup` step S1c — embeddings key, cloud free-tier branch.** A new step that sits strictly between S1b (stack root resolved) and S2 (bring-up), and runs only when Q2 was answered *cloud free-tier*. It accompanies the signup (best-effort browser open at `https://kvendra.cloud`, URL always printed for headless and remote sessions, then a pause with no polling and no timeout), asks for the key with the escape hatch offered in the same message, creates the stack's `.env` when the clone does not have one yet, rewrites it, verifies the placeholder is gone, and probes the key against the live embeddings endpoint before anything is brought up. The wizard accompanies the signup; it does not create the account and does not mint the key — that needs an already-authenticated caller.
  - **Detect first, then decide how many lines to rewrite.** "Only the key line changes" holds for a `.env` freshly copied from `.env.example` and is false for one an earlier Ollama bring-up rewired, which is a case `/setup` reaches on its own because it is idempotent and its S1 branch (c) lands exactly there. When the file is Ollama-wired, the provider, base URL and model lines are restored to the cloud values and the now-false `# set by up.sh --with-ollama` marker is dropped. Detection matches that marker as a WHOLE LINE: `.env.example` quotes the same string inside a prose comment, so a substring match reports a pristine file as Ollama-wired.
  - **Secret hygiene, stated honestly.** The key never travels in a command line, so it is never visible to `ps`; it does appear once in the conversation transcript, and the step says so and offers the user the option of pasting it into `.env` themselves. It reaches `awk` through the environment (an `awk -v` assignment is visible in the process argv) and reaches `curl` through `--config -` on stdin rather than a `-H` argument, with the shell's `printf` builtin so no real process ever carries it. `chmod 600` runs after every rewrite, because the temp-file-plus-`mv` pattern replaces the file and its permissions; `.env` is checked as git-ignored before anything is written. Form validation rejects an empty, multi-line, whitespace-bearing, `=`-bearing or placeholder value, and only WARNS on an unexpected key prefix — the format belongs to the hosted engine, which this skill cannot re-read at runtime.
  - **Five-state probe ladder** instead of pass/fail: `2xx` continues, `401` re-asks and refuses to bring the stack up, `429` reports a valid key with an exhausted quota and continues, any other `4xx`/`5xx` is inconclusive and hands the user the code plus the first ~200 characters of the body, and a transport failure reports no verdict and offers to continue. Only `401` blocks: a probe that stopped the wizard behind a corporate proxy would be worse than no probe.
  - All rewrites use the portable `awk`-into-a-temp-file-then-`mv` pattern the stack's own start script uses, never the in-place flag of `sed` (BSD/macOS and GNU disagree on its argument).
- **Cloud path branches on "do you already have Pro?"** — C1 (account exists) guides `/mcp` and verifies; C2 (no account) opens `https://kvendra.ai`, states that the wizard neither creates the account nor handles payment, pauses, and then falls into C1. Carries an explicit disclaimer that **the wizard does not authenticate**: the OAuth 2.1 + PKCE cycle is driven by Claude Code, and `/mcp` is a slash command the user types.
- **The two domains are distinguished up front, in Q1/Q2** rather than only when a verify fails: `kvendra.ai` is the Pro account for the hosted KB engine, `kvendra.cloud` is a free embeddings key for a self-hosted stack. A free signup is not a way into the hosted KB, and the tier note in the cloud path spells out that difference next to the `403 forbidden_tier` case.

### Fixed

- **S2 passed the Ollama flag unconditionally, in BOTH branches of Q2.** This is the bug the rest of the increment is built around, not a nicety: anyone who chose cloud free-tier ended up with the Ollama container running, `mxbai-embed-large` downloaded, and their embeddings key inert — with no warning at all, because the start script's placeholder warning is itself suppressed when that flag is passed. S2 now has two blocks and the flag appears only in the Ollama one. Writing the key without making the flag conditional would have fixed nothing.
- **Q2 told the user to export the key before bring-up. That never worked** and has been removed: the start script sources `.env` after parsing its flags, so the value read from the file overwrites the exported one, and Compose then interpolates the placeholder. The skill now says explicitly that the export does not work, so the instruction does not come back.
- **S1 branch (c) "reconfigure embeddings" was an empty promise** — it is now a real path that re-enters Q2 and performs an actual rewire, including the Ollama-to-cloud direction.
- **S6 verified the wrong server on the self-hosted path.** The read test was written with the `kvendra-cloud` tool namespace for both paths, so a self-hosted verify probed the cloud server or failed confusingly. There are now two verify blocks, one per namespace, and the claim that "the read test is identical" is gone.
- **`.mcp.json` published an internal ops instruction pointing at a file that does not exist.** The `kvendra-cloud` description no longer tells readers to promote a Free user to Pro with an AWS CLI snippet in `docs/SETUP-PRO.md` (no such file is in the repo). "Pro tier required" stays — it is honest user-facing information that prevents a baffling 403 — and now points at `https://kvendra.ai`. The tool count is corrected from 14 to 20, and the load-bearing note about the server name and `Local > Plugin` scope precedence is preserved verbatim.
- Marketplace entry said "29 skills"; the plugin ships 28.

### Changed

- The self-hosted section heading drops "+ local-embeddings": the flow now covers both embeddings backends.
- `## Required output` gains three rows: `Embeddings backend`, `Embeddings key` (WIRED / KEPT_EXISTING / PASTED_BY_USER / SKIPPED) and `Key probe`.
- Test fixtures extended from 54 assertions to cover the new surface: the four `.env` scenarios (pristine, real key already present, Ollama-wired, missing file), the marker false positive, idempotency, permissions after every rewrite, the git-ignore gate, the placeholder check, the conditional flag in S2, document order and wording, the probe under a mocked `curl` (including an assertion that the key does NOT appear in the recorded argv), and the manifests. The bring-up snippet extractor is now anchored to the S2 section instead of to the first `curl` line in the file, so a later step that also uses `curl` cannot capture it by accident.

### Refs

- REQ: `REQ-KVD-SKILLS-317B7B` (`## Increment v1.3`, `AC-V13-1..27`) · ISSUE: `ISSUE-KVD-SKILLS-75BFCC` · REL: `REL-KVD-SKILLS-1.13.0` · ROAD: `ROAD-KVD-SKILLS-C20D24`
- Built via `/new-feature` pipeline `TXN-KVD-20260908-002` (zero-gate). Consumes `IF-KVD-ENTERPRISE-25BF5A` v1.0.4 (`POST /v1/embeddings`, the `kvendra-embedding-v1` model alias and the `kvd_live_*` key format); no interface is modified.
- Still deferred: programmatic signup (a backend feature, explicitly discarded by the owner), removal of the bundled cloud MCP preconfig, the no-restart pattern, and the Free tier gating of the hosted KB. No change to `kvendra.dev`.

## [1.12.0] — 2026-09-08 — /setup locates or clones the reference stack

### Added

- **`/setup` step S1b — reference-stack root resolution.** The self-hosted path no longer assumes the session already sits inside a reference-stack clone: the wizard detects an existing clone (walking up from the cwd, then a canonical `kvendra-reference-stack/` subdirectory, then the sibling `../kvendra-reference-stack`, then subdirectory candidates), and otherwise asks where to place one and clones it. Idempotent: an existing clone is reused, never re-cloned or overwritten. The whole self-hosted onboarding now happens inside Claude Code, with no terminal step.
  - **Detection predicate**: a single shared check, reused by every branch, that demands three signals — `docker-compose.yml`, `scripts/up.sh`, and a `kvendra-platform` service declared inside that compose file. The third signal is what keeps the wizard from adopting the user's own repository: the first two match any project that happens to ship a Compose file and a start script, and a resolved root is used with no confirmation, so a two-signal predicate would run the *user's* `scripts/up.sh` with `--with-ollama`. The service name is the one S3 addresses, so it is the signal with the fewest false positives.
  - **Sibling branch**: the side-by-side workspace layout (the user's repository and the stack as sibling directories under one root) is detected instead of reported as "nothing found", which previously led to a second clone under `$HOME`.
  - **Guard against polluting the user's repo**: when the cwd is a git repo that is *not* the reference stack, the wizard refuses to clone inside the work tree (an embedded repo would dirty `git status`) and defaults the destination to `$HOME` instead, only cloning inside after an explicit confirmation plus a `.gitignore` warning.
  - **Destination safety**: rejects the filesystem root, `$HOME` itself, system directories and the read-only plugin cache; stops instead of overwriting a non-empty destination; warns on cloud-synced paths (the stack writes a `.env` in the clone root) and on awkward path characters; checks parent writability and free disk space before touching the disk.
  - **Supply-chain hygiene**: the clone URL is a constant of the skill and never parametrizable from context (org typosquat vector), `GIT_TERMINAL_PROMPT=0` plus a neutralized credential helper fail fast instead of hanging on a credential prompt, and the resolved URL and commit are displayed before the wizard executes `scripts/up.sh` from the clone. Partial clones are cleaned up only when the wizard created the directory.
- **Bootstrap exemption rationale** documented in the skill: `/setup` cannot read its own recipe from a KB STD because its job is to create the KB connection, so the detection and clone logic is inlined by design, not by omission (`ADR-KVD-SKILLS-BB0E8A`).

### Changed

- **S2 and S3 now operate against the absolute stack root** resolved in S1b instead of the current working directory. This fixes a pre-existing bug: with the platform already healthy but the session outside the clone, S2 skipped the bring-up and S3's token extraction failed. `up.sh` is invoked by absolute path (it relocates itself), while the Compose calls are wrapped so they run from the stack root inside the same Bash invocation.
- **Stack collision detection** added to the already-up branch: a healthy port with no containers under the resolved root means another stack owns it, so the wizard stops and explains it rather than proceeding.
- **`curl` added to the S1b-1 prerequisites gate**, with its own diagnosis alongside `git` and `docker`. It is a hard dependency of S2 (the `/healthz` probe) and of the stack's own `up.sh`: absent, the probe exits 127, the `||` operator reads that as "not healthy", and the wizard fires the bring-up over a stack that may already be running.
- Test fixtures extended from 7 to 54 assertions, including a mock that records its own working directory to prove cwd independence, plus the full S1b resolution matrix. Mutation testing covers the load-bearing lines of S1b-1, S1b-2, S1b-4, S2 and S3 — 15 mutants (each of the three detection signals and each detection branch, the `$HOME` and system-directory rejections, the deliberate absence of `/opt` from that list, the destination normalisation, the parent-writability guard, the `curl` prerequisite, the absolute-path invocation of the start script, and the `cd` on each of the two Compose commands), all 15 red. One of them — dropping the `docker-compose.yml` existence test while keeping the service grep on that same file — is behaviourally equivalent to the original, so it is pinned by a textual drift assertion rather than by a fixture.

### Refs

- REQ: `REQ-KVD-SKILLS-317B7B` (`## Increment v1.2`, `AC-V12-1..12`) · ISSUE: `ISSUE-KVD-SKILLS-C6B6D3` · REL: `REL-KVD-SKILLS-1.12.0` · ROAD: `ROAD-KVD-SKILLS-C20D24`
- Built via `/new-feature` pipeline `TXN-KVD-20260908-001` (zero-gate). Companion copy update on kvendra.dev (`CMP-KVD-DEV`): the onboarding no longer shows a terminal step.
- Out of scope, still deferred to v1.1 of the wizard REQ: the no-restart pattern, removal of the bundled cloud MCP preconfig, and cloud/OAuth automation. The restart caveat is unchanged.

## [1.11.0] — 2026-06-30 — New /setup onboarding wizard (MVP self-hosted-local)

### Added

- **NEW skill `/setup`** — "the Quickstart in a skill". A user-invocable, no-TXN onboarding wizard that connects Claude Code to a Kvendra backend and chains to `/onboard-project`. Q1 cloud (KB-managed) vs self-hosted; Q2 (self-hosted) embeddings local (Ollama) vs cloud free-tier. The MVP fully automates the **self-hosted + Ollama** path; the cloud-KB (OAuth) and cloud-embeddings branches give honest instructions/derivations (full automation → v1.1).
  - **Pattern B** (additive, backwards-compatible): registers a separate `kvendra-platform` MCP server (`http://localhost:7777/mcp`, Bearer token read from the reference-stack container); the bundled `kvendra-cloud` server is left untouched, so existing cloud users keep their onboarding. The backend-agnostic plugin cleanup (parametrized bundled MCP + `/reload-plugins` no-restart) is deferred to v1.1.
  - Robust token extraction via `docker compose exec -T kvendra-platform cat /data/auth.token` (retry); reference-stack bring-up with `up.sh --with-ollama`. Idempotent (`claude mcp list` first). Honest restart caveat (no false no-restart promise) and honest self-hosted→cloud migration guard (re-embedding required, no export/import).
- New offline test fixtures `tests/setup/run-fixtures.sh` (mock docker+claude; drift-guarded against the SKILL.md).

### Refs

- REQ: `REQ-KVD-SKILLS-317B7B` (consultancy 2026-06-25 + 2026-06-30) · ISSUE: `ISSUE-KVD-SKILLS-9B265B` · TEST: `TEST-KVD-SKILLS-46469C`, `TEST-KVD-SKILLS-56BD65` · REL: `REL-KVD-SKILLS-1.11.0`
- Built via `/new-feature` pipeline `TXN-KVD-20260630-001` (zero-gate). Validator professional 7/7 ACs, 0 defects; lint 4/4; fixtures 7/7.

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
