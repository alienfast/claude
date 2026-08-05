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

- **Deadline** — remaining time, `STOPPED` (a wind-down was requested), or none. Ending a fleet early is `/fleet-launch stop`: it ends the timer, in-flight issues finish, nothing is killed.
- **Sessions** — one row per `tmp/auto-state-*.json` ledger. Liveness is the recorded pid *plus* a process-start-time match, so a reused pid never reads as alive. **A `dead` session whose status still says `active` died without recording an outcome** — its last issue likely sits claimed (In Progress) with a preserved worktree; that is retro/reap material, surfaced here so it isn't discovered days later. Note: killing sessions in `claude agents` (the documented way to abort in-flight work) produces exactly this signature — expected cost, same cleanup.
- **In flight** — live worktrees joined with Linear state and the owning session. A worktree whose issue reads terminal (Done/Canceled) is leftover, awaiting `/reap-worktrees`.
- **Shipped, cross-checked** — the union of every session ledger, each entry verified against commits on the integration branch, falling back to the merge queue. The three verdicts: merged ✓, deferred (queued — a transient block, the drainer retries), or ⚠️ recorded-but-unfound (investigate: a session may have died between recording and merging).
- **Runway** — unblocked certified candidates remaining, with the hidden-count notes (`needs decision` / `solo` / `human`) passed through verbatim.

Surface the script's markdown to the user as-is, then add narration only where the output flags something (⚠️ rows, deferred merges, dead-active sessions) — say what it means and what resolves it, don't repeat the tables in prose.

## What this skill must NOT do

- No writes anywhere — never "fix" a stranded claim, drain the queue, or reap a worktree from here; point at `/fleet-retro`, `/merge-queue`, and `/reap-worktrees` instead.
- No session control — starting is `/fleet-launch`, stopping is `/fleet-launch stop`, killing is the user's `claude agents` view.

## Error Handling

- Not in a git repo → the script errors; relay it.
- `linear-cli` missing or team not inferable → the Linear joins and runway are skipped with a note; the local sections (deadline, sessions, worktrees, git cross-check) still render.
