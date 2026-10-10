export type Phase = 'judgment' | 'mechanical'
export type Lane = Phase | 'polling'
export type Effort = 'low' | 'medium' | 'high' | 'xhigh' | 'max'
export type ToolUse = { readonly name: string; readonly input: unknown }

export const EFFORTS: readonly Effort[] = ['low', 'medium', 'high', 'xhigh', 'max']

// The checkout a ledger belongs to. A session resumed inside a /start wt worktree reports the worktree as its root — measured
// 2026-10-10: three fleet sessions resumed at 14:22Z wrote their later rows under <worktree>/tmp, where /finish deletes them and
// fleet-metrics.py never looked — so a linked worktree (its `.git` is a file naming the owning repo's worktrees dir) resolves to
// the checkout that owns it. Anything else, a main checkout's `.git` directory included, keeps the root as reported.
export function owningCheckout(root: string, dotGit: string | null): string {
  const target = /^gitdir:\s*(.+?)\s*$/m.exec(dotGit ?? '')?.[1]
  if (target === undefined) return root
  const gitdir = (/^(?:\/|[A-Za-z]:[\\/])/.test(target) ? target : `${root}/${target}`).replace(/\\/g, '/')
  const at = gitdir.indexOf('/.git/worktrees/')
  if (at === -1) return root
  const out: string[] = []
  for (const seg of gitdir.slice(0, at).split('/')) {
    if (seg === '..') out.pop()
    else if (seg !== '.' && (seg !== '' || out.length === 0)) out.push(seg)
  }
  return out.join('/')
}

// A main checkout's `.git` is a directory, which the read rejects; a linked worktree's is a one-line file.
export async function dotGitOf(read: (path: string) => Promise<string>, root: string): Promise<string | null> {
  try {
    return await read(`${root}/.git`)
  } catch {
    return null
  }
}

// Skills whose expansion marks the rest of the turn as bookkeeping: Linear posts, git, merges, reaping. Everything else
// (start, spec, quality-review, auto, full, do, ...) is judgment, so an unknown skill never lowers effort.
export const MECHANICAL_SKILLS: ReadonlySet<string> = new Set([
  'finish',
  'checkpoint',
  'pr-update',
  'exec-summary',
  'merge-queue',
  'reap-worktrees',
  'reap-tmp',
  'update',
  'fleet-status',
  'fleet-stop',
])

export function phaseForSkill(skill: string): Phase {
  return MECHANICAL_SKILLS.has(skill) ? 'mechanical' : 'judgment'
}

// The polling lane needs this many consecutive wait-shaped steps first: the step right after a single wait is usually
// the one that reads the result and acts on it, and only a sustained loop is the blind-sleep signature.
export const POLL_STREAK = 2

const WAIT_TOOLS: ReadonlySet<string> = new Set(['Monitor', 'ScheduleWakeup', 'TaskStop'])
// A wait as a command of its own, at the start or after a separator, so `grep wait file` or a path carrying the word does not match.
const WAIT_COMMAND = /(^|[;&|(]\s*)(do\s+|then\s+)?(sleep\s+\d|until\s+\[|tail\s+-f|wait\b)/

function commandOf(input: unknown): string {
  if (typeof input !== 'object' || input === null) return ''
  const command = (input as { command?: unknown }).command
  return typeof command === 'string' ? command : ''
}

export function isWaitShaped(uses: readonly ToolUse[]): boolean {
  if (uses.length === 0) return false
  return uses.every((u) => WAIT_TOOLS.has(u.name) || (u.name === 'Bash' && WAIT_COMMAND.test(commandOf(u.input))))
}

// A bookkeeping command outside any mechanical skill (a Linear post from /start, a push from an interactive turn):
// the request that reads its result is mechanical, and the one after that returns to the phase.
const MECHANICAL_COMMAND = /(^|[\s\/;&|(])(finish-[a-z-]+\.sh|linear-post\.sh|linear-set-state\.sh|mark-ready-for-release\.sh)\b|\bgit\s+push\b/

export function isMechanicalCommand(uses: readonly ToolUse[]): boolean {
  return uses.some((u) => u.name === 'Bash' && MECHANICAL_COMMAND.test(commandOf(u.input)))
}

export function commandsOf(uses: readonly ToolUse[]): string[] {
  return uses.filter((u) => u.name === 'Bash').map((u) => commandOf(u.input).slice(0, 160))
}

export type EffortMap = {
  readonly judgment: Effort | 'session'
  readonly mechanical: Effort
  readonly polling: Effort
}

export function effortFor(lane: Lane, map: EffortMap, session: Effort | number | undefined): Effort | number | undefined {
  const pick = map[lane]
  return pick === 'session' ? session : pick
}

export function asEffort(value: unknown, fallback: Effort): Effort {
  return typeof value === 'string' && (EFFORTS as readonly string[]).includes(value) ? (value as Effort) : fallback
}

export type Options = {
  readonly enabled: boolean
  readonly map: EffortMap
  readonly cap: number
  readonly ledger: boolean
}

export function readOptions(raw: Readonly<Record<string, unknown>>): Options {
  const judgment = raw.judgment_effort
  return {
    enabled: raw.enabled !== false,
    map: {
      judgment: typeof judgment === 'string' && (EFFORTS as readonly string[]).includes(judgment) ? (judgment as Effort) : 'session',
      mechanical: asEffort(raw.mechanical_effort, 'high'),
      polling: asEffort(raw.polling_effort, 'low'),
    },
    cap: typeof raw.max_switches_per_turn === 'number' && raw.max_switches_per_turn > 0 ? Math.floor(raw.max_switches_per_turn) : 0,
    ledger: raw.ledger !== false,
  }
}
