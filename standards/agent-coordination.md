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

**Read-only delegations are not exempt.** A reviewer's prompt names no write targets, so the enumeration above returns empty for it — yet a revert-based probe (edit a
line out, run the tests, restore by file copy) makes it a transient writer anyway, and the resulting failures read as real defects. Parallel read-only agents in one
tree need the mitigation from the observer's side: tell each that a red run or an unexpected diff may be a sibling's in-flight probe, to be re-checked before it is
reported and never attributed to a named session (`skills/quality-review/SKILL.md` § Step 3 carries the dispatch sentence).

**The orchestrator is a writer too.** The enumeration above pairs delegations against each other; the third pair is the orchestrator against its own
in-flight agent. A dispatch launches asynchronously and the orchestrator keeps the turn, so an edit it makes lands in a tree the agent is reading live —
while the prompt the agent was handed (an inline diff, a quoted file, a precomputed snapshot passed by path) still shows the old text. The agent then
reports against neither: it may confirm text you have already replaced, or flag as a mismatch something you fixed a minute earlier. That mismatch is not
itself a finding and costs a round-trip to adjudicate — but the replacement is un-reviewed code the agent is reading anyway, so a defect in it is a real
finding at its real severity. The window is easy to walk into because the wait is exactly when re-reading your own just-landed edits turns one up: in
BF-1056 a comment correction landed on a policy file 2m19s into a 10m44s `quality-verifier` re-review, and the verifier spent a report paragraph
reconciling the tree against the diff it was given.

Writing to `tmp/`, the tracker, or files no dispatch named is free. Hold the files the dispatch named — every file in a supplied delta, whether inlined
or passed by path — until it returns. If an edit genuinely cannot wait, state it in the next dispatch rather than leaving the agent to discover it.

## Long-running commands in delegations

If a delegated task includes a multi-minute command (Rust/C++ compile, installer build, dev-server smoke test), tell the agent explicitly to run it
synchronously with a long Bash timeout (up to 600000ms) — or, if backgrounded, to poll its output file within the same turn. A subagent that ends its
turn "waiting for a background task/Monitor" does not self-resume — the orchestrator must notice the stall and re-message it, which stalls the whole run.

**Past 600000ms there is no synchronous option, so don't delegate the command at all.** That is the Bash tool's ceiling, and exceeding it does not fail — the harness
moves the command to the background and returns a task ID, so "run it in the foreground" silently becomes the backgrounded case above, leaving only the fragile
poll-in-turn path. An agent told to run a suite longer than the ceiling strands whichever way it is instructed, returning no report mid-task. Keep the full test
suite, the long build, and the end-to-end run in the orchestrator, which handles background completion notifications normally; delegate the edit and give the agent
only the targeted checks that bound its own work (a single spec file, a type check). Say which in the dispatch — an agent told to "verify" reaches for the most
complete check available. (`/start` Step 8 already assigns verification to the orchestrator, and its Step 5 rule 1 says the same for suites outside `pnpm check`.)

**A stranded delegation leaves its command still running.** Before re-messaging or re-dispatching, confirm the original process is gone (`pgrep -f`) — otherwise the
retry runs concurrently with it, and two runs against one set of test databases, one dev-server port, or one lock produce failures that read as real defects but are
pure contention.

## Background-agent completion reports

A background agent's completion often surfaces as a bare idle notification — the substantive report may arrive late, separately, or not at all. When delegating to background agents:

