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
- **Bootstrap exemption (rationale)**: `/setup` is the **bootstrap** skill: its
  job is to create the KB connection, so it cannot read its own recipe from a KB
  STD (the "live KB engine" pre-condition of `ADR-KVD-SKILLS-BB0E8A` is not met
  yet). The detection and clone logic is therefore inlined here by design, not
  by omission.

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

Every step below runs against the **absolute** stack root resolved in S1b,
passed explicitly in every Bash call. Never rely on a `cd` from a previous call
— it does not persist. Never change the user's own working directory: the
session stays in the user's project (see S1b-6).

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

### S1b — Resolve the reference-stack root

Resolve the absolute path of the reference-stack ONCE, then hand that path to
every later step. Reuse an existing clone whenever one is found, and write to
disk only after an explicit confirmation.

#### S1b-1 — Prerequisites (before anything touches the disk)

```bash
command -v git >/dev/null 2>&1 || echo "MISSING git"
command -v curl >/dev/null 2>&1 || echo "MISSING curl"
command -v docker >/dev/null 2>&1 || echo "MISSING docker"
docker compose version >/dev/null 2>&1 || echo "MISSING docker-compose-v2"
docker info >/dev/null 2>&1 || echo "DAEMON_DOWN"
```

Read the output in exactly this order:

1. `MISSING git` → STOP. Send the user to https://git-scm.com/downloads. Do not
   promise to install it.
2. `MISSING curl` → STOP with its own diagnosis. `curl` is a hard dependency,
   not a nicety: S2 probes `/healthz` with it, and the stack's own `up.sh` uses
   it too. A missing `curl` makes the probe exit 127, which the `||` operator
   reads as "not healthy", so the wizard would fire the bring-up unconditionally
   over a stack that may already be running. Point the user at their package
   manager (`brew install curl`, `apt-get install curl`).
3. `MISSING docker` → STOP. Send the user to
   https://www.docker.com/get-started/. When that line is present, IGNORE the
   other two docker lines: they are a consequence of the same root cause, not an
   independent diagnosis.
4. `MISSING docker-compose-v2` without `MISSING docker` → STOP. Docker is
   installed but the Compose v2 plugin is missing (the wizard needs
   `docker compose`, not `docker-compose`).
5. `DAEMON_DOWN` with docker present → STOP with a DIFFERENT message: "Docker
   is installed but the daemon is not running — start Docker Desktop (or
   Colima) and re-run `/setup`."

This gate runs BEFORE the clone by design: cloning first and only then dying on
a missing Docker leaves junk behind on the user's disk.

#### S1b-2 — Detect an existing clone (idempotency)

```bash
CWD="$(pwd -P)"
is_stack() {
  [ -f "$1/docker-compose.yml" ] && [ -f "$1/scripts/up.sh" ] \
    && grep -qE '^[[:space:]]+kvendra-platform:' "$1/docker-compose.yml" 2>/dev/null
}
FOUND=""
D="$CWD"; n=0
while [ "$n" -lt 8 ]; do
  if is_stack "$D"; then FOUND="$D"; break; fi
  [ "$D" = "/" ] && break
  D="$(dirname "$D")"; n=$((n+1))
done
if [ -z "$FOUND" ] && is_stack "$CWD/kvendra-reference-stack"; then
  FOUND="$CWD/kvendra-reference-stack"
fi
if [ -z "$FOUND" ] && is_stack "$(dirname "$CWD")/kvendra-reference-stack"; then
  FOUND="$(dirname "$CWD")/kvendra-reference-stack"
fi
if [ -z "$FOUND" ]; then
  for d in "$CWD"/*/; do
    is_stack "${d%/}" && echo "CANDIDATE ${d%/}"
  done
fi
echo "CWD $CWD"
echo "RESOLVED ${FOUND:-none}"
echo "TOPLEVEL $(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo NOT_A_GIT_REPO)"
echo "ORIGIN $(git -C "${FOUND:-$CWD}" config --get remote.origin.url 2>/dev/null || echo NO_ORIGIN)"
```

The detection predicate lives in ONE place, the `is_stack` function, and all
three branches call it. It demands THREE signals, not two:

