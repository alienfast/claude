---
name: fleet-launch
description: Launch a fleet of parallel /loop /auto sessions as background agents in `claude agents`, staggered so each session's first pick sees the previous session's claim, with an optional time budget that winds the fleet down cleanly (in-flight issues finish; no new picks). Count defaults to /auto-prep's persisted recommendation; an explicit count is the quota throttle. Ending a running fleet early is /fleet-stop, not this skill. Use when the user says 'fleet launch', 'launch the fleet', 'spawn N auto loops', 'start 5 loops for 10 hours', or invokes /fleet-launch.
---

# Fleet Launch

The middle bookend of the fleet workflow: `/auto-prep` (groom + recommend a count) → **`/fleet-launch`** (dispatch) → `/fleet-retro` (post-mortem). All logic lives in [scripts/fleet-launch.sh](../../scripts/fleet-launch.sh); this skill dispatches to it and narrates the result.

Each session is a `claude --bg "/loop /auto"` background agent — they land in the user's `claude agents` view, not in new terminals. Dispatches are staggered on a local signal (a new worktree under `.claude/worktrees/` — the stamp `/auto` Step 2's live-owner probe excludes from the next pick) so sessions never race each other for the same first issue, capped at 180s per wait.

This skill does NOT run `/auto-prep` (its solo/decision-gated advice needs human eyes before a launch) and does NOT run `/fleet-retro` (run it after the fleet quiesces). It assumes prep already happened; if `tmp/fleet-recommendation.json` is missing and no count was given, the script says so and stops.

## Arguments

`/fleet-launch [count] [duration]`

- **(none)** — launch the count `/auto-prep` persisted to `tmp/fleet-recommendation.json`, no deadline: loops run until the certified backlog drains (`NO-CANDIDATES`).
- `<count>` (e.g. `/fleet-launch 5`) — launch exactly that many sessions — that many MORE when a fleet is already running, not a target total. This is the quota throttle: auto-prep recommends from lane math alone and knows nothing about the user's remaining quota.
- `<duration>` (e.g. `/fleet-launch 5 10 hours`, `/fleet-launch 90m`) — also write `tmp/fleet-deadline.json`. Each session's `/auto` checks it **before picking new work, never mid-issue**: at the deadline every session finishes its in-flight issue, then ends its loop with `NO-CANDIDATES: fleet deadline reached`. Accepted forms: `10h`, `10 hours`, `90m`, `45 minutes`.

Ending a running fleet early is [`/fleet-stop`](../fleet-stop/SKILL.md), not a form of this skill. Check the current picture any time with [`/fleet-status`](../fleet-status/SKILL.md).

## Behavior

