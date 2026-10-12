import { describe, expect, test } from 'claude-code/testing'

import {
  READ_ONLY_TOOLS,
  assertReadOnly,
  MAX_LOG_BYTES,
  parseFilesSummary,
  legendText,
  skillMarkdown,
  SKILL_DESCRIPTION,
  LOADING_TEXT,
  LABELS,
  HINT,
  bandMode,
  shouldReadUserName,
  shouldShowFailure,
  slowFieldsFor,
  slowPlan,
  KB_SERVER_CANDIDATES,
  skillsFromInstalled,
  parsePluginVersion,
  compareReleasesFor,
  enabledFlagPath,
  emptyUsage,
  rebuildUsage,
  newTokens,
  applyTurn,
  costStep,
  formatResets,
  formatTokens,
  normalizeUsage,
  turnTokens,
  usageLine,
  windowsOf,
  appendLine,
  bandLines,
  classifyTool,
  emptyCounts,
  logFileName,
  recordLine,
  turnRecord,
  lineWidth,
  findProjectId,
  formatBytes,
  latestRelease,
  normalizeSummary,
  parseProjectId,
  payload,
  skillsSegment,
  staleHours,
} from '../hooks/lib'
import type { Summary } from '../types'

const base: Summary = {
  project: 'KVD', userName: 'ana.lopez', tier: 'pro', role: 'owner', workspace: null,
  openTxns: 0, staleTxnHours: null, entities: 1953, openIssues: 309, filesBytes: 2306867, filesCount: 23,
  skills: { loaded: '1.25.0', disk: '1.25.0', published: '1.25.0' }, at: 0,
}
const text = (lines: ReturnType<typeof bandLines>) => lines.map(l => l.map(s => s.text).join(' · '))

describe('allowlist', () => {
  test('allows every read tool', async () => {
    for (const t of READ_ONLY_TOOLS) expect(() => assertReadOnly(t)).not.toThrow()
  })
  test('refuses writes and secrets', async () => {
    for (const t of ['txn_create', 'txn_activate', 'entity_update', 'entity_create', 'send_message', 'private_value_resolve', 'check_notifications'])
      expect(() => assertReadOnly(t)).toThrow()
  })
})

describe('format', () => {
  test('project id from the boot ROM', async () => {
    expect(parseProjectId('- `project_id`: **KVD**\n')).toBe('KVD')
    expect(parseProjectId('nothing here')).toBe(null)
  })
  test('bytes', async () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2048)).toBe('2.0 KB')
  })
  test('payload parses a text block and refuses errors', async () => {
    expect(payload({ content: [{ type: 'text', text: '{"total":3}' }], isError: false })).toEqual({ total: 3 })
    expect(() => payload({ content: [], isError: true })).toThrow()
  })
})

describe('versions', () => {
  test('latest release by version, not by order; pre-releases skipped', async () => {
    const ids = ['REL-KVD-SKILLS-1.8.0', 'REL-KVD-SKILLS-1.25.0', 'REL-KVD-SKILLS-1.13.1', 'REL-KVD-SKILLS-1.26.0-alpha.1']
    expect(latestRelease(ids)).toBe('1.25.0')
    expect(latestRelease([])).toBe(null)
  })
  test('skills segment', async () => {
    expect(skillsSegment({ loaded: '1.25.0', disk: '1.25.0', published: '1.25.0' })).toEqual({ text: 'skills 1.25.0 ✓' })
    expect(skillsSegment({ loaded: '1.24.0', disk: '1.25.0', published: '1.25.0' })).toEqual({ text: 'skills 1.24.0 → 1.25.0 · restart', warn: true })
    expect(skillsSegment({ loaded: '1.24.0', disk: '1.24.0', published: '1.25.0' })).toEqual({ text: 'skills 1.24.0 (1.25.0 published)' })
    expect(skillsSegment({ loaded: null, disk: '1.25.0', published: null })).toEqual({ text: 'skills 1.25.0 ✓' })
    expect(skillsSegment(null)).toBe(null)
  })
})

describe('orphan TXN', () => {
  const now = Date.parse('2026-10-11T12:00:00Z')
  test('two hours is the threshold', async () => {
    expect(staleHours(['2026-10-11T11:00:00Z'], now)).toBe(null)
    expect(staleHours(['2026-10-11T10:00:00Z'], now)).toBe(2)
    expect(staleHours(['2026-10-11T06:30:00Z', '2026-10-11T11:30:00Z'], now)).toBe(5)
  })
  test('no timestamp, no alarm', async () => {
    expect(staleHours([undefined, 'garbage'], now)).toBe(null)
  })
})

