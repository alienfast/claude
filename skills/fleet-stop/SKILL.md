---
name: fleet-stop
description: Gracefully wind down a running fleet of /loop /auto sessions — writes an already-passed deadline so every session finishes its in-flight issue and picks nothing new. Nothing is killed; quota rationing is the primary use. Use when the user says 'fleet stop', 'stop the fleet', 'wind down the fleet', 'end the fleet early', or invokes /fleet-stop.
---

# Fleet Stop

The early-end command of the fleet workflow: `/auto-prep` → `/fleet-launch` → `/fleet-status` → **`/fleet-stop`** →
`/fleet-retro`. The implementation is the `stop` form of the launch script — the deadline marker is shared state between
launching and stopping, so one script owns it; this skill dispatches and narrates:

```bash
~/.claude/scripts/fleet-launch.sh stop                # the one running fleet
~/.claude/scripts/fleet-launch.sh stop epic:BF-2948   # one of several — the epic's fleet
~/.claude/scripts/fleet-launch.sh stop team           # the team fleet
```

## Arguments

`/fleet-stop [epic:<ID> | team]` — the fleet to wind down. Several fleets run side by side in one checkout, one marker
each (`tmp/fleet-deadline-<slug>.json`, [`/fleet-launch`](../fleet-launch/SKILL.md) § Several fleets in one checkout).
With exactly one fleet running the token may be omitted; with several the script lists them with their tokens and exits
1 — ask (AskUserQuestion) which to stop, or whether all, and re-run per fleet.

## Semantics

- Writes `stopped: true` and an already-passed deadline onto that fleet's marker, preserving its other fields
  ([`/fleet-launch`](../fleet-launch/SKILL.md) § The deadline contract) — unless the marker's deadline has already
  passed: the fleet is then winding down on its own and the marker is left byte-identical, so the retro's idle-tail gauge
  keeps the real deadline. A stop never moves a deadline later, and never touches another fleet's marker.
- Each session's `/auto` reads its own fleet's marker after preflight and before its next pick, **never mid-issue**:
  in-flight issues run to completion (through `/finish` and the merge), then each session ends its loop with
  `NO-CANDIDATES: fleet deadline reached`.
- Nothing is killed, ever. To abort in-flight work too, the user kills sessions in `claude agents` — this skill never does.
- Sessions never delete the marker; the next `/fleet-launch` of the same slug archives it (or expires it once the retro
  has measured the fleet).
- The team marker gates every team-scoped `/auto` in that checkout, fleet or not — a later **solo** `/loop /auto` also
  declines to pick until the marker is deleted or a launch replaces it. If the user hits that, the fix is
  `rm tmp/fleet-deadline-team.json`. An epic marker gates only `/auto epic:<ID>` runs the same way.

Watch the wind-down with [`/fleet-status`](../fleet-status/SKILL.md) — the fleet's deadline row reads `STOPPED` (or
`passed` when the stop found the deadline already behind it), and the in-flight section empties as sessions finish.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before writing anything; relay it.
- No marker at all → `nothing to stop`, exit 1, nothing written (until 2026-10-28 a stop with no marker wrote one, which
  then gated every later solo `/auto`). A token naming a fleet with no marker → the same, with the fleets that do have
  one listed. A fleet that already ended at its deadline → the marker is left as is.
