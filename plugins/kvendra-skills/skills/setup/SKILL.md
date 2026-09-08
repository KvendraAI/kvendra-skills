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
  `kvendra-cloud` MCP server (no token is ever pasted). The account lives at
  **https://kvendra.ai** and the hosted engine requires the Pro tier.
- **Self-hosted** — the user runs the Kvendra Platform locally via Docker
  (the reference stack). This skill registers a distinct MCP server named
  `kvendra-platform` alongside the bundled `kvendra-cloud` server.

**Two domains, two different things. Signal it HERE, not later when a verify
fails:**

| Domain | What it gives | Which branch |
|---|---|---|
| `https://kvendra.ai` | the Kvendra **Pro** account that unlocks the hosted KB engine | Q1 = cloud |
| `https://kvendra.cloud` | a free **embeddings API key** (200k tokens/month) for a stack the user hosts | Q2 = cloud free-tier |

A free `kvendra.cloud` signup is NOT a way into the hosted KB engine: anything
below Pro gets `403 forbidden_tier` there. It is only a source of an
`EMBEDDINGS_API_KEY` for a self-hosted stack.

### Cloud path (KB-managed, Pro)

Open the branch with one question: **does the user already have a Kvendra Pro
account?** The two answers are two different executable paths.

**C1 — the account already exists.**

1. Tell the user to run `/mcp` in Claude Code, pick `kvendra-cloud`, and
   complete the browser flow.
2. Once `/mcp` reports `kvendra-cloud` connected, go to **S6 — Verify** and use
   the CLOUD verify block there (the server name to verify is `kvendra-cloud`).

**C2 — no account yet.**

1. Open `https://kvendra.ai` best-effort and ALWAYS print the URL as well, the
   same way `S1c-2` does it: a headless or remote session has neither `open` nor
   `xdg-open`, and a step that only launches a browser strands that user.
2. Say plainly what the wizard does NOT do: it does not create the account and
   it does not handle payment. Both of those happen on that site.
3. PAUSE. No polling, no timeout. Resume only when the user confirms the account
   exists, then continue with C1.

**Explicit disclaimer — the wizard does not authenticate.** The OAuth 2.1 + PKCE
cycle against `auth.kvendra.cloud` is driven by **Claude Code**, not by this
skill, and `/mcp` is a slash command the USER types: no skill can invoke it. The
wizard opens a URL, explains, and waits. It never logs anybody in, and it must
never claim otherwise.

**Tier note.** A verify that fails with `403 forbidden_tier` means the account
sits below Pro: the hosted KB engine is Pro-only, so point at
`https://kvendra.ai`. Do not confuse that 403 with the free `kvendra.cloud`
embeddings key, which grants no access to the hosted KB at all. Never attempt to
work around the 403.

The cloud path performs no local registration: the bundled server is used
as-is. Skip the self-hosted automation entirely.

## Q2 — (self-hosted only) Embeddings backend?

Ask which embeddings backend the self-hosted stack should use. The two answers
lead to DIFFERENT executable paths — this is a branch, not a preamble:

- **Local (Ollama)** — everything stays on the machine, nothing to register
  anywhere. SKIP `S1c` entirely and go to `S2`, **Ollama branch**. The reference
  stack rewires `EMBEDDINGS_*` for the `mxbai-embed-large` model when it is
  brought up with the Ollama flag.
- **Cloud free-tier** — a free key from `https://kvendra.cloud` (200k
  tokens/month) drives the embeddings while the KB engine still runs on the
  user's own machine. Go to **`S1c`** next: the wizard accompanies the signup,
  asks for the key, writes it into the stack's `.env`, probes it, and only then
  brings the stack up in `S2`, **cloud branch**, with no Ollama flag.

**Why the choice is worth a minute — vector spaces.** Ollama embeds with
`mxbai-embed-large`; the cloud embeds with `kvendra-embedding-v1` (1024-dim).
Those are DIFFERENT vector spaces, so a KB embedded locally cannot simply be
pointed at the cloud later: the whole corpus has to be re-embedded. Cloud
embeddings from day one leave the vectors already in the hosted engine's space.
Honest guard, unchanged: that does not make a later migration free — the
open-core build still has no export/import path. See `S7`.

