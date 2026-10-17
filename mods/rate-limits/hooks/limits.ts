export type RateLimit = { readonly kind: string; readonly percentUsed: number; readonly resetsAt?: string }
export type Options = { readonly enabled: boolean; readonly status: boolean }

export function readOptions(raw: Readonly<Record<string, unknown>>): Options {
  return { enabled: raw.enabled !== false, status: raw.status !== false }
}

function trimDir(p: string | undefined): string {
  return (p ?? '').trim().replace(/[\\/]+$/, '')
}

// One machine-wide file under ~/.claude/local/, the directory ~/.claude/CLAUDE.md reserves for state kept across sessions, read by
// scripts/fleet-launch.sh. Null without a home directory, and then nothing is written.
export function readingPath(home: string | undefined): string | null {
  const h = trimDir(home)
  return h === '' ? null : `${h}/.claude/local/rate-limits.json`
}

// Where Claude Code records the live login's identity. The file sits beside ~/.claude, not inside it, unless CLAUDE_CONFIG_DIR names
// a profile directory (a `cswap run` session), where it sits inside that directory. cswap rewrites it on every switch, which is what
// makes it the account the session is on rather than the one it started on.
export function configPath(home: string | undefined, configDir: string | undefined): string | null {
  const dir = trimDir(configDir)
  if (dir !== '') return `${dir}/.claude.json`
  const h = trimDir(home)
  return h === '' ? null : `${h}/.claude.json`
}

export function accountOf(configText: string): string | null {
  try {
    const parsed: unknown = JSON.parse(configText)
    const email = (parsed as { oauthAccount?: { emailAddress?: unknown } } | null)?.oauthAccount?.emailAddress
    return typeof email === 'string' && email !== '' ? email : null
  } catch {
    return null
  }
}

// cswap's backup root marks a machine that rotates accounts: ~/.claude-swap-backup on macOS and Windows, $XDG_DATA_HOME/claude-swap
// (default ~/.local/share/claude-swap) on Linux. Its presence, not the binary's, is the test: the binary sits in a PATH the plugin
// environment cannot search.
export function rotationDirs(home: string | undefined, xdgDataHome: string | undefined): string[] {
  const h = trimDir(home)
  if (h === '') return []
  const xdg = trimDir(xdgDataHome)
  return [`${h}/.claude-swap-backup`, `${xdg !== '' ? xdg : `${h}/.local/share`}/claude-swap`]
}

// The weekly window's reset is stable for the life of an account's week and differs between accounts, so a change in it is the one
// signal in the reading itself that the login may have moved; the identity is then re-read rather than inferred.
export function weeklyResetOf(windows: readonly RateLimit[]): string | null {
  return windows.find((w) => w.kind === 'seven_day')?.resetsAt ?? null
}

export function statusText(account: string | null, windows: readonly RateLimit[]): string {
  const parts = windows
    .filter((w) => w.kind === 'five_hour' || w.kind === 'seven_day')
    .map((w) => `${w.kind === 'five_hour' ? '5h' : '7d'} ${w.percentUsed}%`)
  return [`⇄ ${account ?? 'account ?'}`, ...parts].join(' · ')
}

function windowsOf(windows: readonly RateLimit[]) {
  return windows.map((w) => (w.resetsAt === undefined ? { kind: w.kind, percentUsed: w.percentUsed } : { kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt }))
}

// The file's text: the windows as the engine reported them, dated, and the account they belong to when it is known; null when the
// measurement carried none (off a subscription, or before the first response), so an empty reading never overwrites a dated one.
export function readingOf(windows: readonly RateLimit[], session: string, nowMs: number, account: string | null = null): string | null {
  if (windows.length === 0) return null
  const reading = { measured_at: new Date(nowMs).toISOString(), session, ...(account === null ? {} : { account }), windows: windowsOf(windows) }
  return `${JSON.stringify(reading, null, 2)}\n`
}

// The snapshot above keeps only the latest writer, so it cannot say how full a window got while a fleet ran. Each session also keeps
// its own history, one file per session so concurrent sessions never race a shared one; fleet-metrics.py reads a fleet's files for
// the peak five_hour reading. A line that records a switch names the account left as `switched_from`. Null without a home directory
// or a session id.
export function historyPath(home: string | undefined, session: string): string | null {
  const h = trimDir(home)
  return h === '' || session === '' ? null : `${h}/.claude/local/rate-limits/${session}.jsonl`
}

export function historyLine(windows: readonly RateLimit[], nowMs: number, account: string | null = null, switchedFrom: string | null = null): string | null {
  if (windows.length === 0) return null
  return JSON.stringify({
    measured_at: new Date(nowMs).toISOString(),
    ...(account === null ? {} : { account }),
    ...(switchedFrom === null ? {} : { switched_from: switchedFrom }),
    windows: windowsOf(windows),
  })
}
