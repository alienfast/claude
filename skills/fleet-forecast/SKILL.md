---
name: Fleet Forecast
description: Estimate — explicitly not a plan — of what a fleet of parallel /loop /auto sessions would ship over a time horizon. Simulates the certified backlog draining across N sessions (blockers resolve and make way for their dependents), reporting the projected pick order as waves, roughly when the Planned/Todo stage burns down and Backlog picks begin, what a given horizon (e.g. 12h) cannot reach, and which candidates are stranded behind blockers the fleet can never ship. Read-only; nothing is launched or written. Use when the user says 'fleet forecast', 'forecast the fleet', 'what would a fleet run look like', 'what order would issues run', 'how many hours to burn the Planned issues', 'what would ship overnight/in 12 hours', or invokes /fleet-forecast.
---

# Fleet Forecast

Project the *shape* of a fleet run before launching it: which issues go first, which chains gate the
middle of the run, when the Planned/Todo stage drains into Backlog, and what a given horizon leaves
on the table. The sibling of `/fleet-status` (read-only, one screen) pointed at the future instead of
the present, and a companion to `/auto-prep` (which grooms and sizes; this skill projects the drain).

**This is an estimate, never a plan.** Pick order is decided at pick time by `next-candidates.sh`
against live state; review churn, file collisions, failures, mid-run filings refilling the pool, and
5h-window headroom parking all move the real timeline. Frame every rendering of the output that way —
the value is seeing the graph's structure over time, not predicting any single pick. Never persist
the output anywhere `/auto` or a fleet session might read it as instructions.

## Workflow

### Step 1: Resolve context

- Team: `$LINEAR_TEAM`, or ask. Never scan the workspace.
- Run from the **project main checkout** — the script defaults read `tmp/fleet-recommendation.json`
  (session count and duration from `/auto-prep`) and `tmp/fleet-metrics-history.jsonl` (hours-per-issue
  calibration from past fleets) relative to the cwd.

### Step 2: Run the simulation

```bash
~/.claude/scripts/fleet-forecast.py --team <KEY> [--sessions N] [--horizon-h H]
```

Defaults: sessions and horizon from `tmp/fleet-recommendation.json` (horizon falls back to 12h); no
count from either source is a hard error — point at `/auto-prep` or ask for one. Useful overrides:
`--hours-per-issue X` (replace the history calibration; default 2.0 when no history),
`--flat` (disable estimate-point weighting of per-issue duration). `-h` documents the rest.

The script fetches once (states, labels, estimates, relations), classifies fleet-eligibility with the
same gate rules as `fleet-blockers.sh` (certified + workable state, unclaimed, non-epic, no
`human`/`needs decision`/`solo`/`stalled`, not Triage), then greedily drains the graph: each free
session picks the top-ranked available candidate (stage-first — Backlog only when nothing Planned/Todo
is available; Urgent does not pierce stage), ships it after its estimated duration, and resolves its
`blocks` edges. Clean in-flight blockers are assumed to finish within one mean issue duration.

### Step 3: Cross-check the first wave

Run `next-candidates.sh --label specified` and compare its top ranks against the sim's wave-1 `PICK`
lines. The shell script is the pick-time authority (it carries tiers the sim deliberately omits —
assigned-to-me, sibling spread, parent weighting); where they disagree, narrate the divergence in the
report. Never edit the sim output to match.

### Step 4: Render the report

Lead with the headline: the `FORECAST` line (ships / unreached / stranded), the `STAGE` line (hours to
burn Planned/Todo and when Backlog picks begin — often the number the user actually wanted), the
hours-per-issue basis, and any `THROTTLE-RISK` warning. Then:

- **Timeline as waves** — group the `PICK`/`SHIP` events into waves and narrate the unlock chains
  ("TT-1 ships ≈t=2h → frees TT-2"), with the `LANE` lines rendered as a compact per-session Gantt.
- **`POOL-DRAINED`** if present — the certified runway is shorter than the horizon; that gap is the
  argument for certifying more work before launch.
- **Stranded and unreached, with routing** — `STRANDED` rows need keeper action the fleet cannot
  perform; point at `/auto-prep` (whose `fleet-blockers.sh` FOCUS audit owns the remedies and
  transitive root-cause walk) rather than re-deriving remedies here. `UNREACHED` rows are the
  horizon/capacity argument: what a longer run or another session would add.
- **Caveats, once, at the end** — one short line restating that this is an estimate of shape, with
  whatever model simplifications bit this particular run (e.g. many same-file candidates the sim
  schedules concurrently that collision edges would serialize).

## Error handling

- Fetch/parse failure → the script exits non-zero with `ERROR:` on stderr; report it, never render a
  partial timeline from a broken run.
- Zero shippable candidates → the `FORECAST … pool 0 shippable` line is a real result: report it and
  point at `/spec` (certify) or `/auto-prep` (label repair), not at launching anyway.
- Stale `tmp/fleet-recommendation.json` (>24h, same threshold `fleet-launch.sh` warns at) → mention
  the staleness when its defaults were used.
