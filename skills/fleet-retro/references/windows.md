# Quota and rate-limit windows

Read from `/fleet-retro` Step 1 when reporting the `windows` block, any `quota_stall_groups` entry, or the `Window
readings` line and its Headroom verdict.

## What is not asked

Do not ask for `/usage` readings. The weekly allowance is handled by account rotation and concurrency is settled at 3
(`skills/fleet-launch/SKILL.md` § The count is settled at 3 — no capacity readings at dispatch), so no launch/close
quota bracket is calibrated and no `tmp/fleet-quota-launch.json` exists to close. The weekly window still ends a fleet
whose account has less of its week left than the run burns — which is why `/fleet-launch` prints the active account's
`seven_day` reading at dispatch; a retro that finds a `weekly` cutoff reports it as a rotation miss, never as a sizing
input.

## The four numbers

All four are in the `windows` block already emitted.

1. `peak_5h_output_tokens` with `peak_5h_concurrency` — the burst-window floor. It rises only when a fleet survives a
   denser window, so a run that sets a new one is worth noting.
2. `output_tokens_per_session_hour_at_peak` paired with that concurrency — one point on the burn-rate curve. Recorded
   across runs at different `n`, these replace the flat-rate assumption that makes large-`n` projections optimistic. On
   a fleet whose sessions run under 5h the at-peak rate understates burn — its divisor counts every session overlapping
   the window as a full 5h — so report `output_tokens_per_in_window_session_hour` beside it.
3. Any `quota_stall_groups` — sessions that stopped together. This is the fingerprint that distinguishes a clean
   deadline wind-down from an allowance cutoff, and only the second leaves in-flight worktrees needing a human. Check
   those worktrees before reaping anything (`standards/git-worktrees.md`). A group whose `kind` is `recovered` looks
   entirely clean in every other column — the sessions woke hours later and drained with proper terminal tags — so this
   field is the only thing that will tell you. The reading rules are the next section.
4. When a stall group exists, `peak_5h_output_tokens` is a CEILING, not a floor — the run was cut off at that volume,
   so it bounds the limit from above where every un-throttled observation bounds it from below. Say plainly which kind
   of observation the run produced. It is a ceiling on the limit named in `limit_kind` only; a weekly cutoff leaves the
   5h burst ceiling unobserved. A `session`/`5-hour` cutoff at n≤3 re-opens the concurrency cap;
   `skills/fleet-launch/SKILL.md` § The count is settled at 3 owns the count, the 5h-window reason and the
   headroom-probe rule; check the recovery mechanism before touching n. n=3 runs near the refill rate and hits the
   ceiling about once per 5h window by construction, which costs minutes of reset wait when recovery is automatic and
   hours when it is not, while shrinking to n=2 forfeits about a third of the allowance to fix a stall that costs
   minutes.

## Reading a stall group

- **Expect several groups on a long run, and read `recovery_lag_s` rather than the lost-hours total.** An allowance
  that refills on a fixed period cuts a fleet off once per period, so a 12h run at the sustainable concurrency produces
  two or three groups. Lost hours bundle two costs: the allowance's own duration, which nothing can avoid, and the lag
  after it reset, which is the entire actionable finding. Report them separately. The cheap groups are the control: two
  cutoffs on one fleet under one limit differ in cost only by whether a `ScheduleWakeup` happened to be pending when
  the turn died, and that comparison is what identifies the mechanism — a report showing only the expensive stall reads
  as "quota is the problem" and points at `n`.
- **Read `limit_kind` as the harness's WORDING, not as the meter's scope.** The field is read from the harness message
  (`You've hit your <kind> limit · resets <time>`), so it is evidence about what was said, and the limits produce an
  identical synchronized-silence fingerprint. `weekly` caps total session-hours (lever: account rotation — a weekly
  cutoff says nothing about fleet shape). When the field is absent no limit message was found at all — treat the cause
  as unestablished (machine sleep, daemon restart, network) rather than assuming quota.
- **`session` does NOT mean per-session.** A `session` cutoff is the account-level 5-hour window: its stated resets fall
  on exact 5h boundaries, and every session actively making a request hits within seconds of the others, which a
  genuinely per-session cap cannot do to independently launched sessions. A session that misses a cutoff was idle at
  that instant and made no request to be refused — absence from a cutoff is evidence about activity, not about scope —
  so check each session's entry count in the window before concluding a limit spared it. Route a `session` cutoff
  exactly as a `5-hour` one: the levers are **n** and stall recovery.
- **The ceiling is read, not derived.** `mods/rate-limits` records the account's own `five_hour` reading per session,
  the headroom probe parks on it, and the `Window readings` line with its Headroom verdict is the sizing evidence. The
  cutoff-window token meters stay in the report as cost figures only — a machine-wide token sum maps to no one
  account's window on a multi-account machine, and a probe's and the analyzer's token units can differ by a multiple —
  so carry them forward for cost, never as a ceiling.
- **Cross-run token comparisons are valid only within one `limit_kind`.** Unrelated ceilings can coincide closely, and
  a 5h window is simply the wrong instrument for a weekly cutoff: trailing-5h totals at a `weekly` and a `5-hour`
  cutoff agreeing to a fraction of a percent is coincidence, not an identified meter.

## The `Window readings` line and its Headroom verdict

Read it before sizing anything on the token peaks. `mods/rate-limits` keeps each session's history of the account's own
window meter (`~/.claude/local/rate-limits/<session>.jsonl`); the line names each window's highest reading (`5h%` in the
trend) and the account it was read on, and the verdict spreads the peak `five_hour` reading over the hours the block had
run and every session on that account's meter in the block — this fleet's active at the instant plus any other session
whose history read the same account in the same block, another project's fleet or an interactive one, each named by
project — to say how many sessions a WHOLE block fits at that workload: whether more would have fit, the question the
four numbers above can only bracket. Take it as a bracket of one: the meter is account-wide and a session that kept no
history is invisible to the count, the share assumes burn scales with the count, and a reading moves only when the
window moves a whole point. It reads `none` for a fleet launched before the mod was enabled on the machine, and such a
retro can only estimate headroom from a snapshot.

**Only a 5h block the fleet ran from its start counts.** The meter's blocks are fixed (`resetsAt` steps in whole 5h
blocks), so a block already running at launch carries what was spent in it before, and the peak, `5h%` and the verdict
leave it out; a higher reading from one is named on the readings line as inherited. A fleet launched into a nearly full
block that resets minutes later would otherwise read "fits ~1 session" off the inherited reading while its own first
block shows room. A fleet that never outlives the block it launched into gets no verdict, and the line says so.

## A deliberate wind-down is not a stall

The detector excludes a silence beginning at a `ScheduleWakeup(stop: true)` with no limit message, because an ended loop
has no wakeup pending and going quiet is its contract. Do not undo that by hand when reading the report: a session that
reads the deadline with too little time left for an issue and halts is exemplary judgement, and counting its hours of
correct silence as lost capacity turns it into the run's largest apparent fault.
