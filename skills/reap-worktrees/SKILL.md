---
name: reap-worktrees
description: Inspect and reclaim leftover /start wt worktrees. Shows which worktrees under .claude/worktrees/ are eligible for cleanup (PR merged, branch merged, or Linear issue Canceled/Done) and which are preserved (active or abandoned-for-resumption), and can reap the eligible ones now. Use when the user says 'reap worktrees', 'clean up worktrees', 'what worktrees are leftover', 'prune worktrees', or invokes /reap-worktrees.
---

# Reap Worktrees

`/start wt` creates a worktree at `<repo>/.claude/worktrees/<issue-lower>`. Two flows leave one behind
that nothing else reclaims:

1. **`/finish pr`** (worktree mode) — the PR merges asynchronously on GitHub *later*, so `/finish`
   can't clean up when it runs. The `SHIPPED-PR` tag tells you to remove the worktree after the PR
   lands, but that hand-off is manual and easy to forget.
2. **An issue Canceled/Done directly in Linear** with no live `/start` session — `/start` Step 8.5 only
   surfaces cleanup while a session is running, so a cancel outside that window orphans the worktree.

(`/finish merge` does **not** leak — [finish-merge.sh](../../scripts/finish-merge.sh) removes the
worktree on a successful merge.)

A local launchd job ([reap-worktrees-cron.sh](../../scripts/reap-worktrees-cron.sh) →
`com.alienfast.worktree-reap`, hourly) runs the reaper automatically, mirroring the merge-queue drainer.
This skill is for **on-demand inspection and cleanup** between those passes.

## Reap discipline

[reap-worktrees.sh](../../scripts/reap-worktrees.sh) destroys a worktree **only on positive evidence of
completion** — never on mere inactivity. A worktree is reaped iff **all** hold:

- **Completion evidence** (any one): its branch is an ancestor of its source branch or the repo default
  (merged); **or** its PR state is `MERGED` (via `gh`); **or** its Linear issue state type is
  `completed`/`canceled`.
- **No unsaved commits**: every commit on the branch is reachable from a durable ref — merged into
  mainline, or present on its `origin` remote-tracking branch (pushed).
- **Clean working tree**: `git status --porcelain` is empty. The reaper **never** passes `--force`, so
  untracked work is never destroyed; gitignored scratch (`tmp/`, `node_modules`) doesn't block removal.
- **No in-flight deferred merge**: no `<repo>/.claude/merge-queue/<issue>.json` marker (the drainer owns
  those).

**Abandoned-for-resumption worktrees are preserved automatically** — branch unmerged, PR open, issue
still active means they fail the evidence test, so no special-casing is needed. A worktree that is
eligible but **dirty** or has **local-only commits** is reported, not reaped, with the exact command to
finish the job by hand.

Source branch comes from the per-worktree `start.source-branch` config recorded by
[start-wt-setup.sh](../../scripts/start-wt-setup.sh); the repo set is the union of the self-registering
`~/.claude/worktree-repos.txt` and `~/.claude/merge-queue-repos.txt`.

## Usage

**Inspect (dry run — mutates nothing, takes no lock):**

```bash
~/.claude/scripts/reap-worktrees.sh list            # every registered repo
~/.claude/scripts/reap-worktrees.sh list <repo>     # one repo
```

Each worktree prints one of: `REAP-ELIGIBLE`, `KEEP` (with the reason — active, unpushed, or dirty),
`SKIP` (detached / merge-queued), or `STRAY`.

**Reap (mutating — removes eligible worktrees, serialized per repo under the same common-git-dir lock
`/finish merge` uses, so it can never race an in-flight merge):**

```bash
~/.claude/scripts/reap-worktrees.sh reap            # every registered repo
~/.claude/scripts/reap-worktrees.sh reap <repo>     # one repo
```

When the user asks to inspect, run `list` and summarize the verdicts. When they ask to clean up, run
`list` first, show what will be removed, and on confirmation run `reap`. The hourly launchd log is at
`~/.claude/logs/worktree-reap.log`.

## The launchd agent

`~/.claude/update.sh` installs and refreshes the agent automatically (renders the `__HOME__` template
and bootstraps it idempotently — see [the plist header](../../launchd/com.alienfast.worktree-reap.plist)
for the by-hand commands). To remove it:

```bash
launchctl bootout gui/$(id -u)/com.alienfast.worktree-reap
rm ~/Library/LaunchAgents/com.alienfast.worktree-reap.plist
```
