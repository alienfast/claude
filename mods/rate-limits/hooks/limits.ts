export type RateLimit = { readonly kind: string; readonly percentUsed: number; readonly resetsAt?: string }
export type Options = { readonly enabled: boolean }

export function readOptions(raw: Readonly<Record<string, unknown>>): Options {
  return { enabled: raw.enabled !== false }
}

// One machine-wide file under ~/.claude/local/, the directory ~/.claude/CLAUDE.md reserves for state kept across sessions, read by
// scripts/fleet-launch.sh. Null without a home directory, and then nothing is written.
export function readingPath(home: string | undefined): string | null {
  const h = (home ?? '').trim().replace(/[\\/]+$/, '')
  return h === '' ? null : `${h}/.claude/local/rate-limits.json`
}

function windowsOf(windows: readonly RateLimit[]) {
  return windows.map((w) => (w.resetsAt === undefined ? { kind: w.kind, percentUsed: w.percentUsed } : { kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt }))
}

// The file's text: the windows as the engine reported them, dated; null when the measurement carried none (off a subscription, or
// before the first response), so an empty reading never overwrites a dated one.
export function readingOf(windows: readonly RateLimit[], session: string, nowMs: number): string | null {
  if (windows.length === 0) return null
  return `${JSON.stringify({ measured_at: new Date(nowMs).toISOString(), session, windows: windowsOf(windows) }, null, 2)}\n`
}

// The snapshot above keeps only the latest writer, so it cannot say how full a window got while a fleet ran. Each session also keeps
// its own history, one file per session so concurrent sessions never race a shared one; fleet-metrics.py reads a fleet's files for
// the peak five_hour reading. Null without a home directory or a session id.
export function historyPath(home: string | undefined, session: string): string | null {
  const h = (home ?? '').trim().replace(/[\\/]+$/, '')
  return h === '' || session === '' ? null : `${h}/.claude/local/rate-limits/${session}.jsonl`
}

export function historyLine(windows: readonly RateLimit[], nowMs: number): string | null {
  if (windows.length === 0) return null
  return JSON.stringify({ measured_at: new Date(nowMs).toISOString(), windows: windowsOf(windows) })
}