describe('band', () => {
  test('Pro: no workspace, two lines', async () => {
    expect(text(bandLines(base))).toEqual([
      'KVD · ana.lopez (pro/owner)',
      'TXN 0 · 1953 entities · 309 open ISSUEs · 2 files 2.2 MB · skills 1.25.0 ✓'.replace('2 files', '23 files'),
    ])
  })
  test('Team: workspace name and role', async () => {
    const l = text(bandLines({ ...base, tier: 'team', workspace: { name: 'Acme', role: 'admin' } }))
    expect(l[0]).toBe('KVD · Acme (admin) · ana.lopez (team/owner)')
  })
  test('missing data is omitted, never a placeholder', async () => {
    const l = text(bandLines({ ...base, userName: null, entities: null, openIssues: null, filesBytes: null, skills: null, project: null }))
    expect(l).toEqual(['no project · pro/owner', 'TXN 0'])
  })
  test('yellow only for an orphan TXN and a restart', async () => {
    const lines = bandLines({ ...base, staleTxnHours: 3, skills: { loaded: '1.24.0', disk: '1.25.0', published: '1.25.0' } })
    expect(lines[1]?.filter(s => s.warn === true).length).toBe(2)
    expect(bandLines(base)[1]?.some(s => s.warn === true)).toBe(false)
  })
  test('an orphan TXN shortens labels instead of wrapping', async () => {
    const lines = bandLines({ ...base, staleTxnHours: 3 })
    expect(text(lines)[1]).toBe('TXN 0 · orphan 3h · 1953 ent · 309 ISS · 23 f 2.2 MB · skills 1.25.0 ✓')
    expect(lineWidth(lines[1] ?? [])).toBeLessThanOrEqual(80)
    expect(text(bandLines(base))[1]).toContain('1953 entities')
  })
})

describe('project lookup', () => {
  const files: Record<string, string> = { '/home/u/Dev/Kvendra/CLAUDE.md': '- `project_id`: **KVD**' }
  const read = async (p: string) => {
    const v = files[p]
    if (v === undefined) throw new Error('missing')
    return v
  }
  test('found in the start folder', async () => {
    expect(await findProjectId(read, '/home/u/Dev/Kvendra')).toBe('KVD')
  })
  test('found by walking up from a sub-repo', async () => {
    expect(await findProjectId(read, '/home/u/Dev/Kvendra/kvendra-cli/src')).toBe('KVD')
  })
  test('none anywhere: null, no throw', async () => {
    expect(await findProjectId(read, '/home/u/.claude/plugins/synced')).toBe(null)
    expect(await findProjectId(read, '/')).toBe(null)
  })
})

describe('state from earlier versions', () => {
  test('empty state: nothing to draw', async () => {
    expect(normalizeSummary(null)).toBe(null)
    expect(normalizeSummary(undefined)).toBe(null)
    expect(normalizeSummary('x')).toBe(null)
  })
  test('v1 shape (no workspace, no userName, no skills) draws without throwing', async () => {
    const v1 = { project: 'KVD', tier: 'pro', role: 'owner', openTxns: 0, entities: 5, filesBytes: 10, filesCount: 1, at: 1 }
    const s = normalizeSummary(v1)
    expect(s).not.toBe(null)
    expect(text(bandLines(s as Summary))[0]).toBe('KVD · pro/owner')
  })
  test('a workspace of undefined or a bad shape is ignored', async () => {
    expect(() => bandLines({ ...base, workspace: undefined as never })).not.toThrow()
    expect(normalizeSummary({ ...base, workspace: {} })?.workspace).toBe(null)
  })
})

describe('which turns used Kvendra', () => {
  test('KB MCP, broker and skills are told apart', async () => {
    expect(classifyTool('mcp__plugin_kvendra-skills_kvendra-cloud__entity_get')).toBe('kb')
    expect(classifyTool('mcp__kvendra__kvendra_git')).toBe('broker')
    expect(classifyTool('Skill', 'kvendra-skills:kvendra')).toBe('skills')
  })
  test('everything else is not Kvendra', async () => {
    expect(classifyTool('Bash')).toBe(null)
    expect(classifyTool('Skill', 'security-audit')).toBe(null)
    expect(classifyTool('Skill')).toBe(null)
    expect(classifyTool('mcp__claude_ai_Figma__authenticate')).toBe(null)
  })
})

