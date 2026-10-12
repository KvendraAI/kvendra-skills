import type { Skills, Summary, Usage, Window } from '../types'

// The only KB tools this mod may call. All read-only: no txn_*, no entity
// writes, no send_message, no private_value_resolve.
export const READ_ONLY_TOOLS = [
  'whoami',
  'workspace_list',
  'entity_query',
  'entity_get',
  'file_list',
  'help',
  'txn_check_interrupted',
] as const

export const KB_SERVER = 'plugin:kvendra-skills:kvendra-cloud'
export const STALE_TXN_MS = 2 * 60 * 60 * 1000

export function assertReadOnly(tool: string): void {
  if (!(READ_ONLY_TOOLS as readonly string[]).includes(tool)) {
    throw new Error(`kvendra-companion: tool not allowed: ${tool}`)
  }
}

// `- \`project_id\`: **KVD**` in the boot ROM.
export function parseProjectId(claudeMd: string): string | null {
  const m = /`project_id`\W+([A-Z][A-Z0-9]*)/.exec(claudeMd)
  return m?.[1] ?? null
}

// The boot ROM nearest to `start`, looking up the tree; `read` rejects when a file is missing.
export async function findProjectId(
  read: (path: string) => Promise<string>,
  start: string,
): Promise<string | null> {
  let dir = start
  for (let i = 0; i < 12 && dir !== ''; i++) {
    try {
      const id = parseProjectId(await read(`${dir === '/' ? '' : dir}/CLAUDE.md`))
      if (id !== null) return id
    } catch {
      // no file here: keep going up
    }
    if (dir === '/') break
    dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
  }
  return null
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

type Block = { type: string; text?: string }
type Result = { content: Block[]; isError: boolean; structuredContent?: unknown }

// A tool result as plain data: structuredContent, else the first text block as JSON.
export function payload(res: Result): Record<string, unknown> {
  if (res.isError) throw new Error('kb tool returned an error')
  const s = res.structuredContent
  if (s !== null && typeof s === 'object') return s as Record<string, unknown>
  const text = res.content.find(b => b.type === 'text')?.text
  if (text === undefined) throw new Error('kb tool returned no text')
  return JSON.parse(text) as Record<string, unknown>
}

export function num(v: unknown): number | null {
  return typeof v === 'number' ? v : null
}

// ---- versions -------------------------------------------------------------

export function parseSemver(v: string): [number, number, number] | null {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v)
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

export function cmpSemver(a: string, b: string): number {
  const x = parseSemver(a)
  const y = parseSemver(b)
  if (x === null || y === null) return 0
  for (let i = 0; i < 3; i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}

// The highest x.y.z among REL ids (`REL-KVD-SKILLS-1.25.0`), by version and not
// by edit date; a pre-release id (`...-1.3.0-alpha.1`) is skipped.
export function latestRelease(ids: readonly string[]): string | null {
  let best: string | null = null
  for (const id of ids) {
    const v = /-(\d+\.\d+\.\d+)$/.exec(id)?.[1]
    if (v !== undefined && (best === null || cmpSemver(v, best) > 0)) best = v
  }
  return best
}

// ---- the band -------------------------------------------------------------

export type Seg = { text: string; warn?: boolean }
export type Line = Seg[]

// Yellow only when the session needs a restart; otherwise neutral.
export function skillsSegment(s: Skills | null): Seg | null {
  if (s === null || s.disk === null) return null
  if (s.loaded !== null && s.loaded !== s.disk) {
    return { text: `${LABELS.skills.long} ${s.loaded} → ${s.disk} · restart`, warn: true }
  }
  if (s.published !== null && cmpSemver(s.published, s.disk) > 0) {
    return { text: `${LABELS.skills.long} ${s.disk} (${s.published} published)` }
  }
  return { text: `${LABELS.skills.long} ${s.disk} ✓` }
}

// An in-progress TXN older than two hours is read as orphaned.
export function staleHours(startedAt: readonly (string | number | undefined)[], now: number): number | null {
  let oldest: number | null = null
  for (const t of startedAt) {
    const ms = typeof t === 'number' ? t : typeof t === 'string' ? Date.parse(t) : NaN
    if (Number.isNaN(ms)) continue
    const age = now - ms
    if (age >= STALE_TXN_MS && (oldest === null || age > oldest)) oldest = age
  }
  return oldest === null ? null : Math.floor(oldest / 3_600_000)
}

export const BAND_WIDTH = 80

// One table feeds the band and the legend, so the two cannot drift apart.
export const LABELS = {
  txn: { long: 'TXN', short: 'TXN', means: 'open transactions in this project; "orphan Nh" = one open for 2 h or more' },
  entities: { long: 'entities', short: 'ent', means: 'entities in the knowledge base' },
  issues: { long: 'open ISSUEs', short: 'ISS', means: 'ISSUEs not closed in this project' },
  files: { long: 'files', short: 'f', means: 'files in Workspace Files and their total size' },
  skills: { long: 'skills', short: 'skills', means: 'kvendra-skills version; "✓" up to date, "→ … · restart" = restart the session' },
  ctx: { long: 'ctx', short: 'ctx', means: 'context window used' },
  five: { long: '5h', short: '5h', means: 'account usage in the 5-hour window; ↻ = time until it resets' },
  seven: { long: '7d', short: '7d', means: 'account usage in the 7-day window; ↻ = time until it resets' },
  last: { long: 'last', short: 'last', means: 'tokens the last turn added ("new": input + output + cache written; cache only read is left out)' },
  avg: { long: 'avg', short: 'avg', means: 'average of "new" tokens per turn in this session' },
} as const

export const LEGEND_COMMAND = 'kvendra-legend'

// Written out at the end of line 3, only when it fits: it never costs another figure.
export const HINT = `/${LEGEND_COMMAND}`

export const LOADING_TEXT = `Kvendra: loading… · legend: ${HINT}`

function dataLine(s: Summary, isShort: boolean): Line {
  const data: Line = []
  data.push(
    s.staleTxnHours === null
      ? { text: `${LABELS.txn.long} ${s.openTxns}` }
      : { text: `${LABELS.txn.long} ${s.openTxns} · orphan ${s.staleTxnHours}h`, warn: true },
  )
  if (s.entities !== null) data.push({ text: `${s.entities} ${isShort ? LABELS.entities.short : LABELS.entities.long}` })
  if (s.openIssues !== null) data.push({ text: `${s.openIssues} ${isShort ? LABELS.issues.short : LABELS.issues.long}` })
  if (s.filesBytes !== null) {
    const n = s.filesCount ?? 0
    data.push({ text: `${n} ${isShort ? LABELS.files.short : LABELS.files.long} ${formatBytes(s.filesBytes)}` })
  }
  const sk = skillsSegment(s.skills)
  if (sk !== null) data.push(sk)
  return data
}

export function lineWidth(line: Line): number {
  return line.reduce((n, seg, i) => n + seg.text.length + (i > 0 ? 3 : 0), 0)
}

// What $.state may hold from an earlier version of this mod: fill what is missing
// and drop what is not an object, so a draw never throws on an old shape.
export function normalizeSummary(raw: unknown): Summary | null {
  if (raw === null || typeof raw !== 'object') return null
  const r = raw as Partial<Summary>
  const w = r.workspace
  return {
    project: r.project ?? null,
    userName: r.userName ?? null,
    tier: r.tier ?? '?',
    role: r.role ?? '?',
    workspace: w != null && typeof w.name === 'string' ? { name: w.name, role: w.role ?? '?' } : null,
    openTxns: r.openTxns ?? 0,
    staleTxnHours: r.staleTxnHours ?? null,
    entities: r.entities ?? null,
    openIssues: r.openIssues ?? null,
    filesBytes: r.filesBytes ?? null,
    filesCount: r.filesCount ?? null,
    skills: r.skills ?? null,
    at: r.at ?? 0,
  }
}

export function bandLines(s: Summary): Line[] {
  const who: Line = []
  who.push({ text: s.project ?? 'no project' })
  // The workspace role is shown only when it differs from the account role (shown below).
  if (s.workspace != null) {
    who.push({ text: s.workspace.role === s.role ? s.workspace.name : `${s.workspace.name} (${s.workspace.role})` })
  }
  const tierRole = `${s.tier}/${s.role}`
  who.push({ text: s.userName === null ? tierRole : `${s.userName} (${tierRole})` })

  // Shorter labels, not a second row, when the data line would pass the width.
  const long = dataLine(s, false)
  return [who, lineWidth(long) > BAND_WIDTH ? dataLine(s, true) : long]
}

// ---- per-turn usage log ---------------------------------------------------
// Numbers and ids only: never a prompt, an answer, a command or a path.

export type Counts = { kb: number; broker: number; skills: number }

export function emptyCounts(): Counts {
  return { kb: 0, broker: 0, skills: 0 }
}

const KB_PREFIX = 'mcp__plugin_kvendra-skills_kvendra-cloud__'
const BROKER_PREFIX = 'mcp__kvendra__'

// Which Kvendra surface a tool call belongs to, by its name alone.
export function classifyTool(tool: string, skill?: string): keyof Counts | null {
  if (tool.startsWith(KB_PREFIX)) return 'kb'
  if (tool.startsWith(BROKER_PREFIX)) return 'broker'
  if (tool === 'Skill' && typeof skill === 'string' && skill.startsWith('kvendra-skills:')) return 'skills'
  return null
}

export type TurnRecord = {
  ts: string
  session: string
  turn: string
  agent: string | null
  model: string | null
  reason: string
  durationMs: number
  input: number | null
  output: number | null
  cacheRead: number | null
  cacheWrite: number | null
  usdDelta: number | null
  ctxPercent: number | null
  fiveHourPct: number | null
  sevenDayPct: number | null
  kvendra: Counts
  txn: string[]
  project: string | null
}

type TurnUsageLike = {
  input_tokens: number
  output_tokens: number
  cache_read_input_tokens: number
  cache_creation_input_tokens: number
  model: string
}

export type TurnRecordArgs = {
  now: number
  session: string
  turn: string
  agent: string | undefined
  reason: string
  durationMs: number
  usage: TurnUsageLike | undefined
  usdNow: number | null
  usdBefore: number | null
  ctxPercent: number | undefined
  rateLimits: readonly { kind: string; percentUsed: number }[]
  counts: Counts
  txn: readonly string[]
  project: string | null
}

export function turnRecord(a: TurnRecordArgs): TurnRecord {
  const win = (kind: string) => a.rateLimits.find(r => r.kind === kind)?.percentUsed ?? null
  const delta = costStep(a.usdNow, a.usdBefore)
  return {
    ts: new Date(a.now).toISOString(),
    session: a.session,
    turn: a.turn,
    agent: a.agent ?? null,
    model: a.usage?.model ?? null,
    reason: a.reason,
    durationMs: a.durationMs,
    input: a.usage?.input_tokens ?? null,
    output: a.usage?.output_tokens ?? null,
    cacheRead: a.usage?.cache_read_input_tokens ?? null,
    cacheWrite: a.usage?.cache_creation_input_tokens ?? null,
    usdDelta: delta === null ? null : Math.round(delta * 1e6) / 1e6,
    ctxPercent: a.ctxPercent ?? null,
    fiveHourPct: win('five_hour'),
    sevenDayPct: win('seven_day'),
    kvendra: { ...a.counts },
    txn: [...a.txn],
    project: a.project,
  }
}

export function recordLine(r: TurnRecord): string {
  return JSON.stringify(r)
}

// One file per session and day, so two sessions never rewrite the same file.
export function logFileName(now: number, sessionId: string): string {
  const day = new Date(now).toISOString().slice(0, 10)
  return `turns-${day}-${sessionId.replace(/[^A-Za-z0-9]/g, '').slice(0, 8)}.jsonl`
}

export const MAX_LOG_BYTES = 3 * 1024 * 1024

// $.fs only overwrites, so the whole file is rewritten; null when it has grown too big.
export function appendLine(existing: string, line: string): string | null {
  if (existing.length + line.length + 1 > MAX_LOG_BYTES) return null
  return existing + line + '\n'
}

// ---- line 3: consumption ---------------------------------------------------

export function formatTokens(n: number): string {
  if (n < 1000) return String(Math.round(n))
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

// Time left until a window resets: "3h", "45m"; null when unknown or past.
export function formatResets(resetsAt: string | null, now: number): string | null {
  if (resetsAt === null) return null
  const ms = Date.parse(resetsAt) - now
  if (Number.isNaN(ms) || ms <= 0) return null
  const min = Math.round(ms / 60_000)
  if (min >= 90) return `${Math.round(min / 60)}h`
  return `${Math.max(1, min)}m`
}

export function turnTokens(u: {
  input_tokens: number
  output_tokens: number
  cache_read_input_tokens: number
  cache_creation_input_tokens: number
}): number {
  return u.input_tokens + u.output_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens
}

// What a turn added: uncached input, output and what it wrote to the cache. The
// cache it only read is left out (a turn of many tool calls rereads it each time).
export function newTokens(u: { input_tokens: number; output_tokens: number; cache_creation_input_tokens: number }): number {
  return u.input_tokens + u.output_tokens + u.cache_creation_input_tokens
}

export const CTX_WARN = 85
export const WINDOW_WARN = 90

function windowSeg(label: string, w: Window | null, now: number, withReset: boolean): Seg | null {
  if (w === null) return null
  const reset = withReset ? formatResets(w.resetsAt, now) : null
  const text = `${label} ${Math.round(w.pct)}%${reset === null ? '' : ` ↻${reset}`}`
  return w.pct >= WINDOW_WARN ? { text, warn: true } : { text }
}

// Line 3: context fill, account windows, the last turn and the session average.
// Yellow only for a context or window near its limit. Over the width, the
// reset times go first, then the average.
export function usageLine(u: Usage | null, now: number): Line | null {
  if (u === null) return null
  const build = (withReset: boolean, withAvg: boolean): Line => {
    const line: Line = []
    if (u.ctxPercent !== null) {
      const text = `${LABELS.ctx.long} ${Math.round(u.ctxPercent)}%`
      line.push(u.ctxPercent >= CTX_WARN ? { text, warn: true } : { text })
    }
    const five = windowSeg(LABELS.five.long, u.fiveHour, now, withReset)
    if (five !== null) line.push(five)
    const seven = windowSeg(LABELS.seven.long, u.sevenDay, now, withReset)
    if (seven !== null) line.push(seven)
    if (u.lastTokens !== null) {
      line.push({ text: `${LABELS.last.long} ${formatTokens(u.lastTokens)} new` })
    }
    if (withAvg && u.turns > 0) line.push({ text: `${LABELS.avg.long} ${formatTokens(u.totalTokens / u.turns)} new` })
    return line
  }
  for (const [r, a] of [[true, true], [false, true], [false, false]] as const) {
    const line = build(r, a)
    if (lineWidth(line) <= BAND_WIDTH) return withHint(line)
  }
  return withHint(build(false, false))
}

function withHint(line: Line): Line | null {
  if (line.length === 0) return null
  return lineWidth(line) + 3 + HINT.length <= BAND_WIDTH ? [...line, { text: HINT }] : line
}

// Bump when the meaning of a stored figure changes: a state of another version is
// never read as this one (v1 summed the cache it only read).
export const USAGE_V = 2

export function emptyUsage(): Usage {
  return { v: USAGE_V, ctxPercent: null, fiveHour: null, sevenDay: null, lastTokens: null, turns: 0, totalTokens: 0 }
}

export function normalizeUsage(raw: unknown): Usage | null {
  if (raw === null || typeof raw !== 'object') return null
  const r = raw as Partial<Usage>
  if (r.v !== USAGE_V) return null
  const win = (w: unknown): Window | null =>
    w !== null && typeof w === 'object' && typeof (w as Window).pct === 'number'
      ? { pct: (w as Window).pct, resetsAt: (w as Window).resetsAt ?? null }
      : null
  return {
    v: USAGE_V,
    ctxPercent: r.ctxPercent ?? null,
    fiveHour: win(r.fiveHour),
    sevenDay: win(r.sevenDay),
    lastTokens: r.lastTokens ?? null,
    turns: r.turns ?? 0,
    totalTokens: r.totalTokens ?? 0,
  }
}

// The count and average of "new" tokens, rebuilt from this session's log: the log
// keeps the four counts of every turn, so the figures can always be recomputed.
export function rebuildUsage(jsonl: string): Usage {
  const u = emptyUsage()
  for (const line of jsonl.split('\n')) {
    if (line.trim() === '') continue
    try {
      const r = JSON.parse(line) as { agent?: string | null; input?: number | null; output?: number | null; cacheWrite?: number | null }
      if ((r.agent ?? null) !== null || typeof r.input !== 'number') continue
      const tokens = r.input + (r.output ?? 0) + (r.cacheWrite ?? 0)
      u.turns += 1
      u.totalTokens += tokens
      u.lastTokens = tokens
    } catch {
      continue
    }
  }
  return u
}

export function windowsOf(limits: readonly { kind: string; percentUsed: number; resetsAt?: string }[]): {
  fiveHour: Window | null
  sevenDay: Window | null
} {
  const pick = (kind: string): Window | null => {
    const r = limits.find(x => x.kind === kind)
    return r === undefined ? null : { pct: r.percentUsed, resetsAt: r.resetsAt ?? null }
  }
  return { fiveHour: pick('five_hour'), sevenDay: pick('seven_day') }
}

// The cost of one turn: the step of the session's running total; null when either end is unknown.
export function costStep(usdNow: number | null, usdBefore: number | null): number | null {
  return usdNow !== null && usdBefore !== null ? Math.max(0, usdNow - usdBefore) : null
}

export type TurnEnd = {
  isMain: boolean
  tokens: number | null
  ctxPercent: number | null
  fiveHour: Window | null
  sevenDay: Window | null
}

// Line 3's figures after a turn ends. Only a main-loop turn that reported usage
// moves "last" and the average; a subagent's or an interrupted turn only
// refreshes the context and the windows.
export function applyTurn(prev: Usage | null, t: TurnEnd): Usage {
  const p = normalizeUsage(prev) ?? emptyUsage()
  const counts = t.isMain && t.tokens !== null
  return {
    ...p,
    ctxPercent: t.ctxPercent,
    fiveHour: t.fiveHour,
    sevenDay: t.sevenDay,
    lastTokens: counts ? t.tokens : p.lastTokens,
    turns: counts ? p.turns + 1 : p.turns,
    totalTokens: counts ? p.totalTokens + (t.tokens ?? 0) : p.totalTokens,
  }
}

// ---- what is switched on, and where --------------------------------------

// The per-turn log only runs on a machine that asks for it: the owner creates this file.
export function enabledFlagPath(home: string): string {
  return `${home}/.claude/kvendra-companion/ENABLED`
}

// The published version comes from the Kvendra KB's own REL entities, so it is only
// compared in the Kvendra project; in any other project it is left out.
export function compareReleasesFor(project: string | null): boolean {
  return project === 'KVD'
}

// The version a plugin manifest states, when it is a plain x.y.z.
export function parsePluginVersion(manifestJson: string): string | null {
  try {
    const v = (JSON.parse(manifestJson) as { version?: unknown }).version
    return typeof v === 'string' && parseSemver(v) !== null ? v : null
  } catch {
    return null
  }
}

// The kvendra-skills entry of ~/.claude/plugins/installed_plugins.json (marketplace
// installs): its version, or where its manifest is when the entry states none.
export function skillsFromInstalled(json: string): { version: string | null; installPath: string | null } | null {
  try {
    const plugins = (JSON.parse(json) as { plugins?: Record<string, unknown> }).plugins ?? {}
    let best: { version: string | null; installPath: string | null } | null = null
    for (const [key, entries] of Object.entries(plugins)) {
      if (!key.startsWith('kvendra-skills@') || !Array.isArray(entries)) continue
      for (const e of entries as { version?: unknown; installPath?: unknown }[]) {
        const version = typeof e.version === 'string' && parseSemver(e.version) !== null ? e.version : null
        const installPath = typeof e.installPath === 'string' ? e.installPath : null
        if (best === null || (version !== null && (best.version === null || cmpSemver(version, best.version) > 0))) {
          best = { version, installPath }
        }
      }
    }
    return best
  } catch {
    return null
  }
}

// Candidate names for the KB MCP server, as /mcp lists it; the first that answers is kept.
export const KB_SERVER_CANDIDATES = ['plugin:kvendra-skills:kvendra-cloud', 'kvendra-cloud'] as const

// The slow figures (entities, ISSUEs, Files, releases) are read in full at start, when the
// project changes and every `intervalMs`. In between, only the ones that failed are read
// again, a few times: a session that starts before its MCP server is connected fills in
// as soon as the server answers, and a read that keeps failing is not repeated for ever
// against a workspace.
export type SlowField = 'entities' | 'openIssues' | 'files' | 'release'

export function slowFieldsFor(project: string | null): SlowField[] {
  const fields: SlowField[] = ['files']
  if (project !== null) fields.push('entities', 'openIssues')
  if (compareReleasesFor(project)) fields.push('release')
  return fields
}

export function slowPlan(a: {
  now: number
  lastFullAt: number | null
  slowFor: string | null | undefined
  project: string | null
  pendingCount: number
  failures: number
  intervalMs: number
  maxFailures: number
}): 'full' | 'retry' | 'skip' {
  if (a.lastFullAt === null || a.slowFor !== a.project) return 'full'
  if (a.now - a.lastFullAt >= a.intervalMs) return 'full'
  if (a.pendingCount > 0 && a.failures < a.maxFailures) return 'retry'
  return 'skip'
}

// While the first reads can still be retried the band says "loading"; "unavailable" only
// once the retries are used up.
export function shouldShowFailure(failedRefreshes: number, maxRetries: number): boolean {
  return failedRefreshes > maxRetries
}

// The user name comes from the project entity, a read of the KB's own content. It is only
// made in the user's own KB (no workspace); in a team workspace it is left out.
export function shouldReadUserName(a: { isWorkspaceRead: boolean; workspace: unknown; project: string | null }): boolean {
  return a.isWorkspaceRead && a.workspace === null && a.project !== null
}

// What the band shows before it has data: a short "loading" line while the first read
// is under way (it keeps the band in the tree, so the first write redraws it), the
// "unavailable" line once a read failed, and the band itself once there is data.
export function bandMode(summary: Summary | null, failure: string | null): 'loading' | 'unavailable' | 'band' {
  if (summary !== null) return 'band'
  return failure !== null ? 'unavailable' : 'loading'
}

// ---- Workspace Files: one call --------------------------------------------

export type FilesSummary = { count: number; bytes: number }

// The answer of file_list({summary:true}): { count, bytes, quota_used_bytes, quota_bytes }.
// Extra or null fields are ignored; count and bytes must be non-negative numbers, else
// null (an old server that ignores `summary` answers with a "files" list instead).
export function parseFilesSummary(page: Record<string, unknown>): FilesSummary | null {
  const ok = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0
  return ok(page.count) && ok(page.bytes) ? { count: page.count, bytes: page.bytes } : null
}

// ---- /kvendra-legend ----------------------------------------------------------

// What each element of the band means, built from the same labels the band draws.
export function legendText(): string {
  const row = (k: keyof typeof LABELS) => `  ${LABELS[k].long}${LABELS[k].short !== LABELS[k].long ? ` (${LABELS[k].short})` : ''} - ${LABELS[k].means}`
  return [
    'Kvendra band',
    '',
    'Line 1: project · workspace (role, if it differs from yours) · user (tier/role)',
    'Line 2: what is in your Kvendra knowledge base',
    row('txn'),
    row('entities'),
    row('issues'),
    row('files'),
    row('skills'),
    '',
    'Line 3: your consumption',
    row('ctx'),
    row('five'),
    row('seven'),
    row('last'),
    row('avg'),
    `  ${HINT} - prints this legend; it is written at the end of line 3 when there is room`,
    '',
    'Yellow = needs attention (orphan TXN, restart, context or window near its limit).',
    '"outdated" = the last refresh failed; the figures shown are the last good ones.',
    'Short labels replace long ones when the line would not fit in 80 columns.',
  ].join('\n')
}

// ---- the kvendra-band skill -----------------------------------------------------

// Short on purpose: the description is what the skill costs in every session's context.
export const SKILL_DESCRIPTION = 'Explains the Kvendra band above the prompt (TXN, ctx, 5h, 7d, new tokens, files, skills) when the user asks what it means.'

// skills/kvendra-band/SKILL.md: the legend, from the same table as /kvendra-legend.
export function skillMarkdown(): string {
  return `---\nname: kvendra-band\ndescription: ${SKILL_DESCRIPTION}\n---\n\nThe user asks what an element of the Kvendra band means. Answer from this legend, briefly:\n\n${legendText()}\n`
}
