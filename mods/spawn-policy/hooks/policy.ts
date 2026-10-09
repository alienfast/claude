export type Spawn = {
  readonly subagentType: string
  readonly model?: string
  readonly background: boolean
  readonly fork: boolean
  readonly isTeammate?: true
  readonly workflow?: unknown
  readonly parentAgentId?: string
}

export type Policy = {
  readonly models: Readonly<Record<string, string>>
  readonly syncTypes: ReadonlySet<string>
  readonly syncReview: boolean
}

export type Decision = {
  readonly model?: string
  readonly background?: false
  readonly rules: readonly string[]
}

// An alias (`sonnet`) is compliant with itself and with any id or bracketed form that carries it (`claude-sonnet-5-5`,
// `opus[1m]`); an unset model is never compliant, because the agent definition's own pin then decides (developer.md pins opus).
export function isCompliant(given: string | undefined, want: string): boolean {
  return given !== undefined && (given === want || given.includes(want))
}

export function decide(e: Spawn, policy: Policy): Decision {
  if (e.fork || e.isTeammate === true || e.workflow !== undefined) return { rules: [] }
  const rules: string[] = []
  let model: string | undefined
  let background: false | undefined
  const want = policy.models[e.subagentType]
  if (want !== undefined && !isCompliant(e.model, want)) {
    model = want
    rules.push(`model:${e.subagentType}->${want}`)
  }
  if (policy.syncReview && e.background && e.parentAgentId === undefined && policy.syncTypes.has(e.subagentType)) {
    background = false
    rules.push(`sync:${e.subagentType}`)
  }
  return background === false ? { model, background, rules } : { model, rules }
}

export type Enforce = 'auto' | 'always' | 'never'

export type Options = {
  readonly enforce: Enforce
  readonly policy: Policy
  readonly ledger: boolean
}

const REVIEW_TYPES = ['quality-reviewer', 'quality-verifier', 'developer'] as const

function str(value: unknown, fallback: string): string {
  return typeof value === 'string' && value !== '' ? value : fallback
}

export function readOptions(raw: Readonly<Record<string, unknown>>): Options {
  const enforce = raw.enforce
  return {
    enforce: enforce === 'always' || enforce === 'never' ? enforce : 'auto',
    policy: {
      models: {
        developer: str(raw.developer_model, 'sonnet'),
        'quality-verifier': str(raw.verifier_model, 'sonnet'),
        'quality-reviewer': str(raw.reviewer_model, 'opus'),
      },
      syncTypes: new Set(REVIEW_TYPES),
      syncReview: raw.sync_review_dispatch !== false,
    },
    ledger: raw.ledger !== false,
  }
}