- Instruct the agent in its prompt that its final action must be to SendMessage its completion report to the orchestrator ("main") — do not rely on the idle notification to carry findings. A named teammate's turn-final text is silently discarded, not delivered — an agent that "returns" its report as plain text has delivered nothing, and goes idle believing it replied.
- On an idle notification with no report, recover by task type — **not** with `TaskOutput`, which is deprecated ("Deprecated `TaskOutput` tool in favor of using `Read` on the background task's output file path"). For a **background shell** task, `Read` the output file path carried in the tool result and the `<task-notification>`: it is plain stdout/stderr and is the supported replacement. For a **subagent** (`local_agent`) there is no pull path at all — the tool description directs you to the `Agent` tool result, which a *backgrounded* dispatch does not have (its result was `Async agent launched successfully …`), and explicitly says NOT to `Read` the `.output` file, because that path is a symlink to the full JSONL conversation transcript and will overflow the context window. So the only route is the ping: `SendMessage` the agent's id once and ask for the report itself. **Treat a confident non-report as failure exactly like silence** — an agent replying "my report already stands" is describing its own transcript, which you cannot see and which was never delivered; do not accept it, and do not re-run the work on the strength of it. After one ping, stop pulling and independently verify the claimed output (read the diff, re-run the relevant tests/checks) — that verification is the orchestrator's job regardless, and in the observed case it was what actually closed the stall, turning a missing report into a verification task rather than a redo.
- Never end a turn passively "waiting" after an idle notification has arrived — it is the only push signal the harness sends for that agent, so nothing further will wake the session. Recover actively within the turn: one ping, then independent verification.
- **Before** a notification arrives, the opposite applies: end the turn rather than filling it with no-op tool calls. Something always wakes the session — an unnamed one-shot dispatch returns its report in a completion notification (the omit-`name` bullet below), and a named agent that dies silently still produces the idle notification the bullet above is written for — so repeated status probes (re-running `git status`, re-grepping a log still being written) buy nothing and burn context while the agent works. The rule above is scoped to the *post*-notification case, where the push signal has already been spent; it is not licence to poll while work is still in flight. Narrating what you're waiting on in prose is free; a tool call that only says it is not. Under self-paced `/loop`, ending the turn still means re-arming whatever long fallback heartbeat the skill prescribes — the agent's task notification is the real wake signal, but polling is not a substitute for the timer either.
- For small verification tasks, prefer synchronous delegation (`run_in_background: false`) — the report returns directly as the tool result, avoiding the loss window entirely. **The parameter is feature-flagged on `Agent`, so this is conditional**: where the tool does not expose it, every dispatch backgrounds no matter what you pass, and the bullet above — end the turn, let the completion notification wake you — is the normal path rather than the fallback. Key off the tool result (`Async agent launched successfully …` in place of the report), never the schema, which cannot discriminate: one harness context omits the parameter precisely *because* only synchronous subagents are supported, so absence means the opposite there. Passing it where the schema omits it is silently accepted despite `additionalProperties: false` and has no effect, but it does not corrupt the census: `scripts/fleet-metrics.py` censuses at result time, and a typed `false` alongside an `Async agent launched successfully` result lands in the **`ignored`** bucket — the per-dispatch signal that this session ran on a harness without `run_in_background`, surfaced in the report as `<n> ignored (run_in_background absent on harness)`. The one place typed intent is trusted is `_census_dispatch_typed`, the fallback for dispatches whose result cannot testify (errored or dangling), where `false` does count as sync — so an errored dispatch carrying the parameter is the only shape that misreports.
- **Omit `name` for one-shot dispatches you need back this turn** (adversarial review, exploration, planning). Passing `name` makes the agent an addressable, resumable teammate — its termination can surface as a bare idle notification with no recoverable findings, and pinging an already-terminated named agent does not recover the content (the remedy above doesn't rescue this case). Reserve `name` exclusively for agents you deliberately intend to resume across multiple conversation turns; unnamed one-shot Agent calls reliably return findings via the standard background-task pattern (an `output_file` plus a completion notification).

## `file:line` citations lifted from a subagent's report

A subagent that quotes source back to you does not carry the source's line numbering with it. Persist a long report and Read it back and the numbers
you see are the **report's** — `cat -n` over the report file, not over the file it quotes. Inline, there are no line numbers at all beyond whatever the
agent asserted. Either way a citation taken from the report is unanchored, and it fails in the way that survives review: a real file and a plausible range.

**Before a `file:line` goes into anything durable** — a Linear comment, a dispatch prompt, a commit message, a PR description — confirm it against the
file itself (`grep -n`, or a Read of that range). One call. Citing loosely inside your own reasoning is fine; the rule is about what you write down for
someone else. (In a *code* comment, don't cite a line number at all — it moves; see `rules/comments.md`.)

In BF-617 an orchestrator relayed `tenant_paying_agent_access_spec.rb:271-278` into a Linear plan comment and a `developer` dispatch. 271 was where the
report quoted that example; the file is 171 lines, so the cited range does not exist. The delegate caught it after the comment was already posted.

## Measure from the transcript before optimizing

When asked to optimize agent/skill/workflow latency, extract a measured timeline from the session transcript first — `~/.claude/projects/<project-slug>/<session-uuid>.jsonl` timestamps every event. Compute tool-call execution durations vs inter-event gaps (model-turn time) and attribute the wall-clock before proposing fixes: cost-profile intuition routinely misattributes it (e.g. blaming environment setup when the time went to a serial subagent or a long reasoning turn).
