# Resuming an issue `/start` already began

Read from `/start` Step 0 when its existing-worktree gate fires on a plain `/start <ISSUE-ID>`, from Step 5 when its
`start.source-branch` probe is what arms `IS_WT`, and from Step 8 when a posted plan is found. `/start` is idempotent on
the same issue: re-running it after a `/checkpoint`-and-stop, or after `/auto` resumed an orphaned worktree, runs Step 0's
full procedure rather than skipping it.

## Step 0 on a resume

- Sub-step 1's setup script reuses the existing worktree and branch (its create/attach/reuse logic handles this) and
  re-stamps ownership to this session.
- Sub-step 2 re-enters via `EnterWorktree(path=<WT_ABS>)` so the resumed session's isolation is registered — without it
  a background resumption's `developer` writes hit the guard. Its cwd precondition applies as written: a manual
  resumption launched with cwd already inside the worktree **re-anchors cwd to the main checkout first** (entering from
  inside trips the same-cwd refusal), and passes the **absolute** path `git worktree list` reports for the issue-keyed
  `.claude/worktrees/<id>` — the tool rejects a relative path as not a registered worktree.
- Sub-step 3 runs `start-wt-verify.sh` with `--no-claim` (the issue is already claimed by me — Step 3's idempotent
  resumption bullet); its availability check still runs, and a `needs decision` label still gates it.
- Step 3's `stalled` label cleanup still applies: remove the label after `VERIFIED`.

## Step 5 arms `IS_WT`

When Step 0's gate did not fire but Step 5's `git config --worktree --get start.source-branch` probe returns a value —
cwd started this session already inside a leftover worktree directory and the user ran a plain `/start <ISSUE-ID>` —
`IS_WT` is true for the rest of the session even though no `wt` token was given, and `WT_ABS` has not been derived. Cwd
may be a *subdirectory* of the worktree, and there is no setup-script output to cross-check it against, so derive
`WT_ABS` with `git rev-parse --show-toplevel` as its own plain Bash call before composing any delegation — never `pwd -P`
(which would silently substitute the wrong root into every READ-SCOPING block), and never an assign-and-run compound,
which the isolation guard refuses in exactly these sessions
([standards/git-worktrees.md](../../../standards/git-worktrees.md) § Worktree-isolated sessions).

## Exploration and the posted plan

Check the digest's comments for an already-posted implementation plan:

- **A plan exists and still applies** → skip Steps 6 and 7 entirely and resume directly at Step 8. Sub-step 3 dispatches
  NO exploration on this path (its "Two exceptions" rule) — there is nothing new to feed.
- **A plan exists but is STALE** → sub-step 3 already skipped its exploration dispatch, so dispatch exploration now, at
  Step 6 before `EnterPlanMode` (Step 6's re-dispatch fallback covers exactly this), and plan again.
- **No plan was ever posted** → sub-step 3 dispatched exploration as usual; it is already running. Continue at Step 6.

## A prior review

If Step 9 had already run, the existing `tmp/quality-review-verdict-<issue-id-lowercased>.md` is still consulted by
`/finish` Step 1.5. The user can re-run `/quality-review` to refresh it, or skip ahead to `/finish` if the prior verdict
still applies.
