# Install `kvendra-skills`

Three steps. Total time ≈ 5 minutes. This page covers the **hosted**
service (Kvendra Cloud); the canonical, always-current version of these
steps is <https://app.kvendra.cloud/docs/>. To run your own engine
instead, see the **Self-hosted** note at the end.

## 1. Sign up on a Pro or Team plan

The hosted Kvendra KB engine needs a Pro or Team account. Sign up at
<https://app.kvendra.cloud/signup> and pick a Pro or Team plan. If you
already have a Free account, upgrade it from
<https://app.kvendra.cloud/me/>.

The dashboard at <https://app.kvendra.cloud/kb/> shows your KB overview
once the plan is active.

## 2. Add the marketplace + install the plugin

In Claude Code:

```
/plugin marketplace add KvendraAI/kvendra-skills
/plugin install kvendra-skills@kvendra-marketplace
```

The `install` command:

- Drops the 28 skills into `~/.claude/plugins/`.
- Reads `.mcp.json` and adds the `kvendra-cloud` HTTP MCP server entry
  to `~/.claude.json`. The server is named `kvendra-cloud` (not
  `kvendra`) so it does not collide with users who already have a
  local `kvendra` CLI MCP server registered — Claude Code resolves
  same-name servers by scope precedence, and a Plugin server is
  eclipsed silently by any Local server with the same name. Tools
  appear under the `mcp__plugin_kvendra-skills_kvendra-cloud__*` prefix.
  If you connect Kvendra another way, the prefix changes: a claude.ai
  connector shows up as `mcp__claude_ai_<connector name>__*` (when it points at the same
  URL as the plugin server, Claude Code hides the plugin server as a duplicate;
  with a `KVENDRA_WS` workspace the URLs differ and both stay, and the skills
  then use the plugin server, which carries that workspace), and
  `claude mcp add <name> https://api.kvendra.cloud/mcp` as `mcp__<name>__*`.
  The skills work with any of them: they call the engine tools by their
  bare name, and the plugin hooks match any prefix.

## 3. First MCP request triggers OAuth

The first time a skill makes a tool call (`/kvendra-skills:to-do` is a
gentle one — it just lists open issues), Claude Code talks to
`https://api.kvendra.cloud/mcp` without a token, the server replies
401 with a `WWW-Authenticate: Bearer` header, and Claude Code follows
the OAuth metadata at
`https://api.kvendra.cloud/.well-known/oauth-authorization-server`.

That metadata points the client at the Cognito Hosted UI on
`auth.kvendra.cloud/oauth2/authorize` for the PKCE flow. A browser tab
opens, you confirm, the callback delivers an authorization code, the
client exchanges it for an access token, and from then on Claude Code
attaches the token to every `/mcp` request.

You can also start the sign-in yourself: run `/mcp`, pick
`kvendra-cloud` and choose sign in. If your session expires later, do
the same again — see
<https://app.kvendra.cloud/docs/troubleshooting/#reauth>.

## Verify

Run any of the heavy-help skills to sanity-check the wiring:

- `/kvendra-skills:user-help` — lists every available skill.
- `/kvendra-skills:env-check` — confirms the `kvendra-cloud` MCP server
  is connected and a real KB read works.
- `/kvendra-skills:to-do` — fetches your open issues from the KB.

If a call is refused because of your plan, jump back to step 1 (see
<https://app.kvendra.cloud/docs/troubleshooting/#forbidden-tier>).

## Upgrading to 2.0.0

kvendra-skills 2.0.0 writes tasks, specifications, notes, decisions and
project releases through the Kvendra tool `work` (the work cycle). Three
things to know when you update from 1.x:

- **Sign in once more.** The plugin server now sends the header
  `X-Kvendra-Client: kvendra-skills/2.0.0`. Claude Code stores the OAuth
  credential under the server's type, URL and headers, so after the update
  `kvendra-cloud` shows *Needs authentication*. Run `/mcp`, pick
  `kvendra-cloud` and choose Authenticate, once (once per `KVENDRA_WS`
  account). The header keeps that value for every 2.x release, so later 2.x
  updates do not ask again.
- **The server must list `work`.** Without it the skills stop before any
  write and tell you so. A session opened before the server gained `work`
  keeps its old tool list: restart Claude Code, or run `/mcp` and reconnect.
  A Kvendra server without `work` (for example an older self-hosted engine)
  needs kvendra-skills 1.35.x: there is no 1.x fallback in 2.0.0.
  `/kvendra-skills:env-check` checks both (check 2).
- **claude.ai Kvendra connector.** If you also connected Kvendra as a
  claude.ai connector on the same URL, Claude Code may hide the plugin server
  (often in headless `claude -p` sessions) and the skills then use the
  connector. The header is not sent in that case; everything else works the
  same. `/kvendra-skills:env-check` reports it as a warning (check 1).

Open sessions load 2.0.0 only after `/plugin update` (or your org's sync)
and `/exit` + `claude --resume`. What changes in the pipelines is listed
in the [CHANGELOG](./CHANGELOG.md).

## Several Kvendra accounts (optional)

A token is one identity and one tenant: the server resolves the workspace
from your membership, so an account cannot be switched from inside a
session. If you use more than one account (a personal Pro plan plus one or
more Team workspaces), keep one credential per account and pick it by
directory.

The plugin's server URL is `https://api.kvendra.cloud/mcp${KVENDRA_WS:-}`.
Without the variable it expands to the plain URL, so single-account users
notice nothing. To add an account, declare a label in the
`.claude/settings.json` (or `settings.local.json`) of the directory you
work from:

```json
{ "env": { "KVENDRA_WS": "?ws=acme" } }
```

Start Claude Code **from that directory**, run `/mcp`, pick
`kvendra-cloud` and sign in **with that account**. Each distinct label is a
separate, persistent credential.

Rules worth knowing:

- Project settings are not inherited by subdirectories. Start Claude Code
  from the exact directory that holds `.claude/`.
- The label does not choose the account; the sign-in does. Confirm with
  `/kvendra-skills:env-check` (check 10 prints the real `tenant_id`).
- A `KVENDRA_WS` exported in your shell overrides every directory.
- Do not hand-edit the plugin's cached `.mcp.json`: plugin updates
  overwrite it. Since 1.16.1 the variable is part of the published URL.

## Known caveats

- **No primitives bundle**: this plugin does NOT ship the CLI primitives
  (`kvendra.git`, `kvendra.github`, `kvendra.aws`, …). Those still run
  via the `kvendra` Rust binary on your laptop in tier Free / Team
  workspace mode, and need a separate install (`brew install kvendra`
  when the formula is published — pending CLI 0.1.0 stable).
- **Self-hosted**: to run your own engine instead of the hosted one,
  follow the self-hosted quickstart at
  <https://kvendra.dev/docs/getting-started/> (for AI agents:
  <https://kvendra.dev/llms.txt>).

The canonical hosted guide is <https://app.kvendra.cloud/docs/>.
