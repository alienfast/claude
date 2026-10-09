import type { Register } from 'claude-code'

// Measures the premises loop-boundary rests on. The first attempt called $.session.compact() from the prompt.submit
// hook of the next prompt; the engine's host check refuses that ("it would compact under the turn this hook is holding;
// call it from a later event (turn.complete)", measured 2026-10-09 in the plugin test harness), so the compaction is
// called from the main loop's turn.complete instead, after every turn but the first. One row per submitted prompt (its
// origin and whether a turn was running) and one per compaction attempt (accepted, skipped or rejected; whether this
// plugin's own session.compact hook saw the compaction it triggered; context before and after).
type Row = Record<string, unknown>

const rows: Row[] = []
let outPath = ''
let prompts = 0
let compacting = false
let ownHookSaw = false

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const out = await $.env.get('LOOP_PROBE_OUT')
    outPath = out ?? `${await $.session.cwd()}/tmp/loop-boundary-probe-${await $.session.id()}.jsonl`
    return next(e)
  })

  on('session.compact', async ($, e, next) => {
    if (e.trigger === 'plugin' && compacting) ownHookSaw = true
    // The engine always hands a transcript; the plugin test harness hands none for a compaction a hook started.
    return next(Array.isArray(e.messages) && e.messages.length > 0 ? e : { ...e, messages: [{ role: 'user', text: '(probe)', toolUses: [] }] })
  })

  on('prompt.submit', async ($, e, next) => {
    prompts += 1
    rows.push({ ts: new Date().toISOString(), event: 'prompt', index: prompts - 1, origin: e.origin, turnRunning: e.turnId !== undefined, text: e.text.slice(0, 80) })
    await $.fs.write(outPath, rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || prompts < 2) return result
    const row: Row = { ts: new Date().toISOString(), event: 'compact', turnId: e.turnId, reason: e.reason, answer: e.answer.slice(0, 80) }
    row.contextBefore = (await $.session.usage()).context
    compacting = true
    ownHookSaw = false
    try {
      const compacted = await $.session.compact({ instructions: 'Keep one line: this conversation is a compaction probe.' })
      row.compact =
        compacted.skip !== undefined
          ? { skipped: compacted.skip }
          : { accepted: true, messages: compacted.messages.length, tokensBefore: compacted.tokensBefore ?? null, tokensAfter: compacted.tokensAfter ?? null }
    } catch (err) {
      row.compact = { rejected: String(err) }
    }
    compacting = false
    row.ownHookSaw = ownHookSaw
    row.contextAfter = (await $.session.usage()).context
    rows.push(row)
    await $.fs.write(outPath, rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
    return result
  })
}