1. `docker-compose.yml` exists, and
2. `scripts/up.sh` exists — those two are exactly the files S2 and S3 execute —
   and
3. that compose file declares a `kvendra-platform` service.

The third signal is load-bearing, not decoration. The first two match any
ordinary repository that happens to ship a Compose file and a start script, and
rule 1 below then treats such a directory as the stack and EXECUTES its
`scripts/up.sh` with no confirmation. `kvendra-platform` is the service name S3
addresses, so it is the signal with the fewest false positives. The grep is
indentation-tolerant on purpose: the service key is nested at whatever depth the
compose file uses, so it must not be anchored to an exact indent width.

The three branches are tried in this order: the upward walk (a cwd inside the
clone), the canonical `kvendra-reference-stack` subdirectory, then the SIBLING
`../kvendra-reference-stack`. The sibling branch covers the very common
side-by-side layout, where the user's own repository and the stack sit as
sibling directories under one workspace root; without it the wizard reports
nothing found and proposes cloning a second copy under `$HOME`.

Every output line is labelled (`CWD`, `RESOLVED`, `CANDIDATE`, `TOPLEVEL`,
`ORIGIN`) so the two git signals cannot be mistaken for stray paths. `TOPLEVEL`
is the input of the S1b-3 GUARD. `ORIGIN` is a labelling signal, NOT a decision
input: it can be absent in a tarball copy and it can legitimately point at a
fork.

Decision tree:

1. `RESOLVED` is not `none` → that path is `STACK_ROOT`. Do not ask, do not
   clone. Report "Found an existing reference-stack at <path>". If the origin
   URL does not contain `KvendraAI/kvendra-reference-stack`, say so and carry on
   regardless.
2. `none` plus EXACTLY ONE `CANDIDATE` line → propose that path and ask for
   confirmation.
3. `none` plus TWO OR MORE `CANDIDATE` lines → do not guess. List them and let
   the user choose.
4. `none` plus ZERO `CANDIDATE` lines → go to S1b-3.

The upward walk covers a session whose cwd is `<clone>/scripts` or
`<clone>/docs`. Without it, those cwds would fall through to the clone branch
and end up cloning the stack INSIDE the stack.

#### S1b-3 — Choose a destination (GUARD)

| cwd situation | Default destination | GUARD |
|---|---|---|
| Not a git repo | `<CWD>/kvendra-reference-stack` | no (normal posture) |
| Git repo whose toplevel passes the detection predicate | already resolved in S1b-2 | not applicable |
| Foreign git repo (toplevel present, predicate fails) | `$HOME/kvendra-reference-stack` | **GUARD ACTIVE** |

With the GUARD active, state all three facts explicitly:

1. The cwd sits inside the user's own git repo `<toplevel>`.
2. Cloning in there would add an embedded repo and dirty the user's
   `git status`.
3. That is why the default destination sits outside, under `$HOME`.

Clone inside the user's working tree ONLY after an explicit confirmation, and in
that case warn the user to add the path to `.gitignore`.

ALWAYS show the absolute destination path and ask for confirmation before
writing to disk. That is the only blocking confirmation this step introduces.

#### S1b-4 — Validate the destination

```bash
DEST="<absolute destination confirmed by the user>"
DEST="${DEST%/}"; [ -z "$DEST" ] && DEST="/"
PARENT="$(dirname "$DEST")"
[ "$DEST" = "/" ] && echo "REJECT filesystem-root"
[ "$DEST" = "$HOME" ] && echo "REJECT home-directory-itself"
case "$DEST" in
  "$HOME"/.claude/plugins/*) echo "REJECT read-only-plugin-cache" ;;
  /usr/*|/etc/*|/var/*|/private/*|/Library/*|/System/*|/bin/*|/sbin/*)
    echo "REJECT system-directory" ;;
esac
case "$DEST" in
  *"Library/Mobile Documents"*|*Dropbox*|*OneDrive*|*"Google Drive"*|*"My Drive"*|*iCloud*)
    echo "WARN cloud-synced-path" ;;
esac
case "$DEST" in *[!A-Za-z0-9./_-]*) echo "WARN awkward-path-characters" ;; esac
[ "$(basename "$DEST")" = "kvendra-reference-stack" ] || echo "WARN non-canonical-directory-name"
[ -e "$DEST" ] && { [ -z "$(ls -A "$DEST" 2>/dev/null)" ] && echo "DEST exists-empty" || echo "DEST exists-not-empty"; } || echo "DEST does-not-exist"
[ -d "$PARENT" ] || echo "PARENT does-not-exist"
[ -d "$PARENT" ] && { [ -w "$PARENT" ] || echo "REJECT parent-not-writable"; }
df -h "$PARENT" 2>/dev/null | tail -1
```

