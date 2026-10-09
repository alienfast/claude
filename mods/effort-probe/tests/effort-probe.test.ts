import { expect, mock, test } from 'claude-code/testing'

const STEP = { turnId: 't', model: 'claude-opus-5-5', messageCount: 1 } as const

async function drain(stream: AsyncGenerator<unknown, unknown, unknown>) {
  let step = await stream.next()
  while (step.done !== true) step = await stream.next()
  return step.value
}

test('switch mode rewrites only the second main-loop step and logs every step', async ($, on) => {
  mock.env(on, { EFFORT_PROBE_MODE: 'switch', EFFORT_PROBE_OUT: '/work/tmp/probe.jsonl' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.cwd', () => ({ value: '/work' }))
  let written = ''
  on('fs.write', ($, e) => {
    written = e.text
    return { value: undefined }
  })
  const seen: unknown[] = []
  on('turn.step', async function* ($, e) {
    seen.push(e.effort)
    yield { kind: 'text', index: 0, text: 'ok' }
    return {
      turnId: e.turnId,
      index: e.index,
      answer: 'ok',
      toolUses: [{ name: 'Read', input: {} }],
      stopReason: 'tool_use',
      usage: { input_tokens: 2, output_tokens: 7, cache_read_input_tokens: 100, cache_creation_input_tokens: 5, model: 'claude-opus-5-5' },
    }
  })

  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  for (const index of [0, 1, 2]) await drain($.turn.step({ ...STEP, index, effort: 'high' }))
  await drain($.turn.step({ ...STEP, index: 3, effort: 'high', agentId: 'sub' }))

  expect(seen).toEqual(['high', 'low', 'high', 'high'])
  const rows = written.trim().split('\n').map((line) => JSON.parse(line))
  expect(rows.map((r) => r.effortOut)).toEqual(['high', 'low', 'high'])
  expect(rows[1].usage.cache_read_input_tokens).toBe(100)
})

test('control mode leaves every step alone', async ($, on) => {
  mock.env(on, { EFFORT_PROBE_MODE: 'control' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'abc' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.write', () => ({ value: undefined }))
  const seen: unknown[] = []
  on('turn.step', async function* ($, e) {
    seen.push(e.effort)
    yield { kind: 'text', index: 0, text: 'ok' }
    return { turnId: e.turnId, index: e.index, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: null }
  })

  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  for (const index of [0, 1]) await drain($.turn.step({ ...STEP, index, effort: 'high' }))
  expect(seen).toEqual(['high', 'high'])
})
