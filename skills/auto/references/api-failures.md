# Transient API failures, re-entry, and recovery

Read from `/auto` when a tool call or dispatched agent fails on infrastructure, when a wakeup re-delivers the skill
mid-iteration, or when a recovery prompt (a human's, or an `auto-rewake:` reminder) arrives.

## What counts as transient

- A Claude API error from any tool call or delegated agent: overload (529), rate limit (429), transient 5xx.
- Linear's rate limit: `/next` exiting 4 with `RATELIMITED`, or any linear-cli call answering `Rate limit exceeded`.
  The per-user request window is shared by every session on the machine, and a ranking re-run on the spot spends it
  again — never re-rank immediately.
- Another service's plainly transient failure: `linear-cli` returning `HTTP 5xx` / `Service Unavailable`, or a
  timeout. Probe once (`linear-cli issues get <ISSUE-ID>`), retry, record no outcome.
- A terminal tag from a dispatched skill whose cause is one of the above — a `/start` auto-mode
  `BLOCKED-ON-REVIEW: <ISSUE-ID> — claim update failed (linear-cli error)` whose stderr shows a 5xx. Re-dispatch the
  same `/full auto wt <ISSUE-ID>` (idempotent on the issue and its worktree) instead of applying Step 4's failure row,
  which would post a failure comment and `stalled` label on a healthy issue and burn a `reviewBlocks` slot.

Authentication, permission, and unknown-state-name failures are not transient and keep their documented handling.

## Handling

Infrastructure, not an issue failure: never count it toward `consecutiveFailures`, never mark the issue failed, never
emit `AUTO-HALTED` for it (one carve-out below).

1. Retry with a short delay, respecting a `Retry-After` header or stated reset time when one is given.
2. If retries keep failing, fall back to a 15-minute wake-and-retry cadence: under self-paced `/loop`, end the turn
   with a ~900s `ScheduleWakeup` and resume the same iteration on wake; under fixed-interval `/loop`, end the turn and
   let the next interval retry.
3. A retry turn still ends on a tagged line:
   - mid-issue: `AUTO-CONTINUE: <ISSUE-ID> paused mid-issue (Claude API <error>); retrying in ~15m.`
   - before a pick (Step 0/1/2, `/next` included):
     `AUTO-CONTINUE: paused pre-pick (Claude API <error> | Linear RATELIMITED); retrying in ~15m.`
4. The next iteration resumes where it left off: Step 1's preflight routes back into the same issue (`/start` and
   `/full` are idempotent on it).

## A reset beyond the wakeup ceiling is an environment halt

`ScheduleWakeup` clamps `delaySeconds` to [60, 3600]. An error stating a reset hours or days out (a weekly or
multi-day quota) cannot be waited on: the 900s cadence would fire futile wakeups against the same limit, and a
multi-day block sits inside the dynamic loop's 7-day age-out. When the stated reset is materially beyond 3600s:

1. **Re-test first.** This halt is sticky (Step 0) and ends the loop, so it is owed a current reading, and a quota error
   already in your context is stale the moment anything sat between it and now — a turn boundary, a wake, a resumption
   after silence (a resumption is positive evidence the condition may have lifted, never continuity). Spend one trivial
   call (a `Bash` `echo`, a one-line `Agent`) and halt only if that call fails on quota.
2. Set `status: "halted"` with a `reason` and emit
   `AUTO-HALTED: Claude API quota exhausted (resets <stated time>) — wait for the reset, then delete tmp/auto-state-<runKey>.json and re-invoke /auto.`
   Under self-paced `/loop`, pair it with `ScheduleWakeup(stop: true)`.
