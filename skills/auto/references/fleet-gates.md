# Fleet gates at pick time

Read from `/auto` Step 2 when `tmp/fleet-deadline.json` exists. The marker's fields are the deadline contract in
`skills/fleet-launch/SKILL.md` § The deadline contract (shared with /auto); this file is how `/auto` applies it.

## Deadline gate

- Read `deadline_epoch` with `jq -r '.deadline_epoch // empty'`. Absent → no time budget, nothing to gate or note.
  Present but non-numeric → ignore it and say so in the iteration's summary sentence; a malformed marker must not end
  a run.
- The budget is spent when `date +%s` ≥ `deadline_epoch`, or when this session's run key (the first 8 characters of
  its session id) is in the marker's `retiring` list — a relaunch carried it out of a wound-down fleet, so it treats
  the deadline as passed whatever `deadline_epoch` says.
- Spent → first the wind-down push: run `~/.claude/scripts/auto-push-main.sh` from the main checkout and carry its one
  line into the tag. Under `AUTO_PUSH_MAIN=lazy` (the project's committed `.claude/settings.json`) it pushes the
  default branch fast-forward only, so origin does not lag Linear overnight. `DISABLED` is a no-op line; `DIVERGED`
  names a human's job, not this run's failure; `FETCH-FAILED`/`PUSH-FAILED` is transient infrastructure — say so and
  drain anyway. Then set `status: "drained"` with `reason` and emit the `fleet deadline reached` `NO-CANDIDATES` line;
  under self-paced `/loop`, `ScheduleWakeup(stop: true)`.
- The gate sits after Step 1 deliberately: preflight finishes in-flight work first, so a past-deadline session
  completes what it started and only declines new work; targeted mode skips Step 2, so `/auto <ISSUE-ID>` ignores the
  deadline by construction — typing an ID is the human override.
- It is the deadline's ONLY point of contact with the run. Once an issue is picked the marker is inert until the next
  pick: no mid-issue time-remaining arithmetic, no "will the gates fit" estimation, no parking, no compressing or
  cutting gates to fit the clock. The in-flight issue runs its full pipeline however far past the deadline that lands,
  because overrun is what every wind-down consumer budgets for (`/fleet-launch` and `/fleet-stop` both document
  in-flight issues running to completion).
- Never delete the marker from this skill — sibling sessions still mid-issue need to see it at their own next pick.
- `hooks/auto-deadline-gate.sh` backs the gate: it refuses a `next-candidates.sh` invocation from a `/loop /auto`
  session once `deadline_epoch` has passed, because this gate is prose and a session that read the marker on every
  earlier iteration can still skip the step. It fires only inside a `/loop /auto` session, so interactive `/next`,
  `/auto-prep`, `/fleet-status` and `/fleet-retro` — byte-identical commands — are unaffected, and targeted mode stays
  exempt by the same rule that exempts it here.

## Headroom gate

Fleet mode only (the marker exists, dated or not), and it governs every pick Step 2 makes, the hot handoff included.
Why the count is settled at 3 per account with room and why parking between issues is the protection rather than a
smaller fleet: `skills/fleet-launch/SKILL.md` § The count — 3 per account with room.

- Run `~/.claude/scripts/fleet-headroom.sh --session "$RUN_KEY"` (the identity Step 0 resolved). It reads this
  session's own `rate-limits` meter — the account it runs on, so a multi-account machine reads the right one — and
  falls back to the machine's latest snapshot.
- On a machine rotating accounts through cswap (`scripts/cswap-setup.sh`) it asks cswap first: while another enrolled
  account is under the engine's threshold with a fresh `ok` figure, the answer is `PICK-OK` whatever the local meter
  says — the engine lands there when the active account fills — and the line's tail reads `cswap=target(…)`. With no
  such account, or an idle engine, the local meter governs and the tail says why (`cswap=no-target(…)`,
  `cswap=engine-idle(…)`, `cswap=unreadable(…)`). A `THROTTLE` whose tail reads `cswap=switching(…)` means the engine
  is mid-move: its `resets_in` is 180s, so the delay rule re-probes in four minutes rather than at the reset.
- Exit 0 (`PICK-OK`) → proceed. Exit 2 (`THROTTLE`) → the account's 5-hour window is within the probe's reserve of
  full (about one issue's burn), so a pick now would likely be killed mid-issue by the limit: do not pick. This is a
  pause, not an outcome — touch no `status`, emit no terminal tag; end the iteration as an `AUTO-CONTINUE` no-pick
  whose summary sentence is the probe's one-line output, and under self-paced `/loop` arm `ScheduleWakeup` with
  `noop: true`, the reason carrying the reading, and `delaySeconds` = the line's `resets_in` plus 60, clamped to
  [60, 1800] — the reset is when a pick becomes possible, and 1800 is the re-check cadence when it is further out or
  unknown.
- The probe FAILS OPEN (exit 0, `source=none`, WARN on stderr) when no reading exists — a missing mod must not idle a
  healthy fleet. `auto-stall-watch` is the backstop, `/fleet-launch` prints the burst reading before dispatch, and
  `/fleet-retro` flags a session whose every probe ran blind. Nothing is calibrated by hand.
- Why parking wins: a limit met BETWEEN issues costs minutes — the parked wakeup fires after the reset and the loop
  resumes itself. A limit met MID-issue kills the turn: StopFailure fires instead of Stop, no wakeup is armed, and the
  session waits on `hooks/auto-rewake.sh` (every 900s for up to six hours), with the killed turn's work redone — a kill
  can land mid non-idempotent step — and the fleet stopped until the reset.
