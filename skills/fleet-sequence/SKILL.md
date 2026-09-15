---
name: fleet-sequence
description: Ship an ordered list of certified issues onto one integration branch and open one PR for the lot — strictly one at a time, each in its own background `claude --bg "/auto <ID>"` session (a fresh context per issue), each forked from the branch's current tip so it carries its predecessor's merged code, then `/pr-update` on the PR. A `merge` token ships them straight into the launch branch instead. The runner for `solo` work and for big issues that must land in order; the targeted, serialized sibling of /fleet-launch. Use when the user says 'fleet sequence', 'run these in sequence', 'ship BF-1 then BF-2 then BF-3', 'sequential auto', 'solo batch', or invokes /fleet-sequence.
---

# Fleet Sequence

The targeted, serialized counterpart of [`/fleet-launch`](../fleet-launch/SKILL.md): instead of N parallel `/loop /auto` pickers, one detached runner walks an explicit issue list, dispatching a single `/auto <ID>` background session at a time and starting the next only after the previous session's ledger says `shipped` and its merge has landed. Every issue ships onto **one integration branch** (`seq/<first-id>`, forked from the branch you launch from), and when the list completes the runner pushes that branch, opens **one PR** onto the launch branch, and runs `/pr-update` on it. All logic lives in [scripts/fleet-sequence.sh](../../scripts/fleet-sequence.sh); this skill dispatches to it and narrates the result.

Why this shape:

- **`solo` never reaches a picker.** `next-candidates.sh` hides `solo` issues from every ranking, so a `/loop /auto` session cannot pick them, and a targeted `/auto <ID>` is one-shot by design (`standards/issue-spec.md` § The `solo` label). Several solo issues therefore need an external sequencer.
- **One session per issue.** A big issue wants its own context; a session that shipped one big issue and then starts another carries the first one's residue into the second. Each child here is a fresh `claude --bg` with exactly one `/auto <ID>` prompt.
- **One branch, one PR — not a stack of PRs.** GitHub's stacked pull requests assume a rebase-and-restack workflow, and this house merges and never rebases ([standards/git.md](../../standards/git.md)). Measured in September 2026 on three PRs stacked on `hotfixes`: when the base moved, every level had to be re-merged separately, each re-run its CI, and the stack still reached the base one merge at a time. An integration branch takes one catch-up merge and one CI run, and it is the release shape an epic-scoped fleet already uses (keeper decision 2026-09-11) — the sequence is that fleet with an explicit list and one lane.
- **The children merge; the runner opens the PR.** Each child runs plain `/auto <ID>` (never `pr` — that token is `/auto`'s and is passed only when a human types it), so `/finish` merges the issue into the integration branch and marks it Ready For Release there, exactly as an epic fleet's members are. The PR is the runner's, opened by [scripts/integration-pr.sh](../../scripts/integration-pr.sh) with a roster body — every ID bare, never behind a close keyword — and then rewritten by a closing `/pr-update` child session from the real diff.

## Arguments

`/fleet-sequence [pr|merge] <ISSUE-ID> <ISSUE-ID>...` · `/fleet-sequence status` · `/fleet-sequence stop`

- **Issue IDs** — every token matching `^[A-Za-z]+-[0-9]+$`, in the order they must ship. Each is probed the way `/auto`'s targeted mode probes (`specified` present, `human` absent) and refused if already Done, Canceled, Duplicate, or Ready For Release — except an issue the marker already records as shipped on this run, which a resume skips without probing (a merge lands at Ready For Release). `solo` is expressly welcome.
- **`pr`** (default) — create `seq/<first-id>` from the launch branch, ship every issue onto it, push it after each ship, open one PR onto the launch branch when the list completes, then `/pr-update`. The launch branch must exist on origin. **`merge`** — no branch and no PR: each issue merges straight into the launch branch, the shape an unscoped fleet ships in; needs no remote.
- `status` — read-only readout (below). `stop` — finish the issue in flight, then stop; what shipped stays on the branch, no PR is opened, nothing is killed.
- Anything else → error: `Unrecognized argument 'X'. /fleet-sequence takes an optional pr|merge, issue IDs in ship order, or the single word status / stop.`

Model and permission defaults follow `/auto`'s unattended-run prerequisites, identical to `/fleet-launch` (`--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto`); pass overrides after `--` when calling the script directly.

## Behavior

Run from the project the issues belong to, with the main checkout **clean** and on the branch the PR should target (usually the default branch). The script refuses a dirty tree, a detached HEAD, a set `start.wt-source-branch` (another posture is in effect), a live fleet, a running sequence, and — in `pr` mode — a launch branch missing from origin or a stray `seq/<first-id>` branch no marker accounts for:

```bash
~/.claude/scripts/fleet-sequence.sh BF-101 BF-102 BF-103          # onto seq/bf-101, one PR at the end
~/.claude/scripts/fleet-sequence.sh merge BF-101 BF-102 BF-103    # straight into the launch branch
```

Surface the script's output verbatim: the sequence line, the runner pid and log path, and its note that the main checkout is parked until the run ends. **Do not wait in this session** — the runner is detached (`nohup`, reparented to launchd) and lives for hours; there is nothing to poll here, and `no-blind-sleep.sh` would refuse the attempt anyway. Close by telling the user how to watch, and that the main checkout is the runner's until the run ends:

- `/fleet-sequence status` — mode, branch and base, the PR once it exists, per-issue session id, registry liveness, outcome and the commit it landed at, the branch's position against its base, the runner's own liveness, and the log tail.
- `claude agents` — every child is named `fleet-sequence <ID>` (the closing one `fleet-sequence pr-update`), so the view reads as the queue.

Invoking `/fleet-sequence` is the run-scoped commit/push grant for the issues it lists, exactly as `/auto` is for a loop: each child ships under `/auto`'s grant, merging into the integration branch, and the runner pushes that branch and opens its PR ([standards/git.md](../../standards/git.md) § Named exceptions).

### The runner's contract

Per issue, in list order:

1. Refuse to continue if the main checkout is dirty (a session would halt on it — the sequence fails with the reason recorded).
2. **Park the checkout.** `/start wt` forks from the main checkout's HEAD, not from a branch ref, and `/finish` merges into the branch recorded as the source — so the runner **detaches HEAD at the integration branch's current tip and sets `start.wt-source-branch` to it before every dispatch**, the detached-HEAD path start-wt-setup.sh documents. Re-detaching each time is what makes each fork carry its predecessor: the ref moves at every merge, a detached HEAD does not. In `merge` mode the checkout simply stays on the launch branch and each merge fast-forwards it.
3. Dispatch `claude --bg <flags> -n "fleet-sequence <ID>" "/auto <ID>"` and record the short id `claude --bg` prints — the same id that keys the session's ledger `tmp/auto-state-<id>.json`.
4. Wait for the **ledger** — `tmp/auto-state-<id>.json` recording the issue in any outcome list. That file is `/auto` Step 4's last act (Linear comment, label, ownership release, then the state file), so an outcome means the work is over whatever the session registry says: measured 2026-09-10, a session sat busy in `claude agents` for seven hours after its ledger said shipped, and a registry-only wait burned the whole timeout. The registry is the fallback for a session that ends without a ledger (`done`, or absent after `FLEET_SEQUENCE_GRACE`, 120s). A ledger keyed by something other than the session id counts only if written since the dispatch, so an earlier run's ledger naming the same issue cannot fake a ship. Polls every `FLEET_SEQUENCE_POLL` (30s), bounded by `FLEET_SEQUENCE_ISSUE_TIMEOUT` (6h): on expiry the sequence fails and the session is **left running**.
5. Read the outcome — which of `shipped` / `canceled` / `skipped` / `failed` lists the issue. Only `shipped` continues. Shipped means merged, so the branch's tip must have **moved** past where the dispatch saw it: a `shipped` whose merge the queue deferred (`DEFERRED-MERGE`) is waited on up to `FLEET_SEQUENCE_MERGE_TIMEOUT` (30 min; the drainer runs every 15) and named as queued when `.claude/merge-queue/<id>.json` exists; a tip that never moves fails the sequence. The landing commit is recorded, a landing whose commits never mention the issue is a WARN, and in `pr` mode the branch is pushed (best-effort — the PR step pushes again and fails loudly).
6. Anything else stops the sequence: `status: failed`, the reason names the issue, its session, and the issues not started. `/auto` has already posted the Linear comment and applied `stalled` (or a park label) on that issue, so the human-facing trail is on the issue itself.

When the last issue has landed (`pr` mode): `integration-pr.sh` pushes the branch, finds or opens the PR onto the launch branch with the roster body, and reports how many commits the base gained during the run — that many is one catch-up merge (GitHub's *Update branch*) before it merges. Then the checkout is attached to the branch for one closing child, `claude --bg -n "fleet-sequence pr-update" "/pr-update"`, waited on up to `FLEET_SEQUENCE_PR_UPDATE_TIMEOUT` (30 min; `FLEET_SEQUENCE_PR_UPDATE=0` skips it). A PR that cannot be opened fails the run with the ships kept — re-running the same list repeats only the PR step.

On every exit — done, failed, stopped, or crashed — the runner puts the main checkout back on the launch branch and unsets the config.

**Marker:** `<main-checkout>/tmp/fleet-sequence.json` — `{queue, base, mode: pr|merge, branch, claude_args, status: running|done|failed|stopped, reason, stop_requested, current, issues: {<ID>: {session, started_epoch, ended_epoch, outcome, tip_before, landed_sha}}, pr_url, pr_number, pr_update_session, launch_epoch, log, runner_pid}`. **Log:** `tmp/fleet-sequence.log`. Both persist after the run for inspection; the next launch rewrites them.

### Stopping, resuming, merging

- `/fleet-sequence stop` sets `stop_requested`; the runner checks it before each dispatch, so the issue in flight finishes and nothing else starts. Killing an in-flight session is `claude agents`, never this skill.
- **Re-running the same list resumes.** On the same launch branch and mode (and, in `pr` mode, while the integration branch still exists) issues the marker recorded as shipped are skipped and the next one forks from the branch's tip, which already carries them. This is the recovery path after a failure too — fix or drop the failed issue (re-list it to retry, omit it to skip), then re-run; a list whose every issue has shipped goes straight to the PR step. A run from a different branch is a fresh sequence, and a fresh sequence refuses a leftover `seq/<first-id>` branch it did not create (delete it, or re-run the list that made it).
- **Merge the one PR.** Review it by commit if you like — the common case fast-forwards each issue's own commits, with its ID in every message — then merge it (merge commit, as always). Each issue was marked Ready For Release when it landed on the integration branch (keeper ruling 2026-09-11: that is the state of work waiting for its release; `In Review` is a human-review request, never a ship's state), so the PR merging changes nothing in Linear. In `merge` mode there is nothing to merge: the launch branch already carries every issue.

## Relationship to the fleet skills

- **Never mid-fleet.** A sequence is solo work by definition; the script refuses when `tmp/fleet-deadline.json` names a session the registry still lists as running. Run it before or after a fleet, as `standards/issue-spec.md` § The `solo` label prescribes.
- **The same posture as an epic fleet.** Detached HEAD at an integration branch plus `start.wt-source-branch`, merges landing ref-only, one PR at the end — `fleet-launch.sh` sets it once for a fleet; the sequence re-sets it per issue. The two therefore refuse each other: a set `start.wt-source-branch` at launch is another run's posture. The post-fleet PR step is the same script, `integration-pr.sh`.
- `/fleet-status` does not row these sessions: their ledgers are `mode: single`, which it labels rather than counts. `/fleet-sequence status` is the readout. `/fleet-retro` measures them when named with `--sessions`.
- `/auto`'s targeted mode ignores the fleet deadline by construction, so a deadline marker left by an earlier fleet does not gate a sequence.

## Error Handling

- Refusals before dispatch (nothing launched, checkout untouched, no branch created): an unparseable or duplicate ID; `pr` and `merge` together; an issue without `specified`, with `human`, or already terminal; `linear-cli` unreachable; a dirty tree (files listed); detached HEAD; a set `start.wt-source-branch`; a live fleet; a running sequence; in `pr` mode no `origin`, a launch branch missing from origin, or a stray `seq/<first-id>` branch; any option other than a trailing `--`.
- Runner failures land in the marker's `reason` and the log; `status` shows both, and the checkout is already back on the launch branch. A dispatch whose session id could not be read fails fast (the runner cannot wait on an unknown session) — find it in `claude agents`, let it finish, then re-run the list.
- `claude`, `jq`, `git`, or `gh` missing → the script errors before doing anything; relay it.
