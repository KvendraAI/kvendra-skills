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

- Drops the 27 skills into `~/.claude/plugins/`.
- Reads `.mcp.json` and adds the `kvendra-cloud` HTTP MCP server entry
  to `~/.claude.json`. The server is named `kvendra-cloud` (not
  `kvendra`) so it does not collide with users who already have a
  local `kvendra` CLI MCP server registered — Claude Code resolves
  same-name servers by scope precedence, and a Plugin server is
  eclipsed silently by any Local server with the same name. Tools
  appear under the `mcp__plugin_kvendra-skills_kvendra-cloud__*` prefix.

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

The hosted server exposes 25 tools. If a call is refused because of your
plan, jump back to step 1 (see
<https://app.kvendra.cloud/docs/troubleshooting/#forbidden-tier>).

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
