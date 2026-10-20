# Why the loop is shaped this way

Read from `/auto` when a rule in `SKILL.md` looks arbitrary and you are tempted to relax it.

## One issue per invocation, not an internal "keep going" loop

In-prose anti-stop scaffolding is the documented failure mode of autonomous macros. `/loop`'s wakeup machinery is the
reliable recurrence mechanism; the `full-continue.sh` Stop hook guards the intra-issue start→finish handoff, and
`auto-heartbeat.sh` guards the loop heartbeat the same way. This skill keeps its reliability in those hooks and in
`/loop`, not in prose — it composes the enforced pieces.

## Worktree mode is not optional

In-place mode leaves the checkout on issue N's branch, and `/start`'s "already on a non-`main` branch → stay on it"
rule would stack issue N+1 onto it — every subsequent issue cascading onto the first issue's branch. `wt` mode forks
each issue from the source branch and `/finish merge` folds it back, so successive issues chain correctly (each fork
sees the prior merges) with no stacking.

## Parallel sessions coordinate through shared state, never through each other

- **Linear is the claim registry.** `/next` offers only unstarted states (Backlog/Planned/Todo), so a claimed
  (In Progress) issue is invisible to every other session's pick. The residual race — two sessions taking the same
  top candidate before either claims — is closed at the git layer: `start-wt-create.sh` runs under the repo lock and
  refuses to reuse a worktree owned by a live other session, so exactly one wins and the loser exits `SKIPPED-BLOCKED`
  (a skip, not a failure).
- **Owner liveness distinguishes died from live.** Every `/start wt` stamps the owning harness PID and start time into
  the worktree identity; Step 1 resumes only a worktree whose owner is provably dead. Alive → a sibling's active work;
  unknown → parked for a human. Never resume on "In Progress + mine" alone.
  - The PID tier is harness-process-granular and fails in both directions under a fleet: a session that dies inside a
    still-live harness reads `alive` until that process exits, while a live fleet session can read `unknown` or `dead`
    (the pid walk resolves nothing when the pool chain is reparented to pid 1, and the shared fleet root's exit reads
    every sibling dead at once).
  - `wt-identity.sh` therefore probes the owner's session first: the daemon's per-session job dir answers at session
    granularity for background sessions, in both directions, until the session is deleted. `claude stop` and the
    daemon's own retire keep the dir with its terminal state; `claude rm` or a delete in the `claude agents` view
    removes it, and a fleet stamp's daemon pid then reads the owner `alive` until the daemon restarts.
    `start-wt-create.sh` fails closed on a foreign claim whose liveness stays `unknown`; the pid tier is the fallback
    for owners with no job dir (interactive sessions).
  - The `released` state closes the tail: Step 4's failure rows and Step 1's flagging release the stamp
    (`wt-disown.sh`) when they label, so a `stalled` issue is immediately resumable by any session even while the
    shared harness process lives on.
- **Run state is per-session** (`tmp/auto-state-<runKey>.json`): the lists and the circuit breaker are scoped to one
  session's run. Parallel runs have independent breakers — systemic breakage can cost up to 2× the failed attempts
  before both trip, which is accepted.
- **The merge queue is cross-session.** A `DEFERRED-MERGE` marker under `.claude/merge-queue/` gates resumption
  regardless of which session shipped the issue.

Interactive work alongside `/auto` belongs in a worktree — `/start interactive <ISSUE-ID>` exists for exactly this.
In-place work dirties the main checkout with no ownership stamp, so Step 1's preflight cannot distinguish it from a
died run's leftovers.

## Failure policy defaults

- **Skip, don't stall.** A single failed issue gets a Linear comment and preserved state (`/finish auto` never
  overrides its verdict gate; `/start auto` never reassigns or reopens); the loop tries the next candidate. One flaky
  issue must not end an overnight run. The one exception: a failed issue that leaves the main checkout dirty (Step 1
  check 1's `failed`-list branch) halts the run — the next candidate cannot start over someone's uncommitted failure
  without shipping it or destroying it, and `/auto` does neither.
- **Circuit breaker at 2.** Two consecutive failures usually mean something systemic (broken main, dead service,
  exhausted auth); more unattended attempts burn tokens and litter Linear. Any ship resets the counter; Step 0 makes
  the halt sticky across re-invocations.
- **Review blocks are exempt from the consecutive breaker.** `BLOCKED-ON-REVIEW` is the quality gate succeeding —
  work preserved, verdict documented, human flagged via `stalled`. Two in a row on distinct issues is normal on a hard
  backlog, not systemic breakage. They still count as failures everywhere else. What bounds them is the review-block
  cap: 4 per run, total not consecutive, never reset by ships — capping token burn under a broken reviewer and the
  pile of preserved-but-unmerged worktrees accumulating merge drift.
- **Transient API errors are exempt.** Infrastructure recovers on its own — retry on a delay, never count it, never
  halt for it — except a quota whose stated reset is materially beyond `ScheduleWakeup`'s 3600s ceiling, which is an
  environment halt (`api-failures.md`).
- **Conservative everywhere.** Every underlying `auto` default chooses abort/preserve over override/guess. The worst
  acceptable outcome of an unattended run is "nothing happened and Linear says why" — never "something wrong shipped."

## Why the pick-time rules look paranoid

- **Double-run before `drained`.** `next-candidates.sh` exits 0 on its no-workable-issues path both when the backlog is
  drained and when the `issues` query returned 200-OK with an empty or short `nodes` array (the fetch loop aborts only
  on an empty body, an `errors` key, or a non-zero CLI exit, which surface as exit 2). The two print identical text, and
  `drained` is sticky, so one transient empty would end an overnight run against an untouched backlog.
- **Holds are never `drained`.** A `PLANNED-HOLD` or `BLOCKED-HOLD` is an explicit verdict that the pool still holds
  work; latching `drained` on it forfeits every issue a sibling's ship would have released.
- **A live sibling's worktree is dropped at pick time.** A sibling stamps its worktree before `start-wt-verify.sh`
  claims the issue in Linear (tens of seconds later, behind a digest pre-fetch and a baseline capture), so Linear-state
  ranking cannot see the claim, and Step 3's locked create would only refuse, costing the whole iteration.
- **Parking beats dying.** A rate limit met between issues costs minutes — the parked wakeup fires after the reset.
  One met mid-issue kills the turn: StopFailure fires instead of Stop, no wakeup is armed, and the session waits on
  `hooks/auto-rewake.sh` (every 900s for up to six hours) with the killed turn's work redone — a kill can land mid
  non-idempotent step.
- **The deadline gate is prose backed by a hook.** `hooks/auto-deadline-gate.sh` refuses a `next-candidates.sh`
  invocation from a `/loop /auto` session once `deadline_epoch` has passed, because a session that read the marker on
  every earlier iteration can still skip the step. It fires only inside a `/loop /auto` session, so interactive
  `/next`, `/auto-prep`, `/fleet-status` and `/fleet-retro` — byte-identical commands — are unaffected, and targeted
  mode stays exempt.
- **`canceled` is its own list.** Recording cancellations in `shipped` overstates the run's tally against git, and every
  retro then re-derives it.
- **`mode` is written once.** A single run writes a ledger of the same shape as a loop's, so without the field nothing
  downstream can tell a targeted one-shot from a fleet member, and a retro's time window admits every stray session.
