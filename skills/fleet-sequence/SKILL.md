---
name: fleet-sequence
description: Ship an ordered list of certified issues as a stack of PRs — strictly one at a time, each in its own background `claude --bg "/auto pr <ID>"` session (a fresh context per issue), each forked from the previous issue's branch with its PR targeting that branch. The runner for `solo` work and for big issues that must land in order; the targeted, serialized sibling of /fleet-launch. Use when the user says 'fleet sequence', 'run these in sequence', 'ship BF-1 then BF-2 then BF-3', 'stack these', 'sequential auto', 'solo batch', or invokes /fleet-sequence.
---

# Fleet Sequence

The targeted, serialized counterpart of [`/fleet-launch`](../fleet-launch/SKILL.md): instead of N parallel `/loop /auto` pickers, one detached runner walks an explicit issue list, dispatching a single `/auto pr <ID>` background session at a time and starting the next only after the previous session has ended with a `shipped` outcome and an open PR. The result is a **PR stack**: the first PR targets the branch you launched from, every later one targets its predecessor's branch. All logic lives in [scripts/fleet-sequence.sh](../../scripts/fleet-sequence.sh); this skill dispatches to it and narrates the result.

Why this shape, and not one loop or one batch PR:

- **`solo` never reaches a picker.** `next-candidates.sh` hides `solo` issues from every ranking, so a `/loop /auto` session cannot pick them, and a targeted `/auto <ID>` is one-shot by design (`standards/issue-spec.md` § The `solo` label). Several solo issues therefore need an external sequencer.
- **One session per issue.** A big issue wants its own context; a session that shipped one big issue and then starts another carries the first one's residue into the second. Each child here is a fresh `claude --bg` with exactly one `/auto pr <ID>` prompt.
- **A stack is the correct use of `pr` mode.** `/auto`'s `pr` caveat is that the source branch never advances until PRs merge, so a dependent issue forks without its predecessor's code. Forking each issue from the previous issue's branch is the fix, and one PR per issue is what Linear's PR linking and the auto-close keyword rule in `standards/git.md` assume. **Merge commits only** — a squash or rebase merge rewrites the base and every dependent PR then needs a restack; this house merges, never squashes, which is why the stack is the only mode.
- **It is a GitHub stack, not just a chain of bases.** GitHub's stacked pull requests (public preview; REST API version `2026-03-10`) take an ordered list of PR numbers whose bases equal the previous heads — exactly this chain — and give every PR a stack map in its merge box, retarget on partial merges, and let **merging the top PR merge the whole stack**. The runner creates the stack through `gh api` once the second PR exists and appends each later PR; a stack that already holds the bottom PR (one made in the web UI) is adopted instead. Linking failure is a WARN carrying the manual command, never a failed sequence, and `link` retries it later.

## Arguments

`/fleet-sequence <ISSUE-ID> <ISSUE-ID>...` · `/fleet-sequence status` · `/fleet-sequence stop` · `/fleet-sequence link`

- **Issue IDs** — every token matching `^[A-Za-z]+-[0-9]+$`, in the order they must ship. Each is probed the way `/auto`'s targeted mode probes (`specified` present, `human` absent) and refused if already Done, Canceled, Duplicate, or Ready For Release. `solo` is expressly welcome.
- `status` — read-only readout (below). `stop` — finish the issue in flight, then stop; the PRs already opened stand; nothing is killed. `link` — link the marker's shipped PRs into a GitHub stack now, for a run that ended without one (linking WARNed, or shipped before linking existed); idempotent.
- Anything else → error: `Unrecognized argument 'X'. /fleet-sequence takes issue IDs in ship order, or the single word status / stop / link.`

Model and permission defaults follow `/auto`'s unattended-run prerequisites, identical to `/fleet-launch` (`--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto`); pass overrides after `--` when calling the script directly.

## Behavior

Run from the project the issues belong to, with the main checkout **clean** and on the branch the first PR should target (usually the default branch). The script refuses a dirty tree, a detached HEAD, a live fleet, and a sequence already running:

```bash
~/.claude/scripts/fleet-sequence.sh BF-101 BF-102 BF-103
```

Surface the script's output verbatim: the sequence line, the runner pid and log path, and its warning that the main checkout's HEAD moves between issues. **Do not wait in this session** — the runner is detached (`nohup`, reparented to launchd) and lives for hours; there is nothing to poll here, and `no-blind-sleep.sh` would refuse the attempt anyway. Close by telling the user how to watch, and that the main checkout is the runner's until the run ends:

- `/fleet-sequence status` — per-issue session id, registry liveness, outcome, branch and PR, then the stack in merge order, the runner's own liveness, and the log tail.
- `claude agents` — every child is named `fleet-sequence <ID>`, so the view reads as the queue.

Invoking `/fleet-sequence` is the run-scoped commit/push grant for the issues it lists, exactly as `/auto` is for a loop: each child ships under `/auto`'s grant, pushing its branch and opening its PR ([standards/git.md](../../standards/git.md) § Named exceptions).

### The runner's contract

Per issue, in list order:

