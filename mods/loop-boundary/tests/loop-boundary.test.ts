import { expect, test, type TestBody } from 'claude-code/testing'
import { boundaryMessage, loopPromptOf, matchesPrefix, outcomeLineOf, readOptions, requestTokensOf, wakeupPromptOf } from '../hooks/boundary'

type TestOn = Parameters<TestBody>[1]

const SESSION = { surface: 'terminal', isInteractive: false, cwd: '/work' } as const
const STEP = { turnId: 't', model: 'claude-opus-5-5', messageCount: 1, effort: 'xhigh' } as const
const USAGE = { input_tokens: 2, output_tokens: 7, cache_read_input_tokens: 110000, cache_creation_input_tokens: 2000, model: 'claude-opus-5-5' }
const done = (turnId: string, answer: string, extra: Record<string, unknown> = {}) => ({ turnId, reason: 'answer' as const, answer, durationMs: 5, isAborted: false, ...extra })
const typed = (text: string) => ({ text, wait: false, origin: { kind: 'composer' as const } })
const wakeup = (text: string) => ({ text, wait: false, origin: { kind: 'scheduled-trigger' as const } })

async function drain(stream: AsyncGenerator<unknown, unknown, unknown>) {
  let step = await stream.next()
  while (step.done !== true) step = await stream.next()
  return step.value
}

function harness(on: TestOn, opts: { contextTokens?: number; percent?: number; stateExists?: boolean; tools?: Record<number, { name: string; input: unknown }[]> } = {}) {
  const coreCompactions: string[] = []
  const logs: string[] = []
  let written = ''
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'abcd1234-0000-4000-8000-000000000000' }))
  on('session.root', () => ({ value: '/work' }))
  on('fs.exists', ($, e) => ({ value: e.path.includes('auto-state') ? (opts.stateExists ?? true) : false }))
  on('fs.read', () => ({ value: '' }))
  on('fs.write', ($, e) => {
    written = e.text
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('session.usage', () => ({ value: { startedAt: 0, context: { tokens: opts.contextTokens ?? 480000, window: 1000000, percent: opts.percent ?? 48 }, rateLimits: [] } }))
  on('session.compact', ($, e) => {
    coreCompactions.push(e.trigger)
    return { messages: [{ role: 'user', text: 'core summary', toolUses: [] }], tokensBefore: 480000, tokensAfter: 9000 }
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.step', async function* ($, e) {
    yield { kind: 'text', index: 0, text: 'ok' }
    const toolUses = opts.tools?.[e.index] ?? []
    return { turnId: e.turnId, index: e.index, answer: 'ok', toolUses, stopReason: toolUses.length ? 'tool_use' : 'end_turn', usage: USAGE }
  })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  const rows = () => written.trim().split('\n').filter(Boolean).map((l) => JSON.parse(l) as Record<string, unknown>)
  return { coreCompactions, logs, rows }
}

const SHIPPED = 'Issue done.\n\n**SHIPPED-MERGE: BF-1** — merged onto main.'

test('a looping /auto session compacts to the boundary message when a turn ends with an outcome line', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.start({ turnId: 't1', text: '/loop /auto' })
  await drain($.turn.step({ ...STEP, turnId: 't1', index: 0 }))
  await $.turn.complete(done('t1', SHIPPED))
  expect(h.coreCompactions).toEqual([])
  const rows = h.rows()
  expect(rows.length).toBe(1)
  expect(rows[0]).toMatchObject({ event: 'boundary', accepted: true, nearClear: true, outcome: 'SHIPPED-MERGE: BF-1 — merged onto main.', tokensBefore: 480000, tokensAfter: null, path: 'turn-complete', loopPrompt: '/auto', session: 'abcd1234-0000-4000-8000-000000000000' })
  expect(h.logs[0]).toContain('compacted at the iteration boundary after `SHIPPED-MERGE: BF-1 — merged onto main.`')
  expect(h.logs[0]).toContain('480,000')
})

test('the next iteration first request fills tokensAfter', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.start({ turnId: 't1', text: '/loop /auto' })
  await $.turn.complete(done('t1', SHIPPED))
  await $.prompt.submit(wakeup('/auto'))
  await $.turn.start({ turnId: 't2', text: '/auto' })
  await drain($.turn.step({ ...STEP, turnId: 't2', index: 0 }))
  expect(h.rows()[0]?.tokensAfter).toBe(112002)
  expect(h.logs.at(-1)).toContain('112,002')
})

test('a heartbeat status check, a stalled turn, an aborted turn: no outcome line, no compaction', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.complete(done('t1', 'Delegated work is still in flight; re-armed the fallback heartbeat.'))
  await $.turn.complete(done('t2', 'I will dispatch the developer next.'))
  await $.turn.complete({ ...done('t3', ''), reason: 'aborted', isAborted: true })
  expect(h.coreCompactions).toEqual([])
  expect(h.rows().map((r) => [r.event, r.reason])).toEqual([
    ['pass', 'no-outcome'],
    ['pass', 'no-outcome'],
    ['pass', 'aborted'],
  ])
})

test('a scheduled-trigger wakeup marks the session as looping even when no /loop was typed here', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(wakeup('/auto epic:BF-1826'))
  await $.turn.complete(done('t1', 'SKIPPED-BLOCKED: BF-9 — blocker open'))
  expect(h.rows()[0]).toMatchObject({ event: 'boundary', accepted: true, outcome: 'SKIPPED-BLOCKED: BF-9 — blocker open', loopPrompt: '/auto epic:BF-1826' })
})

test('a session running no loop writes nothing, whatever its answers say', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/auto BF-123'))
  await $.turn.complete(done('t1', SHIPPED))
  expect(h.coreCompactions).toEqual([])
  expect(h.rows()).toEqual([])
})

