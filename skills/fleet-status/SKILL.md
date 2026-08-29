---
name: fleet-status
description: One-screen readout of a running (or just-finished) /fleet-launch — time remaining on the deadline, per-session shipped/canceled/failed ledgers with liveness, in-flight issues from live worktrees, the shipped ledger cross-checked against git and the merge queue, stalled flags, and remaining certified runway. Read-only. Use when the user says 'fleet status', 'how's the fleet doing', 'what has the fleet shipped', 'what's in flight', 'how much time is left on the fleet', or invokes /fleet-status.
argument-hint: "[--no-runway]"
---

# Fleet Status

The during-view of the fleet workflow: `/auto-prep` (before) → `/fleet-launch` (dispatch) → **`/fleet-status`** (any time) → `/fleet-retro` (after). All logic lives in [scripts/fleet-status.sh](../../scripts/fleet-status.sh); this skill dispatches to it and narrates. Strictly read-only — no Linear writes, no git mutations — so it is safe to run mid-fleet, repeatedly, or with no fleet at all.

Run from the project the fleet works on (a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-status.sh              # full readout
~/.claude/scripts/fleet-status.sh --no-runway  # skip the remaining-candidates count (the one slow section)
```

## Reading the output

- **Deadline** — remaining time, `STOPPED` (a wind-down was requested), or none. Ending a fleet early is [`/fleet-stop`](../fleet-stop/SKILL.md): it ends the timer, in-flight issues finish, nothing is killed.
- **Sessions** — one row per `tmp/auto-state-*.json` ledger **from the current fleet**: a ledger whose last write predates the launch (the marker's `launch_epoch`; marker mtime for pre-2026-08 markers) is prior-run history, hidden with a count — `/fleet-retro` reads those until the next `/fleet-launch` clears the dead ones. Liveness comes from the session registry (`claude agents --json`), joined on the ledger's filename key. **The ledger's recorded pid cannot answer it and is never reported as one** — under `claude agents` every session in a fleet embeds the fleet-root pid, so siblings share one value while a session whose recorded ancestor exited reads dead mid-work (measured 2026-08-25: all three ledgers of one fleet held a pid that was not their session's, in both directions). Three row shapes follow. **`ALIVE (<state>)`** — the registry lists it. **`dead`** — the registry is available and does *not* list it; only this shape may be treated as a session that is genuinely gone, and only this one is ever retro/reap material. **Paired with a `status` still reading `active` it has two causes, and only one strands anything**: the session died without recording an outcome (its last issue likely sits claimed with a preserved worktree), or it wound down cleanly and never wrote its terminal status. Its transcript tells them apart — a `NO-CANDIDATES`/`AUTO-HALTED` tag or a `ScheduleWakeup(stop: true)` means it finished as designed and nothing is stranded; `fleet-metrics.py` reports that second shape as `wound down but never finalized its ledger`. Measured 2026-08-22: one of three sessions sat that way for 5+ hours at 0.0% CPU and was twice called possibly-wedged and a kill candidate, having shipped all 3 of its issues and exited correctly. **`unknown (no registry; pid …)`** — `claude` was unavailable, so the pid hint is all there is; **this is not evidence of death and must never be reaped against.** Note: killing sessions in `claude agents` (the documented way to abort in-flight work) produces a genuine `dead` row — expected cost, same cleanup.

  A **`no ledger`** row is a session that owns a live worktree here but has written no `auto-state` file. Its shipped work is *not* in the Shipped cross-check below, which is built from ledgers alone, so treat the row as a gap in the ledger rather than as an idle session. Only `/auto` sessions are listed — an interactive session holding a worktree is the operator's own work, not a fleet member that lost its ledger, and appears under In flight only. `/fleet-retro` recovers ledger-less sessions from transcripts.
- **In flight** — live worktrees joined with Linear state and the owning session. A worktree whose issue reads terminal (Done/Canceled) is leftover, awaiting `/reap-worktrees`.
- **Shipped, cross-checked** — the union of the fleet's session ledgers, each entry verified against commits on the integration branch, falling back to the merge queue. The three verdicts: merged ✓, deferred (queued — a transient block, the drainer retries), or ⚠️ recorded-but-unfound (investigate: a session may have died between recording and merging).
- **Failed/canceled, cross-checked** — each recorded failure/cancel joined with the issue's *current* Linear state. A ledger entry is a claim about that run only: a later session or an interactive pickup can resolve the issue without writing any ledger, so a completed-type state renders as "since shipped" history rather than a live failure. Only ⚠️ rows (a failure still unshipped, or a cancel Linear disagrees with) need action.
- **Runway** — unblocked certified candidates remaining, with the hidden-count notes (`needs decision` / `solo` / `human`) passed through verbatim.

Surface the script's markdown to the user as-is, then add narration only where the output flags something (⚠️ rows, deferred merges, dead-active sessions) — say what it means and what resolves it, don't repeat the tables in prose.

## What this skill must NOT do

- No writes anywhere — never "fix" a stranded claim, drain the queue, or reap a worktree from here; point at `/fleet-retro`, `/merge-queue`, and `/reap-worktrees` instead.
- No session control — starting is `/fleet-launch`, stopping is `/fleet-stop`, killing is the user's `claude agents` view.

## Error Handling

- Not in a git repo → the script errors; relay it.
- `linear-cli` missing or team not inferable → the Linear joins and runway are skipped with a note; the local sections (deadline, sessions, worktrees, git cross-check) still render.
