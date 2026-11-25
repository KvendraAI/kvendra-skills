---
name: s1
description: Fixture skill for the skills contract checker
---

# Fixture

Open the task with `work({ op:"start_work", project_id, description, type:"feature" })`.

Then call `gate_log({ project_id, limit:500 })`.

<!-- kvendra:work-cycle v1 -->
## Work cycle (canonical block — edit it in every carrier or in none)

- **The tool `work`.** Tasks, specifications, notes, decisions and project releases are written through the engine tool `work` on the Kvendra server: one call per op (`what_now`, `start_work`, `fill`, `pause`, `finish`, `confirm`, `capture`, `record_decision`, `resolve_review`, `release`, `create_structure`) with only the arguments of that op. An unknown key (for example `component_id`, `metadata`, `tags` or `updated_by`) is `INVALID_INPUT`, and `txn_id` is accepted only by `finish`, `confirm` and `release`. The contract of every op is `help({topic:"work"})`: read it before an op this skill does not show, or when an answer carries a code this skill does not explain. Never change the status of a task or a specification with `entity_update`.
- **No `work`, no run.** If the Kvendra server does not list the tool `work`, stop before any write and tell the user: "kvendra-skills 2.0.0 needs the Kvendra tool `work`, and this session does not list it. Restart Claude Code, or run /mcp and reconnect the Kvendra server; if your Kvendra server has no `work`, keep kvendra-skills 1.35.x." There is no fallback to the 1.x flow.
- **Answers.** Act in the same run on `next_step`, `missing`, `warnings[]` (each `{code, reason, missing, next_step}`), `hints[]`, `evidence_plan` and `advice_skipped`. An error (`{code, message, missing, next_step}`) wrote nothing: fix the input it names and retry once. `finish`, `confirm` and `release` write even when they warn: never repeat them to clear a warning; repair with `evidence_plan` (record the RUN, then cite it in the closed task with a guarded `entity_update`). Tell the user every `WAIVERS_RECORDED` and `RELEASE_WITH_WAIVERS`.
- **Evidence.** Cite only the id of a TEST or RUN of this project that you created or read; never invent one, and a commit alone is not evidence. `finish` carries `evidence`, `criteria_evidence` with one entry per criterion of the specification (`"C1": "<RUN id>"`, `{"waive": "<reason, 5+ words>"}` only when the user decides it, or `"pending"` while another open task of the same specification covers it) and `txn_id` when the RUN is a draft of your TXN. A closure written with `entity_update` also lists its TEST or RUN ids in `metadata.evidence`. A discard (`finish` with `outcome: "wontfix"`) carries no `evidence`, no `criteria_evidence` and no `metadata.evidence` (the engine rejects `evidence` there with `INVALID_INPUT`): name the DOC or RUN that shows why in its `reason`; they keep their `affects` link to the task. `criteria_evidence` takes one id per criterion: the RUN that checks every part of it; never keep a second RUN for a criterion in other metadata.
- **Shape.** A feature task hangs from its specification (`part_of` the REQ, set by `fill`), and the specification from an epic or a roadmap; a link to an umbrella ISSUE is `derives_from`, never `part_of`. A smoke test, a synthetic check or a follow-up idea is a note (`capture`), not a task. A bug that is not a bug, or that cannot be reproduced, is closed with `finish` and `outcome: "wontfix"` plus a `reason` of 5+ words, never as `done`.
- **Releases.** Confirm the member specifications before publishing. A project release is `work` `release`; a component release (`REL-<PROJ>-<COMP>-<VER>`) is created with `entity_create` in `planning`, gets its members with `part_of`, and only then moves to `released`. Never create a REL directly as `released`.
- **Enforced gates.** Today `finish`, `confirm` and `release` only advise. When the engine enforces its gates, a closure, a `txn_activate` or a release can fail with `GATE_REJECTED`: nothing was written. Read its `code`, `problems`, `next_step` and `evidence_plan`, do what they name (record and cite the RUN, answer the criterion, confirm the specification) and retry, at most twice; then stop and report it on the first line. Never report a rejected write as done. After a production deploy, a release that did not end `released` is a blocker you report first, not a footnote.
<!-- /kvendra:work-cycle -->

## External-execution policy

This fixture respects the broker policy.