test('a loop on another prompt is passed through by prefix', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop 5m /babysit-prs'))
  await $.turn.complete(done('t1', 'AUTO-CONTINUE: nothing to do'))
  expect(h.coreCompactions).toEqual([])
  expect(h.rows()[0]).toMatchObject({ event: 'pass', reason: 'prefix', loopPrompt: '/babysit-prs' })
})

test('the turn that ends the loop (ScheduleWakeup stop) is not compacted', async ($, on) => {
  const h = harness(on, { tools: { 0: [{ name: 'ScheduleWakeup', input: { stop: true } }] } })
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.start({ turnId: 't1', text: '/loop /auto' })
  await drain($.turn.step({ ...STEP, turnId: 't1', index: 0 }))
  await $.turn.complete(done('t1', 'NO-CANDIDATES: backlog drained'))
  expect(h.rows()[0]).toMatchObject({ event: 'pass', reason: 'loop-ended', outcome: 'NO-CANDIDATES: backlog drained' })
})

test('a ScheduleWakeup call carrying the loop prompt marks the session as looping', async ($, on) => {
  const h = harness(on, { tools: { 0: [{ name: 'ScheduleWakeup', input: { delaySeconds: 60, prompt: '/auto', noop: false, reason: 'next pick' } }] } })
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't1', text: 'carry on' })
  await drain($.turn.step({ ...STEP, turnId: 't1', index: 0 }))
  await $.turn.complete(done('t1', SHIPPED))
  expect(h.rows()[0]).toMatchObject({ event: 'boundary', loopPrompt: '/auto' })
})

test('below the context floor a boundary is logged, not compacted', { options: { min_context_percent: 60 } }, async ($, on) => {
  const h = harness(on, { percent: 48 })
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.complete(done('t1', SHIPPED))
  expect(h.coreCompactions).toEqual([])
  expect(h.rows()[0]).toMatchObject({ event: 'pass', reason: 'below-floor', contextPercent: 48 })
})

test('the kill switch leaves every turn alone and writes nothing', { options: { enabled: false } }, async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.prompt.submit(typed('/loop /auto'))
  await $.turn.complete(done('t1', SHIPPED))
  expect(h.coreCompactions).toEqual([])
  expect(h.rows()).toEqual([])
})

test('every other compaction passes through: the engine threshold, a typed /compact, a subagent', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  const msgs = [{ role: 'user' as const, text: 'hi', toolUses: [] }]
  await $.session.compact({ trigger: 'auto', messages: msgs })
  await $.session.compact({ trigger: 'manual', messages: msgs })
  await $.session.compact({ trigger: 'auto', messages: msgs, agentId: 'a1' })
  expect(h.coreCompactions).toEqual(['auto', 'manual', 'auto'])
  expect(h.rows()).toEqual([])
})

test('pure helpers: outcome lines, loop prompts, prefixes, wakeups, request tokens, options', async () => {
  expect(outcomeLineOf('done\n\n**SHIPPED-MERGE: BF-1** — merged')).toBe('SHIPPED-MERGE: BF-1 — merged')
  expect(outcomeLineOf('`AUTO-CONTINUE: no pick — PLANNED-HOLD`')).toBe('AUTO-CONTINUE: no pick — PLANNED-HOLD')
  expect(outcomeLineOf('- SKIPPED-REVIEW-BLOCKED: BF-2')).toBe('SKIPPED-REVIEW-BLOCKED: BF-2')
  expect(outcomeLineOf('I will emit SHIPPED-MERGE once the merge lands.')).toBe(null)
  expect(outcomeLineOf('Re-armed the heartbeat; developer still running.')).toBe(null)
  expect(loopPromptOf('/loop /auto')).toBe('/auto')
  expect(loopPromptOf('/loop 15m /auto epic:BF-1')).toBe('/auto epic:BF-1')
  expect(loopPromptOf('/loop 2 hours /babysit')).toBe('/babysit')
  expect(loopPromptOf('/auto')).toBe(null)
  expect(loopPromptOf('please /loop this')).toBe(null)
  expect(matchesPrefix('/auto', ['/auto'])).toBe(true)
  expect(matchesPrefix('/auto epic:BF-1', ['/auto'])).toBe(true)
  expect(matchesPrefix('/auto-prep', ['/auto'])).toBe(false)
  expect(matchesPrefix('/babysit', ['/auto', '/babysit'])).toBe(true)
  expect(wakeupPromptOf([{ name: 'ScheduleWakeup', input: { prompt: '/auto', delaySeconds: 60 } }])).toEqual({ prompt: '/auto', stop: false })
  expect(wakeupPromptOf([{ name: 'ScheduleWakeup', input: { stop: true } }])).toEqual({ prompt: null, stop: true })
  expect(wakeupPromptOf([{ name: 'Bash', input: { command: 'ls' } }])).toEqual({ prompt: null, stop: false })
  expect(requestTokensOf(USAGE)).toBe(112002)
  expect(requestTokensOf(null)).toBe(null)
  expect(boundaryMessage({ outcome: 'SHIPPED-PR: BF-1', runKey: 'abcd1234', statePath: '/w/tmp/auto-state-abcd1234.json', stateExists: true })).toContain('run state in /w/tmp/auto-state-abcd1234.json')
  expect(readOptions({})).toEqual({ enabled: true, prefixes: ['/auto'], minContextPercent: 0, ledger: true })
  expect(readOptions({ loop_prefixes: '/auto, /babysit-prs', min_context_percent: 250, ledger: false })).toEqual({ enabled: true, prefixes: ['/auto', '/babysit-prs'], minContextPercent: 100, ledger: false })
})
