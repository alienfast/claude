import { expect, mock, test, type TestBody } from 'claude-code/testing'
import { readOptions, readingOf, readingPath } from '../hooks/limits'

type TestOn = Parameters<TestBody>[1]

const SESSION = { surface: 'terminal', isInteractive: false, cwd: '/work' } as const
const SID = 'abcd1234-0000-4000-8000-000000000000'
const NOW = Date.UTC(2026, 9, 10, 20, 15, 3)
const CONTEXT = { tokens: 1000, window: 1000000, percent: 0 }
// The windows as the engine reports them to a subscription session.
const FIVE_HOUR = { kind: 'five_hour', percentUsed: 12.5, resetsAt: '2026-10-11T00:00:00.000Z' }
const SEVEN_DAY = { kind: 'seven_day', percentUsed: 71, resetsAt: '2026-10-13T22:00:00.000Z' }
const WINDOWS = [FIVE_HOUR, SEVEN_DAY]

function harness(on: TestOn, env: Readonly<Record<string, string>> = { HOME: '/home/u' }) {
  const writes: { path: string; text: string }[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: SID }))
  on('clock.now', () => ({ value: NOW }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  mock.env(on, env)
  return { writes }
}

test('a measurement carrying windows rewrites ~/.claude/local/rate-limits.json whole', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context', 'rateLimits'] })
  await $.session.measure({ context: CONTEXT, rateLimits: [SEVEN_DAY], changed: ['rateLimits'] })
  expect(h.writes.map((w) => w.path)).toEqual(['/home/u/.claude/local/rate-limits.json', '/home/u/.claude/local/rate-limits.json'])
  const written = h.writes.map((w) => JSON.parse(w.text) as { windows: unknown })
  expect(written[0]).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', session: SID, windows: WINDOWS })
  expect(written[1]?.windows).toEqual([SEVEN_DAY])
})

test('a measurement with no windows (off a subscription, or before the first response) writes nothing', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: [], changed: ['context'] })
  expect(h.writes).toEqual([])
})

test('the kill switch writes nothing', { options: { enabled: false } }, async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.writes).toEqual([])
})

// The harness resolves a `C:/` path against the plugin directory on a POSIX host, so only the tail is pinned.
test('USERPROFILE stands in for HOME', async ($, on) => {
  const h = harness(on, { USERPROFILE: 'C:/Users/u' })
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.writes.map((w) => w.path.endsWith('C:/Users/u/.claude/local/rate-limits.json'))).toEqual([true])
})

test('no home directory at all: nothing is written', async ($, on) => {
  const h = harness(on, {})
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.writes).toEqual([])
})

test('pure helpers: the path, the file text, the options', async () => {
  expect(readingPath('/home/u')).toBe('/home/u/.claude/local/rate-limits.json')
  expect(readingPath('/home/u/')).toBe('/home/u/.claude/local/rate-limits.json')
  expect(readingPath('C:\\Users\\u\\')).toBe('C:\\Users\\u/.claude/local/rate-limits.json')
  expect(readingPath(undefined)).toBe(null)
  expect(readingPath('  ')).toBe(null)
  expect(readingOf([], 's', NOW)).toBe(null)
  expect(JSON.parse(readingOf([{ kind: 'seven_day', percentUsed: 7 }], 's', NOW) ?? '')).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', session: 's', windows: [{ kind: 'seven_day', percentUsed: 7 }] })
  expect(readOptions({})).toEqual({ enabled: true })
  expect(readOptions({ enabled: false })).toEqual({ enabled: false })
})
