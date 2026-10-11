# Changelog

All notable changes to the `kvendra-companion` plugin are recorded here.
Each release also has a canonical `REL-KVD-SKILLS-COMPANION-<VER>` entity in
the Kvendra KB.

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
