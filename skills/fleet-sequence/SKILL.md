---
name: fleet-sequence
description: Ship an ordered list of certified issues one at a time onto one integration branch and open one PR — each issue in its own background `/auto <ID>` session forked from the branch's tip; `merge` ships straight into the launch branch. The runner for `solo` and ordered big issues. Use when the user says 'fleet sequence', 'run these in sequence', 'ship BF-1 then BF-2', or invokes /fleet-sequence.
---

# Fleet Sequence

The targeted, serialized counterpart of [`/fleet-launch`](../fleet-launch/SKILL.md): one detached runner walks an
explicit issue list, dispatching a single `/auto <ID>` background session at a time and starting the next only after the
previous session's ledger says `shipped` and its merge has landed. Every issue ships onto **one integration branch**
(`seq/<first-id>`, forked from the branch you launch from); when the list completes the runner pushes that branch, opens
**one PR** onto the launch branch, and runs `/pr-update` on it. All logic lives in
[scripts/fleet-sequence.sh](../../scripts/fleet-sequence.sh); this skill dispatches to it and narrates.

Why this shape:

- **`solo` never reaches a picker.** `next-candidates.sh` hides `solo` issues from every ranking and a targeted
  `/auto <ID>` is one-shot (`standards/issue-spec.md` § The `solo` label), so several solo issues need a sequencer.
- **One session per issue.** A big issue wants its own context; each child is a fresh `claude --bg` with one prompt.
- **One branch, one PR — not a stack.** Stacked PRs assume rebase-and-restack and this house merges, never rebases
  ([standards/git.md](../../standards/git.md)); an integration branch takes one catch-up merge, and it is the release
  shape an epic-scoped fleet uses.
- **The children merge; the runner opens the PR.** Each child runs plain `/auto <ID>` (never `pr` — that token is passed
  only when a human types it), so `/finish` merges the issue into the integration branch and marks it Ready For Release
  there. [scripts/integration-pr.sh](../../scripts/integration-pr.sh) opens the PR with a roster body (every ID bare,
  never behind a close keyword); a closing `/pr-update` child rewrites it from the real diff.

## Arguments

`/fleet-sequence [pr|merge] [stale-ok] <ISSUE-ID> <ISSUE-ID>...` · `/fleet-sequence status [<ISSUE-ID>]` ·
`/fleet-sequence stop [<ISSUE-ID>]`

- **Issue IDs** — every token matching `^[A-Za-z]+-[0-9]+$`, in ship order. Each is probed as `/auto`'s targeted mode
  probes (`specified` present, `human` absent) and refused if already Done, Canceled, Duplicate, or Ready For Release —
  except an issue the marker records as shipped on this run, which a resume skips. `solo` is expressly welcome.
- **`pr`** (default) — create `seq/<first-id>` from the launch branch, ship every issue onto it, push after each ship,
  open one PR onto the launch branch when the list completes, then `/pr-update`. The launch branch must exist on origin.
  **`merge`** — no branch and no PR: each issue merges straight into the launch branch; needs no remote.
