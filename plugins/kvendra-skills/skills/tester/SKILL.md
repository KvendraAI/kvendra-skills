---
name: tester
description: Tester — runs tests and persists results as TEST entries in the Kvendra KB with preconditions, process, validations and evidence
user_invocable: false
args: "[test plan, objective, or REQ/ISSUE to test]"
---

# Tester — Run tests with Kvendra KB persistence

You act as an **Automated Tester**. You run tests and persist the results
as TEST entries in the Kvendra KB (structure: preconditions, process,
postconditions, validations, data, evidence). Subagent — receives `txn_id`
via args; does NOT open a TXN; the created TEST entries are born `draft`.

## Test plan / Objective

$ARGUMENTS

## Step 0 — Kvendra initialization

Identify `project_id` and `component_id` from the `CLAUDE.md`.

## Kvendra rules (summary)

- Identify yourself on every write: `updated_by: "skill:<this-skill>"`. The
  `X-Kvendra-Skill` header is added by the MCP client automatically.
- Orchestrator → `txn_create` before creating entities, close with
  `txn_activate` (success) or `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel(reason)` (failure).
  Subagent → receives `txn_id` via args and does NOT open/close the TXN.
- Before opening a TXN: `mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted(project_id, component_id?)`.
  If an in-progress TXN exists: Resume / Cancel / Ignore.
- Entity IDs are emitted by the server. Exception: `PRJ`/`CMP`/`REL` require `force_id`.
- If an error returns `error.help.topic`, call `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.

## External-execution policy

This skill respects the project'''s broker policy declared in
`STD-<PROJ>-BROKER-POLICY` and materialised at `.kvendra-protected`.
See `help({topic:"broker-policy"})` for the schema and resolution
order. Ops blocked by policy fail with a `[KVD-PROTECTED]` error
pointing to the required broker primitive.

## Step 1 — Load Kvendra context

1. **CMP of the component:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROJ>, tags_all:["CMP-<PROJ>-<COMP>"] })`

2. **IFs (to verify naming in tests):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"IF", project_id:<PROJ>, component_id:"<COMP>" })`

3. **REQ to validate** (if indicated):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REQ-<PROJ>-<NN>" })`

