# Clean skill

Identify yourself on every write with `metadata.updated_by`.

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROJ>",
  title: "<title>",
  metadata: { updated_by: "skill:clean" }
})
```

`txn_activate({ txn_id })` and `txn_cancel({ txn_id, reason })` take nothing else.