Never tell the user to export the key into the environment before bring-up.
It does not work: the start script sources `.env` AFTER parsing its flags, so
the value read from the file overwrites whatever was exported.

## Self-hosted automated flow

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
  - **(c) is a real path now, not an empty promise.** It runs `S1b` first (the
    root has to be resolved before anything can be rewritten), then re-enters
    `Q2`, and then executes the branch the user picks: cloud free-tier → `S1c`,
    which performs the full rewire including the Ollama-to-cloud direction of
    `S1c-5`; Ollama → `S2`, Ollama branch. Either way the stack must be brought
    down and up again for the new `EMBEDDINGS_*` values to reach the container,
    because Compose interpolates `.env` when the container is created, not while
    it runs.
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

### S1c — Embeddings key (cloud free-tier only)

**Gate.** Run this whole step ONLY when the answer to `Q2` was *cloud
free-tier*. On the Ollama branch, skip `S1c` completely and go to `S2`.

**Ordering rule, and it is load-bearing**: on the cloud branch, `S2` does NOT
run until `S1c` has finished. The reason is mechanical, not stylistic — the
stack's start script only warns about an unreplaced key placeholder AFTER it has
brought everything up, so a wizard that brings up first makes the user sit
through a full bring-up and only then learn that `entity_create` and
`entity_search` are going to fail.

**Four traps this step exists to avoid.** All four were hit while building it,
so they are written down here instead of being rediscovered:

1. **Substring detection of an Ollama-wired `.env` is a FALSE POSITIVE.** The
   stack's `.env.example` documents the Ollama mode in prose and QUOTES the
   marker string `# set by up.sh --with-ollama` inside that comment. A
   fixed-string grep matches the comment and concludes that a PRISTINE `.env` is
   wired to Ollama. Match the marker as a WHOLE LINE (`$0 == m`), never as a
   substring.
2. **`VAR=value somefunction` does NOT export.** A variable assignment prefixing
   a shell FUNCTION call does not enter that function's environment, so
   `ENVIRON["VAR"]` inside its `awk` comes back empty and the `.env` silently
   ends up with an empty value. Non-secret values travel as `awk -v`; the secret
   is exported by a statement of its own.
3. **`mv` overwrites the destination's permissions.** The temp-file rewrite
   pattern REPLACES the file, so `chmod 600` has to run after EVERY `mv`, not
   once at the end.
4. **Never use the in-place flag of `sed`.** BSD/macOS and GNU disagree on its
   argument, and the stack's own start script already avoids it for that reason.
   The portable pattern is `awk` into a temp file, then `mv`.

#### S1c-1 — Confirm the branch

State which branch is running and what is about to happen: the wizard points the
user at the signup page, asks for the key, writes it into `<STACK_ROOT>/.env`,
checks it against the live endpoint, and only then brings the stack up without
the Ollama flag. Nothing is written to disk before the user hands over a key or
picks the escape hatch of `S1c-3`.

#### S1c-2 — Accompany the signup (the wizard cannot create the account)

```bash
KVD_SIGNUP_URL="https://kvendra.cloud"
echo "Free embeddings key (200k tokens/month): $KVD_SIGNUP_URL"
if command -v open >/dev/null 2>&1; then
  open "$KVD_SIGNUP_URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$KVD_SIGNUP_URL" >/dev/null 2>&1 || true
fi
```

- Opening a browser is BEST-EFFORT; the URL is ALWAYS printed. A headless box,
  an SSH session or a container has neither helper, and a step that only opens a
  browser leaves that user with no instruction at all.
- Say in one sentence that the wizard can neither create the account nor mint
  the key: minting one needs an already-authenticated caller, and identity goes
  through a hosted sign-in page with email verification. The wizard accompanies;
  the user signs up.
- Then PAUSE. No polling, no timeout, no spinner. Resume when the user says the
  key is in hand.

#### S1c-3 — Ask for the key, with the escape hatch in the SAME message