3. It is still not an issue failure: record no outcome, leave `consecutiveFailures` and `reviewBlocks` untouched, and
   leave the issue In Progress with its worktree and branch intact. Follow the failure rows' ordering minus the label:
   post a Linear comment naming the block and the reset time, release the worktree stamp
   (`~/.claude/scripts/wt-disown.sh <main-checkout>/.claude/worktrees/<issue-id-lowercased>`, best-effort), then write
   the state file. Without the release the stamp reads `alive` for this harness process's lifetime, so Step 1 skips
   the worktree, Step 2 drops the candidate, and `start-wt-create.sh` refuses — the resume path the comment advertises
   would be blocked by the stamp itself. Do not apply `stalled`; that marker is for pipeline failures.
4. After the reset a human deletes the state file and re-invokes; `/start` and `/full` are idempotent on the issue, so
   a fresh `/loop /auto` or a targeted `/auto <ISSUE-ID>` resumes it.

## Heartbeat re-entry mid-iteration

Under self-paced `/loop`, a fallback wakeup may re-deliver this skill while the current iteration's delegated work is
still in flight in this session. That re-entry is a status check, not a new iteration:

- Check on the in-flight work (ping stalled agents, verify state), re-arm the fallback at 1200–1800s — the delegated
  `Agent` call's task notification is the real wake signal, not the timer; this is not the 60s `AUTO-CONTINUE` tick —
  and end the turn on that call.
- Do not run Step 0's re-anchor or `ExitWorktree`: the in-flight iteration is registered on its worktree, and releasing
  that registration guard-blocks its outstanding `developer` writes. `ExitWorktree` is safe only at a true iteration
  boundary, with no delegated work live.
- Do not re-run preflight, dispatch `/next`, or treat the in-progress worktree as orphaned — Step 1's resumption path
  is for a new invocation after a died iteration, not one still running here.

## Stall recovery on re-entry

When re-entry finds no delegated work in flight and no iteration tag yet, the previous turn stalled — it ended without
a tool call (an announced-but-unmade dispatch, or an inner skill's closing message obeyed as a turn end). Resume the
iteration exactly where the transcript left off: make the missing dispatch, or, if `/full`'s terminal tag was already
emitted, go straight to Step 4. This recovery, not the status check, is the heartbeat's primary purpose.

## A human prompt recovers the iteration, not just the issue

When an operator prompts a stalled run forward ("limit lifted, complete this issue"), completing and verifying the
issue is not the end: run Step 4 — record the outcome, end on a terminal status or wakeup — before reporting back.
A bare "finish your issue" is that same resume; the loop's own gates (the fleet deadline, Step 2) decide whether
another pick follows. When the operator's words do end the loop ("stop after this one", "finish it and stop"),
`ScheduleWakeup(stop: true)` alone is wrong: write `status: "halted"` with the instruction as `reason` first, or the
ledger reads `active` and `/fleet-status` shows a finished session as live. Nothing mechanical re-drives this:
`hooks/auto-heartbeat.sh` stands down after a human message (`human-override` — it must not fight an operator
mid-decision), so the bookkeeping happens in this turn or not at all.

## An `auto-rewake:` reminder is a recovery prompt from a hook, not a human

`hooks/auto-rewake.sh` waits in the background after every turn of a self-paced `/loop /auto` run — and, for the
API-error case only, after every turn of a one-shot run (a targeted `/auto <ID>`, which is every `/fleet-sequence`
child, or a bare `/auto` typed once) — and wakes the session only when it has gone silent. Its message says which way:

- *"the ScheduleWakeup this session armed at … never fired"*: the previous iteration ended correctly and its wakeup
  was lost. Run the next iteration from Step 0 as that wakeup would have, and end the turn with `ScheduleWakeup`.
- *"killed by an API error (…)"*: the previous turn died mid-iteration. Resume via Stall recovery above, run Step 4,
  and end on a wakeup. If the API refuses again the hook retries on its own (every ~900s, 24 times) — do not halt.
- In a one-shot run the message names the run as one-shot and ends with *arm no wakeup*: resume the same way, run
  Step 4, and end the turn; nothing loops.

The reminder arrives with `origin.kind` `task-notification`, never `human`, so `auto-heartbeat.sh` stays armed and the
user-stop semantics do not apply: the run is not under manual control.
