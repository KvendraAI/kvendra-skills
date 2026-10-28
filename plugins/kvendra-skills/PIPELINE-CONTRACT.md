# Pipeline contract

The roadmap engine can only drive an ISSUE that carries a specific set of fields. This
document is that contract. `tests/pipeline-contract/run.sh` applies it to example ISSUEs.

## Required fields

| Field | Meaning |
|---|---|
| Relation `part_of` → `ROAD-…` | The ROAD the task belongs to. The engine discovers a ROAD's tasks through this relation. |
| Tag `pipeline:ready` | The task is ready to be offered to a runtime. Without it the engine ignores the ISSUE. |
| Tag `priority:<value>` | Exactly one, with a value of `critical`, `high`, `medium` or `low`. Orders the work. |
| `status` | `open` or `in-progress`. Any other status means the task is not workable. |

## Optional fields

| Field | Meaning |
|---|---|
| `metadata.pipeline.depends_on` | Array of ISSUE ids (`^ISSUE-[A-Z0-9-]+$`) that must be done before this task is offered. |
| `metadata.pipeline.scope` | Non-empty string naming the component scope (for example `SKILLS`); drives the lease key. |
| `metadata.pipeline.repo` | Repository the work is done in, when it is not the component's default one. |

## Who emits the contract

| skill | ¿emite el contrato? | cuándo |
|---|---|---|
| `planner` | sí | siempre, una ISSUE por paso del plan |
| `to-do` | condicional | sólo si la petición nombra un ROAD o se pide el pipeline |
| `new-feature` | **no todavía** | emite `part_of` pero no `pipeline:ready` |

## Why `part_of` and not `derives_from`

The engine lists the tasks of a ROAD by filtering the ROAD's `relations_inbound` on
`type === 'part_of'`, so an ISSUE linked to its ROAD any other way — `derives_from` included —
is invisible to it and never gets offered.

## Why the ROAD is identified by a tag and not by metadata

`entity_query` returns ids, tags and version but not metadata, so anything the engine has to
filter on in a query — such as `road:ROAD-…` — must be a tag; a ROAD id kept only in metadata
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
  "title": "[task] Example task",
  "tags": ["type:task", "pipeline:ready", "priority:high", "road:ROAD-KVD-SKILLS-000001"],
  "metadata": {
    "pipeline": {
      "scope": "SKILLS",
      "depends_on": ["ISSUE-KVD-SKILLS-000000"],
      "repo": "KvendraAI/kvendra-skills"
    }
  },
  "relations": [
    { "type": "part_of", "target": "ROAD-KVD-SKILLS-000001" }
  ]
}
```
