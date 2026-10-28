---
name: fleet-status
description: One-screen read-only readout of a running or just-finished /fleet-launch — time left on the deadline, per-session ledgers with liveness, in-flight worktrees, shipped work cross-checked against git and the merge queue, and remaining certified runway. Use when the user says 'fleet status', 'how's the fleet doing', 'what has the fleet shipped', 'what's in flight', or invokes /fleet-status.
argument-hint: "[epic:<ID> | team] [--no-runway]"
---

# Fleet Status

The during-view of the fleet workflow: `/auto-prep` (before) → `/fleet-launch` (dispatch) → **`/fleet-status`** (any
time) → `/fleet-retro` (after). All logic lives in [scripts/fleet-status.sh](../../scripts/fleet-status.sh); this skill
dispatches to it and narrates. Strictly read-only — no Linear writes, no git mutations — so it is safe mid-fleet,
repeatedly, or with no fleet at all.

Run from the project the fleet works on (a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-status.sh                 # every running fleet, one section each
~/.claude/scripts/fleet-status.sh epic:BF-2948    # one fleet alone (or `team`)
~/.claude/scripts/fleet-status.sh --no-runway     # skip the remaining-candidates count (the one slow section, per fleet)
```

Several fleets run side by side in one checkout, one marker each (`tmp/fleet-deadline-<slug>.json`,
[`/fleet-launch`](../fleet-launch/SKILL.md) § Several fleets in one checkout). With no token the readout opens with a
line naming them and renders the per-fleet sections (deadline, headroom, scope, sessions, shipped, failed/canceled,
runway) once per fleet under `### Fleet <token>`, then the checkout-wide sections (in flight, merge queue, attention)
once. An archived marker (an ended run a later launch displaced) is never a section.

## Reading the output

- **Deadline** — remaining time, `STOPPED` (a wind-down was requested), or none. The marker's fields and who writes them
  are [`/fleet-launch`](../fleet-launch/SKILL.md) § The deadline contract; ending a fleet early is
  [`/fleet-stop`](../fleet-stop/SKILL.md), whose token the wind-down line names.
- **Headroom** (only when it matters) — the pick-time probe `/auto` parks on (`scripts/fleet-headroom.sh`), run once per
  fleet session on its own `mods/rate-limits` history. `Headroom: THROTTLE` means that account's 5h window is within the
  reserve of full — and, on a cswap-rotating machine, that no other account has room (the `cswap=` tail says which):
  sessions park between picks and re-probe at the reset, so a ledger that has gone quiet is likely parked, not dead — wait
  it out rather than reaping. `⚠️ Headroom gate is blind` means no reading exists, so every pick fails open; enable
  `rate-limits@alienfast-claude` before the next launch. Nothing prints when every reading says `PICK-OK`.
- **Scope** (epic-scoped fleets only) — the epic, its integration branch and base, and a **member burn-down**:
  `N shipped · M remaining (K in flight: …) · A added since prep: …`, plus the shipped members with their states. The
  burn-down is a live `epic-graph.sh` read against the `members` snapshot the launch recorded, so a child filed mid-run
  appears as *added since prep*; a member resolved outside the fleet's own ledgers counts as shipped only. A marker with no
  snapshot says added-since-prep is unknown. The Runway section is then the epic's own `--root` ranking.
- **Sessions** — one row per `tmp/auto-state-*.json` ledger **from that fleet**: membership in its marker's
  `fleet_sessions`, else a ledger whose last write predates `launch_epoch` is prior-run history. Non-members — another
  fleet's sessions, an ended fleet's awaiting its retro — are hidden with a count, single-run ledgers (`mode: single`) are
  never rowed and get their own count, and a recorded member with no ledger rows as `no ledger`. Liveness comes from the session registry (`claude agents --json`), joined on the ledger's
  filename key — **the ledger's recorded pid cannot answer it**: every session in a fleet embeds the fleet-root pid, so
  siblings share one value. Three row shapes:
  - **`ALIVE (<state>)`** — the registry lists it.
  - **`dead`** — the registry is available and does not list it, or lists it as ended (`dead (ended)`: a
    `done`/`failed`/`stopped` state, or the row `claude stop` leaves with `status` and `pid` gone). Only this shape may be
    treated as genuinely gone, and only this one is retro/reap material. Paired with a `status` still `active` it has two
    causes, and only one strands anything: the session died without recording an outcome (its last issue likely sits
    claimed with a preserved worktree), or it wound down cleanly and never wrote its terminal status. The transcript tells
    them apart — a `NO-CANDIDATES`/`AUTO-HALTED` tag or a `ScheduleWakeup(stop: true)` means it finished as designed;
    `fleet-metrics.py` reports that shape as `wound down but never finalized its ledger`. A finished fleet's rows read
    `dead` by design: `hooks/auto-rewake.sh` retires every drained session at its loop end (`claude stop`, then
    `claude rm`), with their ledgers `drained`.
  - **`unknown (no registry; pid …)`** — `claude` was unavailable; **not evidence of death, never reap against it.**

  A **`no ledger`** row is a session that owns a live worktree here but has written no `auto-state` file. Its shipped work
  is *not* in the Shipped cross-check below, which is built from ledgers alone — treat the row as a gap in the ledger, not
  an idle session. Only `/auto` sessions are listed; an interactive session holding a worktree appears under In flight
  only. `/fleet-retro` recovers ledger-less sessions from transcripts.
- **In flight** — live worktrees joined with Linear state and the owning session. A worktree whose issue reads terminal
  is leftover, awaiting `/reap-worktrees`.
- **Shipped, cross-checked** — the union of the fleet's ledgers, each entry verified against commits on the integration
  branch, falling back to the merge queue: merged ✓, deferred (queued — the drainer retries), or ⚠️ recorded-but-unfound
  (a session may have died between recording and merging).
- **Failed/canceled, cross-checked** — each recorded failure or cancel joined with the issue's *current* Linear state. A
  ledger entry is a claim about that run only: a later session or an interactive pickup can resolve the issue without
  writing any ledger, so a completed-type state renders as "since shipped" history. Only ⚠️ rows need action.
- **Runway** — unblocked certified candidates remaining, with the hidden-count notes (`needs decision` / `solo` /
  `deploy-gated` / `human`) passed through verbatim. Under a `backlog` launch — every epic-scoped launch is one — the
  count includes Backlog once nothing Planned/Todo is pickable and the heading says `(backlog fallback on)`.

Surface the script's markdown as-is, then narrate only where the output flags something (⚠️ rows, deferred merges,
dead-active sessions) — what it means and what resolves it; don't repeat the tables in prose.

## What this skill must NOT do

- No writes anywhere — never "fix" a stranded claim, drain the queue, or reap a worktree from here; point at
  `/fleet-retro`, `/merge-queue`, and `/reap-worktrees`.
- No session control — starting is `/fleet-launch`, stopping is `/fleet-stop`, killing is the user's `claude agents`.

## Error Handling

- Not in a git repo → the script errors; relay it.
- A token naming a fleet with no marker → exit 1 with the fleets that do have one listed; relay the list.
- `linear-cli` missing or team not inferable → the Linear joins and runway are skipped with a note; the local sections
  (deadline, sessions, worktrees, git cross-check) still render.