- `stale-ok` — launch although `~/.claude` is behind `origin/main` in a file sessions load. Without it the launch stops
  with `TOOLING-STALE` (exit 4) before anything is created; handle it as
  [`/fleet-launch`'s Tooling confirmation](../fleet-launch/SKILL.md#tooling-confirmation--stale-claude-is-asked-about-never-launched-on)
  does. The check runs once, at launch.
- `status` — read-only readout: with an ID, the sequence naming that issue; without, every running sequence, or the
  latest when none runs. `stop` — finish the issue in flight, then stop; what shipped stays on the branch, no PR is
  opened, nothing is killed. It needs an ID only when several sequences are running.
- Anything else → error: `Unrecognized argument 'X'. /fleet-sequence takes an optional pr|merge and stale-ok, issue IDs
  in ship order, or status / stop with an optional issue ID.`

## Sequences are discrete

**The list decides which sequence a launch is — never the launch branch.** A list sharing an issue with an earlier
sequence (same launch branch and mode, its `seq/` branch still there) resumes it; a list sharing none is a **new**
sequence with its own branch, marker, log, and PR. To *extend* an earlier sequence, name one of its issues. A list sharing
issues with two earlier sequences is refused: split it. Deciding by branch alone would fork an unrelated list from, and
rewrite the marker of, a sequence it never belonged to.

State is keyed by the sequence's **slug** — the lowercased first ID of the list that created it, the suffix of its
branch — fixed across resumes, including one that drops the first issue.

Several sequences may run at once, each strictly serial within itself, and a fleet may run beside them
([Relationship to the fleet skills](#relationship-to-the-fleet-skills)). Two guards keep them apart: an issue a live
runner holds is refused in any other list, and two `merge` sequences never share a launch branch (each would read the
other's merges as its own landings). Whether to run two at once is the operator's call — `solo` work still wants the
checkout's merge point and the check gate to itself.

Model and permission defaults are `/fleet-launch`'s (`--model 'opus[1m]' --effort xhigh --permission-mode auto`, no
`--autocompact` — the `loop-boundary` mod owns boundary compaction, and the launch refuses, exit 5, where it is not
enabled unless an explicit `--autocompact` is passed); overrides go after `--` when calling the script directly.

## Behavior

Run from the project the issues belong to, on the branch the PR should target (usually the default branch). The script
refuses a dirty tree on a branch whose name carries an issue ID (each child's `/auto` would refuse that dirt or finish it
as its own work), a detached HEAD, an issue a running sequence holds, and — in `pr` mode — a launch branch missing from
origin or a stray `seq/<first-id>` branch no marker accounts for:

```bash
~/.claude/scripts/fleet-sequence.sh BF-101 BF-102 BF-103          # onto seq/bf-101, one PR at the end
~/.claude/scripts/fleet-sequence.sh merge BF-101 BF-102 BF-103    # straight into the launch branch
```

Surface the script's output verbatim: the sequence line, the runner pid and log path, and its note that the main
checkout is never moved. **Do not wait in this session** — the runner is detached in a session of its own (a `setsid`
fork survives a harness restart that takes the tool shell) and lives for hours; `no-blind-sleep.sh` refuses the attempt
anyway. Close by telling the user how to watch and that the checkout stays theirs — other worktree sessions may run
alongside, and an uncommitted edit there only holds a merge that changes the same path (it defers to the queue and the
runner waits). **Read the `Sequence:` line before closing:** it names the branch the list ships onto, and `Resuming on …`
means the list joined an earlier sequence — expected on a re-run, a surprise to raise on a new list.

- `/fleet-sequence status [<ISSUE-ID>]` — mode, branch and base, the PR once it exists, any per-issue fork key set,
  per-issue session id, registry liveness, outcome and landing commit, the branch's position against its base, the
  runner's liveness, and the log tail.
- `claude agents` — every child is named `fleet-sequence <ID>` (the closing one `fleet-sequence pr-update`).

Invoking `/fleet-sequence` is the run-scoped commit/push grant for the issues it lists, as `/auto` is for a loop: each
child ships under `/auto`'s grant and the runner pushes the branch and opens its PR ([standards/git.md](../../standards/git.md)
§ Named exceptions).

### The runner's contract

Per issue, in list order:

1. Note a dirty main checkout in the log and continue — except on a branch whose name carries an issue ID, where the
   sequence fails with the reason recorded.
2. **Steer the fork with a per-issue key.** Set `start.<id-lower>.wt-source-branch` to the integration branch (the launch
   branch in `merge` mode) just before the dispatch and unset it once the session ends. `/start wt` resolves that key
   ahead of the checkout's branch and forks from the branch's *ref*, so each fork is the branch's current tip and carries
   every predecessor's merge, `finish-merge.sh` advances the branch ref-only, and a `/start wt` for any *other* issue still
   forks from the checkout's own branch. The main checkout never moves. `scripts/auto-fork-key.sh`'s header documents the
   key; an epic fleet's sessions set the same one.
3. Dispatch `claude --bg <flags> -n "fleet-sequence <ID>" "/auto <ID>"` and record the short id it prints — the key of
   the session's ledger `tmp/auto-state-<id>.json`.
4. Wait for the **ledger** to record the issue in any outcome list (`skills/auto/SKILL.md` Step 4 — the file is
   `/auto`'s last act, so an outcome means the work is over whatever the registry says; a session can sit busy for hours
   after its ledger said shipped). The registry is the fallback for a session that ends without a ledger (`done`,
   `failed`, `stopped` — the row `claude stop` leaves keeps its state and loses `status`/`pid`, read as `stopped` — or
   absent after `FLEET_SEQUENCE_GRACE`, 120s). A session listed **`idle`** with no ledger ended its turn without
   finishing; `hooks/auto-rewake.sh` retries it every ~15 minutes for up to six hours, and the runner logs the
   transitions and keeps waiting. A ledger keyed by something other than the session id counts only if written since the
   dispatch. Polls every `FLEET_SEQUENCE_POLL` (30s), bounded by `FLEET_SEQUENCE_ISSUE_TIMEOUT` (12h — big and `solo` work
   runs long): on expiry the sequence fails naming the state the registry last showed, and the session is **left
   running**.
5. Read the outcome. Only `shipped` continues, and shipped means merged: the branch tip must have **moved** past where
   the dispatch saw it and the merge queue must no longer hold the issue. A `DEFERRED-MERGE` is waited on up to
   `FLEET_SEQUENCE_MERGE_TIMEOUT` (30 min; the drainer runs every 15) and named as queued while
   `.claude/merge-queue/<id>.json` exists; a tip that never moves fails the sequence. The landing commit is recorded, a
   landing whose commits never mention the issue is a WARN, and in `pr` mode the branch is pushed (best-effort — the PR
   step pushes again and fails loudly).
6. Anything else stops the sequence: `status: failed`, the reason naming the issue, its session, and the issues not
   started. `/auto` has already posted the Linear comment and applied `stalled` or a park label.

When the last issue lands (`pr` mode): `integration-pr.sh` pushes the branch, finds or opens the PR with the roster body,
and reports how many commits the base gained — one catch-up merge (GitHub's *Update branch*) before it merges. Then one
closing child, `claude --bg -n "fleet-sequence pr-update" "/pr-update"`, runs from a throwaway worktree on the branch
(`tmp/fleet-sequence-pr-update-<slug>`, removed when the session ends; left with a WARN on timeout), waited on up to
`FLEET_SEQUENCE_PR_UPDATE_TIMEOUT` (30 min; `FLEET_SEQUENCE_PR_UPDATE=0` skips it). A PR that cannot be opened fails the
run with the ships kept — re-running the same list repeats only the PR step.

On every exit — done, failed, stopped, crashed — the runner unsets every per-issue key its queue could have set. It never
touches the main checkout's HEAD.

**Marker:** `<main-checkout>/tmp/fleet-sequence-<slug>.json`, one per sequence — `{slug, queue, base, mode: pr|merge,
branch, claude_args, status: running|done|failed|stopped, reason, stop_requested, current, issues: {<ID>: {session,
started_epoch, ended_epoch, outcome, tip_before, landed_sha}}, pr_url, pr_number, pr_update_session, launch_epoch, log,
runner_pid}`. **Log:** `tmp/fleet-sequence-<slug>.log`. Both persist. A resume rewrites its own marker and **appends** to
its own log (the only record of why the earlier run stopped); no launch touches another sequence's files.

### Stopping, resuming, merging

- `/fleet-sequence stop` sets `stop_requested`; the runner checks it before each dispatch, so the issue in flight
  finishes and nothing else starts. Killing an in-flight session is `claude agents`, never this skill.
- **Re-running the same list resumes.** Landed issues are skipped and the next forks from the branch's tip, which
  carries them; a recorded shipped whose deferred merge outlasted the wait is waited on again first. This is the recovery
  path after a failure: fix or drop the failed issue (re-list to retry, omit to skip), then re-run; a list whose every
  issue has shipped goes straight to the PR step. A run from a different branch is a fresh sequence, and a fresh sequence
  refuses a leftover `seq/<first-id>` branch it did not create.
- **A resume adopts a session that outlived its runner.** An issue whose recorded session is still working (or whose
  ledger says shipped with the landing never recorded) is waited on in that session, never dispatched twice, and must
  stay on the list — dropping it is refused, since its session would still merge onto the branch under a runner not
  waiting for it. A recorded session that ended without shipping is an ordinary retry.
- **Merge the one PR** (merge commit, as always; review by commit if you like). Each issue was marked Ready For Release
  when it landed on the integration branch — the state of work waiting for its release — so the PR merging changes
  nothing in Linear. In `merge` mode there is nothing to merge.

## Relationship to the fleet skills

- **A fleet may run alongside.** Neither refuses the other: `next-candidates.sh` hides every issue a running sequence
  holds, the issue in flight is In Progress and claimed, both merge under the same repo lock, and `fleet-launch.sh`'s
  ledger expiry leaves a live sequence's child sessions alone. Running `solo` work beside a fleet is the operator's call.
- **The same release shape as an epic fleet, steered differently.** Both land merges ref-only on an integration branch
  and end in one PR from `integration-pr.sh`; both steer with the per-issue key and leave the checkout alone — the runner
  sets it because it knows each issue before the dispatch, an epic fleet's sessions set it themselves because only the
  picking session knows the issue ([`/fleet-launch`](../fleet-launch/SKILL.md) § Epic-scoped launch).
- `/fleet-status` does not row these sessions: their ledgers are `mode: single`, which it labels rather than counts.
  `/fleet-sequence status` is the readout; `/fleet-retro` measures them when named with `--sessions`.
- `/auto`'s targeted mode ignores the fleet deadline by construction, so an earlier fleet's marker does not gate a
  sequence.

## Error Handling

- Refusals before dispatch (nothing launched, checkout untouched, no branch created): an unparseable or duplicate ID;
  `pr` and `merge` together; an issue without `specified`, with `human`, or already terminal; `linear-cli` unreachable;
  a dirty tree on a branch whose name carries an issue ID (files listed — elsewhere a WARN); detached HEAD; an issue a
  running sequence holds; a list sharing issues with two earlier sequences; a second `merge` sequence on a launch branch
  one is already merging into; on a resume, an issue left off the list whose session is still working; in `pr` mode no
  `origin`, a launch branch missing from origin, or a stray `seq/<first-id>` branch; any option other than a trailing
  `--`. `stop` with several sequences running and no ID is refused the same way.
- Runner failures land in the marker's `reason` and the log; `status` shows both, and every per-issue key is already
  unset. A per-issue timeout names what the registry last showed: `still working` is a long issue (raise
  `FLEET_SEQUENCE_ISSUE_TIMEOUT`); `still idle` is a turn that ended without a ledger and no rewake followed —
  `claude attach <id>`, prompt it forward, re-run the list; `still blocked` is a permission decision only a human can
  give. A session listed `failed` or `stopped` ends the wait at once. A dispatch whose session id could not be read fails
  fast — find it in `claude agents`, let it finish, re-run the list.
- `claude`, `jq`, `git`, or `gh` missing → the script errors before doing anything; relay it.
