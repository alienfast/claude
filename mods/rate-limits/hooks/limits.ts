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

// The file's text: the windows as the engine reported them, dated; null when the measurement carried none (off a subscription, or
// before the first response), so an empty reading never overwrites a dated one.
export function readingOf(windows: readonly RateLimit[], session: string, nowMs: number): string | null {
  if (windows.length === 0) return null
  const out = windows.map((w) => (w.resetsAt === undefined ? { kind: w.kind, percentUsed: w.percentUsed } : { kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt }))
  return `${JSON.stringify({ measured_at: new Date(nowMs).toISOString(), session, windows: out }, null, 2)}\n`
}
