---
name: kvendra-band
description: Explains the Kvendra band above the prompt (TXN, ctx, 5h, 7d, new tokens, files, skills) when the user asks what it means.
---

The user asks what an element of the Kvendra band means. Answer from this legend, briefly:

Kvendra band

Line 1: project · workspace (role, if it differs from yours) · user (tier/role)
Line 2: what is in your Kvendra knowledge base
  TXN - open transactions in this project; "orphan Nh" = one open for 2 h or more
  entities (ent) - entities in the knowledge base
  open ISSUEs (ISS) - ISSUEs not closed in this project
  files (f) - files in Workspace Files and their total size
  skills - kvendra-skills version; "✓" up to date, "→ … · restart" = restart the session

Line 3: your consumption
  ctx - context window used
  5h - account usage in the 5-hour window; ↻ = time until it resets
  7d - account usage in the 7-day window; ↻ = time until it resets
  last - tokens the last turn added ("new": input + output + cache written; cache only read is left out)
  avg - average of "new" tokens per turn in this session
  /kvendra-legend - prints this legend; it is written at the end of line 3 when there is room

Yellow = needs attention (orphan TXN, restart, context or window near its limit).
"outdated" = the last refresh failed; the figures shown are the last good ones.
Short labels replace long ones when the line would not fit in 80 columns.
