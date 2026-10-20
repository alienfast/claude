# Agent Coordination Patterns

Tool selection and ordering, parallel file reads, search parallelization, retry logic, and context management are
handled without instruction. Specify coordination only where the model cannot infer the constraint from the task: real
dependencies between delegations, shared write targets, quality gates that must hold before the next phase starts.
Everything below is one of those cases.

## Background-agent completion reports

`run_in_background` is a parameter of the `Agent` tool. Subagents start in the background by default and deliver their
report in a completion notification; `run_in_background: false` blocks and returns the report as the tool result. When
the next step consumes the result (a review, a fix batch, an implementation), dispatch synchronously: there is nothing
to wait for. When it does not, leave the dispatch backgrounded and end the turn; the harness re-invokes you when it
finishes, and status probes meanwhile only burn context. When a notification arrives without a usable report, verify the
claimed output independently (read the diff, run the relevant checks), which is the orchestrator's job regardless, and
resume the agent with `SendMessage` and its id only if a question remains; never re-run the work on the strength of the
agent's own summary. A background shell task's stdout is read from the output file path its notification names;
`TaskOutput` is deprecated.

The enabled `spawn-policy` mod (`mods/spawn-policy/README.md`) applies the review tiers mechanically once the `auto`
skill has expanded or the spawn's permission mode is `auto`: it rewrites the `developer` agent's model to sonnet (the
verifier's to sonnet, the reviewer's to opus) and forces synchronous dispatch for main-loop spawns of
`quality-reviewer`, `quality-verifier` and `developer`. An orchestrator should expect those dispatches to block and
return whatever it passed for `run_in_background`; the ledger is `tmp/spawn-policy-<sessionId>.jsonl`.

## Cross-agent interface contracts

When two parallel agents build opposite sides of an interface (IPC command, HTTP endpoint, event or message shape), the
pinned contract MUST be an exact literal example of the wire payload, every wrapper key, every field name, and a concrete
typed value, plus the receiving signature. Never pin a prose type signature: each side resolves its ambiguity
differently, and each side's mocked unit tests then encode its own assumption as green. Pin
`{ "args": { "gameId": 13 } }` → `fn motion_start(args: MotionStartArgs)`, not "motion_start({ gameId: number })".

## Write-target exclusivity

Before dispatching a parallel batch, enumerate every file each delegation might write, including any file a prompt
merely *mentions* as optional or "consider also" work: the delegate may act on it. If two delegations in one batch can
write the same file, the batch has a lost-update hazard: one agent's `Read` may precede the other's `Write`, so a later
Edit based on a stale read clobbers the earlier one with no error and no merge conflict. Landing correctly is luck, not
safety by construction. Resolve it by scoping the optional mention out of the delegation that does not own the file,
making the two sequential, or bundling both pieces into one delegation.

**Read-only delegations are not exempt.** A reviewer's revert-based probe (edit a line out, run the tests, restore by
file copy) makes it a transient writer, and the resulting failures read as real defects. Tell each parallel read-only
agent in one tree that a red run or an unexpected diff may be a sibling's in-flight probe, to be re-checked before it is
reported and never attributed to a named session (`skills/quality-review/SKILL.md` § Step 3 carries the sentence).

**Write-capable delegates in one tree fail each other's exit gate.** Every `developer` runs the project check before it
reports, and a whole-tree check reads a sibling's half-written files as errors, so the second delegate's gate reddens on
files it never touched and "if it fails, fix it" aims it at files outside its write scope. Every write-capable dispatch
in a parallel batch therefore carries: *"Other delegates are editing this same tree. A red confined to files outside
your write scope is a sibling mid-edit: re-run the check once; if it stays red only there, report the files and the
errors as a sibling-in-flight red and stop. Never edit those files, and do not poll the tree to settle. Your own files
must still check clean."* Report-and-stop rather than poll, because the orchestrator owes the settled-tree check
regardless (§ Long-running commands below) and routes any red it finds to the delegate that owns the files.

**The orchestrator is a writer too.** A backgrounded dispatch keeps the turn, so an edit the orchestrator makes lands in
a tree the agent is reading live while the prompt it was handed (an inline diff, a quoted file, a snapshot passed by
path) still shows the old text. The agent then confirms text already replaced, or flags as a mismatch something fixed a
minute earlier, and the replacement is un-reviewed code anyway. Writing to `tmp/`, the tracker, or files no dispatch
named is free. Hold the files the dispatch named, every file in a supplied delta, until it returns; if an edit cannot
wait, state it in the next dispatch.

## Parallel delegations falsify each other's comments

Disjoint file sets are not sufficient for comments. A delegate writes comments true of the tree it can see; when a
sibling is concurrently changing the behaviour a comment asserts, the comment lands false and nothing catches it: a
comment cannot fail a type check, nothing prompts the delegate to re-read the sibling's files, and each delegate's own
check passes. Specific to *parallel* dispatch; a sequential delegation reads the landed state, and a delegate that checks
the machine first (`rules/comments.md`) still ships a false comment because the falsification happens after the check.