Ask for the key and give the way out in the same breath — not as a footnote:

- The pasted key is written to `<STACK_ROOT>/.env` and used for one probe
  request. It is never echoed back; at most its last 4 characters are shown.
- It never travels on a command line, so it is **never visible to `ps` on your
  machine; it does appear once in this conversation's transcript**. There is no
  secure-input primitive here, and pretending otherwise would be a lie.
- **Escape hatch**: anyone not comfortable with that pastes the key into the
  `EMBEDDINGS_API_KEY=` line of `<STACK_ROOT>/.env` themselves and tells the
  wizard to continue. The wizard then skips the write, still runs the checks of
  `S1c-6`, and reports the key as `PASTED_BY_USER`.

Form rules, applied before anything is written (implemented in `S1c-5`):

- REJECT: empty, multi-line, containing whitespace, containing `=`, or equal to
  the placeholder `REPLACE_WITH_YOUR_KVENDRA_KEY`.
- WARN, never REJECT, when the key does not start with `kvd_live_`. That format
  belongs to the hosted engine, which this skill cannot re-read at runtime, so
  it must not block on a contract it does not own.
- WARN when the key contains characters outside `[A-Za-z0-9_.:-]`, and give the
  REAL reason: the start script sources `.env` as shell code, so a space, a `#`,
  a `$` or a quote inside the value either breaks the bring-up or gets expanded
  into something else.

#### S1c-4 — Make sure a `.env` exists, and that it is git-ignored

A fresh clone has NO `.env` — the start script creates it from `.env.example` in
its own first step. So "write the key into the clone's `.env`" is impossible
until the wizard creates that file itself:

```bash
STACK_ROOT="<absolute path resolved in S1b>"
ENV_FILE="$STACK_ROOT/.env"
if [ -f "$ENV_FILE" ]; then echo "ENV exists-keep"; else
  cp "$STACK_ROOT/.env.example" "$ENV_FILE" && echo "ENV created-from-example"
fi
chmod 600 "$ENV_FILE"
if ! git -C "$STACK_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "GITIGNORE not-a-git-repo"
elif git -C "$STACK_ROOT" check-ignore -q .env; then
  echo "GITIGNORE ok"
else
  echo "REJECT env-not-gitignored"
fi
```

- An existing `.env` is NEVER overwritten. It may already hold a real key, a
  custom port or a database password.
- `chmod 600` because the copy inherits the umask (typically 644) and the file
  is about to hold a secret.
- That `chmod 600` is UNCONDITIONAL: it also tightens a `.env` the user already
  had and the wizard did not create. Say it out loud, because it is a real
  change to the user's own file - another account on the same machine that could
  read that `.env` before cannot any more.
- `REJECT env-not-gitignored` → STOP and explain. The reference stack does
  git-ignore `.env` today; if that ever stops being true, writing a secret into
  a tracked file is a far worse outcome than an aborted wizard.
- `GITIGNORE not-a-git-repo` is not a rejection: a tarball copy of the stack has
  no git metadata. Say so, and let the user decide.

#### S1c-5 — Detect FIRST, then decide how many lines to rewrite

"Only one line changes" is true of a `.env` freshly copied from `.env.example`
(provider, base URL and model are already the cloud values, only the key line
differs) and FALSE of a `.env` that an earlier Ollama bring-up rewired. The
second case is not hypothetical: `/setup` is idempotent and its own `S1` branch
(c) lands exactly there. Detect, then decide.