describe('turn log', () => {
  const usage = { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 9000, cache_creation_input_tokens: 400, model: 'm' }
  const args = {
    now: Date.parse('2026-10-11T10:00:00Z'), session: 'abcd1234-ef', turn: 't1', agent: undefined, reason: 'answer',
    durationMs: 5000, usage, usdNow: 1.5, usdBefore: 1.2, ctxPercent: 37,
    rateLimits: [{ kind: 'five_hour', percentUsed: 23.5 }, { kind: 'seven_day', percentUsed: 41 }],
    counts: { kb: 2, broker: 0, skills: 1 }, txn: ['TXN-KVD-1'], project: 'KVD',
  }
  test('record carries the four counts, the cost step, the windows and the Kvendra counters', async () => {
    const r = turnRecord(args)
    expect(r.input).toBe(100)
    expect(r.cacheRead).toBe(9000)
    expect(r.usdDelta).toBe(0.3)
    expect(r.fiveHourPct).toBe(23.5)
    expect(r.sevenDayPct).toBe(41)
    expect(r.kvendra).toEqual({ kb: 2, broker: 0, skills: 1 })
    expect(r.agent).toBe(null)
  })
  test('a subagent turn keeps its agent id', async () => {
    expect(turnRecord({ ...args, agent: 'sub-1' }).agent).toBe('sub-1')
  })
  test('no usage (an interrupt) and no earlier cost: nulls, no throw', async () => {
    const r = turnRecord({ ...args, usage: undefined, usdBefore: null, ctxPercent: undefined, rateLimits: [] })
    expect(r.input).toBe(null)
    expect(r.usdDelta).toBe(null)
    expect(r.ctxPercent).toBe(null)
    expect(r.fiveHourPct).toBe(null)
  })
  test('a cost that went down never gives a negative step', async () => {
    expect(turnRecord({ ...args, usdNow: 1.0, usdBefore: 1.2 }).usdDelta).toBe(0)
  })
  test('only whitelisted keys: nothing that could hold text', async () => {
    const keys = Object.keys(JSON.parse(recordLine(turnRecord(args)))).sort()
    expect(keys).toEqual(['agent', 'cacheRead', 'cacheWrite', 'ctxPercent', 'durationMs', 'fiveHourPct', 'input', 'kvendra', 'model', 'output', 'project', 'reason', 'session', 'sevenDayPct', 'ts', 'turn', 'txn', 'usdDelta'])
  })
  test('one file per session and day', async () => {
    expect(logFileName(args.now, 'abcd1234-ef56')).toBe('turns-2026-10-11-abcd1234.jsonl')
  })
  test('appends a line, refuses to grow past the cap', async () => {
    expect(appendLine('a\n', 'b')).toBe('a\nb\n')
    expect(appendLine('x'.repeat(MAX_LOG_BYTES), 'b')).toBe(null)
  })
  test('counters start at zero', async () => {
    expect(emptyCounts()).toEqual({ kb: 0, broker: 0, skills: 0 })
  })
})

