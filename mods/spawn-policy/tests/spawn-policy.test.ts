import { expect, test, type TestBody } from 'claude-code/testing'
import { decide, dotGitOf, isCompliant, owningCheckout, readOptions } from '../hooks/policy'

type TestOn = Parameters<TestBody>[1]

const BASE = {
  tool_use_id: 'tu',
  prompt: 'do the thing',
  description: 'a task',
  provider: { plugin: 'engine', tier: 'core' },
  parentModel: 'claude-opus-5-5',
  background: false,
  fork: false,
} as const

type Spawned = { model?: string; background: boolean; subagentType: string }

function harness(on: TestOn, dotGit = '') {
  const spawned: Spawned[] = []
  const logs: string[] = []
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
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('skill.prompt', ($, e) => ({ text: e.text }))
  on('agent.spawn', ($, e) => {
    spawned.push({ model: e.model, background: e.background, subagentType: e.subagentType })
    return { model: e.model ?? e.parentModel, agentId: 'a1' }
  })
  return { spawned, logs, rows: () => written.trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)), path: () => writtenPath }
}

// The `.git` text is what `git worktree add` writes; the root is what a session resumed inside that worktree reports (the three
// 2026-10-10 fleet sessions, resumed at 14:22Z, wrote their later rows under the worktree until this resolution).
test('a session whose root is a linked worktree writes its ledger under the owning checkout', async ($, on) => {
  const h = harness(on, 'gitdir: /main/.git/worktrees/bf-1\n')
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.skill.prompt({ skill: 'auto', text: '# auto' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', permissionMode: 'default' })
  expect(h.path()).toBe('/main/tmp/spawn-policy-sid.jsonl')
  expect(h.rows()).toHaveLength(1)
})

test('an unpinned developer spawn runs on sonnet once the auto skill has run', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.skill.prompt({ skill: 'auto', text: '# auto' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', permissionMode: 'default' })
  expect(h.spawned).toEqual([{ model: 'sonnet', background: false, subagentType: 'developer' }])
  expect(h.rows()[0]).toMatchObject({ type: 'developer', modelIn: null, modelOut: 'sonnet', rules: ['model:developer->sonnet'], enforced: true, resolvedModel: 'sonnet' })
  expect(h.logs).toEqual(['rewrote developer: model:developer->sonnet'])
})

test('a developer spawn naming opus is moved to sonnet when the permission mode is auto', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', model: 'opus', permissionMode: 'auto' })
  expect(h.spawned[0]?.model).toBe('sonnet')
})

test('interactively the same spawn is untouched and logged', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', model: 'opus', permissionMode: 'default' })
  expect(h.spawned).toEqual([{ model: 'opus', background: false, subagentType: 'developer' }])
  expect(h.rows()[0]).toMatchObject({ modelIn: 'opus', modelOut: 'opus', enforced: false })
  expect(h.logs).toEqual(['would rewrite developer: model:developer->sonnet'])
})

test('a background reviewer dispatch from the main loop becomes synchronous', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'quality-reviewer', model: 'opus', background: true, permissionMode: 'auto' })
  expect(h.spawned).toEqual([{ model: 'opus', background: false, subagentType: 'quality-reviewer' }])
  expect(h.rows()[0]).toMatchObject({ rules: ['sync:quality-reviewer'], backgroundIn: true, backgroundOut: false })
})

test('a fork, a compliant verifier, and an unknown agent type pass through without a row', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'fork', fork: true, permissionMode: 'auto' })
  await $.agent.spawn({ ...BASE, subagentType: 'quality-verifier', model: 'claude-sonnet-5-5', permissionMode: 'auto' })
  await $.agent.spawn({ ...BASE, subagentType: 'Explore', background: true, permissionMode: 'auto' })
  expect(h.spawned.map((s) => s.model)).toEqual([undefined, 'claude-sonnet-5-5', undefined])
  expect(h.spawned[2]?.background).toBe(true)
  expect(h.rows()).toEqual([])
})

test('a developer spawned by a subagent gets the model rule but not the sync rule', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', background: true, parentAgentId: 'p1', permissionMode: 'auto' })
  expect(h.spawned).toEqual([{ model: 'sonnet', background: true, subagentType: 'developer' }])
  expect(h.rows()[0].rules).toEqual(['model:developer->sonnet'])
})

test('enforce never only logs; enforce always rewrites interactively', { options: { enforce: 'never' } }, async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', permissionMode: 'auto' })
  expect(h.spawned[0]?.model).toBe(undefined)
  expect(h.rows()[0]).toMatchObject({ enforced: false })
})

test('enforce always rewrites in an interactive session', { options: { enforce: 'always', developer_model: 'haiku' } }, async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.agent.spawn({ ...BASE, subagentType: 'developer', permissionMode: 'default' })
  expect(h.spawned[0]?.model).toBe('haiku')
})

test('pure helpers: compliance, decisions, and options', async () => {
  expect(isCompliant(undefined, 'sonnet')).toBe(false)
  expect(isCompliant('claude-sonnet-5-5', 'sonnet')).toBe(true)
  expect(isCompliant('opus[1m]', 'opus')).toBe(true)
  const policy = readOptions({}).policy
  expect(decide({ subagentType: 'developer', background: true, fork: false }, policy)).toEqual({ model: 'sonnet', background: false, rules: ['model:developer->sonnet', 'sync:developer'] })
  expect(decide({ subagentType: 'developer', background: true, fork: false, workflow: { runId: 'r', agentIndex: 0 } }, policy)).toEqual({ rules: [] })
  expect(decide({ subagentType: 'developer', background: true, fork: false, isTeammate: true }, policy)).toEqual({ rules: [] })
  expect(readOptions({ enforce: 'bogus', sync_review_dispatch: false }).enforce).toBe('auto')
  expect(readOptions({ sync_review_dispatch: false }).policy.syncReview).toBe(false)
  expect(owningCheckout('/w', null)).toBe('/w')
  expect(owningCheckout('/r/.claude/worktrees/bf-1', 'gitdir: /r/.git/worktrees/bf-1\n')).toBe('/r')
  expect(owningCheckout('/r/.claude/worktrees/bf-1', 'gitdir: ../../../.git/worktrees/bf-1\n')).toBe('/r')
  expect(owningCheckout('/r/sub', 'gitdir: ../.git/modules/sub\n')).toBe('/r/sub')
  expect(owningCheckout('C:/u/r/.claude/worktrees/bf-1', 'gitdir: C:/u/r/.git/worktrees/bf-1\r\n')).toBe('C:/u/r')
  expect(await dotGitOf(async () => { throw new Error('EISDIR') }, '/w')).toBe(null)
  expect(await dotGitOf(async (p) => `gitdir: ${p}`, '/w')).toBe('gitdir: /w/.git')
})
