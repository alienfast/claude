---
name: reap-worktrees
description: Inspect and reclaim leftover /start wt worktrees. Shows which worktrees under .claude/worktrees/ are eligible for cleanup (PR merged, branch merged, or Linear issue Canceled/Done) and which are preserved (active or abandoned-for-resumption), and can reap the eligible ones now. Use when the user says 'reap worktrees', 'clean up worktrees', 'what worktrees are leftover', 'prune worktrees', or invokes /reap-worktrees.
---

# Reap Worktrees

`/start wt` creates a worktree at `<repo>/.claude/worktrees/<issue-lower>`. Three flows leave one behind
that nothing else reclaims:

1. **`/finish pr`** (worktree mode) — the PR merges asynchronously on GitHub *later*, so `/finish`
   can't clean up when it runs. The `SHIPPED-PR` tag tells you to remove the worktree after the PR
   lands, but that hand-off is manual and easy to forget.
2. **An issue Canceled/Done directly in Linear** with no live `/start` session — `/start` Step 8.5 only
   surfaces cleanup while a session is running, so a cancel outside that window orphans the worktree.
3. **A `/finish merge` whose cleanup failed** — [finish-merge.sh](../../scripts/finish-merge.sh) lands
   the merge, then `git worktree remove` refuses over an untracked or modified file it never forces past;
   it prints `CLEANUP-FAILED:` and leaves the worktree, its branch, and its `refs/finish-merge/…-orig` ref
   behind (2026-10-07: eleven basefund issues, a tool-written `AGENTS.md` in each). Its branch tip is then
   a sibling of the source branch, never an ancestor, which is why "merged" below is also decided by content.

A local launchd job ([reap-worktrees-cron.sh](../../scripts/reap-worktrees-cron.sh) →
`com.alienfast.worktree-reap`, hourly) runs the reaper automatically, mirroring the merge-queue drainer.
This skill is for **on-demand inspection and cleanup** between those passes.

## Reap discipline

[reap-worktrees.sh](../../scripts/reap-worktrees.sh) destroys a worktree **only on positive evidence of
completion** — never on mere inactivity. A worktree is reaped iff **all** hold:

- **Provenance**: `/start wt` created it — the per-worktree `start.source-branch` stamp, or a loadable
  identity sidecar — or the user opted it in (`git -C <wt> config --worktree reap.managed true`). Every rule
  below assumes the `/start wt` lifecycle (one issue, one branch, merged once = done); a hand-made or
  `EnterWorktree` worktree the user keeps merging from is "merged, clean, idle" between every round, and one
  was reaped on exactly that shape (api-memo, 2026-09-08). An unstamped worktree is reported
  `KEEP — unmanaged` and never touched.
- **Not pinned**: `git -C <wt> config --worktree reap.keep true` keeps any worktree, stamped or not
  (`KEEP — pinned`); `--unset reap.keep` releases it. Only a queued merge outranks the pin.
- **Completion evidence** (any one): its branch is merged into its source branch or the repo default —
  an ancestor of it, **or** contained by content: a dry-run merge (`git merge-tree --write-tree <ref>
  <branch>`, git ≥ 2.38) yields the ref's own tree, which is how a `finish-merge.sh` merge that rebuilt its
  merge commit reads afterwards; a conflicting dry run, or a git without the command, reads as not merged;
  **or** its PR state is `MERGED` (via `gh`); **or** its Linear issue state type is terminal
  (`completed`/`canceled`/`duplicate`).
- **No unsaved commits**: every commit on the branch is reachable from a durable ref — merged into
  mainline, or present on its `origin` remote-tracking branch (pushed).
- **Clean working tree**: `git status --porcelain` is empty. The reaper **never** passes `--force`, so
  untracked work is never destroyed; gitignored scratch (`tmp/`, `node_modules`) doesn't block removal.
- **No in-flight deferred merge**: no `<repo>/.claude/merge-queue/<issue>.json` marker (the drainer owns
  those).
- **Not in use**: no live Claude session has its cwd inside the worktree (`lsof`, matched on the harness
  comm — the same allowlist `wt-identity.sh` recognizes — so a leftover dev server never holds a worktree).
  This outranks every evidence rule: a session that runs `/finish merge` from inside the worktree and keeps
  working, or finishes one issue and plans the next in the same worktree, does no git ops for hours while
  "merged" or "issue Done, zero commits" both read as done — three interactive sessions were reaped that
  way in one week (BF-2074 twice on 2026-09-23, BF-2101 on 2026-09-24), each then TERMed by the sweep
  below for sitting in the directory just removed. Without `lsof` the guard stands down for the pass (one
  WARN in the log) and the index-mtime guard alone decides.
- **Not live**: the worktree's index is stale (no git activity for `WORKTREE_REAP_GRACE_MIN` minutes,
  default 60), **and** the branch has commits beyond its recorded baseline — *or*, for a zero-commit
  branch, the completion evidence is something other than "merged". A zero-commit branch is trivially an
  ancestor of its source and trivially contained by content, so the merged test says nothing about it
  (reaping on that alone destroyed a live just-forked worktree once — PL-459). A terminal Linear issue is independent of commit count and does
  count, which is what reclaims a `/start wt` worktree whose issue was canceled before the first commit.
  So is a **dead or released owning session** (`wt_owner_alive`, from the `/start` identity stamp): a
  zero-commit worktree whose session provably died, or that was released via
  [wt-disown.sh](../../scripts/wt-disown.sh), is abandoned no matter what its issue says, and would
  otherwise be preserved forever. `alive` and `unknown` never reap — an unresolvable owner has to fail
  safe, and in a `claude agents` fleet every session shares the fleet-root pid, so a session that dies
  while its root runs still reads `alive` and keeps its worktree until the root exits.