describe('line 3: consumption', () => {
  const now = Date.parse('2026-10-11T10:00:00Z')
  const u = {
    ctxPercent: 37, fiveHour: { pct: 23.4, resetsAt: '2026-10-11T13:00:00Z' }, sevenDay: { pct: 41, resetsAt: null },
    v: 2, lastTokens: 18200, turns: 4, totalTokens: 84000,
  }
  const t3 = (l: ReturnType<typeof usageLine>) => (l ?? []).map(s => s.text).join(' · ')
  test('the owner-approved shape', async () => {
    expect(t3(usageLine(u, now))).toBe('ctx 37% · 5h 23% ↻3h · 7d 41% · last 18.2k new · avg 21.0k new · /kvendra-legend')
  })
  test('no yellow while everything is below its limit', async () => {
    expect((usageLine(u, now) ?? []).some(s => s.warn === true)).toBe(false)
  })
  test('yellow for context at 85 and a window at 90, only on that part', async () => {
    const l = usageLine({ ...u, ctxPercent: 86, fiveHour: { pct: 91, resetsAt: null } }, now) ?? []
    expect(l.filter(s => s.warn === true).map(s => s.text.split(' ')[0])).toEqual(['ctx', '5h'])
  })
  test('no subscription windows (API key): they are left out', async () => {
    expect(t3(usageLine({ ...u, fiveHour: null, sevenDay: null }, now))).toBe('ctx 37% · last 18.2k new · avg 21.0k new · /kvendra-legend')
  })
  test('before the first turn: only what is known; nothing known: no line', async () => {
    expect(t3(usageLine({ ...u, lastTokens: null, turns: 0, totalTokens: 0 }, now))).toBe('ctx 37% · 5h 23% ↻3h · 7d 41% · /kvendra-legend')
    expect(usageLine({ v: 2, ctxPercent: null, fiveHour: null, sevenDay: null, lastTokens: null, turns: 0, totalTokens: 0 }, now)).toBe(null)
    expect(usageLine(null, now)).toBe(null)
  })
  test('never wider than 80 columns: reset times, then the average, go first', async () => {
    const wide = { ...u, fiveHour: { pct: 99.9, resetsAt: '2026-10-11T14:30:00Z' }, sevenDay: { pct: 100, resetsAt: '2026-10-14T10:00:00Z' }, lastTokens: 1234567, totalTokens: 9_999_999 }
    const l = usageLine(wide, now) ?? []
    expect(l.reduce((n, s, i) => n + s.text.length + (i > 0 ? 3 : 0), 0)).toBeLessThanOrEqual(80)
  })
  test('units', async () => {
    expect(formatTokens(950)).toBe('950')
    expect(formatTokens(18200)).toBe('18.2k')
    expect(formatTokens(2_300_000)).toBe('2.3M')
    expect(formatResets('2026-10-11T10:45:00Z', now)).toBe('45m')
    expect(formatResets('2026-10-11T13:00:00Z', now)).toBe('3h')
    expect(formatResets('2026-10-11T09:00:00Z', now)).toBe(null)
    expect(formatResets(null, now)).toBe(null)
  })
  test('a turn is the sum of the four counts', async () => {
    expect(turnTokens({ input_tokens: 1, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4 })).toBe(10)
  })
  test('the windows come from rate limits by kind; missing ones are null', async () => {
    const w = windowsOf([{ kind: 'five_hour', percentUsed: 5, resetsAt: 'x' }])
    expect(w.fiveHour).toEqual({ pct: 5, resetsAt: 'x' })
    expect(w.sevenDay).toBe(null)
    expect(windowsOf([])).toEqual({ fiveHour: null, sevenDay: null })
  })
  test('state of an older shape or empty is tolerated', async () => {
    expect(normalizeUsage(undefined)).toBe(null)
    expect(normalizeUsage({})).toBe(null)
    expect(normalizeUsage({ v: 2 })?.turns).toBe(0)
    expect(normalizeUsage({ v: 2, fiveHour: {} })?.fiveHour).toBe(null)
  })
})

describe('avg and cost across turns', () => {
  const win = { pct: 10, resetsAt: null }
  const end = (o: Partial<Parameters<typeof applyTurn>[1]>) => ({ isMain: true, tokens: 1000, ctxPercent: 20, fiveHour: win, sevenDay: win, ...o })
  const avg = (u: ReturnType<typeof applyTurn>) => u.totalTokens / u.turns

  test('the average follows each main turn', async () => {
    let u = applyTurn(null, end({ tokens: 1000 }))
    expect(avg(u)).toBe(1000)
    u = applyTurn(u, end({ tokens: 3000 }))
    expect(avg(u)).toBe(2000)
    u = applyTurn(u, end({ tokens: 8000 }))
    expect(u.turns).toBe(3)
    expect(Math.abs(avg(u) - 4000) < 1e-9).toBe(true)
    expect(u.lastTokens).toBe(8000)
  })
  test('a subagent turn moves neither last nor the average, but refreshes the windows', async () => {
    const before = applyTurn(null, end({ tokens: 2000, ctxPercent: 30 }))
    const after = applyTurn(before, end({ isMain: false, tokens: 90000, ctxPercent: 55 }))
    expect(after.turns).toBe(1)
    expect(after.lastTokens).toBe(2000)
    expect(after.totalTokens).toBe(2000)
    expect(after.ctxPercent).toBe(55)
  })
  test('an interrupted turn with no usage does not count', async () => {
    const before = applyTurn(null, end({}))
    const after = applyTurn(before, end({ tokens: null }))
    expect(after.turns).toBe(1)
    expect(after.lastTokens).toBe(1000)
  })
  test('the first turn after a reload has no cost step; the next one does', async () => {
    expect(costStep(1.5, null)).toBe(null)
    expect(costStep(null, 1.5)).toBe(null)
    expect(Math.abs((costStep(1.8, 1.5) ?? 0) - 0.3) < 1e-9).toBe(true)
  })
  test('a cost that went down is a zero step, never negative', async () => {
    expect(costStep(1.0, 1.5)).toBe(0)
  })
  test('state from before the line existed starts clean', async () => {
    expect(applyTurn(undefined as never, end({})).turns).toBe(1)
    expect(applyTurn({} as never, end({})).turns).toBe(1)
  })
  test('what the band prints: last and avg after three turns', async () => {
    let u = applyTurn(null, end({ tokens: 10000 }))
    u = applyTurn(u, end({ tokens: 20000 }))
    u = applyTurn(u, end({ tokens: 30000 }))
    const line = (usageLine(u, Date.parse('2026-10-11T10:00:00Z')) ?? []).map(s => s.text)
    expect(line).toContain('last 30.0k new')
    expect(line).toContain('avg 20.0k new')
  })
})