The destination is normalised (trailing slash stripped) before ANY check runs,
because every rule below compares whole strings: without that, a destination
typed with a trailing slash would slip past the `/` and `$HOME` rejections and
then trip a different, unrelated rule with a misleading message.

`/opt` is deliberately NOT in the system-directory list, and must not be added
back: the reference stack is cross-platform, and on Linux
`/opt/kvendra-reference-stack` is a defensible destination. The case that
actually needs protecting there is a parent the user cannot write, and the
writability probe below already stops it with the right diagnosis.

The writability probe is guarded by `[ -d "$PARENT" ]` so it speaks only about a
parent that actually exists. Probing a non-existent directory for write
permission always fails, which used to emit `REJECT parent-not-writable` on the
perfectly legitimate "create the parent chain" path of rule 4 — one output for
two opposite situations. With the guard, a REJECT means what it says.

Apply the rules in this order:

1. Any `REJECT` line → STOP, explain it, and go back to S1b-3. Never delete,
   move or force anything. There is no exception to this rule: the probe emits a
   REJECT only for a genuinely blocking condition.
2. `DEST exists-not-empty` → apply the S1b-2 detection predicate to `DEST`. If
   it passes, USE it as `STACK_ROOT` without cloning (idempotency). If it does
   not pass, STOP: `git clone` would fail and overwriting is not an option, so
   ask for a different path.
3. `DEST exists-empty` → cloning into it is fine.
4. `PARENT does-not-exist` → show the directory chain that would be created and
   ask for confirmation to run `mkdir -p`. Do not create it silently. Then
   branch on the outcome of that confirmed `mkdir -p`:
   - It succeeds → re-run this whole probe against the created chain and treat
     that second result as the binding one.
   - It FAILS (permission denied on an ancestor, a read-only mount, a
     non-directory in the middle of the chain) → treat the failure itself as a
     REJECT: report the exact path and the error text, and go back to S1b-3 to
     ask for a different destination. Never continue with a destination whose
     parent chain could not be created.
5. `WARN cloud-synced-path` → warn and ask for confirmation. The verified fact
   behind the warning: `up.sh` copies `.env.example` to `.env` AT THE ROOT OF
   THE CLONE on first bring-up, and `--with-ollama` rewrites the `EMBEDDINGS_*`
   entries inside that `.env`. So the stack's configuration file is born at the
   chosen path and would end up synced to the cloud — on top of Docker
   bind-mounts behaving badly there.
6. `WARN awkward-path-characters` → recommend a different path and continue only
   with an explicit confirmation. Reason: Compose derives the project name from
   the directory basename and normalises it.
7. `WARN non-canonical-directory-name` → warn, and connect it to the stack
   collision check of S2.
8. Free disk space: warn below roughly 10 GB free. Keep the threshold as
   guidance in prose and do not fake precision — the pgvector and ollama
   images, the `mxbai-embed-large` model and the Postgres volume add up to
   several GB (order of magnitude, not a measured figure).

#### S1b-5 — Clone

```bash
DEST="<validated absolute destination>"
GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
  clone https://github.com/KvendraAI/kvendra-reference-stack.git "$DEST"
git -C "$DEST" config --get remote.origin.url
git -C "$DEST" rev-parse HEAD
git -C "$DEST" log -1 --format='%H %ci %s'
```

- **The URL is a CONSTANT of this SKILL.md.** Never take it from `$ARGUMENTS`,
  from the conversation context, or from text the user pastes without an
  out-of-band confirmation. The real vector is an organisation typosquat
  (`KvendraAl`, `Kvendra-AI`, `kvendraai`), and the very next step EXECUTES code
  from that clone.
