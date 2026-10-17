import { expect, mock, test, type TestBody } from 'claude-code/testing'
import { accountOf, configPath, historyLine, historyPath, readOptions, readingOf, readingPath, rotationDirs, statusText, weeklyResetOf } from '../hooks/limits'

type TestOn = Parameters<TestBody>[1]

const SESSION = { surface: 'terminal', isInteractive: false, cwd: '/work' } as const
const SID = 'abcd1234-0000-4000-8000-000000000000'
const NOW = Date.UTC(2026, 9, 10, 20, 15, 3)
const CONTEXT = { tokens: 1000, window: 1000000, percent: 0 }
// The windows as the engine reports them to a subscription session.
const FIVE_HOUR = { kind: 'five_hour', percentUsed: 12.5, resetsAt: '2026-10-11T00:00:00.000Z' }
const SEVEN_DAY = { kind: 'seven_day', percentUsed: 71, resetsAt: '2026-10-13T22:00:00.000Z' }
const WINDOWS = [FIVE_HOUR, SEVEN_DAY]

const SNAPSHOT = '/home/u/.claude/local/rate-limits.json'
const HISTORY = `/home/u/.claude/local/rate-limits/${SID}.jsonl`

function harness(on: TestOn, env: Readonly<Record<string, string>> = { HOME: '/home/u' }, files: Readonly<Record<string, string>> = {}) {
  const writes: { path: string; text: string }[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: SID }))
  on('clock.now', () => ({ value: NOW }))
  on('fs.exists', ($, e) => ({ value: e.path in files }))
  on('fs.read', ($, e) => ({ value: files[e.path] ?? '' }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  mock.env(on, env)
  return { writes, at: (p: string) => writes.filter((w) => w.path === p).map((w) => w.text) }
}

test('a measurement carrying windows rewrites ~/.claude/local/rate-limits.json whole', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context', 'rateLimits'] })
  await $.session.measure({ context: CONTEXT, rateLimits: [SEVEN_DAY], changed: ['rateLimits'] })
  expect(h.at(SNAPSHOT)).toHaveLength(2)
  const written = h.at(SNAPSHOT).map((t) => JSON.parse(t) as { windows: unknown })
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
  expect(h.writes.map((w) => w.path.endsWith('C:/Users/u/.claude/local/rate-limits.json'))).toEqual([true, false])
  expect(h.writes[1]?.path.endsWith(`C:/Users/u/.claude/local/rate-limits/${SID}.jsonl`)).toBe(true)
})

test('no home directory at all: nothing is written', async ($, on) => {
  const h = harness(on, {})
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.writes).toEqual([])
})

test('the session history gains a line only when a window moved, and keeps every earlier one', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context', 'rateLimits'] })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context'] })
  await $.session.measure({ context: CONTEXT, rateLimits: [{ ...FIVE_HOUR, percentUsed: 14 }, SEVEN_DAY], changed: ['rateLimits'] })
  const last = h.at(HISTORY).at(-1) ?? ''
  const lines = last.trim().split('\n').map((l) => JSON.parse(l) as { measured_at: string; windows: { percentUsed: number }[] })
  expect(lines.map((l) => l.windows[0]?.percentUsed)).toEqual([12.5, 14])
  expect(lines[0]).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', windows: WINDOWS })
})

test('a reloaded module appends after the readings the session already wrote', async ($, on) => {
  const earlier = `${JSON.stringify({ measured_at: '2026-10-10T19:00:00.000Z', windows: [{ ...FIVE_HOUR, percentUsed: 3 }] })}\n`
  const h = harness(on, { HOME: '/home/u' }, { [HISTORY]: earlier })
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const lines = (h.at(HISTORY).at(-1) ?? '').trim().split('\n')
  expect(lines).toHaveLength(2)
  expect(lines[0]).toBe(earlier.trim())
})

test('pure helpers: the path, the file text, the options', async () => {
  expect(historyPath('/home/u/', 's1')).toBe('/home/u/.claude/local/rate-limits/s1.jsonl')
  expect(historyPath('/home/u', '')).toBe(null)
  expect(historyPath(undefined, 's1')).toBe(null)
  expect(historyLine([], NOW)).toBe(null)
  expect(JSON.parse(historyLine([FIVE_HOUR], NOW) ?? '')).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', windows: [FIVE_HOUR] })
  expect(readingPath('/home/u')).toBe('/home/u/.claude/local/rate-limits.json')
  expect(readingPath('/home/u/')).toBe('/home/u/.claude/local/rate-limits.json')
  expect(readingPath('C:\\Users\\u\\')).toBe('C:\\Users\\u/.claude/local/rate-limits.json')
  expect(readingPath(undefined)).toBe(null)
  expect(readingPath('  ')).toBe(null)
  expect(readingOf([], 's', NOW)).toBe(null)
  expect(JSON.parse(readingOf([{ kind: 'seven_day', percentUsed: 7 }], 's', NOW) ?? '')).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', session: 's', windows: [{ kind: 'seven_day', percentUsed: 7 }] })
  expect(readOptions({})).toEqual({ enabled: true, status: true })
  expect(readOptions({ enabled: false })).toEqual({ enabled: false, status: true })
})

// ---- the account the reading belongs to, and the status line a rotating machine gets ----

const CONFIG = '/home/u/.claude.json'
const ROTATING = '/home/u/.claude-swap-backup'
const login = (email: string) => JSON.stringify({ oauthAccount: { emailAddress: email, organizationName: 'org' } })
// A second account's windows: the weekly reset differs, which is what the reading itself shows when the login moved.
const OTHER_WEEK = { kind: 'seven_day', percentUsed: 4, resetsAt: '2026-10-15T05:00:00.000Z' }