describe('"new" tokens, not the cache it only read', () => {
  test('a real turn: 8 in, 6110 out, 6623 written, 1.27M read -> 12.7k new', async () => {
    const u = { input_tokens: 8, output_tokens: 6110, cache_read_input_tokens: 1270236, cache_creation_input_tokens: 6623 }
    expect(newTokens(u)).toBe(12741)
    expect(formatTokens(newTokens(u))).toBe('12.7k')
    expect(turnTokens(u)).toBe(1282977)
  })
  test('the owner case fits in 80 columns with both reset times', async () => {
    const now = Date.parse('2026-10-11T10:00:00Z')
    const l = usageLine({ ctxPercent: 32, fiveHour: { pct: 16, resetsAt: '2026-10-11T14:00:00Z' }, sevenDay: { pct: 20, resetsAt: '2026-10-13T06:00:00Z' }, v: 2, lastTokens: 12741, turns: 5, totalTokens: 55000 }, now) ?? []
    const text = l.map(s => s.text).join(' · ')
    expect(text).toBe('ctx 32% · 5h 16% ↻4h · 7d 20% ↻44h · last 12.7k new · avg 11.0k new')
    expect(text.length).toBeLessThanOrEqual(80)
  })
})

describe('no money on the band', () => {
  test('whatever the figures, no segment of line 3 carries a $', async () => {
    const now = Date.parse('2026-10-11T10:00:00Z')
    for (const u of [emptyUsage(), applyTurn(null, { isMain: true, tokens: 5000, ctxPercent: 90, fiveHour: { pct: 95, resetsAt: '2026-10-11T12:00:00Z' }, sevenDay: { pct: 10, resetsAt: null } })]) {
      expect((usageLine(u, now) ?? []).some(s => s.text.includes('$'))).toBe(false)
    }
  })
})

describe('state of another version', () => {
  test('v1 state (it summed the cache it only read) is not read as v2', async () => {
    const v1 = { ctxPercent: 33, lastTokens: 994691, turns: 3, totalTokens: 3_564_000 }
    expect(normalizeUsage(v1)).toBe(null)
  })
  test('the figures are rebuilt from the log with the "new" formula', async () => {
    const log = [
      { agent: null, input: 8, output: 6110, cacheRead: 1270236, cacheWrite: 6623 },
      { agent: null, input: 8, output: 5855, cacheRead: 1299255, cacheWrite: 7019 },
      { agent: 'sub-1', input: 5, output: 900000, cacheRead: 0, cacheWrite: 0 },
      { agent: null, input: 6, output: 1442, cacheRead: 990963, cacheWrite: 2280 },
    ].map(r => JSON.stringify(r)).join('\n') + '\nnot json\n'
    const u = rebuildUsage(log)
    expect(u.turns).toBe(3)
    expect(u.lastTokens).toBe(3728)
    expect(u.totalTokens).toBe(12741 + 12882 + 3728)
    expect(formatTokens(u.totalTokens / u.turns)).toBe('9.8k')
  })
  test('an empty or missing log gives a clean v2 state', async () => {
    expect(rebuildUsage('')).toEqual(emptyUsage())
  })
})

describe('switches', () => {
  test('the log needs the ENABLED file under the companion folder', async () => {
    expect(enabledFlagPath('/home/u')).toBe('/home/u/.claude/kvendra-companion/ENABLED')
  })
  test('release comparison only in the Kvendra project', async () => {
    expect(compareReleasesFor('KVD')).toBe(true)
    expect(compareReleasesFor('ACME')).toBe(false)
    expect(compareReleasesFor(null)).toBe(false)
  })
  test('without a published version the skills segment is only loaded vs disk', async () => {
    expect(skillsSegment({ loaded: '1.25.0', disk: '1.25.0', published: null })).toEqual({ text: 'skills 1.25.0 ✓' })
    expect(skillsSegment({ loaded: '1.24.0', disk: '1.25.0', published: null })).toEqual({ text: 'skills 1.24.0 → 1.25.0 · restart', warn: true })
  })
})

