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

- **5h burst → concurrency, and the bracket is measured:** **n=4 exhausted the allowance 4.9h into a 12h deadline** (2026-08-06) while **n=3 lasted ~11.6h** (2026-08-08) and **ran a 12h deadline unthrottled** (2026-08-09). Only 3 sessions can run for any duration without reliably exhausting a 5h window; the script warns above 3, and an explicit count remains the user's override. The bracket was measured on the BF backlog at opus/xhigh — a materially different workload voids it.
- **Weekly → not a constraint:** the keeper runs multiple accounts, so weekly-remaining on the launching account bounds nothing, and duration needs no scaling by it. The launch/close quota-bracket readings existed to calibrate an allowance that no longer binds; multi-account rotation replaced them.

If a future run IS cut off, `/fleet-retro`'s `quota_stall_groups[].limit_kind` names which allowance bound — read from the harness message, never inferred from the stall's shape, because the three limits leave an identical synchronized-silence fingerprint. A **`5-hour`** cutoff at n≤3 is the one signal that re-opens the bracket; a **`weekly`** cutoff means rotate accounts, not shrink the fleet; a **`session`** cutoff says nothing about fleet size at all.

Model/permission defaults follow `/auto`'s unattended-run prerequisites (`--model 'opus[1m]' --effort xhigh --permission-mode auto` — `auto`, not `acceptEdits`, because acceptEdits only auto-accepts file edits and the first gated Bash command would stall a background session at an unanswerable prompt); anything after `--` passes through to `claude --bg` and overrides them. `FLEET_PROMPT` overrides the dispatched prompt — e.g. `FLEET_PROMPT='/loop /auto BF'` to team-scope the run.

## The deadline contract (shared with /auto)

- Marker: `<main-checkout>/tmp/fleet-deadline.json` — `{deadline_epoch, deadline, count}` (`stopped: true` when written by [`/fleet-stop`](../fleet-stop/SKILL.md)).
- `/auto` reads it at Step 2 (after preflight, before the pick), so in-flight work always completes and targeted `/auto <ISSUE-ID>` ignores it by construction.
- Sessions never delete the marker (siblings still mid-issue must see it); `fleet-launch.sh` clears any stale marker on every launch, so a no-duration launch never inherits a dead fleet's deadline — which also means a top-up launch resets or erases a running fleet's deadline: re-pass the remaining duration when adding sessions.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before dispatching anything; relay it.
- A dispatch failure stops further launches but leaves already-launched sessions running — say how many made it and point at `claude agents`.
- No count and no `tmp/fleet-recommendation.json` → run `/auto-prep` (or pass a count). A recommendation older than 24h gets a staleness WARN — offer to re-run `/auto-prep`.
