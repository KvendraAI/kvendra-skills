export type Workspace = { name: string; role: string }

export type Skills = { loaded: string | null; disk: string | null; published: string | null }

export type Window = { pct: number; resetsAt: string | null }

export type Usage = {
  v: number
  ctxPercent: number | null
  fiveHour: Window | null
  sevenDay: Window | null
  lastTokens: number | null
  turns: number
  totalTokens: number
}

export type Summary = {
  project: string | null
  userName: string | null
  tier: string
  role: string
  workspace: Workspace | null
  openTxns: number
  staleTxnHours: number | null
  entities: number | null
  openIssues: number | null
  filesBytes: number | null
  filesCount: number | null
  filesPartial?: boolean
  skills: Skills | null
  at: number
}

declare module 'claude-code' {
  interface PluginState {
    'kvendra-companion': {
      summary: Summary | null
      failure: string | null
      loadedSkills: string | null
      lastUsd: number | null
      usage: Usage | null
    }
  }
}