describe('plugin version', () => {
  test('read from the plugin manifest', async () => {
    expect(parsePluginVersion('{"name":"kvendra-skills","version":"1.25.0"}')).toBe('1.25.0')
  })
  test('missing, odd or broken: null, no throw', async () => {
    expect(parsePluginVersion('{"name":"x"}')).toBe(null)
    expect(parsePluginVersion('{"version":"1.25"}')).toBe(null)
    expect(parsePluginVersion('{"version":7}')).toBe(null)
    expect(parsePluginVersion('not json')).toBe(null)
  })
})

describe('kvendra-skills in installed_plugins.json', () => {
  const file = (entries: Record<string, unknown>) => JSON.stringify({ version: 2, plugins: entries })
  test('the version of a marketplace install', async () => {
    const j = file({ 'rust-analyzer-lsp@claude-plugins-official': [{ version: '1.0.0', installPath: '/x' }], 'kvendra-skills@acme-market': [{ scope: 'user', version: '1.25.0', installPath: '/p/1.25.0' }] })
    expect(skillsFromInstalled(j)).toEqual({ version: '1.25.0', installPath: '/p/1.25.0' })
  })
  test('the highest version wins when there are several entries', async () => {
    const j = file({ 'kvendra-skills@a': [{ version: '1.9.0', installPath: '/a' }, { version: '1.25.0', installPath: '/b' }] })
    expect(skillsFromInstalled(j)?.version).toBe('1.25.0')
  })
  test('an entry with no usable version still gives the install path', async () => {
    expect(skillsFromInstalled(file({ 'kvendra-skills@a': [{ installPath: '/a' }] }))).toEqual({ version: null, installPath: '/a' })
  })
  test('not installed, or a broken file: null, no throw', async () => {
    expect(skillsFromInstalled(file({ 'other@a': [{ version: '1.0.0' }] }))).toBe(null)
    expect(skillsFromInstalled('nope')).toBe(null)
  })
  test('the KB server is tried by its plugin name first', async () => {
    expect(KB_SERVER_CANDIDATES[0]).toBe('plugin:kvendra-skills:kvendra-cloud')
  })
})

describe('slow figures: a failed read is tried again, a few times', () => {
  const base = { now: 1_000_000, intervalMs: 300_000, maxFailures: 10, project: 'KVD' as string | null }
  test('everything is read in full at start', async () => {
    expect(slowPlan({ ...base, lastFullAt: null, slowFor: undefined, pendingCount: 4, failures: 0 })).toBe('full')
  })
  test('a start with the MCP not ready: only what failed is read again on the next refresh', async () => {
    expect(slowPlan({ ...base, now: base.now + 31_000, lastFullAt: base.now, slowFor: 'KVD', pendingCount: 4, failures: 1 })).toBe('retry')
  })
  test('nothing pending: wait for the interval, then read in full', async () => {
    expect(slowPlan({ ...base, lastFullAt: base.now - 10_000, slowFor: 'KVD', pendingCount: 0, failures: 0 })).toBe('skip')
    expect(slowPlan({ ...base, lastFullAt: base.now - 300_000, slowFor: 'KVD', pendingCount: 0, failures: 0 })).toBe('full')
  })
  test('a read that keeps failing is not repeated every refresh: after the retries, only every interval', async () => {
    expect(slowPlan({ ...base, lastFullAt: base.now - 10_000, slowFor: 'KVD', pendingCount: 1, failures: 10 })).toBe('skip')
    expect(slowPlan({ ...base, lastFullAt: base.now - 300_000, slowFor: 'KVD', pendingCount: 1, failures: 10 })).toBe('full')
  })
  test('a new project is read in full at once', async () => {
    expect(slowPlan({ ...base, project: 'OTHER', lastFullAt: base.now - 1000, slowFor: 'KVD', pendingCount: 0, failures: 0 })).toBe('full')
    expect(slowPlan({ ...base, project: 'KVD', lastFullAt: base.now - 1000, slowFor: null, pendingCount: 0, failures: 0 })).toBe('full')
  })
  test('Files is a workspace figure: read with no project; entities and ISSUEs need one; releases only in KVD', async () => {
    expect(slowFieldsFor(null)).toEqual(['files'])
    expect(slowFieldsFor('ACME')).toEqual(['files', 'entities', 'openIssues'])
    expect(slowFieldsFor('KVD')).toEqual(['files', 'entities', 'openIssues', 'release'])
  })
})

