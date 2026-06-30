---
name: setup
description: Onboarding wizard — connects Claude Code to a Kvendra backend (self-hosted Docker or cloud-managed), registers the MCP, verifies, and chains to /onboard-project
user_invocable: true
args: "[optional: cloud | self-hosted]"
---

# Setup — Connect Claude Code to a Kvendra backend

You act as an **onboarding wizard**. You connect this Claude Code install to a
Kvendra backend, register the MCP server, verify the connection, and offer to
chain into `/onboard-project`. This skill is infra + configuration only: it
performs **no** KB entity writes (it only reads during the verify step).

## Args

`$ARGUMENTS` may pre-select a path: `cloud` or `self-hosted`. Empty → ask Q1.

## Kvendra rules (summary)

- This skill is **user-invocable and runs with NO TXN** — it configures the
  local environment and registers an MCP; it does not create, update, or
  archive KB entities. The only KB call is a read during the verify step.
- Identity-on-write does not apply here (there are no writes). The downstream
  pipelines you chain into (`/onboard-project`, `/new-feature`, etc.) are the
  ones that open TXNs and identify themselves on every write.
- Orchestrator vs subagent does not apply: `/setup` is a standalone, single
  interactive flow with no subagent delegation.

## External-execution policy

This skill respects the project's broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Step 0 — Scope boundary (state up front)

Make the boundary explicit so the user knows what `/setup` does and does not do:

- `/setup` = infra + MCP registration (this skill).
- `/env-check` = diagnosis of an already-configured environment.
- `/onboard-project` = create a project (PRJ/CMP/...) in the KB.

`/setup` connects the backend; it does not create any project. Project creation
is the explicit chain target offered at the end.

## Q1 — Cloud (KB-managed) or self-hosted?

Ask the user which backend they want (skip if `$ARGUMENTS` already answered):

- **Cloud (KB-managed)** — Kvendra hosts the KB engine. No Docker, no local
  containers. Authentication is browser OAuth against the already-bundled
  `kvendra-cloud` MCP server (no token is ever pasted).
- **Self-hosted** — the user runs the Kvendra Platform locally via Docker
  (the reference stack). This skill registers a distinct MCP server named
  `kvendra-platform` alongside the bundled `kvendra-cloud` server.

### Cloud path (KB-managed)

1. Direct the user to create an account at https://kvendra.ai (no signup
   automation in this MVP — that is a v1.1 follow-up).
2. The `kvendra-cloud` MCP server is **already bundled** with this plugin.
   To authenticate, the user runs `/mcp` from Claude Code and completes the
   browser OAuth flow against `kvendra-cloud`. No token is pasted — the flow
   is OAuth/PKCE against `auth.kvendra.cloud`.
3. Once `/mcp` reports `kvendra-cloud` connected, go to **Verify** below
   (the server name to verify is `kvendra-cloud`).

The cloud path performs no local registration: the bundled server is used
as-is. Skip the self-hosted automation entirely.

## Q2 — (self-hosted only) Embeddings backend?

Ask which embeddings backend the self-hosted stack should use:

- **Local (Ollama)** — fully automated by this skill. The reference stack
  wires `EMBEDDINGS_*` automatically for the `mxbai-embed-large` model when
  brought up with the Ollama profile.
- **Cloud free-tier** — instructions only in this MVP. Sign up for the free
  tier at https://kvendra.cloud (200k tokens/month), obtain an
  `EMBEDDINGS_API_KEY`, and export it before bring-up. After that, the same
  bring-up / register / verify steps apply. Full key-rewire automation is a
  v1.1 follow-up — this MVP does not edit the stack's embeddings env for you.

Both embeddings choices converge on the same bring-up, register, and verify
flow below. For the cloud free-tier, the user supplies the key first; the
automated steps then proceed identically.

## Self-hosted + local-embeddings automated flow

All commands below run from the reference-stack repo root.

### S1 — Idempotency check (run first)

Check whether a Kvendra MCP is already registered, so the wizard never
duplicates a server:

```bash
claude mcp list 2>&1 | grep -E 'kvendra-platform|kvendra-cloud'
```

- If `kvendra-platform` is already present → do NOT register a second one.
  Offer three choices instead: (a) re-verify the existing connection,
  (b) re-register with a fresh token, (c) reconfigure embeddings.
