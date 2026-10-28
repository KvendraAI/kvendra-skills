# Multi-line call: updated_by several lines below the opening brace

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  title: "<title>",
  content: <markdown>,
  metadata: { severity, priority },
  tags: ["type:task"],
  relations: [{ type:"part_of", target:"ROAD-<PROJ>-<ID>" }],
  updated_by: "skill:x"
})
```
