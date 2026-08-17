---
name: fleet-launch
description: Launch a fleet of parallel /loop /auto sessions as background agents in `claude agents`, staggered so each session's first pick sees the previous session's claim, with an optional time budget that winds the fleet down cleanly (in-flight issues finish; no new picks). Count defaults to /auto-prep's persisted recommendation; an explicit count is the quota throttle. Ending a running fleet early is /fleet-stop, not this skill. Use when the user says 'fleet launch', 'launch the fleet', 'spawn N auto loops', 'start 5 loops for 10 hours', or invokes /fleet-launch.
---

# Fleet Launch

The middle bookend of the fleet workflow: `/auto-prep` (groom + recommend a count) → **`/fleet-launch`** (dispatch) → `/fleet-retro` (post-mortem). All logic lives in [scripts/fleet-launch.sh](../../scripts/fleet-launch.sh); this skill dispatches to it and narrates the result.

Each session is a `claude --bg "/loop /auto"` background agent — they land in the user's `claude agents` view, not in new terminals. Dispatches are staggered on a local signal (a new worktree under `.claude/worktrees/` — the stamp `/auto` Step 2's live-owner probe excludes from the next pick) so sessions never race each other for the same first issue, capped at 180s per wait.

This skill does NOT run `/auto-prep` (its solo/decision-gated advice needs human eyes before a launch) and does NOT run `/fleet-retro` (run it after the fleet quiesces — and before the next launch: launching is what expires the prior run's ledgers, see below). It assumes prep already happened; if `tmp/fleet-recommendation.json` is missing and no count was given, the script says so and stops.

## Arguments

`/fleet-launch [count] [duration]`

- **(none)** — launch the count `/auto-prep` persisted to `tmp/fleet-recommendation.json`, no deadline: loops run until the certified backlog drains (`NO-CANDIDATES`).
- `<count>` (e.g. `/fleet-launch 5`) — launch exactly that many sessions — that many MORE when a fleet is already running, not a target total. This is the user's override: auto-prep recommends `min(lanes, 3)` (3 is the settled 5h-burst concurrency cap), and an explicit count overrides it in either direction.
- `<duration>` (e.g. `/fleet-launch 5 10 hours`, `/fleet-launch 90m`) — also write `tmp/fleet-deadline.json`. Each session's `/auto` checks it **before picking new work, never mid-issue**: at the deadline every session finishes its in-flight issue, then ends its loop with `NO-CANDIDATES: fleet deadline reached`. Accepted forms: `10h`, `10 hours`, `90m`, `45 minutes`.

Ending a running fleet early is [`/fleet-stop`](../fleet-stop/SKILL.md), not a form of this skill. Check the current picture any time with [`/fleet-status`](../fleet-status/SKILL.md).

## Behavior

Run from the project the fleet should work on (sessions inherit the cwd — the script resolves the main checkout itself, so a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-launch.sh 5 10 hours
```

Surface the script's output: the deadline (if any), each dispatch line, each claim-landed/timeout line, and the closing `claude agents` pointer. A claim-wait timeout is a WARN, not a failure — the session may be in preflight, resuming a dead worktree, or the pool may have drained mid-launch.

### The count is settled at 3 — no capacity readings at dispatch

**Keeper-settled 2026-08-10: do not ask for `/usage` readings at launch, and do not write `tmp/fleet-quota-launch.json` — that calibration apparatus is retired.** The two allowance windows resolve so:

- **5h burst → concurrency, and the bracket is measured:** **n=4 exhausted the allowance 4.9h into a 12h deadline** (2026-08-06) while **n=3 lasted ~11.6h** (2026-08-08) and **ran a 12h deadline unthrottled** (2026-08-09). Only 3 sessions can run for any duration without reliably exhausting a 5h window; the script warns above 3, and an explicit count remains the user's override. The bracket was measured on the BF backlog at opus/xhigh — a materially different workload voids it, **and the 500k autocompact cap was exactly such a change**: leaner contexts iterate faster, so post-cap sessions burn ~118k output tokens/session-hour at peak (vs the 85–102k the bracket was measured on), and the 2026-08-17 x3 @500k run saturated its 5h window 5h07m after launch — n=3 now runs at ~102% of the refill rate against the calibrated ceiling (`~/.claude/telemetry/five-hour-ceiling.json`; 1.57–1.74M output observed).
- **Weekly → not a constraint:** the keeper runs multiple accounts, so weekly-remaining on the launching account bounds nothing, and duration needs no scaling by it. The launch/close quota-bracket readings existed to calibrate an allowance that no longer binds; multi-account rotation replaced them.

**Unattended runs longer than ~5h (the overnight shape) ride the ceiling deliberately — the protection is `/auto`'s fleet headroom gate, not a smaller n.** Sessions probe `scripts/fleet-headroom.sh` at every pick and PARK with a wakeup pending when the trailing-5h burn nears the ceiling, so the fleet grazes the limit between issues (self-recovering — the wakeup fires after the reset) instead of being killed mid-issue (unrecoverable without an operator: 2026-08-17 lost 25.2 session-hours past the reset plus ~2 keeper-hours draining half-done work the next morning). Staggering the launch does NOT substitute: saturation is a steady-state rate deficit (~355k/h burn vs ~348k/h refill at n=3), so a stagger only delays the first cutoff by its own length. If the gate is ever suspect, the zero-code fallback for an unattended long run is **n=2** (~237k/h — never saturates); n=3 with the gate otherwise dominates it on throughput.

If a future run IS cut off, `/fleet-retro`'s `quota_stall_groups[].limit_kind` names which allowance bound — read from the harness message, never inferred from the stall's shape, because the limits leave an identical synchronized-silence fingerprint. A **`5-hour`** cutoff at n≤3 re-opens the bracket; a **`weekly`** cutoff means rotate accounts, not shrink the fleet; and a **`session`** cutoff IS the 5h window under another name — measured 2026-08-14 and again 2026-08-17 (resets on exact 5h boundaries, refuses every session then making a request), so route it exactly as `5-hour`. Each cutoff also yields a fresh ceiling observation — record it in `~/.claude/telemetry/five-hour-ceiling.json` at retro.

Model/permission defaults follow `/auto`'s unattended-run prerequisites (`--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto` — `auto`, not `acceptEdits`, because acceptEdits only auto-accepts file edits and the first gated Bash command would stall a background session at an unanswerable prompt; `--autocompact 500000` because on `opus[1m]` the default compaction threshold sits near the 1M window, so a `/loop /auto` session accumulating across iterations never compacts — the 2026-08-13/14 fleets processed 91% of their billable volume at >200k context, and cache reads scale linearly with context size, which is what let 3 sessions exhaust a 5h window that 9 leaner sessions survived. `/auto`'s cross-iteration state lives in `tmp/` handoff files and Linear, not in context, so compaction between issues is loss-free. The value cannot go much lower: compaction triggers at ~90% of the window, and the trigger must clear a DEEP-issue session's post-compact floor (~152–177k: re-injected overhead plus a summary that must carry the issue) plus the live working set a review/fix loop re-reads after every compact (>=110k) plus single-call ingestions up to ~130k. 150000 thrash-aborted the 2026-08-14 fleet at launch; 300000 survived launch but fell into a compaction orbit mid-review the same night — 9 compacts in 36 minutes, because once the band matches the working set every compact forces re-reads that refill it (doc/compacting-investigation.md, verdict log). **Never restart/resume a deep fleet session** — its floor arrives at the trigger and it compacts on arrival; recover in-flight issues in fresh targeted sessions (`/auto BF-XXX` re-enters the existing worktree). Watch `fleet-metrics.py`'s context-size distribution and review-churn gauges before moving the value in either direction); anything after `--` passes through to `claude --bg` and overrides them. `FLEET_PROMPT` overrides the dispatched prompt — e.g. `FLEET_PROMPT='/loop /auto BF'` to team-scope the run.

### Ledger expiry — prior runs' state files are cleared at launch

Per-session ledgers (`tmp/auto-state-*.json`) deliberately persist after a fleet ends so the operator and `/fleet-retro` can examine them; a new launch is where they expire. The script deletes the **dead** ones (recorded pid gone, or its start time mismatched) before dispatching, and reports what it cleared — so `/fleet-status` shows only the current fleet, and so a run you still want measured must be retro'd **before** relaunching. Ledgers of still-running sessions are kept, and the marker's `launch_epoch` is pulled back to the oldest kept ledger's mtime so a top-up launch never hides a running sibling from `/fleet-status`.

## The deadline contract (shared with /auto)

- Marker: `<main-checkout>/tmp/fleet-deadline.json` — `{deadline_epoch, deadline, count, launch_epoch}` (`launch_epoch` is `/fleet-status`'s session-scoping anchor; `stopped: true` added by [`/fleet-stop`](../fleet-stop/SKILL.md), which preserves the other fields).
- `/auto` reads it at Step 2 (after preflight, before the pick), so in-flight work always completes and targeted `/auto <ISSUE-ID>` ignores it by construction.
- Sessions never delete the marker (siblings still mid-issue must see it); `fleet-launch.sh` clears any stale marker on every launch, so a no-duration launch never inherits a dead fleet's deadline — which also means a top-up launch resets or erases a running fleet's deadline: re-pass the remaining duration when adding sessions.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before dispatching anything; relay it.
- A dispatch failure stops further launches but leaves already-launched sessions running — say how many made it and point at `claude agents`.
- No count and no `tmp/fleet-recommendation.json` → run `/auto-prep` (or pass a count). A recommendation older than 24h gets a staleness WARN — offer to re-run `/auto-prep`.