```bash
STACK_ROOT="<absolute path resolved in S1b>"
ENV_FILE="$STACK_ROOT/.env"
OLLAMA_MARKER="# set by up.sh --with-ollama"

kvd_set_env() {   # KEY VALUE - non-secret, passed via awk -v
  awk -v key="$1" -v val="$2" '
    !replaced && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" val; replaced=1; next }
    { print }
    END { if (!replaced) print key "=" val }
  ' "$ENV_FILE" > "$ENV_FILE.kvdtmp" && mv "$ENV_FILE.kvdtmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

kvd_set_key() {   # the secret, read from the environment, never from argv
  awk 'BEGIN { val = ENVIRON["KVD_EMB_KEY"] }
    !replaced && $0 ~ "^[[:space:]]*#?[[:space:]]*EMBEDDINGS_API_KEY=" { print "EMBEDDINGS_API_KEY=" val; replaced=1; next }
    { print }
    END { if (!replaced) print "EMBEDDINGS_API_KEY=" val }
  ' "$ENV_FILE" > "$ENV_FILE.kvdtmp" && mv "$ENV_FILE.kvdtmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

kvd_drop_marker() {
  awk -v m="$OLLAMA_MARKER" '$0 == m { next } { print }' \
    "$ENV_FILE" > "$ENV_FILE.kvdtmp" && mv "$ENV_FILE.kvdtmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

kvd_is_ollama_wired() {   # EXACT whole-line match, never a substring
  awk -v m="$OLLAMA_MARKER" '
    $0 == m { found=1 }
    /^[[:space:]]*EMBEDDINGS_BASE_URL=/ && /kvendra-ollama/ { found=1 }
    /^[[:space:]]*EMBEDDINGS_MODEL=mxbai-embed-large[[:space:]]*$/ { found=1 }
    END { exit(found?0:1) }
  ' "$ENV_FILE"
}

kvd_check_key_form() {
  case "$KVD_EMB_KEY" in
    "") echo "REJECT empty-key"; return 1 ;;
    REPLACE_WITH_YOUR_KVENDRA_KEY) echo "REJECT placeholder-pasted"; return 1 ;;
    *[[:space:]]*) echo "REJECT whitespace-or-newline-in-key"; return 1 ;;
    *=*) echo "REJECT equals-sign-in-key"; return 1 ;;
  esac
  case "$KVD_EMB_KEY" in
    kvd_live_*) ;;
    *) echo "WARN unexpected-key-prefix" ;;
  esac
  case "$KVD_EMB_KEY" in
    *[!A-Za-z0-9_.:-]*) echo "WARN unsafe-characters-for-dotenv-sourcing" ;;
  esac
  return 0
}

export KVD_EMB_KEY="$(cat <<'KVD_KEY_EOF'
PASTE_THE_KEY_ON_A_LINE_OF_ITS_OWN
KVD_KEY_EOF
)"

if kvd_check_key_form; then
  if kvd_is_ollama_wired; then
    echo "ENV was-ollama-wired: restoring the three cloud values"
    kvd_drop_marker
    kvd_set_env EMBEDDINGS_PROVIDER openai-compatible
    kvd_set_env EMBEDDINGS_BASE_URL https://api.kvendra.cloud/v1
    kvd_set_env EMBEDDINGS_MODEL kvendra-embedding-v1
  else
    echo "ENV cloud-defaults-intact: only the key line changes"
  fi
  kvd_set_key
  echo "ENV key-written"
fi
unset KVD_EMB_KEY
```

How to read that block:

- The secret enters through a heredoc with a **quoted** delimiter
  (`<<'KVD_KEY_EOF'`), so the shell expands nothing inside it: a `$` or a
  backtick in the key stays literal. Replace the placeholder line with the key
  the user pasted, keep it on a line of its own, and change nothing else.
- `kvd_is_ollama_wired` compares the marker with `$0 == m`. That is trap 1: the
  very same string appears inside a prose comment of `.env.example`, so a
  substring match would call a pristine file Ollama-wired and rewrite three
  lines that were already correct.
- The three cloud values travel as `awk -v` because they are not secrets. The
  key travels through `ENVIRON` because an `awk -v` assignment is visible in the
  process argv. `export` on its own line is trap 2: prefixing the function call
  with the assignment would leave `ENVIRON` empty.
- Every rewrite is `awk` into `$ENV_FILE.kvdtmp` followed by `mv`, and every one
  of them ends with its own `chmod 600` — trap 3. The block is idempotent:
  running it twice yields the same file.
- If `awk` itself fails, the `&&` short-circuits before the `mv` and an EMPTY
  `$ENV_FILE.kvdtmp` is left beside the `.env`. It carries no secret (the write
  never got that far), but delete it before re-running, so a stale temp file is
  never mistaken for a half-applied rewrite.
