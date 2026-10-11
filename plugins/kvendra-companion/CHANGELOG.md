# Changelog

All notable changes to the `kvendra-companion` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-COMPANION-<VER>` entity in
the Kvendra KB.

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
