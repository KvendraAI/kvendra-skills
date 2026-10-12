# Changelog

All notable changes to the `kvendra-companion` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-COMPANION-<VER>` entity in
the Kvendra KB.

## [0.2.0] — 2026-10-12 — Files in one read, a legend command and a skill

> Needs the hosted engine with `file_list({summary: true})`
> (REL-KVD-ENTERPRISE-0.41.0, live). With an older server the Files figure is
> left out of the band.

### Changed
- Workspace Files is one read, `file_list({summary: true})`, that returns the
  count and total size. No paging and no "N+ files": a large Team workspace
  shows the real figure, for example "78 files 533.8 MB".
- The loading line reads `Kvendra: loading… · legend: /kvendra-legend`.

### Added
- `/kvendra-legend` command: prints what each element of the band means.
- `kvendra-band` skill: Claude explains the band when you ask, from the same
  legend as the command.
- Line 3 ends with `/kvendra-legend` only when it fits in 80 columns; it never
  replaces a figure.

## [0.1.4] — 2026-10-11 — Files shows in large workspaces

### Fixed
- Workspace Files no longer disappears from the band in a workspace with more
  files than the pages read; it shows a lower bound such as "500+ files".
- The file list is read in at most 5 pages (was 10) every 5 minutes, a
  repeating cursor or an empty page ends the walk, and an answer without a
  "files" list is logged to the debug log (`claude --debug`).

## [0.1.3] — 2026-10-11 — Team workspaces: steadier start, shorter line 1, fewer reads

### Fixed
- The band says "Kvendra: loading…" until its retries are used up (it showed
  "unavailable" on the first failed read when the MCP server was not
  connected yet).
- Line 1 no longer repeats the role in a team workspace ("Acme · team/owner").
- The user name is only read in your own KB, never in a team workspace.
- Failed reads are retried individually and at most 10 times, then once every
  5 minutes.
- Failed reads are logged to the debug log (`claude --debug`): which figure and
  the error text, never KB content.

## [0.1.2] — 2026-10-11 — The band draws itself after the first read

### Fixed
- The band is now drawn as soon as the first read finishes, without the user
  interacting with the prompt. While there is no data it shows a dim
  "Kvendra: loading…" line (or "Kvendra: unavailable" if a read failed), and
  it asks the engine to redraw after each state update.

## [0.1.1] — 2026-10-11 — The band fills in when the KB connects late

### Fixed
- When a session started before its Kvendra MCP server was connected, the
  user name, entities, open ISSUEs and Files figures stayed empty for several
  minutes (the first failed read was recorded as done). A failed read is now
  tried again on the next refresh, and the band retries every 30 seconds, up
  to 10 times, until every figure has been read once. Each slow figure is also
  read on its own, so one failure no longer hides the others.

## [0.1.0] — 2026-10-11 — First release

> Requires a Claude Code build with mods (enabled by default from 2.1.287).
> Mods are an early-access Claude Code feature: their API can change between
> releases. On an older build the plugin loads with nothing to run.

### Added
- A read-only Claude Code mod that draws a three-line band above the prompt:
  project, workspace (Team/Enterprise only) and user; open TXNs (yellow when
  one has been in progress for 2 hours or more), entities, open ISSUEs, Files
  usage and the `kvendra-skills` version (yellow "restart" when the version on
  disk differs from the one the session loaded); and Claude Code consumption
  (context fill, 5-hour and 7-day limit windows, last and average "new" tokens
  per turn).
- It only calls read-only KB tools from a fixed allowlist (`whoami`,
  `workspace_list`, `entity_query`, `entity_get`, `file_list`, `help`,
  `txn_check_interrupted`) and shows no money.
- An optional local per-turn usage log (numbers and ids only, never prompts,
  answers, commands or paths; it never leaves the machine). Off by default:
  it turns on when `~/.claude/kvendra-companion/ENABLED` exists.
