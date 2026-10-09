import type { Register } from 'claude-code'
import { decide, readOptions } from './policy'

let autonomous = false
let sessionId = ''
let ledgerPath = ''
let rows: string[] = []

export const register: Register = (on, options) => {
  const opts = readOptions(options)

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    if (opts.ledger) {
      ledgerPath = `${await $.session.root()}/tmp/spawn-policy-${sessionId}.jsonl`
      if (await $.fs.exists(ledgerPath)) rows = (await $.fs.read(ledgerPath)).split('\n').filter((line) => line !== '')
    }
    return next(e)
  })

  on('skill.prompt', { skill: 'auto' }, async ($, e, next) => {
    autonomous = true
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const decision = decide(e, opts.policy)
    if (decision.rules.length === 0) return next(e)
    const enforced = opts.enforce === 'always' || (opts.enforce === 'auto' && (autonomous || e.permissionMode === 'auto'))
    const modelOut = enforced && decision.model !== undefined ? decision.model : e.model
    const backgroundOut = enforced && decision.background === false ? false : e.background
    const verb = enforced ? 'rewrote' : 'would rewrite'
    $.ui.log(`${verb} ${e.subagentType}: ${decision.rules.join(', ')}`)
    const rewritten = { ...e, background: backgroundOut }
    const result = await next(!enforced ? e : modelOut === undefined ? rewritten : { ...rewritten, model: modelOut })
    if (opts.ledger) {
      rows.push(
        JSON.stringify({
          ts: new Date().toISOString(),
          session: sessionId,
          type: e.subagentType,
          description: e.description,
          modelIn: e.model ?? null,
          modelOut: modelOut ?? null,
          backgroundIn: e.background,
          backgroundOut,
          rules: decision.rules,
          enforced,
          parentAgentId: e.parentAgentId ?? null,
          resolvedModel: result.model,
        }),
      )
      await $.fs.write(ledgerPath, rows.join('\n') + '\n')
    }
    return result
  }).catch(($, e, next) => next(e))
}