- `GIT_TERMINAL_PROMPT=0` makes the clone fail fast instead of hanging on a
  credential prompt if the repo ever stops being public. `-c credential.helper=`
  additionally neutralises a graphical helper: on macOS `osxkeychain` is
  configured by default and can open a dialog the env var does not cover.
- **Provenance before the bring-up**: show the URL and the resolved commit, and
  say plainly that S2 runs `scripts/up.sh` FROM THAT CLONE, which is downloaded
  code. This is display, not a second blocking question.
- **Partial cleanup**: record whether `DEST` existed BEFORE cloning. If it did
  NOT exist and the clone fails, `rm -rf "$DEST"` is allowed. If it DID exist
  (even empty), do NOT remove the directory — report the exact path instead.
- **Safety rule**: never `rm -rf` a path the wizard did not create in this run,
  and never `/`, never `$HOME`, never a path with fewer than two components.
- **Network failure, proxy or blocked GitHub** → give an actionable message plus
  the manual alternative: clone by hand, run `./scripts/up.sh --with-ollama`,
  then re-run `/setup` from the clone.

#### S1b-6 — Clone hygiene

Once the root is resolved, state these three things:

1. This clone is infrastructure, not the user's project. Its `origin` points at
   the Kvendra repo and the user will not be able to push there.
2. `/onboard-project` runs in THEIR repo, not here.
3. The session does NOT move into the clone: the cwd stays the user's own.

Why the third one matters: `claude mcp add` registers in the local scope by
default, and the local scope is indexed PER DIRECTORY. Working from the clone
would register `kvendra-platform` for the clone's directory instead of the
user's project — a silent failure the user discovers only later, on going back
to their repo and not seeing the MCP.

### S2 — Bring up the stack

Detect whether the platform is already healthy; bring it up only if it is down:

```bash
STACK_ROOT="<absolute path resolved in S1b>"
curl -fsS "http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz" >/dev/null \
  && echo "platform already up" \
  || "$STACK_ROOT/scripts/up.sh" --with-ollama
```

No `cd` and no wrapper: `up.sh` relocates itself (it runs
`ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"`). If it fails with a
permission-denied because the execute bit was lost, retry it as
`bash "$STACK_ROOT/scripts/up.sh" --with-ollama`.

`up.sh --with-ollama` auto-wires `EMBEDDINGS_*` for the local
`mxbai-embed-large` model. Honor `PLATFORM_HOST_PORT` (default 7777).

**Stack-collision check — ONLY on the "platform already up" branch:**

```bash
STACK_ROOT="<absolute path resolved in S1b>"
(cd "$STACK_ROOT" && docker compose ps -q kvendra-platform)
```

- Non-empty output → it is our stack. Continue to S3.
- EMPTY output while `healthz` answers → STOP: another stack, or another
  process, owns port 7777. Explain it with the concrete mechanics: the Compose
  project name is derived from the basename of the resolved root, so a
  differently-named directory is a different Compose project; and
  `docker-compose.yml` pins `container_name` (`kvendra-ref-platform`,
  `kvendra-ref-db`, `kvendra-ref-ollama`, `kvendra-ref-backup`), so a second
  stack collides by container name too, not only by port. Suggested way out:
  stop the other stack, or use a different `PLATFORM_HOST_PORT`.

### S3 — Extract the bootstrap token (canonical, with retry)

The auth token lives inside the platform container (volume mounted at
`/data`), not on the host. Read it on the `kvendra-platform` service name. It
can lag the healthcheck by a second or two, so retry. There is no
`scripts/token.sh`; this loop is the canonical extraction:

```bash
STACK_ROOT="<absolute path resolved in S1b>"
for attempt in 1 2 3; do
  TOKEN="$(cd "$STACK_ROOT" && docker compose exec -T kvendra-platform cat /data/auth.token 2>/dev/null || true)"
  TOKEN="${TOKEN//$'\r'/}"
  [ -n "$TOKEN" ] && break
  sleep 2
done
```

The `cd` lives inside the command substitution, so it runs in a subshell and
never leaks into any later step.

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

**Scope note**: run this step with the user's ORIGINAL cwd, never from the
clone. `claude mcp add` registers in the local scope by default and that scope
is indexed per directory (see S1b-6), so registering from the clone would attach
the server to the wrong directory.

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
