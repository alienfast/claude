# Workspace mechanics — worktree setup, in-place claim, cleanup, abandonment

Read this at Phase 0 once the user has chosen worktree or in-place, and again at Phase 6.

## Worktree mode — call `/start`'s own setup scripts, not `/start`

1. `~/.claude/scripts/start-wt-setup.sh <ISSUE-ID>` — the script `/start` Step 0 runs: worktree create/attach under the
   repo lock, the tamper-evident identity stamp, the session-start dirty baseline, the digest pre-fetch. It emits
   `KEY=value` lines (`WT_DIR`, `BRANCH`, `ISSUE_STATE`, `ASSIGNEE`, …) on stdout; carry those forward. Never hand-roll
   `git worktree add`: it skips the stamp and the lock, which is the corruption the locked create exists to prevent.
2. `EnterWorktree(path=<WT_DIR>)` so this session's edits land in the worktree.
3. `~/.claude/scripts/start-wt-verify.sh <WT_ABS> <ISSUE-ID> --claim` — the script `/start` Step 0 sub-step 3 runs, and
   **the step that actually claims the issue**: cwd confirm → claim (assignee *and* In Progress, both written and then
   **read back** via `linear-claim.sh` — an `issues update` exit status is not evidence either field landed, linear
   gotcha #8) → source-branch probe → baseline `pnpm check`. `--claim` is required and has no default.

   Branch on the first line of stdout: `VERIFIED` continues; any `FAILED-*` stops the run and is reported verbatim.
   `FAILED-CHECK` matters most: the tree was **already red before any dependency changed**, so every later failure
   would be unattributable — stop and say so rather than bumping on top of a broken baseline.

**Do not invoke `Skill(skill: "start", args: "... interactive")` for this.** That token's halt is a genuine terminal
state: it emits `INTERACTIVE-READY` as the session's single lifecycle tag and opens the worktree in a new VS Code window
for a human to drive. Both are wrong mid-run — this skill continues working and its terminal tag comes from `/finish`.
The setup script gives the identical worktree without the handoff.

## In-place mode

There is no verify script on this path, so claim the issue yourself with the single command `/start` Step 3 uses —
assignee and state in one call, never one without the other:

```bash
linear-cli issues update <ISSUE-ID> --assignee me --state "In Progress"
```

Then work the current branch. Finish is `pr` only.

## Phase 6 — clean up the worktree (worktree mode only)

- **After `/finish merge`** there is nothing to do — `finish-merge.sh` removes the worktree itself. Confirm it did: when
  it could not, it prints a `CLEANUP-FAILED:` line with the blocking paths and the remedy, and `/finish` carries that
  into the tag and a follow-up comment. Surface it rather than assuming the removal happened.
- **After `/finish pr`** the worktree is still on disk and is this skill's to remove — and not one `reap-worktrees.sh`
  preserves: the branch is pushed and the issue is Ready For Release, a `completed` state type in the house model
  (`mark-ready-for-release.sh`), so once the tree is clean and idle past the reaper's grace it passes the evidence test
  and is reclaimed on the hourly schedule instead of when this run ends.
  1. Delete only the scratch files this run created — the Phase 3 rollback copies under `tmp/`. **Untracked files make
     `git worktree remove` refuse**, and `--force` is blocked by the git-permissions hook, so clearing them is the only
     route. Never `rm -rf tmp/` — it also holds harness-owned session state and cross-skill handoff artifacts.
  2. `cd` to the repo root first — a worktree cannot be removed while it is the working directory.
  3. `git worktree remove <wt-dir>`.

  Removing it loses nothing: the branch is pushed and the PR is open, so follow-up review fixes are done in a fresh
  checkout or worktree. If the removal still refuses, the tree has changes this skill did not make — **stop and
  surface**, never force.

## Abandoning a worktree run

If the run stops before Phase 5, the worktree and its Linear issue both still exist. **Leave the worktree in place** — it
holds the only copy of any uncommitted work, and `reap-worktrees.sh` preserves exactly this shape for resumption. Say
where it is (`.claude/worktrees/<id-lower>`) and what state the issue is in, so the run can be resumed or the issue
Canceled deliberately. Phase 6's removal is for a *completed* run only; a failed run that deleted its own worktree would
destroy the evidence needed to diagnose it. The issue carries `dependencies`, so the next run's recall surfaces the
abandoned run before starting another.