Run from the project the fleet should work on (sessions inherit the cwd — the script resolves the main checkout itself, so a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-launch.sh 5 10 hours
```

Surface the script's output: the deadline (if any), each dispatch line, each claim-landed/timeout line, and the closing `claude agents` pointer. A claim-wait timeout is a WARN, not a failure — the session may be in preflight, resuming a dead worktree, or the pool may have drained mid-launch.

### Record the quota reading BEFORE dispatching

Ask the user for their current **weekly %** and **5h burst %** remaining (`/usage`), and write them alongside the deadline. Ten seconds of their time, and it is the only way the allowance ever becomes a measurement:

```bash
jq -n --argjson weekly <PCT> --argjson burst <PCT> --argjson n <COUNT> --argjson e "$(date +%s)" \
  '{at_launch: {weekly_pct: $weekly, burst_pct: $burst, sessions: $n, epoch: $e, source: "read at dispatch"}}' \
  > tmp/fleet-quota-launch.json
```

**Read it at dispatch — never carry `/auto-prep`'s.** The prep reading is minutes to hours stale, and the burst window is 5 hours wide, so a reading taken before it is describing a different window than the one the fleet will launch into. The 2026-08-06 run carried a reading taken 53 minutes earlier (its own `source` field recorded the fact) and was cut off 4.9h into a 12h deadline. If the user cannot re-read, say the launch is uncalibrated rather than silently reusing the old number.

### Size the count against remaining burst headroom, not the historical peak

`/auto-prep`'s `sizing.peak_5h_observed` is a **survived floor** — what some earlier fleet got away with. It is not a budget, and two corrections have to be applied before it becomes one:

1. **Prefer a measured cutoff over a survived peak.** Once a run has actually been throttled, `/fleet-retro` reports the output volume it was cut at, and that number is a **ceiling** — the first kind of observation this system produces that bounds from above. Use the lowest observed cutoff as the basis whenever one exists; fall back to the survived floor only until then.
2. **Discount by the burst percentage remaining.** The fleet enters a window someone else has partly spent.

```text
n ≤ basis × (burst_pct_remaining / 100) ÷ (rate_tok_per_session_hour × 5)
```

Worked on the 2026-08-06 run, whose numbers are the reason this section exists: basis 2,122,634 (survived floor), rate 84,905, burst 85% remaining → `1,804,239 ÷ 424,525` = 4.2, so 4 sessions — which is what launched, and it was cut off. Re-running the same arithmetic with that run's measured cutoff as the basis (1,575,182) and its realized rate (78,759) gives `1,338,905 ÷ 393,795` = **3.4 → 3 sessions**, which would have fit. The floor was 35% too generous; the discount alone would not have caught it, and the basis correction is what does.

**The 5h window caps concurrency, not duration.** It is a rate limit, so it constrains `n` — stretching the same `n` over a longer deadline does not help, and shortening the deadline does not let you add sessions. Total session-hours are capped by the *weekly* allowance instead, which on that run was never the binding constraint (it ended at 49% remaining, 32 points consumed). When the arithmetic above forces `n` below what the user asked for, say so with the numbers and let them decide — an explicit count is the user's throttle and overrides this.

**Why this one file matters more than it looks.** Without a launch reading, the allowance can only ever be *inferred* from a run ending at zero — and that inference is unsound, because a run consumes whatever was left, not the whole budget. On 2026-08-06 that reasoning put a weekly allowance at ~5x under its real size and produced a recommendation the user correctly rejected. With a launch reading, `/fleet-retro`'s closing reading brackets the run and the allowance falls out by subtraction: `consumed% -> tokens` calibrates the absolute basis against whatever the limit actually meters, so nobody has to know whether it counts output, cache reads, or a weighted blend.

Proceed if the user does not have the numbers to hand — note their absence in the report rather than blocking the launch, and say that this run will not calibrate.

Model/permission defaults follow `/auto`'s unattended-run prerequisites (`--model 'opus[1m]' --effort xhigh --permission-mode auto` — `auto`, not `acceptEdits`, because acceptEdits only auto-accepts file edits and the first gated Bash command would stall a background session at an unanswerable prompt); anything after `--` passes through to `claude --bg` and overrides them. `FLEET_PROMPT` overrides the dispatched prompt — e.g. `FLEET_PROMPT='/loop /auto BF'` to team-scope the run.

## The deadline contract (shared with /auto)

- Marker: `<main-checkout>/tmp/fleet-deadline.json` — `{deadline_epoch, deadline, count}` (`stopped: true` when written by [`/fleet-stop`](../fleet-stop/SKILL.md)).
- `/auto` reads it at Step 2 (after preflight, before the pick), so in-flight work always completes and targeted `/auto <ISSUE-ID>` ignores it by construction.
- Sessions never delete the marker (siblings still mid-issue must see it); `fleet-launch.sh` clears any stale marker on every launch, so a no-duration launch never inherits a dead fleet's deadline — which also means a top-up launch resets or erases a running fleet's deadline: re-pass the remaining duration when adding sessions.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before dispatching anything; relay it.
- A dispatch failure stops further launches but leaves already-launched sessions running — say how many made it and point at `claude agents`.
- No count and no `tmp/fleet-recommendation.json` → run `/auto-prep` (or pass a count). A recommendation older than 24h gets a staleness WARN — offer to re-run `/auto-prep`.
