import type { Register } from 'claude-code'
import { boundaryMessage, loopPromptOf, matchesPrefix, outcomeLineOf, readOptions, requestTokensOf, wakeupPromptOf } from './boundary'

let sessionId = ''
let runKey = ''
let root = ''
let ledgerPath = ''
let rows: string[] = []
let loopPrompt: string | null = null
let loopEnding = false
let compacting: { outcome: string; tokensBefore: number | null } | null = null
let nearClear = false
let pendingAfter: number | null = null

type Writer = { readonly fs: { readonly write: (path: string, text: string) => Promise<void> } }

async function flush($: Writer): Promise<void> {
  await $.fs.write(ledgerPath, rows.join('\n') + '\n')
}

async function record($: Writer, row: Record<string, unknown>, ledger: boolean): Promise<number> {
  if (!ledger) return -1
  rows.push(JSON.stringify({ ts: new Date().toISOString(), session: sessionId, ...row }))
  await flush($)
  return rows.length - 1
}

export const register: Register = (on, options) => {
  const opts = readOptions(options)

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    runKey = sessionId.split('-')[0] ?? sessionId
    root = await $.session.root()
    if (opts.enabled && opts.ledger) {
      ledgerPath = `${root}/tmp/loop-boundary-${sessionId}.jsonl`
      if (await $.fs.exists(ledgerPath)) rows = (await $.fs.read(ledgerPath)).split('\n').filter((line) => line !== '')
    }
    return next(e)
  })

  // A session is looping once a /loop prompt is typed (or dispatched, as a fleet session's first prompt) or a loop
  // wakeup arrives; the loop prompt is what the prefix list is matched against.
  on('prompt.submit', async ($, e, next) => {
    const typed = loopPromptOf(e.text)
    if (typed !== null) loopPrompt = typed
    else if (e.origin.kind === 'scheduled-trigger') loopPrompt = e.text.trim()
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    loopEnding = false
    return next(e)
  })

  // The ScheduleWakeup call that arms the next iteration carries the loop prompt; stop:true ends the loop.
  // The first request after a boundary measures what the compaction left: its context is the boundary's tokensAfter.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || !opts.enabled) return yield* next(e)
    const result = yield* next(e)
    const wake = wakeupPromptOf(result.toolUses)
    if (wake.stop) loopEnding = true
    else if (wake.prompt !== null) loopPrompt = wake.prompt
    if (pendingAfter !== null && opts.ledger) {
      const after = requestTokensOf(result.usage)
      const row = rows[pendingAfter]
      if (row !== undefined && after !== null) {
        rows[pendingAfter] = JSON.stringify({ ...(JSON.parse(row) as Record<string, unknown>), tokensAfter: after })
        await flush($)
        $.ui.log(`loop-boundary: next iteration's first request carried ${after.toLocaleString()} tokens`)
      }
      pendingAfter = null
    }
    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || !opts.enabled || loopPrompt === null) return result
    const base = { turnId: e.turnId, loopPrompt }
    if (!matchesPrefix(loopPrompt, opts.prefixes)) {
      await record($, { event: 'pass', reason: 'prefix', ...base }, opts.ledger)
      return result
    }
    if (e.reason !== 'answer') {
      await record($, { event: 'pass', reason: e.reason, ...base }, opts.ledger)
      return result
    }
    const outcome = outcomeLineOf(e.answer)
    if (outcome === null) {
      await record($, { event: 'pass', reason: 'no-outcome', ...base }, opts.ledger)
      return result
    }
    if (loopEnding) {
      await record($, { event: 'pass', reason: 'loop-ended', outcome, ...base }, opts.ledger)
      return result
    }
    const context = (await $.session.usage()).context
    if (opts.minContextPercent > 0 && (context.percent ?? 0) < opts.minContextPercent) {
      await record($, { event: 'pass', reason: 'below-floor', outcome, contextPercent: context.percent ?? null, ...base }, opts.ledger)
      return result
    }
    const tokensBefore = context.tokens ?? null
    compacting = { outcome, tokensBefore }
    nearClear = false
    let row: Record<string, unknown>
    try {
      const compacted = await $.session.compact()
      row =
        compacted.skip !== undefined
          ? { event: 'boundary', accepted: false, skipped: compacted.skip, outcome, tokensBefore, tokensAfter: null, path: 'turn-complete', nearClear, ...base }
          : { event: 'boundary', accepted: true, outcome, tokensBefore: compacted.tokensBefore ?? tokensBefore, tokensAfter: null, path: 'turn-complete', nearClear, ...base }
    } catch (err) {
      row = { event: 'boundary', accepted: false, error: String(err), outcome, tokensBefore, tokensAfter: null, path: 'turn-complete', nearClear: false, ...base }
    }
    compacting = null
    const index = await record($, row, opts.ledger)
    if (row.accepted === true) {
      pendingAfter = index >= 0 ? index : null
      $.ui.log(`loop-boundary: compacted at the iteration boundary after \`${outcome}\` — the last request carried ${tokensBefore === null ? 'an unmeasured number of' : tokensBefore.toLocaleString()} tokens`)
    } else {
      $.ui.log(`loop-boundary: boundary after \`${outcome}\` not compacted (${String(row.skipped ?? row.error)})`)
    }
    return result
  })

  // The compaction this mod triggered is answered here with the one boundary message, so no summarizer runs. The
  // in-flight flag is the key: it is set just before the call and cleared just after, and the engine stamps the event
  // `trigger: plugin` (the plugin test harness stamps nothing). Every other compaction — the engine's threshold, a typed
  // /compact, a subagent's — passes through untouched.
  on('session.compact', async ($, e, next) => {
    if (e.agentId !== undefined || compacting === null) return next(e)
    nearClear = true
    const statePath = `${root}/tmp/auto-state-${runKey}.json`
    const text = boundaryMessage({ outcome: compacting.outcome, runKey, statePath, stateExists: await $.fs.exists(statePath) })
    return compacting.tokensBefore === null
      ? { messages: [{ role: 'user', text, toolUses: [] }] }
      : { messages: [{ role: 'user', text, toolUses: [] }], tokensBefore: compacting.tokensBefore }
  })
}
