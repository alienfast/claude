---
name: fleet-stop
description: Gracefully wind down a running fleet of /loop /auto sessions — writes an already-passed deadline so every session finishes its in-flight issue, then stops picking new work. Nothing is killed. Quota rationing is the primary use. Use when the user says 'fleet stop', 'stop the fleet', 'wind down the fleet', 'end the fleet early', 'discontinue the fleet', or invokes /fleet-stop.
---

# Fleet Stop

The early-end command of the fleet workflow: `/auto-prep` (before) → `/fleet-launch` (dispatch) → `/fleet-status` (any time) → **`/fleet-stop`** (end early) → `/fleet-retro` (after). The implementation is the `stop` form of the launch script — the deadline marker is shared state between launching and stopping, so one script owns it; this skill dispatches and narrates:

```bash
~/.claude/scripts/fleet-launch.sh stop
```

## Semantics

- Writes an already-passed deadline (`stopped: true`) to `<main-checkout>/tmp/fleet-deadline.json` — the same marker a timed `/fleet-launch` writes.
- Each session's `/auto` reads the marker after preflight and before its next pick, **never mid-issue**: in-flight issues run to completion (through `/finish` and the merge), then each session ends its loop with `NO-CANDIDATES: fleet deadline reached`.
- Nothing is killed, ever. To abort in-flight work too, the user kills sessions in `claude agents` — this skill never does.
- Sessions never delete the marker (siblings still mid-issue must see it); the next `/fleet-launch` clears it. See the deadline contract in [fleet-launch](../fleet-launch/SKILL.md).
- The marker gates every `/auto` in that checkout, fleet or not — a later **solo** `/auto` run also declines to pick until the marker is deleted or a launch clears it. If the user hits that, the fix is `rm tmp/fleet-deadline.json`.

Watch the wind-down with [`/fleet-status`](../fleet-status/SKILL.md) — the deadline row reads `STOPPED`, and the in-flight section empties as sessions finish.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before writing anything; relay it.
- No fleet running → harmless: the marker is written and simply sits until the next launch clears it — but note the solo-`/auto` gate above.
