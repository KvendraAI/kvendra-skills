---
name: user-help
description: Help assistant — explains the kvendra-skills system, workflows and how to use each tool over the Kvendra KB
user_invocable: true
args: "[optional topic: skills, to-do, pipelines, kb, projects, all]"
---

# User Help — kvendra-skills system guide

You act as the **Help Assistant**. You explain how the `kvendra-skills`
ecosystem works, its workflows and the available tooling over the Kvendra
KB.

## Requested topic

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` from the `CLAUDE.md` if present.

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

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Behavior

If the user specifies a topic, show only that section.
If they say "all", show the complete guide.
If they say nothing, show the menu first:

```
HELP — kvendra-skills
=====================

Available topics:

  /user-help skills       Full catalogue of skills
  /user-help to-do        ISSUE system
  /user-help pipelines    Development flows (bug, feature)
  /user-help kb           Kvendra entities (14 tools)
  /user-help projects     Visible projects
  /user-help all          Complete guide

Which topic would you like to know more about?
```

---

## SECTION: skills — Skill catalogue

```
AVAILABLE SKILLS
================

ENTRY POINT
  /consultancy [topic]     Explore an idea, doubt or problem with full
                           Kvendra KB context. Closes with 9 actionable
                           options.

ISSUE MANAGEMENT
  /to-do create [desc]              Create ISSUE (bug | task | incident)
  /to-do update ISSUE-...           Update status, priority, assignee
  /to-do close ISSUE-...            Close ISSUE
  /to-do list                       List with filters
  /to-do-summary                    Visual summary with filters

DEVELOPMENT PIPELINES (orchestrators with TXN)
  /bug [area]             Testing and fix pipeline:
                          plan → test → analysis → fix → validation → KB
  /new-feature [desc]     New functionality pipeline:
                          requirements → spec → backend → deploy →
                          frontend + tests → validation → KB
  /incident-manager       Incident management with RCA + postmortem +
                          derived RUN/REQ/PAT

SUBAGENTS (used by pipelines, also invocable)
  /requirements-analyst   Analyzes requirements against REQ/ROAD/IF/CMP/ADR
  /functional-expert      Detailed test plan
  /planner                Technical spec against REQ/IF/ROAD/SLA/COST/ADR
  /implementer            Applies changes verifying IF/GLO/STD
  /validator              Verifies changes (3 levels)
  /tester                 Runs tests and creates TEST entries (draft)
  /analyzer               Root cause + fix proposal
  /updater                Coherence: relations, REL changelog, derived
  /interface-validator    Naming in code vs IF and GLO
  /doc-indexer            Indexes docs as DOC entries

OPERATIONS
  /deploy                 STD-driven deploy (reads STD-<PROJ>-<COMP>-DEPLOY-PROCESS)
  /regression             Regression suite + auto-generates bug ISSUEs
  /release-manager        Creates / manages / closes REL with SemVer
  /onboard-project        Onboarding: PRJ + CMP + IF + GLO + ENV + REL

DOCUMENTATION
  /manual-writer          Technical and user manuals (English, docs/<topic>/)
  /doc-indexer            Index docs/ Markdown files as KB DOC entries
  /changelog              Cross-entity / REL / date change query

CONFIGURATION
  /env-check              Verifies environment (MCPs, tools, skills)
  /onboard-project        Project setup (interactive, KB-driven)
  /sync-claudemd          Regenerate CLAUDE.md from canonical template
  /lint-claudemd          Verify CLAUDE.md conforms to template
  /version                Show installed plugin version and capabilities
  /user-help [topic]      This help
```

## SECTION: to-do — Kvendra ISSUE system

```
ISSUE SYSTEM (Kvendra KB)
=========================

ISSUEs are stored in the Kvendra KB (entity_type=ISSUE). They persist
across sessions and are the nexus between bugs, features and pending work.

ISSUE TYPES
  bug             Bug found
  task            Pending task
  incident        Operational incident (managed via /incident-manager)

STATES
  new             Pending, not started
  in-progress     In progress
  analyzing       Under analysis
  fixing          Being implemented
  blocked         Blocked
  done            Completed (task)
  closed          Closed (bug)
  postmortem-done RCA completed (incident)

PRIORITIES
  critical | high | medium | low

ID FORMAT
  ISSUE-<PROJ>-<COMP>-<NNN>   With component
  ISSUE-<PROJ>-<NNN>          Cross-component
  The server emits the id automatically (atomic counter).

TYPICAL FLOW
  1. /to-do-summary                See my active ISSUEs
  2. /to-do update ISSUE-...       Change status to in-progress
  3. (work)
  4. /to-do close ISSUE-...        Close the ISSUE

AUTOMATIC CREATION
  - /bug: creates a bug ISSUE per confirmed finding
  - /new-feature: creates a task ISSUE derived from the SPEC
  - /regression: creates a bug ISSUE if a regression-case fails
  - /incident-manager: creates an incident ISSUE