**Abandoned-for-resumption worktrees are preserved automatically** — branch unmerged, PR open, issue
still active means they fail the evidence test, so no special-casing is needed. A worktree that is
eligible but **dirty** or has **local-only commits** is reported, not reaped, with the exact command to
finish the job by hand.

Source branch comes from the per-worktree `start.source-branch` config recorded by
[start-wt-setup.sh](../../scripts/start-wt-setup.sh); the repo set is the union of the self-registering
`~/.claude/worktree-repos.txt` and `~/.claude/merge-queue-repos.txt`.

The gates are regression-guarded by [reap-worktrees.test.sh](../../scripts/reap-worktrees.test.sh)
(`bash ~/.claude/scripts/reap-worktrees.test.sh`) — run it after any change to them, and add the case
alongside the fix. This script deletes work; an unguarded gate is one that quietly reopens.

## Orphan host processes

Every teardown path is git-only, so the dev servers, watchers, and job runners a worktree started keep
running after it is removed — and its pidfiles went with the directory, leaving the resolved cwd as the only
handle. So each reap pass also sweeps processes (yours only) whose cwd sits under
`<repo>/.claude/worktrees/<name>` **where that `<name>` directory no longer exists on disk**. That gate is
what makes the kill safe: a live worktree, or a sibling of a dead one, can never be selected — and a Claude
harness process never is: one parked in a removed worktree is a broken session, printed as `LIVE-SESSION
pid=… cwd=…` and left for you to close or resume. `list` prints
`ORPHAN-PROC pid=… cwd=…` and kills nothing; `reap` sends `TERM`, then `KILL` to survivors, logging
`REAPED-PROC pid=… cwd=…`. Process names are deliberately **not** matched — puma and sidekiq rewrite their
proctitle, so a `pkill -f` pass misses real orphans and can hit unrelated processes. Without `lsof` the sweep
notes itself and skips.

## Identity sidecars

`/start wt` stamps each worktree's tamper-evident identity into `<repo>/.claude/worktree-identity/wt-identity-<slug>.env`
(the repo-level sidecar [wt-identity.sh](../../scripts/wt-identity.sh) reads when `/finish` checks for a
hijack). The sidecar is a per-worktree artifact and ends with the worktree: `/finish merge`, recovery, and this
reaper all delete it when they remove one. A worktree removed by hand leaves its sidecar behind, and nothing
deleted any before 2026-10-07 (basefund held 1,025 against one live worktree), so each pass also sweeps the
directory: a sidecar whose recorded worktree directory is gone **and** whose slug has no worktree at the
conventional path, older than the grace, is removed. `list` prints `STALE-IDENTITY <n> sidecar(s) …` and
deletes nothing; `reap` prints `REAPED-IDENTITY <n> …`. Only `wt-identity-*.env` files are candidates — the
directory's `.gitignore` and a recovery patch beside them are never touched.

## Merge leftovers

`finish-merge.sh` keeps each worktree branch's original tip under `refs/finish-merge/<branch, slashes as
dashes>-orig` and deletes that ref with the branch on a clean removal; a reap of a merged worktree deletes
it too. A cleanup it could not make (flow 3 above) keeps the branch and the ref, and the hand removal of the
directory that usually follows forgets both — on 2026-10-07 basefund held three such branches. Each pass
therefore also sweeps **branch-only leftovers**: a local branch with an orig ref of its own and no worktree,
merged — as an ancestor, or by content — into a ref that already carries its original tip (the default
branch first, then whatever else contains it; never the branch's own remote copy, a branch checked out in a
linked worktree, or a sibling leftover). `list` prints `STALE-BRANCH <branch> — merged into <ref> …` and
`STALE-MERGE-REF <ref> — its branch is gone`; `reap` deletes the branch and ref (`REAPED-BRANCH`) or the
dangling ref alone (`REAPED-MERGE-REF`). A branch-only leftover with unmerged content is left alone, and
a branch any worktree has checked out is that worktree's verdict.

## Usage

**Inspect (dry run — mutates nothing, takes no lock):**

```bash
~/.claude/scripts/reap-worktrees.sh list            # every registered repo
~/.claude/scripts/reap-worktrees.sh list <repo>     # one repo
```

Each worktree prints one of: `REAP-ELIGIBLE`, `KEEP` (with the reason — pinned, unmanaged, in use, active, unpushed, or dirty),
`SKIP` (detached / merge-queued), or `STRAY`, followed by a `STALE-BRANCH` or `STALE-MERGE-REF` line per merge
leftover, one `STALE-IDENTITY` line when sidecars are due, and an `ORPHAN-PROC` line per leftover host process.
A merged worktree whose directory is dirty prints `KEEP — … but the worktree is dirty` with the clear command,
every pass, until someone judges the blocking files; the reaper never forces past them.

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
