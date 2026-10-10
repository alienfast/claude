import { expect, test, type TestBody } from 'claude-code/testing'
import { dotGitOf, isMechanicalCommand, isWaitShaped, owningCheckout, phaseForSkill, readOptions } from '../hooks/phase'

type TestOn = Parameters<TestBody>[1]

const STEP = { turnId: 't', model: 'claude-opus-5-5', messageCount: 1 } as const
const USAGE = { input_tokens: 2, output_tokens: 7, cache_read_input_tokens: 100, cache_creation_input_tokens: 5, model: 'claude-opus-5-5' }
const SESSION = { surface: 'terminal', isInteractive: false, cwd: '/work' } as const
const WAIT_LOOP = { name: 'Bash', input: { command: 'for i in $(seq 1 22); do sleep 25; done' } }
const WAIT_UNTIL = { name: 'Bash', input: { command: 'n=0; until [ -f tmp/run.done ]; do sleep 10; n=$((n+1)); done' } }

async function drain(stream: AsyncGenerator<unknown, unknown, unknown>) {
  let step = await stream.next()
  while (step.done !== true) step = await stream.next()
  return step.value
}

type Seen = { effort: unknown; index: number }

// Stubs every hook the mod reaches, records the effort each request carried, and lets a test script which tools each
// step's answer claims to have called (so the following steps can be classified as polling or not).
function harness(on: TestOn, tools: Record<number, { name: string; input: unknown }[]> = {}, dotGit = '') {
  const seen: Seen[] = []
  let written = ''
  let writtenPath = ''
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sid' }))
  on('session.root', () => ({ value: '/work' }))
  on('fs.exists', () => ({ value: false }))
  on('fs.read', ($, e) => ({ value: e.path === '/work/.git' ? dotGit : '' }))
  on('fs.write', ($, e) => {
    written = e.text
    writtenPath = e.path
    return { value: undefined }
  })
  on('ui.status', () => ({ value: undefined }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('skill.prompt', ($, e) => ({ text: e.text }))
  on('turn.step', async function* ($, e) {
    seen.push({ effort: e.effort, index: e.index })
    yield { kind: 'text', index: 0, text: 'ok' }
    const toolUses = tools[e.index] ?? []
    return { turnId: e.turnId, index: e.index, answer: 'ok', toolUses, stopReason: toolUses.length ? 'tool_use' : 'end_turn', usage: USAGE }
  })
  const rows = () => written.trim().split('\n').filter(Boolean).map((l) => JSON.parse(l))
  return { seen, rows, steps: () => rows().filter((r) => r.event === 'step'), path: () => writtenPath }
}

test('judgment steps keep the session effort and are logged', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'plan it' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  expect(h.seen).toEqual([{ effort: 'xhigh', index: 0 }])
  const rows = h.rows()
  expect(rows.length).toBe(1)
  expect(rows[0]).toMatchObject({ event: 'step', lane: 'judgment', effortIn: 'xhigh', effortOut: 'xhigh', session: 'sid', answeredBy: 'claude-opus-5-5', commands: [] })
})

test('a mechanical skill expanded before the turn lowers effort until a judgment skill or the turn ends', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await $.turn.start({ turnId: 't', text: '/finish' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  await $.skill.prompt({ skill: 'auto', text: '# auto' })
  await drain($.turn.step({ ...STEP, index: 1, effort: 'xhigh' }))
  await $.skill.prompt({ skill: 'checkpoint', text: '# checkpoint' })
  await drain($.turn.step({ ...STEP, index: 2, effort: 'xhigh' }))
  await $.turn.complete({ turnId: 't', reason: 'answer', answer: 'done', durationMs: 5, isAborted: false })
  await $.turn.start({ turnId: 't2', text: 'next' })
  await drain($.turn.step({ ...STEP, turnId: 't2', index: 0, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['high', 'xhigh', 'high', 'xhigh'])
  expect(h.steps().map((r) => r.lane)).toEqual(['mechanical', 'judgment', 'mechanical', 'judgment'])
  expect(h.rows().filter((r) => r.event === 'skill').map((r) => [r.skill, r.lane])).toEqual([
    ['finish', 'mechanical'],
    ['auto', 'judgment'],
    ['checkpoint', 'mechanical'],
  ])
})

test('a subagent turn ending does not reset the main phase', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: '/finish' })
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await $.turn.complete({ turnId: 'sub', reason: 'answer', answer: 'done', durationMs: 5, isAborted: false, agentId: 'a1' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['high'])
})

test('the polling lane needs two wait-shaped steps in a row, then effort returns to the phase', async ($, on) => {
  const h = harness(on, { 0: [WAIT_LOOP], 1: [WAIT_UNTIL], 2: [WAIT_LOOP], 3: [{ name: 'Edit', input: {} }] })
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  for (const index of [0, 1, 2, 3, 4]) await drain($.turn.step({ ...STEP, index, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['xhigh', 'xhigh', 'low', 'low', 'xhigh'])
  expect(h.steps().map((r) => r.lane)).toEqual(['judgment', 'judgment', 'polling', 'polling', 'judgment'])
  expect(h.steps()[0]?.commands).toEqual([WAIT_LOOP.input.command])
})

test('a bookkeeping command outside a mechanical skill lowers only the next step', async ($, on) => {
  const h = harness(on, {
    0: [{ name: 'Bash', input: { command: '~/.claude/scripts/linear-post.sh comment BF-1 tmp/plan.md' } }],
    1: [{ name: 'Edit', input: {} }],
    2: [{ name: 'Bash', input: { command: 'git push -u origin feature/x' } }],
  })
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  for (const index of [0, 1, 2, 3]) await drain($.turn.step({ ...STEP, index, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['xhigh', 'high', 'xhigh', 'high'])
  expect(h.steps().map((r) => r.lane)).toEqual(['judgment', 'mechanical', 'judgment', 'mechanical'])
})

test('subagent requests are never rewritten or logged', async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh', agentId: 'agent-1' }))
  expect(h.seen).toEqual([{ effort: 'xhigh', index: 0 }])
  expect(h.steps()).toEqual([])
})

test('the kill switch leaves every step alone and writes nothing', { options: { enabled: false } }, async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  expect(h.seen).toEqual([{ effort: 'xhigh', index: 0 }])
  expect(h.rows()).toEqual([])
})

test('the per-turn cap holds the last effort once spent', { options: { max_switches_per_turn: 1 } }, async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await drain($.turn.step({ ...STEP, index: 1, effort: 'xhigh' }))
  await $.skill.prompt({ skill: 'auto', text: '# auto' })
  await drain($.turn.step({ ...STEP, index: 2, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['xhigh', 'high', 'high'])
})

test('custom efforts from userConfig apply per lane', { options: { judgment_effort: 'max', mechanical_effort: 'medium' } }, async ($, on) => {
  const h = harness(on)
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'xhigh' }))
  await $.skill.prompt({ skill: 'finish', text: '# finish' })
  await drain($.turn.step({ ...STEP, index: 1, effort: 'xhigh' }))
  expect(h.seen.map((s) => s.effort)).toEqual(['max', 'medium'])
})

test('an existing ledger is kept and appended to', async ($, on) => {
  let written = ''
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sid' }))
  on('session.root', () => ({ value: '/work' }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', () => ({ value: '{"index":9}\n' }))
  on('fs.write', ($, e) => {
    written = e.text
    return { value: undefined }
  })
  on('ui.status', () => ({ value: undefined }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.step', async function* ($, e) {
    yield { kind: 'text', index: 0, text: 'ok' }
    return { turnId: e.turnId, index: e.index, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: USAGE }
  })
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'go' })
  await drain($.turn.step({ ...STEP, index: 0, effort: 'high' }))
  expect(written.split('\n').filter(Boolean).length).toBe(2)
  expect(written.startsWith('{"index":9}\n')).toBe(true)
})

test('pure helpers classify skills, wait-shaped steps, and options', async () => {
  expect(phaseForSkill('finish')).toBe('mechanical')
  expect(phaseForSkill('reap-tmp')).toBe('mechanical')
  expect(phaseForSkill('quality-review')).toBe('judgment')
  expect(phaseForSkill('something-new')).toBe('judgment')
  expect(isWaitShaped([])).toBe(false)
  expect(isWaitShaped([{ name: 'Monitor', input: {} }])).toBe(true)
  expect(isWaitShaped([WAIT_LOOP])).toBe(true)
  expect(isWaitShaped([WAIT_UNTIL])).toBe(true)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'sleep 30' } }])).toBe(true)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'tail -f tmp/run.log' } }])).toBe(true)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'sleep 30' } }, { name: 'Read', input: {} }])).toBe(false)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'git status' } }])).toBe(false)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'grep -n wait scripts/reap-tmp.sh' } }])).toBe(false)
  expect(isWaitShaped([{ name: 'Bash', input: { command: 'ls tmp/wait-run.sh' } }])).toBe(false)
  expect(isMechanicalCommand([{ name: 'Bash', input: { command: 'git push origin main' } }])).toBe(true)
  expect(isMechanicalCommand([{ name: 'Bash', input: { command: '~/.claude/scripts/finish-commit.sh BF-1' } }])).toBe(true)
  expect(isMechanicalCommand([{ name: 'Bash', input: { command: 'scripts/mark-ready-for-release.sh BF-1' } }])).toBe(true)
  expect(isMechanicalCommand([{ name: 'Bash', input: { command: 'git status; git log -3' } }])).toBe(false)
  expect(isMechanicalCommand([{ name: 'Read', input: { file_path: 'scripts/linear-post.sh' } }])).toBe(false)
  expect(readOptions({ judgment_effort: 'bogus', max_switches_per_turn: 2.7 })).toEqual({
    enabled: true,
    map: { judgment: 'session', mechanical: 'high', polling: 'low' },
    cap: 2,
    ledger: true,
  })
  expect(owningCheckout('/w', null)).toBe('/w')
  expect(owningCheckout('/r/.claude/worktrees/bf-1', 'gitdir: /r/.git/worktrees/bf-1\n')).toBe('/r')
  expect(owningCheckout('/r/.claude/worktrees/bf-1', 'gitdir: ../../../.git/worktrees/bf-1\n')).toBe('/r')
  expect(owningCheckout('/r/sub', 'gitdir: ../.git/modules/sub\n')).toBe('/r/sub')
  expect(owningCheckout('C:/u/r/.claude/worktrees/bf-1', 'gitdir: C:/u/r/.git/worktrees/bf-1\r\n')).toBe('C:/u/r')
  expect(await dotGitOf(async () => { throw new Error('EISDIR') }, '/w')).toBe(null)
  expect(await dotGitOf(async (p) => `gitdir: ${p}`, '/w')).toBe('gitdir: /w/.git')
})

// The `.git` text is what `git worktree add` writes; the root is what a session resumed inside that worktree reports (the three
// 2026-10-10 fleet sessions, resumed at 14:22Z, wrote their later rows under the worktree until this resolution).
test('a session whose root is a linked worktree writes its ledger under the owning checkout', async ($, on) => {
  const h = harness(on, {}, 'gitdir: /main/.git/worktrees/bf-1\n')
  await $.session.start(SESSION)
  await $.turn.start({ turnId: 't', text: 'plan it' })
  await drain($.turn.step({ ...STEP, index: 0 }))
  expect(h.path()).toBe('/main/tmp/effort-ledger-sid.jsonl')
  expect(h.steps()).toHaveLength(1)
})