function statusHarness(on: TestOn, files: Record<string, string>) {
  const statuses: (string | undefined)[] = []
  on('ui.status', ($, e) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  return { ...harness(on, { HOME: '/home/u' }, files), statuses }
}

test('a rotating machine gets the account and its windows pinned under the prompt, and the files name the account', async ($, on) => {
  const h = statusHarness(on, { [ROTATING]: '', [CONFIG]: login('a@example.com') })
  await $.session.start(SESSION)
  expect(h.statuses).toEqual(['⇄ a@example.com'])
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.statuses.at(-1)).toBe('⇄ a@example.com · 5h 12.5% · 7d 71%')
  expect(JSON.parse(h.at(SNAPSHOT).at(-1) ?? '')).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', session: SID, account: 'a@example.com', windows: WINDOWS })
  expect(JSON.parse((h.at(HISTORY).at(-1) ?? '').trim())).toEqual({ measured_at: '2026-10-10T20:15:03.000Z', account: 'a@example.com', windows: WINDOWS })
})

test('a single-account machine records the account but pins nothing', async ($, on) => {
  const h = statusHarness(on, { [CONFIG]: login('a@example.com') })
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.statuses).toEqual([])
  expect((JSON.parse(h.at(SNAPSHOT).at(-1) ?? '') as { account?: string }).account).toBe('a@example.com')
})

test('a login moved under the session is recorded as a switch; the same account rolling its week over is not', async ($, on) => {
  const files: Record<string, string> = { [ROTATING]: '', [CONFIG]: login('a@example.com') }
  const h = statusHarness(on, files)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  files[CONFIG] = login('b@example.com')
  await $.session.measure({ context: CONTEXT, rateLimits: [FIVE_HOUR, OTHER_WEEK], changed: ['rateLimits'] })
  const rolled = { ...OTHER_WEEK, percentUsed: 0, resetsAt: '2026-10-22T05:00:00.000Z' }
  await $.session.measure({ context: CONTEXT, rateLimits: [FIVE_HOUR, rolled], changed: ['rateLimits'] })
  const lines = (h.at(HISTORY).at(-1) ?? '').trim().split('\n').map((l) => JSON.parse(l) as { account?: string; switched_from?: string })
  expect(lines.map((l) => [l.account, l.switched_from])).toEqual([
    ['a@example.com', undefined],
    ['b@example.com', 'a@example.com'],
    ['b@example.com', undefined],
  ])
  expect(h.statuses.at(-1)).toBe('⇄ b@example.com · 5h 12.5% · 7d 0%')
})

test('a switch is written to the history even when no window moved a whole point', async ($, on) => {
  const files: Record<string, string> = { [ROTATING]: '', [CONFIG]: login('a@example.com') }
  const h = statusHarness(on, files)
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  files[CONFIG] = login('b@example.com')
  await $.session.measure({ context: CONTEXT, rateLimits: [FIVE_HOUR, OTHER_WEEK], changed: ['context'] })
  const lines = (h.at(HISTORY).at(-1) ?? '').trim().split('\n')
  expect(lines).toHaveLength(2)
  expect((JSON.parse(lines[1] ?? '') as { switched_from?: string }).switched_from).toBe('a@example.com')
})

test('the status option alone turns the pin off; the account is still recorded', { options: { status: false } }, async ($, on) => {
  const h = statusHarness(on, { [ROTATING]: '', [CONFIG]: login('a@example.com') })
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.statuses).toEqual([])
  expect((JSON.parse(h.at(SNAPSHOT).at(-1) ?? '') as { account?: string }).account).toBe('a@example.com')
})

test('without an identity file the reading is unlabelled and the pin says so', async ($, on) => {
  const h = statusHarness(on, { [ROTATING]: '' })
  await $.session.start(SESSION)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(h.statuses.at(-1)).toBe('⇄ account ? · 5h 12.5% · 7d 71%')
  expect('account' in (JSON.parse(h.at(SNAPSHOT).at(-1) ?? '') as object)).toBe(false)
})

test('pure helpers: the identity file, the rotation roots, the pin text', async () => {
  expect(configPath('/home/u', undefined)).toBe('/home/u/.claude.json')
  expect(configPath('/home/u', '/home/u/.claude-swap-backup/sessions/2-b/')).toBe('/home/u/.claude-swap-backup/sessions/2-b/.claude.json')
  expect(configPath(undefined, undefined)).toBe(null)
  expect(accountOf(login('a@example.com'))).toBe('a@example.com')
  expect(accountOf('{"oauthAccount":{}}')).toBe(null)
  expect(accountOf('not json')).toBe(null)
  expect(rotationDirs('/home/u', undefined)).toEqual(['/home/u/.claude-swap-backup', '/home/u/.local/share/claude-swap'])
  expect(rotationDirs('/home/u', '/data/')).toEqual(['/home/u/.claude-swap-backup', '/data/claude-swap'])
  expect(rotationDirs(undefined, '/data')).toEqual([])
  expect(weeklyResetOf(WINDOWS)).toBe(SEVEN_DAY.resetsAt)
  expect(weeklyResetOf([FIVE_HOUR])).toBe(null)
  expect(statusText('a@example.com', [])).toBe('⇄ a@example.com')
  expect(statusText(null, [{ kind: 'spend_limit', percentUsed: 50 }, FIVE_HOUR])).toBe('⇄ account ? · 5h 12.5%')
  expect(readOptions({})).toEqual({ enabled: true, status: true })
  expect(readOptions({ status: false })).toEqual({ enabled: true, status: false })
})