```

## SECTION: pipelines — Development flows

```
PIPELINES (Kvendra)
===================

BUG PIPELINE (/bug)
  TXN: type=bug, 6 phases.

  PHASE 1  functional-expert      Test plan
  PHASE 2  tester                 Execution + TEST entries (draft)
  PHASE 3  analyzer               Root cause (parallel per bug)
  PHASE 4  implementer            Apply fixes
  PHASE 5  validator              Verify (max 3 iter per bug)
  PHASE 6  updater                Kvendra coherence + activate TXN

FEATURE PIPELINE (/new-feature)
  TXN: type=new-feature, 7 phases.

  PHASE 0  requirements-analyst   Analysis (PAUSE)
  PHASE 1  planner                Spec (PAUSE)
  PHASE 2  implementer (backend)  Apply
  PHASE 3  deploy                 STD-driven deploy
  PHASE 4  implementer (frontend) Apply + tester creates TESTs draft
  PHASE 5  validator              Verify (max 3 iter)
  PHASE 6  updater + activate TXN

  Gates are policy-driven (STD-<PROJ>-PIPELINE-AUTONOMY, tag
  scope:pipeline-autonomy): dual (2 pauses, default) | single
  (1 consolidated pause) | none (zero-gate: auto-resolve + audit
  AUTONOMY_LOG; hard floor still pauses: no-go ops, recurring
  cost >20%, security failing exhaustive validation).

AUTONOMOUS SESSIONS (zero-gate + /loop)
  With gates:none + backlog_chaining:true, /new-feature chains the
  next open backlog item of a declared scope (milestone tag, ROAD,
  or ISSUE list) after each txn_activate. Pair it with the harness
  /loop (self-paced) to work through a milestone unattended: the
  skill chains items inside a session; /loop re-invokes the prompt
  across sessions. Stops on: empty scope, hard-floor pause, 2
  consecutive blocked items, or budget exhaustion.

INCIDENTS (/incident-manager)
  Creates ISSUE type:incident with embedding ON (documented exception).
  Lifecycle: detected → investigating → mitigating → resolved →
             postmortem-done.
  Generates derived RUN/REQ/PAT as drafts of the incident TXN.

VALIDATION LEVELS (validator)
  basic          Verifies nothing breaks (UI/CSS/translations)
  professional   Full e2e flows
  exhaustive     Edge cases, roles, errors
  Auto-determined by change type.
```

## SECTION: kb — Kvendra entities

```
KNOWLEDGE BASE
==============

The Kvendra KB is a centralised vector DB with a dedicated schema, accessible
via MCP. Contract lives in the server (not in prompts) — invariants
encapsulated in handlers.

ENTITY TYPES (20)
  PRJ, CMP, IF, REQ, TEST, REG, ISSUE, REL, SLA, ROAD, GLO, STD, PAT, ADR,
  RUN, UX, DOC, TXN, ENV, COST

THE 14 KVENDRA TOOLS
  entity_create        Create entity (auto-id)
  entity_update        Atomic update (change_summary required)
  entity_archive       Soft archive (reversible)
  entity_get           Lookup by entity_id
  entity_query         Boolean filters (tags_all/any, status, ...)
  entity_search        Semantic search (cosine, ≥3 chars, ≤20)
  entity_related       Top-N semantically nearest
  txn_create           Open TXN (orchestrators)
  txn_activate         Close TXN OK (drafts → terminal)
  txn_cancel           Close TXN with reason (drafts → cancelled)
  txn_check_interrupted    List in-progress TXNs by scope
  whoami               Authenticated identity
  config_get           Server config introspection
  help                 Static protocol help

ERROR ENVELOPE
  { code: 'VALIDATION'|'NOT_FOUND'|'CONFLICT'|'INTEGRITY'|'INTERNAL', ... }

EMBEDDING OPT-OUT
  ISSUE, TXN, RUN, ENV, COST: NO embedding by default.
  Exception: incident-manager forces embedding ON on incident ISSUEs.

ARCHIVE NOT ALLOWED
  ADR, TXN: cannot be archived (immutable historical records).
```

## SECTION: projects — Visible projects

This section is **dynamic**. To show it:

1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"PRJ", limit:20 })`.
2. For each PRJ: the content already has the description.
3. Present:

```
PROJECTS
========

| Project | Description | Components |
|---------|-------------|------------|
| <project_id> | <PRJ description> | N |

Each project has its CLAUDE.md with project_id, tier flag, and any
project-specific particularities.
```

If the query fails, suggest `/env-check` to verify the connection.

## Rules

- Adapt the detail level to the requested topic.
- If the user asks something specific ("how do I create an ISSUE?"), answer
  directly without showing the full guide.
- If the user seems lost, suggest `/consultancy` or `/to-do-summary`.
- Always mention that `/user-help [topic]` gives more detail on a specific topic.