- `unset KVD_EMB_KEY` at the end. It also means no later step can reuse the
  variable: `S1c-7` reads the key back out of the `.env` that was just written,
  which is a stronger check anyway and keeps the key to a single appearance in
  the transcript.
- **Mirror warning — say it out loud right after the key is written**: a later
  Ollama bring-up of this same stack will silently repoint it at Ollama and
  leave the key inert. It is the same bug in the opposite direction.

#### S1c-6 — The placeholder must be gone

```bash
STACK_ROOT="<absolute path resolved in S1b>"
ENV_FILE="$STACK_ROOT/.env"
grep -c '^EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY' "$ENV_FILE" || true
grep -c '^EMBEDDINGS_BASE_URL=https://api.kvendra.cloud/v1' "$ENV_FILE" || true
ls -l "$ENV_FILE" | cut -c1-10
```

- The first count MUST be `0`. Anything else means the rewrite did not land:
  stop, show the `EMBEDDINGS_` lines of the file, and do NOT bring the stack up.
  This is the mechanical statement of the ordering rule — with the placeholder
  gone, the start script's late warning can no longer fire at all.
- The second count MUST be `1`. It is what proves the Ollama-to-cloud restore of
  `S1c-5` really happened on a re-run.
- One LEGITIMATE way that second count comes back `0`: the escape hatch of
  `S1c-3` taken over a `.env` that an earlier Ollama bring-up had rewired. The
  user pasted the key by hand, so `EMBEDDINGS_BASE_URL` still points at the
  Ollama service and no rewrite ever ran. That is not a failed rewrite and the
  first count is still the gate. Show the three `EMBEDDINGS_` lines, name the
  cause, and offer the remedy: run the `S1c-5` block once (it is idempotent, and
  the key line lands on the value already there), or have the user restore
  provider, base URL and model to the cloud values by hand.
- The permission string MUST read `-rw-------`.

#### S1c-7 — Probe the key against the live endpoint

Writing the WRONG key ALSO silences the start script's late placeholder warning,
so without a probe the ordering fix is only half honest: the user would still
find out, just later, on the first `entity_create`. One real call settles it,
for a handful of tokens out of the user's own monthly quota.

```bash
STACK_ROOT="<absolute path resolved in S1b>"
ENV_FILE="$STACK_ROOT/.env"
KVD_EMB_KEY="$(awk '/^EMBEDDINGS_API_KEY=/ { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE")"
BODY="$(mktemp)"
HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$KVD_EMB_KEY" \
  | curl --config - -s --max-time 20 -o "$BODY" -w '%{http_code}' \
      -X POST 'https://api.kvendra.cloud/v1/embeddings' \
      -H 'Content-Type: application/json' \
      -d '{"model":"kvendra-embedding-v1","input":"kvendra setup probe"}')"
CURL_RC=$?
BODY_SNIP="$(head -c 200 "$BODY" 2>/dev/null | tr -d '\r')"
rm -f "$BODY"
unset KVD_EMB_KEY
echo "PROBE http=$HTTP_CODE rc=$CURL_RC"
echo "PROBE body=$BODY_SNIP"
```

The header reaches `curl` on **stdin** via `--config -`, not as a `-H` argument,
so the key never lands in any process argv. That `printf` is the shell BUILTIN —
never the `/usr/bin/printf` binary, which would put the key in the argv of a
real process and undo the whole point. `CURL_RC` is captured on its own line
right after the assignment, and the exit code is never mixed with `2>&1` inside
the same capture.

Read the result on this ladder. Five outcomes, not two:

| Result | Meaning | What the wizard does |
|---|---|---|
| `2xx` | key valid, quota available | continue to `S2` |
| `401` | key invalid or revoked | ask for the key again; do NOT bring the stack up |
| `429` | key VALID, quota exhausted | say so and CONTINUE: the wiring is right, the quota is a separate problem the user solves on their account page |
| `403`, any other `4xx`, any `5xx` | inconclusive | show the code and the first ~200 characters of the body, then offer the choice: re-enter the key, or continue anyway |
| `CURL_RC` other than `0` | network, proxy or DNS failure, no verdict on the key | say so and offer to continue |

