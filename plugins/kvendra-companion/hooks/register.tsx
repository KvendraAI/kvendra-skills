import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, TurnCompleteInput } from 'claude-code'

import type { Skills, Summary, Usage, Workspace } from '../types'
import type { Counts } from './lib'
import {

  appendLine,
  applyTurn,
  costStep,
  assertReadOnly,
  bandLines,
  classifyTool,
  emptyCounts,
  findProjectId,
  latestRelease,
  newTokens,
  compareReleasesFor,
  emptyUsage,
  enabledFlagPath,
  normalizeUsage,
  rebuildUsage,
  usageLine,
  windowsOf,
  logFileName,
  normalizeSummary,
  num,
  parsePluginVersion,
  skillsFromInstalled,
  KB_SERVER_CANDIDATES,
  payload,
  recordLine,
  staleHours,
  turnRecord,
} from './lib'

const summary = atom({ plugin: 'kvendra-companion', key: 'summary' } as const, null)
const failure = atom({ plugin: 'kvendra-companion', key: 'failure' } as const, null)
const loadedSkills = atom({ plugin: 'kvendra-companion', key: 'loadedSkills' } as const, null)
const lastUsd = atom({ plugin: 'kvendra-companion', key: 'lastUsd' } as const, null)
const usageAtom = atom({ plugin: 'kvendra-companion', key: 'usage' } as const, null)

const FAST_MS = 30_000
const SLOW_MS = 5 * 60_000
const MAX_FILE_PAGES = 10

let lastFast = 0
let lastSlow = 0
let slowFor: string | null | undefined
let userName: string | null = null
let userNameFor: string | null = null
let workspace: Workspace | null = null
let openTxnIds: string[] = []
// Kvendra tool calls since each loop's last turn, by agent id ('main' for the main loop).
const counts: Record<string, Counts> = {}
let writeQueue: Promise<void> = Promise.resolve()
let isWorkspaceRead = false
// Slow figures kept between slow refreshes.
let slow: Pick<Summary, 'entities' | 'openIssues' | 'filesBytes' | 'filesCount'> & { published: string | null } = {
  entities: null,
  openIssues: null,
  filesBytes: null,
  filesCount: null,
  published: null,
}

let kbServer: string | null = null

async function kb($: EngineInterface, tool: string, args: Record<string, unknown> = {}) {
  assertReadOnly(tool)
  if (kbServer !== null) return payload(await $.mcp.call(kbServer, tool, args))
  let lastError: unknown
  for (const name of KB_SERVER_CANDIDATES) {
    try {
      const result = payload(await $.mcp.call(name, tool, args))
      kbServer = name
      return result
    } catch (err) {
      lastError = err
    }
  }
  throw lastError instanceof Error ? lastError : new Error('no Kvendra KB server')
}

// The kvendra-skills version on disk. Marketplace installs are listed in
// installed_plugins.json; an org-synced plugin lives in a synced folder (the one
// whose manifest was updated last: a heuristic). After an in-place update the disk
// holds the new version while the session still runs the old one; captureLoaded
// keeps what the session started with. Read-only; null when it cannot be told.
async function diskSkillsVersion($: EngineInterface): Promise<string | null> {
  try {
    const home = await $.env.get('HOME')
    if (home === undefined) return null
    const plugins = `${home}/.claude/plugins`
    try {
      const inst = skillsFromInstalled(await $.fs.read(`${plugins}/installed_plugins.json`))
      if (inst !== null) {
        if (inst.version !== null) return inst.version
        if (inst.installPath !== null) {
          const v = parsePluginVersion(await $.fs.read(`${inst.installPath}/.claude-plugin/plugin.json`))
          if (v !== null) return v
        }
      }
    } catch {
      // not installed from a marketplace: look for an org-synced copy
    }
    const root = `${plugins}/synced`
    let best: { dir: string; at: number } | null = null
    for (const entry of await $.fs.list(root)) {
      if (entry.kind !== 'dir') continue
      try {
        const m = JSON.parse(await $.fs.read(`${root}/${entry.name}/manifest.json`)) as {
          lastUpdated?: number
          plugins?: { name?: string }[]
        }
        const has = (m.plugins ?? []).some(p => p.name === 'kvendra-skills')
        if (has && (best === null || (m.lastUpdated ?? 0) > best.at)) {
          best = { dir: entry.name, at: m.lastUpdated ?? 0 }
        }
      } catch {
        continue
      }
    }
    if (best === null) return null
    return parsePluginVersion(await $.fs.read(`${root}/${best.dir}/kvendra-skills/.claude-plugin/plugin.json`))
  } catch {
    return null
  }
}

