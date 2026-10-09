import type { Register } from 'claude-code'

// One row per main-loop model request. `effortIn` is what the engine was about to send; `effortOut` is what this
// hook sent. The usage counts are what the API reported for that request, so a prefix rewrite shows up as
// cache_read collapsing and cache_creation jumping on the switched step relative to its neighbours.
type Row = {
  index: number
  effortIn: unknown
  effortOut: unknown
  model: string
  answeredBy: string | null
  usage: unknown
  toolUses: string[]
}

const rows: Row[] = []
let mode = 'switch'
let outPath = ''

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    mode = (await $.env.get('EFFORT_PROBE_MODE')) ?? 'switch'
    const out = await $.env.get('EFFORT_PROBE_OUT')
    const id = await $.session.id()
    outPath = out ?? `${await $.session.cwd()}/effort-probe-${mode}-${id}.jsonl`
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e)
    const switched = mode === 'switch' && e.index === 1
    const effortOut = switched ? 'low' : e.effort
    const result = yield* next(switched ? { ...e, effort: 'low' } : e)
    rows.push({
      index: e.index,
      effortIn: e.effort,
      effortOut,
      model: e.model,
      answeredBy: result.usage?.model ?? null,
      usage: result.usage,
      toolUses: result.toolUses.map((t) => t.name),
    })
    await $.fs.write(outPath, rows.map((r) => JSON.stringify(r)).join('\n') + '\n')
    return result
  })
}