4. **ISSUE bug we cover** (if it's a regression-case):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"ISSUE-<PROJ>-<COMP>-<NN>" })`

5. **Existing tests** (to avoid duplicates — the server warns via
   `check_duplicates` automatically, but inspection is also useful):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TEST", project_id:<PROJ>, component_id:"<COMP>" })`

6. **SLA targets** (for performance tests):
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"SLA", project_id:<PROJ>, component_id:"<COMP>" })`

## Step 2 — Design the TEST

Determine the type: `functional | integration | regression-case | smoke | performance | ux-validation`.

Design the structure:

### Preconditions
- Environment (ENV ID), data, prior state.

### Process (steps)
- Exact action, expected outcome, timeout, on_failure.

### Postconditions
- Expected state, cleanup.

### Validations (V1, V2, …)
- Description, type (assertion / format-check / performance / naming-check),
  severity (critical / warning), reference (IF / SLA).

### Test data
- Dataset, variants (happy_path / error_case / edge_case), parameterisable.

### Result criteria
- Pass / Warning / Fail / Blocked.

## Step 3 — Execute the test

1. Verify preconditions.
2. Run each step in order.
3. Capture evidence (logs, screenshots, responses). Heavy evidence follows
   **Evidence attachments** below.
4. Evaluate each validation.
5. Record the result per step.

<!-- kvendra:evidence-attachments v1 -->
## Evidence attachments

Heavy evidence goes to Workspace Files, never into entity text. The engine
refuses large inline base64 runs and data-URIs in `content` and `metadata`
(above its size limits; 400 with `help.topic:"files"`) and caps `content` at
200000 characters.

- **Upload when** the evidence is binary (screenshot, PDF, HAR, video,
  archive) of any size, or text larger than about 16 KB (logs, dumps, long
  responses). Keep inline only the summary, the verdict and a short excerpt
  (about 40 lines at most).
- **Availability.** The `file_*` tools exist only on hosted Pro, Team and
  Enterprise servers. If `file_upload_init` is not in your tool list, or a
  call returns 403 (plan or `insufficient_privilege`) or 422
  `files_quota_exceeded`, or the byte upload fails or is blocked by policy,
  do NOT fail the run: keep the file on disk, reference its local path, and
  write `evidence not uploaded: <reason>` next to it.
- **Recipe.** Wire details live in `help({topic:"files"})`; read it once per
  session before the first upload.
  1. Measure the local file: size in bytes and sha256 (64 hex characters).
  2. `file_upload_init({ name, mime, size_bytes, sha256 })`. Omit
     `entity_id`: the entity is written after the upload.
  3. Send the bytes with the method it returns. `PUT`: to `upload.url` with
     exactly the headers in `upload.headers`, no more and no fewer.
     `MULTIPART` (over 100 MB): follow the help topic. The URLs expire after
     300 s; call `file_upload_init` again if they lapse.
  4. `file_complete({ file_id })` must answer `status:"ready"`.
  5. Add `{ file_id, kind:"kvendra-file", title, mime, size_bytes, sha256 }`
     to `metadata.attachments[]` of the entity you write next.
- **Never** write an upload or download URL into an entity, a report or a
  log. Readers mint a fresh one with `file_get_url({ file_id })`.
- If the entity write that should carry the attachments fails, call
  `file_delete({ file_id })` for each file uploaded for it.

```bash
# size and sha256 (macOS and Linux)
wc -c < "$FILE" | tr -d ' '
{ shasum -a 256 "$FILE" 2>/dev/null || sha256sum "$FILE"; } | cut -d' ' -f1
# PUT: one -H per entry of upload.headers, names and values copied verbatim.
# When sha256 was declared there are THREE entries; omitting any one of them
# makes the signature fail (403 SignatureDoesNotMatch). $CHECKSUM is the
# x-amz-checksum-sha256 value exactly as returned (base64, not the hex digest).
curl -sS -f -X PUT --upload-file "$FILE" \
  -H "content-type: $MIME" \
  -H "content-length: $SIZE" \
  -H "x-amz-checksum-sha256: $CHECKSUM" \
  "$UPLOAD_URL"
```
<!-- /kvendra:evidence-attachments -->

## Step 4 — Persist TEST in the Kvendra KB

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "TEST",
  project_id: "<PROJ>",
  component_id: "<COMP>",
  title: "TEST-<PROJ>-<COMP>-<auto>: <descriptive title>",
  content: <full markdown: preconditions / process / postconditions /
            validations / result / evidence summary + excerpts>,
  tags: ["type:<type>", "comp:<COMP>"],
  metadata: { attachments: [ /* only when uploads happened — see Evidence attachments */ ] },
  relations: [
    { type: "fulfills", target: "REQ-<PROJ>-<NN>" },
    { type: "fixes",    target: "ISSUE-<PROJ>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id received from orchestrator>",
  updated_by: "skill:tester"
})
```

The server:
- Auto-generates the `entity_id` (`TEST-<PROJ>-<COMP>-<NNN>`).
- Forces `status='draft'` because of the TXN.
- Generates the embedding (TEST has embedding by default).

## Step 5 — Output

```
### EXECUTIVE SUMMARY
- Tests designed: N
- Tests executed: N
- Pass: N / Warning: N / Fail: N / Blocked: N

### TESTS CREATED IN KVENDRA (DRAFT)
**TEST-<PROJ>-<COMP>-<NNN>: [Title]**
- Type: <type>
- Result: PASS | WARNING | FAIL | BLOCKED
- Validations: V1 OK, V2 OK, V3 WARN (detail)
- Relations: fulfills → REQ-..., fixes → ISSUE-...
- Attachments: N uploaded (FILE-...) | evidence not uploaded: <reason> | none
- KB entry: created (draft, txn_id=<txn>)

### BUGS FOUND
**ISSUE-NEW (type: bug): [Title]**
- Severity: critical | major | minor
- Found in: TEST-<PROJ>-<COMP>-<NNN>
- Steps to reproduce: ...
- Actual vs expected behavior
- Evidence: ...

### NOTES FOR THE UPDATER / ORCHESTRATOR
- Tests created: [list of IDs]
- Bugs found: [list]
- REGs that should include these tests: [suggestion]
- IFs verified: [list]
```
