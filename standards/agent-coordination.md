# Agent Coordination Patterns

Tool selection and ordering, parallel file reads, search parallelization, retry logic, and context
management are handled without instruction. Specify coordination only where the model cannot infer the
constraint from the task: real dependencies between delegations, shared write targets, quality gates
that must hold before the next phase starts. Everything below is one of those cases.

Delegate work that is genuinely independent and large enough to justify a fresh context. Delegation
multiplies cost on small tasks, and a subagent spawned to double-check another agent's reasoning
usually adds spend without adding signal — see [CLAUDE.md](../CLAUDE.md) "Delegation".

## Cross-agent interface contracts

When two parallel agents build opposite sides of an interface (IPC command, HTTP endpoint, event/message shape), the pinned contract MUST be an exact
literal example of the wire payload — every wrapper key, every field name, and a concrete typed value — plus the receiving signature. Never pin a prose
type signature: each side resolves its ambiguity differently, and each side's mocked unit tests then encode its own assumption as green.
Example: pin `{ "args": { "gameId": 13 } }` → `fn motion_start(args: MotionStartArgs)`, not "motion_start({ gameId: number })".

## Write-target exclusivity

Before dispatching a parallel batch, enumerate every file each delegation might write — not just its stated primary target, but any file a prompt merely *mentions* as
optional, bonus, or "consider also" work. An optional mention is still a write-target claim: the delegate may act on it. If two delegations in the same parallel batch
can write the same file, the batch has a latent lost-update hazard — one agent's `Read` may precede the other's `Write` landing, so a later Edit/Write based on a stale
read silently clobbers the earlier one, with no error and no merge conflict. Landing correctly is possible but is luck, not safety by construction: it depends on the
two agents' actual read/write timing, which the orchestrator does not control.

Before dispatch, confirm no two delegations in the batch share a write target. If they do:

- Scope the optional/bonus mention out of the delegation that doesn't exclusively own the file, or
- Make the two delegations sequential instead of parallel, or
- Bundle both pieces of work into a single delegation.

## Long-running commands in delegations

If a delegated task includes a multi-minute command (Rust/C++ compile, installer build, dev-server smoke test), tell the agent explicitly to run it
synchronously with a long Bash timeout (up to 600000ms) — or, if backgrounded, to poll its output file within the same turn. A subagent that ends its
turn "waiting for a background task/Monitor" does not self-resume — the orchestrator must notice the stall and re-message it, which stalls the whole run.

## Background-agent completion reports

A background agent's completion often surfaces as a bare idle notification — the substantive report may arrive late, separately, or not at all. When delegating to background agents:

- Instruct the agent in its prompt that its final action must be to SendMessage its completion report to the orchestrator ("main") — do not rely on the idle notification to carry findings. A named teammate's turn-final text is silently discarded, not delivered — an agent that "returns" its report as plain text has delivered nothing, and goes idle believing it replied.
- On an idle notification with no report, pull before pinging: `TaskOutput` on the agent usually shows the report sitting in its transcript as undelivered turn-final text. If the transcript has no report either, ping the agent once for it rather than re-running the work; if it stays silent after a couple of pings, don't block the session indefinitely — independently verify its claimed output (read the diff, re-run the relevant tests/checks) and proceed.
- Never end a turn passively "waiting" after an idle notification has arrived — it is the only push signal the harness sends for that agent, so nothing further will wake the session. Recover actively within the turn: TaskOutput, then one ping, then independent verification.
- For small verification tasks, prefer synchronous delegation (`run_in_background: false`) — the report returns directly as the tool result, avoiding the loss window entirely.
- **Omit `name` for one-shot dispatches you need back this turn** (adversarial review, exploration, planning). Passing `name` makes the agent an addressable, resumable teammate — its termination can surface as a bare idle notification with no recoverable findings, and pinging an already-terminated named agent does not recover the content (the remedy above doesn't rescue this case). Reserve `name` exclusively for agents you deliberately intend to resume across multiple conversation turns; unnamed one-shot Agent calls reliably return findings via the standard background-task pattern (an `output_file` plus a completion notification).

## Measure from the transcript before optimizing

When asked to optimize agent/skill/workflow latency, extract a measured timeline from the session transcript first — `~/.claude/projects/<project-slug>/<session-uuid>.jsonl` timestamps every event. Compute tool-call execution durations vs inter-event gaps (model-turn time) and attribute the wall-clock before proposing fixes: cost-profile intuition routinely misattributes it (e.g. blaming environment setup when the time went to a serial subagent or a long reasoning turn).