So when one change is split across concurrent delegations, sweep the delta's comments before review: for every comment
asserting how something behaves, ask whether a sibling changed that behaviour. The highest-risk shape is a comment
explaining *why* a defensive branch exists when the sibling's job was to change that very seam: the rationale inverts
while the code stays correct, so a reviewer sees working code and reads past the comment. `/quality-review` bars a
comment-accuracy audit as a new re-review lens, so the class is caught only here.

## Prohibitions in a delegation prompt

Two different things get written as "do NOT do X", and only one is safe as a blanket ban.

A **scope** prohibition bounds what this dispatch may touch (`/quality-review`'s "do NOT extract a new shared
abstraction to deduplicate them"). Those are legitimately categorical because they ship with a release valve: a delegate
that needs the excluded work stops and reports, and the orchestrator routes it.

A **correctness** prohibition ("X won't work here") fails as a blanket ban. Name the specific SHAPE that fails and why,
and say what a passing version looks like. A delegate cannot tell "this kind of X is useless here" from "no X" and
complies with the broader reading; when the right answer is a *different* X, the brief has foreclosed it, and the escape
hatch does not fire because a delegate that can comply by doing *less* never trips it. The check before shipping such a
line: can you name what a passing version looks like? If yes, name it. If no, state the goal and let the delegate choose
the shape. A ban on "a label-formatting helper as the test seam" forecloses the helper that returns both the id and the
label from one row; "the label and the id actually sent must be provably the same row; a formatting-only helper does not
achieve that" bans the useless shape and leaves the working one reachable.

## Long-running commands in delegations

If a delegated task includes a multi-minute command (a compile, an installer build, a dev-server smoke test), tell the
agent explicitly to run it synchronously with a long Bash timeout (up to 600000ms), or, if backgrounded, to poll its
output file within the same turn. A subagent that ends its turn "waiting for a background task" does not self-resume;
the orchestrator must notice the stall and re-message it.

**Past 600000ms there is no synchronous option, so don't delegate the command at all.** Exceeding the Bash ceiling does
not fail: the harness backgrounds the command and returns a task ID, so "run it in the foreground" silently becomes the
backgrounded case, and the agent strands either way. Keep the full test suite, the long build and the end-to-end run in
the orchestrator, which handles completion notifications normally; delegate the edit and give the agent only the
targeted checks that bound its own work (a single spec file, a type check), and say which, since an agent told to
"verify" reaches for the most complete check available.

**A stranded delegation leaves its command still running.** Before re-messaging or re-dispatching, confirm the original
process is gone (`pgrep -f`), and end it by process group rather than by its leader pid
([shell.md](shell.md#a-backgrounded-tool-task-is-a-process-group-kill-the-group-not-its-leader)); otherwise two runs
against one set of test databases, one dev-server port or one lock produce failures that read as real defects but are
contention.

## A write-capable delegation that dies mid-task leaves an unknown tree

A `developer` / `debugger` delegation can terminate early (an API error, a timeout, a session limit) after an arbitrary
number of edits, and whatever partial output the harness recovers is narration, not a filesystem record. Establish the
actual state before resuming or re-dispatching: `git status --porcelain` for what changed, and the project's check gate
for whether it still builds. Then route:

- **Nothing changed** → resume the same agent via `SendMessage` with the id from its spawn result; its context is intact,
  and re-dispatching would re-buy the reading it already paid for.
- **Partial work, gate green** → resume, or re-dispatch scoped to only what remains, telling the delegate what is
  already on disk.
- **Partial work, gate red** → restore green first; within `/start` and `/quality-review` the Working Application
  Contract makes that non-negotiable.

**Never re-dispatch the original prompt verbatim against a partially-edited tree.** It was composed for a clean one, so
the delegate double-applies or conflicts with work already there, silently. This is the trap in `/auto`'s
"transient API error → retry" policy: retrying is right, but the retry starts from the tree's real state. `/start`'s
idempotence covers the issue and the worktree, never a half-applied delegation's edits.

## `file:line` citations lifted from a subagent's report

A subagent that quotes source does not carry the source's line numbering with it: a persisted report read back shows
the **report's** numbers, and an inline report has none beyond what the agent asserted. A citation taken from it is
unanchored and fails in the way that survives review: a real file and a plausible range. Before a `file:line` goes into
anything durable (a Linear comment, a dispatch prompt, a commit message, a PR description), confirm it against the file
itself with `grep -n` or a Read of that range. In a *code* comment, cite no line number at all (`rules/comments.md`).

## Measure from the transcript before optimizing

When asked to optimize agent, skill or workflow latency, extract a measured timeline from the session transcript first:
`~/.claude/projects/<project-slug>/<session-uuid>.jsonl` timestamps every event. Compute tool-call durations against
inter-event gaps (model-turn time) and attribute the wall-clock before proposing fixes; intuition routinely blames
environment setup when the time went to a serial subagent or a long reasoning turn.
