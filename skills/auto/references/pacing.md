# Self-paced loop pacing

Read from `/auto` when deciding a `ScheduleWakeup` delay, or when a session ended without a turn following its wakeup.
The rule itself is inline in `SKILL.md` § Loop pacing; this file carries the mechanics behind each figure.

## Why 60s on `AUTO-CONTINUE`

The backlog is the work queue, Step 2 established it is non-empty, and no external state is being waited on.
`ScheduleWakeup`'s 1200–1800s idle-tick guidance is written for polling loops (CI, deploys, remote queues); inheriting
it inserts 20–30 idle minutes between every shipped issue.

## Why nothing exceeds 1800s

The daemon retires an idle background session (`claude --bg`, which is every fleet session) at its first one-minute tick
past 60 idle minutes (`~/.claude/daemon.log` prints `bg retire <id>: idle-prompt, idle 60m`). `ScheduleWakeup` accepts
up to 3600s, which lands on that threshold, and whether a pending wakeup exempts a session from retirement is
unestablished. Every delay this skill prescribes sits at or under 1800s; wait out anything longer as a chain of ≤1800s
ticks.

The retirement is also how a lost wakeup becomes a dead session: an armed wakeup that never produces a turn leaves the
ledger `active` and the session retired an hour later. `hooks/auto-heartbeat.sh` cannot catch it — it runs at the end
of the turn, when a wakeup was armed, and no Stop event follows when no turn follows. `hooks/auto-rewake.sh` catches
it: it waits out every armed wakeup in the background and wakes the session when none fired (`api-failures.md` § An
`auto-rewake:` reminder). `~/.claude/daemon.log` and `~/.claude/logs/auto-rewake.log` are where a retro reads it.

## Why `stop: true` ends the session

`ScheduleWakeup(stop: true)` on `NO-CANDIDATES` or `AUTO-HALTED` cancels the pending heartbeat, which plain
not-scheduling would leave to fire one more no-op turn against the sticky terminal state. It is also what ends the
session: `hooks/auto-rewake.sh` reads it at the turn's end, confirms the ledger is terminal, and retires the background
session (`claude stop`, then `claude rm`, which keeps the transcript for `/fleet-retro`). Nothing else does — the
harness settles a `--bg` session to `done` only when its launch prompt's turn ends, and a loop's last turn is a
wakeup's, so a drained session otherwise sits listed as `working` or `blocked` indefinitely, and the daemon's idle
retirement is not to be relied on. `scripts/auto-stall-watch.sh --retire` is the backstop for a hook that missed.
Every registry reader (`fleet-launch.sh`, `fleet-status.sh`, `fleet-sequence.sh`) treats the row a stop leaves behind
— state unchanged, `status` and `pid` gone — as ended.

## Why the heartbeat is armed at turn end, never mid-turn

`ScheduleWakeup` is turn-ending by contract: the turn ends as soon as the tool returns. Arming it before an iteration's
work ends the turn before Step 0 runs and idles the session for the full delay. Arm it as the last action of any turn
that ends mid-iteration (~1800s), and supersede it with the 60s tick when the iteration completes; only one dynamic-loop
wakeup is ever pending, since each call cancels the previous (telemetered as `superseded_count`).

The safety net against an accidental turn end is the Stop hook, not pre-arming: `hooks/auto-heartbeat.sh` blocks any
turn ending inside a self-paced `/loop /auto` iteration with no `ScheduleWakeup` since the anchor and re-drives the
arming (1800s mid-iteration, 60s after `AUTO-CONTINUE`), giving up after 3 attempts. It catches both stall shapes —
a turn that ended on `SHIPPED-MERGE` without running Step 4, and one that announced a dispatch it never made. Extra
firings are benign: one landing right after an `AUTO-CONTINUE` tick or against a terminal state reads as a status check
and is absorbed by the re-entry rules and Step 0's sticky states.

Fixed-interval `/loop` and one-shot or targeted runs get no heartbeat: the interval timer re-fires the former, and a
wakeup would wrongly re-fire the latter.