1. Refuse to continue if the main checkout is dirty (a session would halt on it — the sequence fails with the reason recorded).
2. **Position the fork point.** The nearest earlier issue that shipped is the predecessor; the launch branch for the first. `/start wt` forks from the main checkout's HEAD and records the branch it is on as the PR base, and a branch checked out in a live worktree cannot be checked out again — so the runner **detaches HEAD at the predecessor's branch tip and sets `start.wt-source-branch` to that branch**, the detached-HEAD path start-wt-setup.sh documents. For the first issue it simply stands on the launch branch with the config unset.
3. Dispatch `claude --bg <flags> -n "fleet-sequence <ID>" "/auto pr <ID>"` and record the short id `claude --bg` prints — the same id that keys the session's ledger `tmp/auto-state-<id>.json`.
4. Wait for the **ledger** — `tmp/auto-state-<id>.json` recording the issue in any outcome list. That file is `/auto` Step 4's last act (Linear comment, label, ownership release, then the state file), so an outcome means the work is over whatever the session registry says: measured 2026-09-10, a session sat busy in `claude agents` for seven hours after its ledger said shipped, and a registry-only wait burned the whole timeout with the PR already open. The registry is the fallback for a session that ends without a ledger (`done`, or absent after `FLEET_SEQUENCE_GRACE`, 120s). A ledger keyed by something other than the session id counts only if written since the dispatch, so an earlier run's ledger naming the same issue cannot fake a ship. Polls every `FLEET_SEQUENCE_POLL` (30s), bounded by `FLEET_SEQUENCE_ISSUE_TIMEOUT` (6h): on expiry the sequence fails and the session is **left running**.
5. Read the outcome — which of `shipped` / `canceled` / `skipped` / `failed` lists the issue. Only `shipped` continues (`SHIPPED-PR` lands there). Then read the issue's branch from its preserved worktree (`.claude/worktrees/<id>`) and find its open PR with `gh pr list --head`; a shipped issue with no open PR is a failure (open one from the worktree with `/pr-update`, then re-run). The PR's base is checked against the predecessor and the branch is checked to contain the predecessor with commits beyond it — mismatches are logged as WARNs, never treated as failures. Then the PR is linked into the GitHub stack: created from the shipped PRs bottom-to-top once there are two, extended by this PR after that, an existing stack holding the bottom PR adopted.
6. Anything else stops the sequence: `status: failed`, the reason names the issue, its session, and the issues not started. `/auto` has already posted the Linear comment and applied `stalled` (or a park label) on that issue, so the human-facing trail is on the issue itself.

On every exit — done, failed, stopped, or crashed — the runner puts the main checkout back on the launch branch and unsets the config.

**Marker:** `<main-checkout>/tmp/fleet-sequence.json` — `{queue, base, claude_args, status: running|done|failed|stopped, reason, stop_requested, current, issues: {<ID>: {session, started_epoch, ended_epoch, outcome, forked_from, branch, pr_url, pr_number, pr_base}}, stack_number, stack_url, launch_epoch, log, runner_pid}`. **Log:** `tmp/fleet-sequence.log`. Both persist after the run for inspection; the next launch rewrites them.

### Stopping, resuming, merging

- `/fleet-sequence stop` sets `stop_requested`; the runner checks it before each dispatch, so the issue in flight finishes and nothing else starts. Killing an in-flight session is `claude agents`, never this skill.
- **Re-running the same list resumes.** Issues the marker recorded as shipped on the same launch branch keep their branch and PR and are skipped; the next one forks from the last shipped branch. This is the recovery path after a failure too — fix or drop the failed issue (re-list it to retry, omit it to skip), then re-run. A run launched from a different branch is a fresh sequence.
- **Merge from the top, or bottom-up.** With the GitHub stack linked, merging the top PR merges the whole stack; merging a lower PR alone retargets the ones above it. `status` prints the stack bottom → top and the stack number. Each issue stays In Progress until its own PR merges, as in any `pr`-mode ship, and its worktree is preserved until then — `reap-worktrees` sees the open PR and leaves it alone.

## Relationship to the fleet skills

- **Never mid-fleet.** A sequence is solo work by definition; the script refuses when `tmp/fleet-deadline.json` names a session the registry still lists as running. Run it before or after a fleet, as `standards/issue-spec.md` § The `solo` label prescribes.
- `/fleet-status` does not row these sessions: their ledgers are `mode: single`, which it labels rather than counts. `/fleet-sequence status` is the readout. `/fleet-retro` measures them when named with `--sessions`.
- `/auto`'s targeted mode ignores the fleet deadline by construction, so a deadline marker left by an earlier fleet does not gate a sequence.

## Error Handling

- Refusals before dispatch (nothing launched, checkout untouched): an unparseable or duplicate ID; an issue without `specified`, with `human`, or already terminal; `linear-cli` unreachable; a dirty tree (files listed); detached HEAD; a live fleet; a running sequence; any option other than a trailing `--`.
- Runner failures land in the marker's `reason` and the log; `status` shows both, and the checkout is already back on the launch branch. A dispatch whose session id could not be read fails fast (the runner cannot wait on an unknown session) — find it in `claude agents`, let it finish, then re-run the list.
- `claude`, `jq`, `git`, or `gh` missing → the script errors before doing anything; relay it.
