---
name: fleet-solo
description: Ship every workable `solo` issue unattended, one at a time — lists them (the set /auto-prep reports), runs each in its own background `/auto <ID>` session merging into the launch branch, skips one that fails and carries on, optionally inside a time budget; `then-fleet` launches the fleet once the drain ends clean. Use when the user says 'fleet solo', 'run the solo issues', 'drain the solos', 'solos then the fleet', or invokes /fleet-solo.
---

# Fleet Solo

The quiet-window runner of the fleet workflow: `/auto-prep` (marks and lists `solo`) → **`/fleet-solo`** →
`/fleet-launch`. A `solo` issue ships fine unattended but not beside a fleet
([standards/issue-spec.md](../../standards/issue-spec.md) § The `solo` label), so no picker ever takes one and, left to a
human copying IDs into `/fleet-sequence`, the pile grows. This is the `solo` form of that runner:
[scripts/fleet-sequence.sh](../../scripts/fleet-sequence.sh) owns the logic and the marker, this skill dispatches and
narrates.

```bash
~/.claude/scripts/fleet-sequence.sh solo list                  # the running order; launches nothing
~/.claude/scripts/fleet-sequence.sh solo                       # drain until no workable solo issue is left
~/.claude/scripts/fleet-sequence.sh solo 3h then-fleet 6 10h   # end of day: solos first, then the fleet
```

## Arguments

`/fleet-solo [list] [<duration>] [then-fleet [<fleet-launch tokens>...]] [stale-ok]` · `/fleet-solo status` ·
`/fleet-solo stop`

- **(none)** — drain: ship the workable `solo` issues one at a time until the listing is empty.
- `list` — print the running order, each issue probed as its dispatch will be, and launch nothing.
- `<duration>` (`3h`, `3 hours`, `90m`) — a budget. No issue starts after it; the one in flight runs to completion.
- `then-fleet [<tokens>]` — once the drain ends **clean** (drained, or out of time), run `fleet-launch.sh` with the
  tokens that follow, exactly as [`/fleet-launch`](../fleet-launch/SKILL.md) takes them (`6 10h`, `backlog`,
  `stale-ok`; none → the recommendation `/auto-prep` persisted, no deadline). The fleet's duration counts from its own
  launch. Never launched after a stop, the fail limit, or an issue left in flight. **Pass it only when the user asked
  for the fleet to follow** — it is the same launch `/fleet-launch` is, made hours later with nobody watching.