// Workspace: read once per session. Name: read once per project, cached.
async function readIdentity($: EngineInterface, project: string | null) {
  if (project !== null && userNameFor !== project) {
    userNameFor = project
    try {
      const prj = await kb($, 'entity_get', { entity_id: `PRJ-${project}` })
      const actors = (prj.actors ?? {}) as Record<string, { display?: string; is_self?: boolean }>
      const me = Object.values(actors).find(a => a.is_self === true)
      userName = typeof me?.display === 'string' ? me.display : null
    } catch {
      userName = null
    }
  }
  if (isWorkspaceRead) return
  isWorkspaceRead = true
  try {
    const list = ((await kb($, 'workspace_list')).workspaces ?? []) as {
      name?: string
      role?: string
      default?: boolean
    }[]
    const w = list.find(x => x.default === true) ?? (list.length === 1 ? list[0] : undefined)
    workspace = w?.name !== undefined ? { name: w.name, role: w.role ?? '?' } : null
  } catch {
    workspace = null
  }
}

async function refreshSlow($: EngineInterface, project: string | null) {
  const next = { ...slow }
  if (project !== null) {
    next.entities = num((await kb($, 'entity_query', { project_id: project, limit: 1 })).total)
    next.openIssues = num(
      (await kb($, 'entity_query', { project_id: project, entity_type: 'ISSUE', status: 'open', limit: 1 })).total,
    )
  }

  let bytes = 0
  let count = 0
  let cursor: string | undefined
  for (let i = 0; i < MAX_FILE_PAGES; i++) {
    const page = await kb($, 'file_list', cursor ? { limit: 100, cursor } : { limit: 100 })
    const files = (page.files ?? []) as { size_bytes?: number }[]
    for (const f of files) bytes += f.size_bytes ?? 0
    count += files.length
    cursor = typeof page.next_cursor === 'string' ? page.next_cursor : undefined
    if (cursor === undefined) break
  }
  next.filesBytes = cursor === undefined ? bytes : null
  next.filesCount = cursor === undefined ? count : null

  if (compareReleasesFor(project)) {
    const rels = await kb($, 'entity_query', {
      project_id: 'KVD',
      component_id: 'SKILLS',
      entity_type: 'REL',
      status: 'released',
      limit: 100,
    })
    const ids = ((rels.entities ?? []) as { entity_id?: string }[]).map(e => e.entity_id ?? '')
    next.published = latestRelease(ids)
  } else {
    next.published = null
  }
  slow = next
}

async function refresh($: EngineInterface) {
  const now = await $.clock.now()
  if (now - lastFast < FAST_MS) return
  lastFast = now

  try {
    const project = await findProjectId(path => $.fs.read(path), await $.session.cwd())

    await readIdentity($, project)

    if (now - lastSlow >= SLOW_MS || lastSlow === 0 || slowFor !== project) {
      lastSlow = now
      slowFor = project
      try {
        await refreshSlow($, project)
      } catch {
        // keep the previous slow figures
      }
    }

    const who = await kb($, 'whoami', { include_brief: true, max_events: 1 })
    const brief = (who.brief ?? {}) as Record<string, unknown>

    let started: (string | number | undefined)[] = []
    if (project !== null) {
      const t = await kb($, 'txn_check_interrupted', { project_id: project })
      const open = (t.interrupted ?? []) as { started_at?: string | number; txn_id?: string }[]
      started = open.map(x => x.started_at)
      openTxnIds = open.map(x => x.txn_id).filter((x): x is string => typeof x === 'string')
    }

    const disk = await diskSkillsVersion($)
    const skills: Skills | null =
      disk === null ? null : { loaded: await read($, loadedSkills), disk, published: slow.published }

    const next: Summary = {
      project,
      userName,
      tier: String(who.tier ?? '?'),
      role: String(who.role ?? '?'),
      workspace,
      openTxns: num(brief.txn_count) ?? 0,
      staleTxnHours: staleHours(started, now),
      entities: slow.entities,
      openIssues: slow.openIssues,
      filesBytes: slow.filesBytes,
      filesCount: slow.filesCount,
      skills,
      at: now,
    }
    await update($, summary, () => next)
    await update($, failure, () => null)
    await refreshWindows($)
  } catch (err) {
    await update($, failure, () => (err instanceof Error ? err.message : 'unknown error'))
  }
}

// Context fill and the account's windows, as the last response reported them.
async function refreshWindows($: EngineInterface) {
  try {
    const u = await $.session.usage()
    const w = windowsOf(u.rateLimits)
    await update($, usageAtom, prev => ({
      ...(normalizeUsage(prev) ?? emptyUsage()),
      ctxPercent: u.context.percent ?? null,
      fiveHour: w.fiveHour,
      sevenDay: w.sevenDay,
    }))
  } catch {
    // keep the previous figures
  }
}

async function logPath($: EngineInterface, now: number, sessionId: string): Promise<string | null> {
  const home = await $.env.get('HOME')
  return home === undefined ? null : `${home}/.claude/kvendra-companion/${logFileName(now, sessionId)}`
}