- If only `kvendra-cloud` is present → that is the bundled cloud server; it is
  expected and must stay untouched. Continue with bring-up for the distinct
  `kvendra-platform` server.

### S2 — Bring up the stack

Detect whether the platform is already healthy; bring it up only if it is down:

```bash
curl -fsS "http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz" \
  && echo "platform already up" \
  || ./scripts/up.sh --with-ollama
```

`./scripts/up.sh --with-ollama` auto-wires `EMBEDDINGS_*` for the local
`mxbai-embed-large` model. Honor `PLATFORM_HOST_PORT` (default 7777).

### S3 — Extract the bootstrap token (canonical, with retry)

The auth token lives inside the platform container (volume mounted at
`/data`), not on the host. Read it on the `kvendra-platform` service name. It
can lag the healthcheck by a second or two, so retry. There is no
`scripts/token.sh`; this loop is the canonical extraction:

```bash
for attempt in 1 2 3; do
  TOKEN="$(docker compose exec -T kvendra-platform cat /data/auth.token 2>/dev/null || true)"
  TOKEN="${TOKEN//$'\r'/}"
  [ -n "$TOKEN" ] && break
  sleep 2
done
```

If `TOKEN` is still empty after three attempts, the platform has not generated
the token yet — wait a few seconds and re-run S3 (do not register an empty
token).

### S4 — Register the MCP (distinct server name)

Register the self-hosted platform under the distinct name `kvendra-platform`
(pattern B). The bundled `kvendra-cloud` server is left UNTOUCHED — the two
coexist because they have distinct names:

```bash
claude mcp add kvendra-platform http://localhost:7777/mcp --transport http -H "Authorization: Bearer ${TOKEN}"
```

Honor `PLATFORM_HOST_PORT` (default 7777) if the user overrode it during S2.

### S5 — Restart caveat (honest)

State plainly: activating a newly-added MCP requires a Claude Code restart, or
`/mcp reconnect kvendra-platform`. This is the user's step — you cannot do it
for them. Do NOT claim the new server is live without a restart or reconnect.
(A no-restart reload path via a parametrized bundled MCP is a v1.1 design, not
this MVP.)

### S6 — Verify

After the user restarts or reconnects, verify the connection (the same logic
`/env-check` applies, condensed — do not reproduce the full env-check table):

1. The `kvendra-platform` MCP reports connected (via `/mcp` or
   `claude mcp list`).
2. The KB tools are present in the registered tool list (the
   `entity_*` / `txn_*` / `whoami` family).
3. A real KB read succeeds:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"PRJ", limit: 5 })
```

- Read works → report OK and the count of visible projects.
- Read fails → the connection is not live yet (restart pending) or the token
  is stale; re-run S3 + S4 with a fresh token.

For the **cloud path**, the verify target is the bundled `kvendra-cloud`
server instead; the read test is identical.

### S7 — Migration guard (honest)

If the user later wants to move from self-hosted to cloud (or vice versa), be
honest about the cost: vectors are NOT portable across embedding models, so a
backend switch requires **re-embedding** the whole KB. The open-core build has
no export/import path for this. Point the user to https://kvendra.ai/docs for
the supported migration story. Do not present a fake one-click switch.

### S8 — Chain (offer, do not auto-run)

On a successful verify, OFFER the next step — do not run it automatically:

- `/onboard-project` — create the first project (PRJ/CMP/...) in the KB.

Restate the boundary so the user picks the right tool: `/setup` = infra + MCP
registration · `/env-check` = diagnosis · `/onboard-project` = create a project
in the KB.

### S9 — Optional CLI broker (offer only)

At the very end, merely mention the optional `kvendra` CLI broker (audited
external ops with vault-backed credentials) and link to the project's install
docs. No automation — this is informational only.

## Required output

```
## Setup status

| Field | Value |
|-------|-------|
| Backend chosen | cloud / self-hosted |
| MCP server name | kvendra-cloud / kvendra-platform |
| Registration status | REGISTERED / ALREADY_PRESENT / SKIPPED (cloud OAuth) / FAIL |
| Restart pending | Y / N |
| Verify result | OK / FAIL / PENDING (restart required) |
| Next step | /onboard-project (offered) |

### Notes
- [embeddings backend, idempotency outcome, migration caveat if raised]
```
