# kvendra-companion

A read-only Claude Code mod for Kvendra users. It draws a small band above the prompt:

```
KVD · your.name (pro/owner)
TXN 0 · 1953 entities · 309 open ISSUEs · 23 files 2.2 MB · skills 1.25.0 ✓
ctx 34% · 5h 18% ↻4h · 7d 21% ↻44h · last 1.8k new · avg 10.3k new
```

- **Line 1:** project (from the `project_id` in your `CLAUDE.md`), workspace and role (Team/Enterprise only), user.
- **Line 2:** open TXNs (yellow when one has been in progress for 2 hours or more), entities, open ISSUEs, Workspace Files size, and the `kvendra-skills` version (yellow "restart" when the version on disk differs from the one your session loaded).
- **Line 3:** Claude Code consumption: context fill, the 5-hour and 7-day limit windows, and the last and average "new" tokens per turn (uncached input + output + cache writes; cache reads are not counted).

No money is ever shown.

## Requirements

- A Claude Code build with mods, enabled by default in the terminal from 2.1.287. Mods are an **early-access** Claude Code feature: their API can change between releases, and a future build may need a new version of this plugin.
- `kvendra-skills` installed and signed in: the band talks to the Kvendra KB through the MCP server that `kvendra-skills` provides. Without it the band shows "Kvendra: unavailable".

On an older build the plugin loads with nothing to run: no band and no error.

## Install

```
/plugin install kvendra-companion --marketplace KvendraAI/kvendra-skills
```

Or, with the marketplace already added: `/plugin install kvendra-companion@kvendra-marketplace`.

## What it reads and what it never does

- It only calls read-only KB tools from a fixed list: `whoami`, `workspace_list`, `entity_query`, `entity_get`, `file_list`, `help`, `txn_check_interrupted`. It never writes to the KB, never calls the broker CLI and never resolves private values.
- The user name comes from the project entity and is only read in your own KB, never in a team workspace.
- Locally it reads: your `CLAUDE.md` files (walking up from the session folder, to find `project_id`), the plugin manifest of `kvendra-skills`, and the Claude Code usage figures the engine offers to mods.
- Nothing is sent anywhere except those KB reads.
- It refreshes TXNs and the skills version every 30 seconds and the rest every 5 minutes.
- The comparison with published `kvendra-skills` releases is only made in the Kvendra project itself.

## Optional per-turn usage log (off by default)

To measure your own consumption, create an empty file:

```
touch ~/.claude/kvendra-companion/ENABLED
```

From then on, each finished turn appends one line of numbers and ids (token counts, the cost step, context and window percentages, how many Kvendra tools were used) to `~/.claude/kvendra-companion/turns-<date>-<session>.jsonl`. It never records prompts, answers, commands or paths, and it never leaves your machine. Delete the `ENABLED` file to stop.

## Development

```
claude plugin validate .
claude plugin test .
```

Type-check with TypeScript 5.4 or later against the declarations Claude Code writes next to a loaded mod.