describe('"loading" until the retries are used up', () => {
  test('failures up to the retry limit still say loading; unavailable only after', async () => {
    expect(shouldShowFailure(1, 10)).toBe(false)
    expect(shouldShowFailure(10, 10)).toBe(false)
    expect(shouldShowFailure(11, 10)).toBe(true)
  })
})

describe('the user name is read only in the user own KB', () => {
  test('no workspace (own KB) and a project: yes', async () => {
    expect(shouldReadUserName({ isWorkspaceRead: true, workspace: null, project: 'KVD' })).toBe(true)
  })
  test('a team workspace: never (it would read the client KB content)', async () => {
    expect(shouldReadUserName({ isWorkspaceRead: true, workspace: { name: 'Acme', role: 'owner' }, project: 'KVD' })).toBe(false)
  })
  test('workspace not read yet, or no project: no', async () => {
    expect(shouldReadUserName({ isWorkspaceRead: false, workspace: null, project: 'KVD' })).toBe(false)
    expect(shouldReadUserName({ isWorkspaceRead: true, workspace: null, project: null })).toBe(false)
  })
})

describe('line 1 in a team workspace', () => {
  const team = { project: null, userName: null, tier: 'team', role: 'owner', workspace: { name: 'Acme-Corp', role: 'owner' }, openTxns: 0, staleTxnHours: null, entities: null, openIssues: null, filesBytes: 2048, filesCount: 3, skills: null, at: 0 }
  test('the role is not repeated when the workspace role equals the account role', async () => {
    expect(text(bandLines(team))[0]).toBe('no project · Acme-Corp · team/owner')
  })
  test('with a project and no user name', async () => {
    expect(text(bandLines({ ...team, project: 'KVD' }))[0]).toBe('KVD · Acme-Corp · team/owner')
  })
  test('a different workspace role is still shown', async () => {
    expect(text(bandLines({ ...team, workspace: { name: 'Acme-Corp', role: 'admin' } }))[0]).toBe('no project · Acme-Corp (admin) · team/owner')
  })
  test('an empty Files shows "0 files 0 B": empty is not hidden, only a failed read is', async () => {
    expect(text(bandLines({ ...team, filesBytes: 0, filesCount: 0 }))[1]).toBe('TXN 0 · 0 files 0 B')
    expect(text(bandLines({ ...team, filesBytes: null, filesCount: null }))[1]).toBe('TXN 0')
  })
  test('Files shows with no project', async () => {
    expect(text(bandLines(team))[1]).toBe('TXN 0 · 3 files 2.0 KB')
  })
})

describe('what the band shows before it has data', () => {
  const sum = { project: 'KVD', userName: null, tier: 'pro', role: 'owner', workspace: null, openTxns: 0, staleTxnHours: null, entities: null, openIssues: null, filesBytes: null, filesCount: null, skills: null, at: 0 }
  test('nothing read yet: a loading line, so the band is in the tree for the first write', async () => {
    expect(bandMode(null, null)).toBe('loading')
  })
  test('a read failed and there is nothing to show: unavailable', async () => {
    expect(bandMode(null, 'boom')).toBe('unavailable')
  })
  test('data wins, even if the last refresh failed (the band marks it outdated)', async () => {
    expect(bandMode(sum, null)).toBe('band')
    expect(bandMode(sum, 'boom')).toBe('band')
  })
})

describe('Workspace Files, one call', () => {
  test('the summary answer: extra fields are ignored', async () => {
    expect(parseFilesSummary({ count: 12, bytes: 3400, quota_used_bytes: 9000, quota_bytes: null, inbox_pending: 1 })).toEqual({ count: 12, bytes: 3400 })
  })
  test('a real 0 is not a failure', async () => {
    expect(parseFilesSummary({ count: 0, bytes: 0 })).toEqual({ count: 0, bytes: 0 })
  })
  test('an old server that ignores summary (a list, no totals) is not a number', async () => {
    expect(parseFilesSummary({ files: [], next_cursor: null })).toBeNull()
  })
  test('null, negative or text totals are refused', async () => {
    expect(parseFilesSummary({ count: null, bytes: 5 })).toBeNull()
    expect(parseFilesSummary({ count: 1, bytes: -1 })).toBeNull()
    expect(parseFilesSummary({ count: '1', bytes: 5 })).toBeNull()
  })
  test('the band shows the count and the size', async () => {
    const sum = { project: null, userName: null, tier: 'team', role: 'owner', workspace: null, openTxns: 0, staleTxnHours: null, entities: null, openIssues: null, filesBytes: 9_000_000, filesCount: 500, skills: null, at: 0 }
    expect(bandLines(sum)[1]?.map(s => s.text).join(' · ')).toBe('TXN 0 · 500 files 8.6 MB')
  })
})