- `stale-ok` — launch although `~/.claude` is behind `origin/main` in a file sessions load; without it the launch stops
  with `TOOLING-STALE` (exit 4), handled as
  [`/fleet-launch`'s Tooling confirmation](../fleet-launch/SKILL.md#tooling-confirmation--stale-claude-is-asked-about-never-launched-on).
  It covers the drain only: a fleet that should also launch on stale tooling takes its own `stale-ok` after `then-fleet`.
- `status` → `fleet-sequence.sh status solo` · `stop` → `fleet-sequence.sh stop solo` (the issue in flight finishes,
  nothing else starts, no fleet is launched; nothing is killed).
- An issue ID, or `pr`, is refused: a named list, or one PR for the lot, is [`/fleet-sequence`](../fleet-sequence/SKILL.md).

## How a drain differs from a sequence

| | `/fleet-sequence <IDs>` | `/fleet-solo` |
| --- | --- | --- |
| Queue | the IDs typed, in that order | `next-candidates.sh --label solo` for `$LINEAR_TEAM`, read again before every dispatch |
| Lands | one PR from `seq/<id>`, or `merge` | always `merge` into the launch branch |
| An issue ends without shipping | the sequence stops | recorded and skipped; two in a row stop the drain |
| Budget | none | optional duration |
| Afterwards | the PR | optionally the fleet |

- **Re-read, never frozen.** An issue a predecessor's ship unblocked joins the same run; one that left the pool
  (claimed, canceled, label cleared, put on `hold`) is never dispatched from a stale list; one the probe refuses at its
  turn (uncertified, held, already shipped) is recorded `refused` and gets no session.
- **Merge, not a branch.** A broad change parked on `seq/…` until its PR merges only moves the collision to the catch-up
  merge, with a fleet already running on a base that lacks it.
- **Skip, with a limit.** Solo issues do not build on each other, so a failed one costs the drain that issue; `/auto`
  has already commented and labeled it. Two `failed`/no-ledger outcomes in a row are a pattern the next issue would
  repeat (a broken base, an outage): the drain stops `failed` and no fleet follows. `skipped` and `canceled` — `/auto`
  declining an issue — never count.
- **The listing's order is the running order** — Planned/Todo before Backlog, then the ranking `/next` uses. An order
  that matters must live in Linear where the listing reads it: a `blocks` edge between two solo issues (the blocked one
  joins once its blocker ships) or priority. A comment saying "run this first" orders nothing.

## Behavior

Run from the project the issues belong to, on the branch they should merge into, with `LINEAR_TEAM` exported (the
launch refuses without it: the listing would span every team in the workspace). A checkout parked for a fleet —
detached, with `start.wt-source-branch` naming the branch, the posture `/auto-prep`'s launch checklist asks for — works
too: the drain merges by ref into the branch the key names and leaves the checkout parked for the fleet that follows. Surface the script's output verbatim —
the plan with any `[will be skipped: …]` note, the `Budget:` and `Then:` lines, the runner pid and log path, and a
`WARN` naming a fleet still working in the checkout (the operator's call, never a refusal). **Do not wait in this
session**: the runner is detached and lives for hours. Close by saying how to watch (`/fleet-solo status`,
`claude agents` — children are named `fleet-sequence <ID>`) and that the checkout stays the user's.

Invoking `/fleet-solo` is the run-scoped commit grant for the issues the drain takes, as `/fleet-sequence` is for the
issues it lists ([standards/git.md](../../standards/git.md) § Named exceptions).

One drain runs per checkout (marker `tmp/fleet-sequence-solo.json`, log beside it). A re-launch after a `failed` or
`stopped` drain starts from the listing again, and first **waits on** any session the last drain left working, or any
ship whose merge never landed — it never dispatches beside one.

### Reading the result

`/fleet-solo status` prints the outcome per issue, the reason the drain ended, and whether the fleet launched:

- `done` — drained, or out of time. With `then-fleet` the fleet is running; `/fleet-status` reads it.
- `stopped` — `/fleet-solo stop`; what shipped stays merged.
- `failed` — the reason names it: two issues in a row without a ship; a listing Linear would not answer after its
  retries; a session still working at the per-issue timeout or a shipped merge that never landed (both left as they
  are — re-run the drain to wait on them); or a fleet launch `fleet-launch.sh` refused, with the drain's result kept.

## Relationship to the fleet skills

- [`/auto-prep`](../auto-prep/SKILL.md) marks `solo` and prints this skill's command with its quiet-window plan.
- A list never resumes a drain and a drain never takes an issue a running sequence holds; two merge-mode runners on
  one launch branch are refused in either order.
- `/fleet-status` does not row these sessions (their ledgers are `mode: single`); `/fleet-retro` measures them when
  named with `--sessions`.

## Error Handling

- Refused before anything is dispatched or written: `LINEAR_TEAM` unset; a listing that could not be read; an issue
  ID, `pr`, or a duration that does not parse; a drain already running; a merge-mode sequence already merging into
  this branch; unfinished work from the last drain on a different branch; a dirty tree on a branch whose name carries
  an issue ID; a detached HEAD with no `start.wt-source-branch` naming a local branch; `then-fleet` tokens `fleet-launch.sh` refuses (its message is relayed — a missing
  recommendation, a count out of range); `TOOLING-STALE` (exit 4) and a missing `loop-boundary` mod (exit 5).
- No workable solo issue → the script says so and exits 0 with nothing written; with `then-fleet` the fleet launches.
- `claude`, `jq`, `git`, `gh` or `linear-cli` missing → the script errors before doing anything; relay it.
