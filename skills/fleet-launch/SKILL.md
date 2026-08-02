---
name: fleet-launch
description: Launch a fleet of parallel /loop /auto sessions as background agents in `claude agents`, staggered so each session's first pick sees the previous session's claim, with an optional time budget that winds the fleet down cleanly (in-flight issues finish; no new picks). Count defaults to /auto-prep's persisted recommendation; an explicit count is the quota throttle. Also stops a running fleet (`/fleet-launch stop`). Use when the user says 'fleet launch', 'launch the fleet', 'spawn N auto loops', 'start 5 loops for 10 hours', 'wind down the fleet', or invokes /fleet-launch.
---

# Fleet Launch

The middle bookend of the fleet workflow: `/auto-prep` (groom + recommend a count) → **`/fleet-launch`** (dispatch) → `/fleet-retro` (post-mortem). All logic lives in [scripts/fleet-launch.sh](../../scripts/fleet-launch.sh); this skill dispatches to it and narrates the result.

Each session is a `claude --bg "/loop /auto"` background agent — they land in the user's `claude agents` view, not in new terminals. Dispatches are staggered on a local signal (a new worktree under `.claude/worktrees/` — the stamp `/auto` Step 2's live-owner probe excludes from the next pick) so sessions never race each other for the same first issue, capped at 180s per wait.

This skill does NOT run `/auto-prep` (its solo/decision-gated advice needs human eyes before a launch) and does NOT run `/fleet-retro` (run it after the fleet quiesces). It assumes prep already happened; if `tmp/fleet-recommendation.json` is missing and no count was given, the script says so and stops.

## Arguments

`/fleet-launch [count] [duration] | stop`

- **(none)** — launch the count `/auto-prep` persisted to `tmp/fleet-recommendation.json`, no deadline: loops run until the certified backlog drains (`NO-CANDIDATES`).
- `<count>` (e.g. `/fleet-launch 5`) — launch exactly that many sessions. This is the quota throttle: auto-prep recommends from lane math alone and knows nothing about the user's remaining quota.
- `<duration>` (e.g. `/fleet-launch 5 10 hours`, `/fleet-launch 90m`) — also write `tmp/fleet-deadline.json`. Each session's `/auto` checks it **before picking new work, never mid-issue**: at the deadline every session finishes its in-flight issue, then ends its loop with `NO-CANDIDATES: fleet deadline reached`. Accepted forms: `10h`, `10 hours`, `90m`, `45 minutes`.
- `stop` — wind down a **running** fleet: writes an already-passed deadline and exits. Every session stops at its next iteration boundary; in-flight issues run to completion. To abort in-flight work too, the user kills sessions in `claude agents` — this skill never does.

## Behavior

Run from the project the fleet should work on (sessions inherit the cwd — the script resolves the main checkout itself, so a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-launch.sh 5 10 hours
~/.claude/scripts/fleet-launch.sh stop
```

Surface the script's output: the deadline (if any), each dispatch line, each claim-landed/timeout line, and the closing `claude agents` pointer. A claim-wait timeout is a WARN, not a failure — the session may be in preflight, resuming a dead worktree, or the pool may have drained mid-launch.

Model/permission defaults follow `/auto`'s unattended-run prerequisites (`--model 'opus[1m]' --effort xhigh --permission-mode acceptEdits`); anything after `--` passes through to `claude --bg` and overrides them. `FLEET_PROMPT` overrides the dispatched prompt — e.g. `FLEET_PROMPT='/loop /auto BF'` to team-scope the run.

## The deadline contract (shared with /auto)

- Marker: `<main-checkout>/tmp/fleet-deadline.json` — `{deadline_epoch, deadline, count}` (`stopped: true` for the stop form).
- `/auto` reads it at Step 2 (after preflight, before the pick), so in-flight work always completes and targeted `/auto <ISSUE-ID>` ignores it by construction.
- Sessions never delete the marker (siblings still mid-issue must see it); `fleet-launch.sh` clears any stale marker on every launch, so a no-duration launch never inherits a dead fleet's deadline.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before dispatching anything; relay it.
- A dispatch failure stops further launches but leaves already-launched sessions running — say how many made it and point at `claude agents`.
- No count and no `tmp/fleet-recommendation.json` → run `/auto-prep` (or pass a count). A recommendation older than 24h gets a staleness WARN — offer to re-run `/auto-prep`.
