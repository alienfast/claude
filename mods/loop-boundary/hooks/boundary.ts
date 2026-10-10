export type ToolUse = { readonly name: string; readonly input: unknown }

// The lines /auto ends an iteration with (skills/auto/SKILL.md). A heartbeat status check and a stalled turn end with
// none of them, which is what keeps an in-flight iteration's context intact.
const OUTCOME_LINE = /^[\s>*_`#-]*(SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE|SKIPPED-[A-Z]+(?:-[A-Z]+)*|BLOCKED-ON-REVIEW|AUTO-CONTINUE|NO-CANDIDATES|AUTO-HALTED)\b.*$/m

export function outcomeLineOf(answer: string): string | null {
  const m = OUTCOME_LINE.exec(answer)
  if (m === null) return null
  return m[0].replace(/^[\s>*_`#-]+/, '').replace(/[*_`]+/g, '').trim().slice(0, 200)
}

// `/loop 5m /auto epic:BF-1` re-fires `/auto epic:BF-1`; `/loop /auto` re-fires `/auto`. Anything else is its own prompt.
const LOOP_PROMPT = /^\/loop(?:\s+\d+(?:\.\d+)?\s*(?:s|m|h|d|sec|secs|min|mins|minutes?|seconds?|hours?|days?))?\s+([\s\S]*)$/i

export function loopPromptOf(text: string): string | null {
  const m = LOOP_PROMPT.exec(text.trim())
  return m === null ? null : (m[1] ?? '').trim()
}

export function matchesPrefix(prompt: string, prefixes: readonly string[]): boolean {
  const p = prompt.trim()
  return prefixes.some((prefix) => p === prefix || p.startsWith(`${prefix} `))
}

function inputOf(use: ToolUse): Record<string, unknown> {
  return typeof use.input === 'object' && use.input !== null ? (use.input as Record<string, unknown>) : {}
}

// The loop prompt a ScheduleWakeup call carries forward, or null when the call ends the loop or there is no such call. /auto re-arms
// with its whole `/loop /auto …` command, so the prompt is stripped the same way a typed one is before the prefix list sees it.
export function wakeupPromptOf(uses: readonly ToolUse[]): { prompt: string | null; stop: boolean } {
  let prompt: string | null = null
  let stop = false
  for (const use of uses) {
    if (use.name !== 'ScheduleWakeup') continue
    const input = inputOf(use)
    if (input.stop === true) stop = true
    else if (typeof input.prompt === 'string') prompt = loopPromptOf(input.prompt) ?? input.prompt.trim()
  }
  return { prompt, stop }
}

export function requestTokensOf(usage: unknown): number | null {
  if (typeof usage !== 'object' || usage === null) return null
  const u = usage as Record<string, unknown>
  const parts = [u.input_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens].filter((v): v is number => typeof v === 'number')
  return parts.length === 0 ? null : parts.reduce((a, b) => a + b, 0)
}

export function boundaryMessage(args: { outcome: string; runKey: string; statePath: string; stateExists: boolean }): string {
  const state = args.stateExists ? `run state in ${args.statePath}` : `no run-state file at ${args.statePath} yet`
  return [
    `Loop boundary: the previous /auto iteration ended with \`${args.outcome}\`.`,
    `Run key ${args.runKey}; ${state}. The conversation before this point was compacted away at the iteration boundary by the loop-boundary mod; /auto re-reads its state from that file and from Linear, and nothing from the earlier iteration is needed here.`,
  ].join('\n')
}

export type Options = {
  readonly enabled: boolean
  readonly prefixes: readonly string[]
  readonly minContextPercent: number
  readonly ledger: boolean
}

export function readOptions(raw: Readonly<Record<string, unknown>>): Options {
  const prefixes =
    typeof raw.loop_prefixes === 'string'
      ? raw.loop_prefixes
          .split(/[,\s]+/)
          .map((p) => p.trim())
          .filter((p) => p !== '')
      : []
  const min = raw.min_context_percent
  return {
    enabled: raw.enabled !== false,
    prefixes: prefixes.length > 0 ? prefixes : ['/auto'],
    minContextPercent: typeof min === 'number' && min > 0 ? Math.min(100, min) : 0,
    ledger: raw.ledger !== false,
  }
}
