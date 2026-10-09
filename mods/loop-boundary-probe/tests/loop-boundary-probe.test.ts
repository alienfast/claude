import { expect, mock, test, type TestBody } from 'claude-code/testing'

type TestOn = Parameters<TestBody>[1]

const SESSION = { surface: 'terminal', isInteractive: false, cwd: '/work' } as const
const USAGE = { startedAt: 0, context: { tokens: 1000, window: 200000, percent: 1 }, rateLimits: [] }

function harness(on: TestOn, compactImpl: () => unknown) {
  mock.env(on, { LOOP_PROBE_OUT: '/work/tmp/probe.jsonl' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.usage', () => ({ value: USAGE }))
  const calls = { compactions: 0 }
  on('session.compact', () => {
    calls.compactions += 1
    return compactImpl() as { messages: never[] }
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  let written = ''
  on('fs.write', ($, e) => {
    written = e.text
    return { value: undefined }
  })
  return { calls, rows: () => written.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line)) }
}

const done = (turnId: string, answer: string) => ({ turnId, reason: 'answer' as const, answer, durationMs: 5, isAborted: false })

test('after the first turn, every main-loop turn end compacts; prompts are logged with their origin', async ($, on) => {
  const h = harness(on, () => ({ messages: [{ role: 'user', text: 'summary', toolUses: [] }], tokensBefore: 1000, tokensAfter: 50 }))
  await $.session.start(SESSION)
  await $.prompt.submit({ text: 'first', wait: false, origin: { kind: 'sdk' } })
  await $.turn.complete(done('t1', 'ONE'))
  await $.prompt.submit({ text: 'second', wait: false, origin: { kind: 'scheduled-trigger' } })
  await $.turn.complete({ ...done('sub', 'report'), agentId: 'a1' })
  await $.turn.complete(done('t2', 'TWO'))
  expect(h.calls.compactions).toBe(1)
  const rows = h.rows()
  expect(rows.map((r) => r.event)).toEqual(['prompt', 'prompt', 'compact'])
  expect(rows[0]).toMatchObject({ index: 0, origin: { kind: 'sdk' }, turnRunning: false })
  expect(rows[1]).toMatchObject({ index: 1, origin: { kind: 'scheduled-trigger' }, turnRunning: false })
  expect(rows[2]).toMatchObject({ turnId: 't2', compact: { accepted: true, messages: 1, tokensBefore: 1000, tokensAfter: 50 } })
  expect(typeof rows[2].ownHookSaw).toBe('boolean')
  expect(rows[2].contextBefore).toEqual(USAGE.context)
})

test('a rejected compaction is recorded, not thrown', async ($, on) => {
  const h = harness(on, () => {
    throw new Error('a turn is running')
  })
  await $.session.start(SESSION)
  await $.prompt.submit({ text: 'first', wait: false, origin: { kind: 'sdk' } })
  await $.prompt.submit({ text: 'second', wait: false, origin: { kind: 'sdk' } })
  const out = await $.turn.complete(done('t2', 'TWO'))
  expect(out.text).toBe('TWO')
  expect(typeof h.rows().at(-1).compact.rejected).toBe('string')
  expect(h.calls.compactions).toBe(1)
})