// A stored figure of another version is dropped and rebuilt from this session's log.
async function restoreUsage($: EngineInterface) {
  try {
    if (normalizeUsage(await read($, usageAtom)) !== null) return
    const path = await logPath($, await $.clock.now(), await $.session.id())
    let text = ''
    if (path !== null) {
      try {
        text = await $.fs.read(path)
      } catch {
        text = ''
      }
    }
    await update($, usageAtom, () => rebuildUsage(text))
  } catch {
    // the figures start from the next turn
  }
}

// One line per finished turn, main loop or subagent. Numbers and ids only.
// The log is off unless the machine has asked for it (the ENABLED file).
async function isLogEnabled($: EngineInterface): Promise<boolean> {
  try {
    const home = await $.env.get('HOME')
    return home !== undefined && (await $.fs.exists(enabledFlagPath(home)))
  } catch {
    return false
  }
}

async function logTurn($: EngineInterface, e: TurnCompleteInput) {
  try {
    const key = e.agentId ?? 'main'
    const used = counts[key] ?? emptyCounts()
    delete counts[key]
    const isEnabled = await isLogEnabled($)

    const now = await $.clock.now()
    const usage = await $.session.usage()
    const before = await read($, lastUsd)
    const usdNow = usage.cost?.usd ?? null
    await update($, lastUsd, () => usdNow)
    const project = normalizeSummary(await read($, summary))?.project ?? null

    // Line 3: the main loop's turn feeds "last" and the average.
    const w = windowsOf(usage.rateLimits)
    await update($, usageAtom, prev =>
      applyTurn(prev, {
        isMain: e.agentId === undefined,
        tokens: e.usage === undefined ? null : newTokens(e.usage),
        ctxPercent: usage.context.percent ?? null,
        fiveHour: w.fiveHour,
        sevenDay: w.sevenDay,
      }),
    )

    // Line 3 above runs for everyone; only the file below needs the machine to opt in.
    if (!isEnabled) return
    const sessionId = await $.session.id()
    const path = await logPath($, now, sessionId)
    if (path === null) return
    const line = recordLine(
      turnRecord({
        now,
        session: sessionId,
        turn: e.turnId,
        agent: e.agentId,
        reason: e.reason,
        durationMs: e.durationMs,
        usage: e.usage,
        usdNow,
        usdBefore: before,
        ctxPercent: usage.context.percent,
        rateLimits: usage.rateLimits,
        counts: used,
        txn: openTxnIds,
        project,
      }),
    )

    // $.fs only overwrites: reads and writes are queued so two turns never interleave.
    writeQueue = writeQueue
      .then(async () => {
        let existing = ''
        try {
          existing = await $.fs.read(path)
        } catch {
          existing = ''
        }
        const out = appendLine(existing, line)
        if (out !== null) await $.fs.write(path, out)
      })
      .catch(() => undefined)
    await writeQueue
  } catch {
    // the log must never break a turn
  }
}

// The running cost at start, so the first turn after a (re)load already has a step.
async function seedCost($: EngineInterface) {
  try {
    const u = await $.session.usage()
    await update($, lastUsd, prev => prev ?? u.cost?.usd ?? null)
  } catch {
    // no cost known yet
  }
}

// What the session loaded: the version on disk when this module first ran in it.
async function captureLoaded($: EngineInterface) {
  const disk = await diskSkillsVersion($)
  await update($, loadedSkills, prev => prev ?? disk)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // An earlier version pinned a status line; the host keeps it across reloads until cleared.
    $.ui.status(undefined)
    await captureLoaded($)
    await seedCost($)
    await restoreUsage($)
    void refresh($)
    return next(e)
  })

  on('tool.call', ($, e, next) => {
    const kind = classifyTool(e.tool, e.tool === 'Skill' ? e.skill : undefined)
    if (kind !== null) {
      const key = e.agentId ?? 'main'
      const c = counts[key] ?? emptyCounts()
      c[kind] += 1
      counts[key] = c
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    void refresh($)
    void logTurn($, e)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const s = normalizeSummary(await read($, summary))
    const f = await read($, failure)
    const u = normalizeUsage(await read($, usageAtom))
    if (e.props.hasSurvey || (s === null && f === null)) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    if (s === null) {
      return (
        <Box>
          <Text dimColor>Kvendra: unavailable</Text>
        </Box>
      )
    }

    const lines = bandLines(s)
    const consumption = usageLine(u, await $.clock.now())
    if (consumption !== null) lines.push(consumption)
    return (
      <Box flexDirection="column">
        {lines.map((line, i) => (
          <Box key={`l${i}`}>
            {line.map((seg, j) => (
              <Text key={`s${j}`} dimColor={seg.warn !== true} color={seg.warn === true ? 'warning' : undefined}>
                {j > 0 ? ' · ' : ''}
                {seg.text}
              </Text>
            ))}
            {i === lines.length - 1 && f !== null ? <Text dimColor> · outdated</Text> : null}
          </Box>
        ))}
      </Box>
    )
  })
}
