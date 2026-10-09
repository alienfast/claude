import type { Register } from 'claude-code'
import { POLL_STREAK, commandsOf, effortFor, isMechanicalCommand, isWaitShaped, phaseForSkill, readOptions, type Lane, type Phase } from './phase'

let phase: Phase = 'judgment'
let waitStreak = 0
let mechanicalNext = false
let lastSent: unknown = undefined
let switches = 0
let sessionId = ''
let ledgerPath = ''
let rows: string[] = []
let active = false

type Writer = { readonly fs: { readonly write: (path: string, text: string) => Promise<void> } }

async function record($: Writer, row: Record<string, unknown>): Promise<void> {
  if (!active) return
  rows.push(JSON.stringify({ ts: new Date().toISOString(), session: sessionId, ...row }))
  await $.fs.write(ledgerPath, rows.join('\n') + '\n')
}

export const register: Register = (on, options) => {
  const opts = readOptions(options)
  active = opts.enabled && opts.ledger

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    if (active) {
      // Resolved once: a worktree move later in the session would otherwise split the ledger across two tmp/ dirs.
      ledgerPath = `${await $.session.root()}/tmp/effort-ledger-${sessionId}.jsonl`
      if (await $.fs.exists(ledgerPath)) rows = (await $.fs.read(ledgerPath)).split('\n').filter((line) => line !== '')
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    waitStreak = 0
    mechanicalNext = false
    lastSent = undefined
    switches = 0
    return next(e)
  })

  // A typed `/finish` expands before turn.start, so the phase is reset when the turn ends, never when it begins.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) phase = 'judgment'
    return next(e)
  })

  on('skill.prompt', async ($, e, next) => {
    const next_ = phaseForSkill(e.skill)
    if (next_ !== phase) {
      phase = next_
      if (opts.enabled) $.ui.status(`effort-phase: ${phase} (${e.skill})`)
    }
    await record($, { event: 'skill', skill: e.skill, lane: phase })
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || !opts.enabled) return yield* next(e)
    const lane: Lane = waitStreak >= POLL_STREAK ? 'polling' : mechanicalNext ? 'mechanical' : phase
    const want = effortFor(lane, opts.map, e.effort) ?? e.effort
    let effortOut = want
    if (opts.cap > 0 && lastSent !== undefined && want !== lastSent && switches >= opts.cap) effortOut = lastSent as typeof want
    if (lastSent !== undefined && effortOut !== lastSent) switches += 1
    const result = yield* next(effortOut === e.effort ? e : { ...e, effort: effortOut })
    lastSent = effortOut
    waitStreak = isWaitShaped(result.toolUses) ? waitStreak + 1 : 0
    mechanicalNext = isMechanicalCommand(result.toolUses)
    await record($, {
      event: 'step',
      turnId: e.turnId,
      index: e.index,
      lane,
      effortIn: e.effort ?? null,
      effortOut: effortOut ?? null,
      model: e.model,
      answeredBy: result.usage?.model ?? null,
      usage: result.usage,
      tools: result.toolUses.map((t) => t.name),
      commands: commandsOf(result.toolUses),
    })
    return result
  })
}