Only `401` blocks the bring-up. Everything else is either a pass or a decision
handed back to the user with the evidence attached: a probe that halted the
wizard behind a corporate proxy would be worse than no probe at all.

### S2 — Bring up the stack

Detect whether the platform is already healthy; bring it up only if it is down.
**The Ollama flag is CONDITIONAL on the `Q2` answer** — it is not a constant of
this step. Passing it on the cloud-embeddings branch rewires
`EMBEDDINGS_PROVIDER`, `EMBEDDINGS_BASE_URL` and `EMBEDDINGS_MODEL` to Ollama
AND suppresses the placeholder warning, so the key just written in `S1c` would
sit there inert without a single word of warning. Run only the block that
matches the branch.

**Ollama branch (`Q2` = local Ollama):**

```bash
STACK_ROOT="<absolute path resolved in S1b>"
curl -fsS "http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz" >/dev/null \
  && echo "platform already up" \
  || "$STACK_ROOT/scripts/up.sh" --with-ollama
```

This branch auto-wires `EMBEDDINGS_*` for the local `mxbai-embed-large` model.
If the script fails with a permission-denied because the execute bit was lost,
retry the same line as `bash "$STACK_ROOT/scripts/up.sh" --with-ollama`.

**Cloud-embeddings branch (`Q2` = cloud free-tier, `S1c` already finished):**

```bash
STACK_ROOT="<absolute path resolved in S1b>"
curl -fsS "http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz" >/dev/null \
  && echo "platform already up" \
  || "$STACK_ROOT/scripts/up.sh"
```

No flag, no extra container, no model download: the stack picks up the
embeddings values written in `S1c`. Same permission-denied fallback, flagless:
`bash "$STACK_ROOT/scripts/up.sh"`.

Neither block uses `cd` and neither needs a wrapper: the start script relocates
itself (it runs `ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"`). Honor
`PLATFORM_HOST_PORT` (default 7777) in both.

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

1. The MCP server reports connected (via `/mcp` or `claude mcp list`):
   `kvendra-platform` on the self-hosted path, `kvendra-cloud` on the cloud
   path.
2. The KB tools are present in the registered tool list (the
   `entity_*` / `txn_*` / `whoami` family).
3. A real KB read succeeds. **The tool namespace is NOT the same on both
   paths**: each MCP server exposes its own, so the read has to be issued
   against the server that was actually configured. Using the cloud namespace to
   verify a self-hosted registration tests the wrong server, or fails in a
   confusing way.

Self-hosted path — the `kvendra-platform` server registered in S4:

```
mcp__kvendra-platform__entity_query({ entity_type:"PRJ", limit: 5 })
```

Cloud path — the bundled `kvendra-cloud` server:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"PRJ", limit: 5 })
```

- Read works → report OK and the count of visible projects.
- Read fails on the self-hosted path → the connection is not live yet (restart
  pending) or the token is stale; re-run S3 + S4 with a fresh token.
- Read fails on the cloud path with `403 forbidden_tier` → the account is below
  Pro. Apply the tier note of the cloud path in Q1, and do not confuse it with
  the free embeddings key.

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
| Embeddings backend | ollama / cloud-free-tier / not-applicable (cloud KB path) |
| Embeddings key | WIRED / KEPT_EXISTING / PASTED_BY_USER / SKIPPED |
| Key probe | OK (2xx) / QUOTA (429) / INCONCLUSIVE (code) / NETWORK_FAIL / SKIPPED |
| MCP server name | kvendra-cloud / kvendra-platform |
| Registration status | REGISTERED / ALREADY_PRESENT / SKIPPED (cloud OAuth) / FAIL |
| Restart pending | Y / N |
| Verify result | OK / FAIL / PENDING (restart required) |
| Next step | /onboard-project (offered) |

### Notes
- [idempotency outcome, probe verdict when it was not a clean 2xx, the mirror
  warning if a key was written, migration caveat if raised]
```
