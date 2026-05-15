# Install `kvendra-skills`

Three steps. Total time ≈ 5 minutes after the Pro tier is in place.

## 1. Make sure you have a Pro Kvendra account

The Kvendra KB engine is Pro-only until the M2.6 billing milestone
ships. To get on Pro right now:

1. Sign up at <https://app.kvendra.cloud/signup/>. The default tier is
   Free.
2. Ask the Kvendra owner (`admin@kvendra.ai`) to promote the account.
   They run:

   ```bash
   aws cognito-idp admin-add-user-to-group \
     --profile aws_kvendra --region us-east-1 \
     --user-pool-id us-east-1_Bh2YsJNif \
     --username <your-cognito-sub-or-email> \
     --group-name kvendra-pro
   ```

   (Tier is encoded as Cognito User Pool group membership — there are
   `kvendra-pro` / `kvendra-team` / `kvendra-enterprise` groups, and a
   user with none of them is free. `kvendra-staff` is orthogonal and
   only gates admin endpoints.)

3. Sign out and sign back in so the new `cognito:groups` claim with
   `kvendra-pro` lands in your access token.

The dashboard at <https://app.kvendra.cloud/kb/> will start showing the
overview as soon as the upgrade is live.

## 2. Add the marketplace + install the plugin

In Claude Code:

```
/plugin marketplace add KvendraAI/kvendra-skills
/plugin install kvendra-skills@kvendra-marketplace
```

The `install` command:

- Drops the 25 skills into `~/.claude/plugins/`.
- Reads `.mcp.json` and adds the `kvendra-cloud` HTTP MCP server entry
  to `~/.claude.json`. The server is named `kvendra-cloud` (not
  `kvendra`) so it does not collide with users who already have a
  local `kvendra` CLI MCP server registered — Claude Code resolves
  same-name servers by scope precedence, and a Plugin server is
  eclipsed silently by any Local server with the same name. Tools
  appear under the `mcp__kvendra-cloud__*` prefix.

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

If the auto-dance does not trigger in your build of Claude Code, the
plugin ships a manual fallback skill (`/kvendra-skills:setup-auth`) —
not yet implemented but tracked. Until then, paste the Bearer header
directly into your `~/.claude.json` after running the OAuth flow once
from any browser.

## Verify

Run any of the heavy-help skills to sanity-check the wiring:

- `/kvendra-skills:user-help` — lists every available skill.
- `/kvendra-skills:env-check` — confirms the MCP server is reachable,
  the 14 tools are visible, your `kvendra:plan` claim is `pro`.
- `/kvendra-skills:to-do` — fetches your open issues from the KB.

If `env-check` fails the tier check, jump back to step 1.

## Known caveats

- **Two backend tools missing**: `txn_get` and `check_duplicates` (used
  by a handful of skills as a nice-to-have) are not yet exposed by the
  hosted MCP server. They will surface as `not_found` errors when a
  skill calls them. Tracked separately; the affected skills degrade
  gracefully (they fall back to `txn_check_interrupted` + `entity_query`
  for the same purpose).
- **No primitives bundle**: this plugin does NOT ship the CLI primitives
  (`kvendra.git`, `kvendra.github`, `kvendra.aws`, …). Those still run
  via the `kvendra` Rust binary on your laptop in tier Free / Team
  workspace mode, and need a separate install (`brew install kvendra`
  when the formula is published — pending CLI 0.1.0 stable).
- **No `backend-deploy` / `setup` skills**: removed for this plugin
  because they were Winking Owl-specific. The Kvendra equivalent of
  `setup` is this install flow; `backend-deploy` is autonomous per
  CLAUDE.md.
