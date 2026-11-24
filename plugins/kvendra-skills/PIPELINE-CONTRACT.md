# Pipeline contract

The roadmap pipeline (the fleet) can only drive an ISSUE that carries a specific set of fields.
This document is that contract, for kvendra-skills 2.0.0 and later. Its second part is the
contract the skills themselves keep. `tests/pipeline-contract/run.sh` applies both: the first to
example ISSUEs, the second to every `skills/*/SKILL.md`.

## Required fields

| Field | Meaning |
|---|---|
| Relation `part_of` → `REQ-…` | The specification the task belongs to, set by `work` `fill`. A task has no other parent. |
| No `part_of` → `ROAD-…` | A task never hangs from a roadmap: the engine rejects it (`INVALID_PARENT`). The roadmap is reached through the specification. |
| No `part_of` → `ISSUE-…` | An umbrella ISSUE is linked with `derives_from`, never as a parent. |
| Tag `road:ROAD-…` | Exactly one, matching `^road:ROAD-[A-Z0-9-]+$`: the roadmap the specification reaches, directly or through its epic. |
| Tag `pipeline:ready` | The task is ready to be offered to a runtime. Without it the fleet ignores the ISSUE. |
| Tag `priority:<value>` | Exactly one, with a value of `critical`, `high`, `medium` or `low`. Orders the work. |
| `status` | `open` or `in-progress`. Any other status means the task is not workable. |

## Optional fields

| Field | Meaning |
|---|---|
| `metadata.pipeline.depends_on` | Array of ISSUE ids (`^ISSUE-[A-Z0-9-]+$`) that must be done before this task is offered. |
| `metadata.pipeline.scope` | Non-empty string naming the component scope (for example `SKILLS`); drives the lease key. |
| `metadata.pipeline.repo` | Repository the work is done in, when it is not the component's default one. |

## Who emits the contract

| Skill | Emits the contract? | When |
|---|---|---|
| `to-do` | conditional | only when the request names a ROAD or asks for the roadmap pipeline: `start_work`, `fill` with a placement under that ROAD (one of its specifications, an epic of it, or the ROAD itself), `pause` (queued, not started), then the tags and `metadata.pipeline` with a guarded `entity_update` |
| `planner` | **no** | it designs; the orchestrator opens the tasks |
| `new-feature` | **no** | it drives its own task through the work cycle in the same run |

## Why `part_of` the specification

The engine tool `work` keeps one tree: roadmap > epic (optional) > specification (REQ) > task
(ISSUE). It accepts only that shape: a task hangs from a specification, and the specification from
an epic or a roadmap. A task `part_of` a ROAD, the 1.x shape of this contract, is rejected. So
the fleet finds the tasks of a ROAD in one of two ways:

- by the tag: `entity_query({ entity_type:"ISSUE", project_id, tags_all:["pipeline:ready", "road:<ROAD-id>"] })`;
- by the tree: the specifications `part_of` the ROAD (or of its epics), then the tasks `part_of`
  each specification.

A link of any other type (`derives_from` included) is not a parent: a task linked to its
specification only that way is not in the tree.

## Why the ROAD is identified by a tag and not by metadata

`entity_query` returns ids, tags and version but not metadata, so anything the fleet has to
filter on in a query, such as `road:ROAD-…`, must be a tag; a ROAD id kept only in metadata
cannot be queried.

## Example

An ISSUE that satisfies the contract:

```json
{
  "entity_id": "ISSUE-KVD-SKILLS-000001",
  "entity_type": "ISSUE",
  "project_id": "KVD",
  "component_id": "SKILLS",
  "status": "open",
  "title": "Example task",
  "tags": ["pipeline:ready", "priority:high", "road:ROAD-KVD-SKILLS-000001"],
  "metadata": {
    "pipeline": {
      "scope": "SKILLS",
      "depends_on": ["ISSUE-KVD-SKILLS-000000"],
      "repo": "KvendraAI/kvendra-skills"
    }
  },
  "relations": [
    { "type": "part_of", "target": "REQ-KVD-SKILLS-000001" }
  ]
}
```

No `metadata.kind`: a note (`metadata.kind: "note"`) is not a task and is never offered.

## Skills contract (checked by run.sh)

Every `skills/*/SKILL.md` keeps these rules. `run.sh` prints PASS or FAIL per rule with
`file:line`, and proves each rule on its own fixtures under `skills-fixtures/`.

| Rule | Code | What it checks |
|---|---|---|
| S1 | `work_cycle_block` | A SKILL.md that contains `work({` carries the `kvendra:work-cycle v1` block, closed and byte-identical to `tests/pipeline-contract/work-cycle-block.md`, right before the line `## External-execution policy`. A SKILL.md without `work({` that carries the block keeps it identical. |
| S2 | `gate_log` | No SKILL.md calls `gate_log(` or mentions `GATE_LOG_UNAVAILABLE`: the Kvendra server has no such tool. |
| S3 | `never_blocks` | No SKILL.md says that a step never blocks (`never blocks`, `never blocking`, `never blocked`, any case): when the engine enforces its gates, a closure or a release can be rejected. |
| S4 | `rel_created_released` | No `entity_create(` call holds both `"REL"` and `status: "released"`: a REL is created in `planning`, gets its members with `part_of`, and only then moves to `released`. |
| S5 | `task_template_tag` | No SKILL.md contains `"type:task"`: the 1.x task template whose tag left the criteria of a closure uncovered. |