describe('the legend', () => {
  const usage = { ...emptyUsage(), ctxPercent: 12, fiveHour: { pct: 30, resetsAt: null }, sevenDay: { pct: 40, resetsAt: null }, lastTokens: 1500, turns: 2, totalTokens: 4000 }
  test('every label the band draws is explained', async () => {
    const sum = { project: 'KVD', userName: null, tier: 'pro', role: 'owner', workspace: null, openTxns: 1, staleTxnHours: null, entities: 5, openIssues: 2, filesBytes: 10, filesCount: 1, skills: { loaded: '1.0.0', disk: '1.0.0', published: null }, at: 0 }
    const drawn = [...(bandLines(sum)[1] ?? []), ...(usageLine(usage, 0) ?? [])].map(s => s.text).join(' | ')
    const text = legendText()
    for (const l of Object.values(LABELS)) {
      expect(drawn).toContain(l.long)
      expect(text).toContain(l.means)
    }
  })
  test('it names its own command', async () => {
    expect(legendText()).toContain('/kvendra-legend')
  })
})

describe('the /kvendra-legend hint on line 3', () => {
  const usage = { ...emptyUsage(), ctxPercent: 12, fiveHour: { pct: 30, resetsAt: null }, sevenDay: { pct: 40, resetsAt: null }, lastTokens: 1500, turns: 2, totalTokens: 4000 }
  test('it is written out (not a bare "?") when there is room', async () => {
    const line = usageLine(usage, 0)
    expect(line?.[line.length - 1]?.text).toBe('/kvendra-legend')
    expect(HINT).toBe('/kvendra-legend')
  })
  test('with no room, nothing is shown: every figure stays and no "?" appears', async () => {
    const full = { ...usage, fiveHour: { pct: 16, resetsAt: new Date(4 * 3_600_000).toISOString() }, sevenDay: { pct: 20, resetsAt: new Date(44 * 3_600_000).toISOString() }, lastTokens: 12_700, turns: 3, totalTokens: 33_000 }
    const texts = (usageLine(full, 0) ?? []).map(s => s.text)
    expect(texts.some(s => s.includes('legend') || s === '?')).toBe(false)
    expect(texts.length).toBe(5)
  })
  test('it never pushes the line past the width, nor replaces a figure', async () => {
    for (const w of [0, 5, 50, 100]) {
      const u = { ...usage, fiveHour: { pct: 99, resetsAt: new Date(Date.now() + 3 * 3_600_000 + w * 60_000).toISOString() }, sevenDay: { pct: 88, resetsAt: new Date(Date.now() + 90 * 3_600_000).toISOString() }, lastTokens: 123_456_789, totalTokens: 987_654_321 * 2 }
      const line = usageLine(u, Date.now())
      expect(line !== null && lineWidth(line) <= 80).toBe(true)
      expect((line ?? []).filter(s => s.text !== HINT).length).toBeGreaterThanOrEqual(3)
    }
  })
  test('no usage, no hint', async () => {
    expect(usageLine(null, 0)).toBeNull()
  })
})

describe('the loading line', () => {
  test('it names the legend command', async () => {
    expect(LOADING_TEXT).toBe('Kvendra: loading… · legend: /kvendra-legend')
  })
})

describe('the kvendra-band skill', () => {
  test('its body is the legend: every label the band draws is explained in it', async () => {
    const md = skillMarkdown()
    for (const l of Object.values(LABELS)) expect(md).toContain(l.means)
    expect(md).toContain(legendText())
  })
  test('front matter: the name, and a short description (it costs context in every session)', async () => {
    const md = skillMarkdown()
    expect(md.startsWith('---\nname: kvendra-band\ndescription: ')).toBe(true)
    expect(md).toContain(SKILL_DESCRIPTION)
    expect(SKILL_DESCRIPTION.length).toBeLessThanOrEqual(160)
  })
})
