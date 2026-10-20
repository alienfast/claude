# `finish-merge.sh` exit codes 1, 2, 3 and 5

Step 9 of [`/finish`](../SKILL.md) (`ACTION=merge`) reads this file when `finish-merge.sh` exits non-zero; exit 0 is
handled in SKILL.md. Every re-invocation below is the same Step 9 line, run from `<REPO_ROOT>`: the script re-acquires
the lock, re-verifies the worktree branch against source's current tip and converges
([`standards/git-worktrees.md`](../../../standards/git-worktrees.md) § `/finish merge` between worktrees).

## 1 — hard precondition failure

Surface the script's output and stop; attempt no recovery. These are setup problems the user resolves: source branch
missing, worktree gone or on the wrong branch, worktree mid-unrelated-operation or carrying uncommitted tracked changes,
merge unverifiable. Terminal line: `BLOCKED-ON-REVIEW: <ISSUE-ID> — <reason from the script>. <recovery>.` Run no further
bash. Transient blocks are exit 3, never 1.

## 3 — transient block, deferred to the merge queue

The merge cannot advance source right now but will later, untouched: the main checkout is on the source branch with
uncommitted changes to files this merge changes (edits elsewhere ride along on the fast-forward), source is checked out
in another worktree, the main checkout is mid-operation, or source is under continuous contention. The script has
already self-enqueued the merge (`scripts/merge-queue.sh`); a launchd drainer retries until it lands and marks the issue
Ready For Release then. The worktree is intact and the issue remains In Progress — the honest state, since it is not
released until merged. Do not retry, commit, mark the issue, or touch another session's changes. Surface the script's
`DEFERRED:` output and emit the `DEFERRED-MERGE` closing message (SKILL.md § Terminal tags) with the script's reason.
Under `/auto`, `DEFERRED-MERGE` is a shipped outcome.

## 2 — the worktree needs work before the merge can land

Two shapes, told apart by the script's stderr tag. Both are resolved **in the worktree**, which this session owns (edits
there are permitted under bgIsolation once it has entered the worktree — SKILL.md Step 0) and which is private: no lock,
and never wrap these commands in `with-repo-lock.py`.

### `GENERATED-DISCARD:`

A `merge=ours` driver on generated file(s) kept the worktree branch's copy and silently dropped `<SOURCE_BRANCH>`'s
hunks. The merge is already committed — no conflict markers, no `MERGE_HEAD` — so do not `merge --abort`. Stderr names
one `(merge <sha>, <path>)` pair per discard.

**Measure what was dropped before regenerating anything — one pair, two commands.** The discarded content is the source
side's delta since that merge's base, so read exactly that:

```bash
git -C '<WT_DIR>' merge-base '<sha>^1' '<sha>^2'
git -C '<WT_DIR>' diff <that-base> '<sha>^2' -- '<path>'
```

Do not substitute a diff of `<SOURCE_BRANCH>`'s current copy against the merged one. It is wrong in both directions:
source keeps moving, so later siblings' hunks show up as apparent losses; and it goes clean on a source-side deletion
the merge kept (a `remove_column`'s hunks are all removals, so "source has nothing the merged copy lacks" holds while the
merged dump still declares the column). The guard fires only when the two tips' blobs already differ, so that diff is
never empty and never self-interpreting.

- **Every hunk is a version or serial line the merged copy already carries at a higher value** (a schema dump's
  `version:`, a generated timestamp) → nothing of substance was discarded; the usual cause is a sibling's data-only
  migration, whose only trace in a schema dump is the version line. Quote the diff as the justification, run `pnpm check`
  from `<WT_DIR>` (the merged-tree gate — a discard exit pre-empts the script's own exit-5 stop; red routes as § 5
  below), and finalize by re-running the Step 9 line with `_FM_SKIP_OURS_GUARD=1` — **in auto mode too**: this override
  is backed by a measurement rather than an assertion, which is what distinguishes it from the verdict-gate overrides
  Step 8 refuses unattended.
- **Anything else** — any added, removed or changed structural line — is a real loss. Regenerate the listed artifacts in
  the worktree from the merged sources (the project's documented schema/codegen regeneration), run `pnpm check` from
  `<WT_DIR>` (red routes as § 5), then `git -C '<WT_DIR>' add <files> && git -C '<WT_DIR>' commit -m 'Regenerate merged
  artifacts'` and re-invoke the Step 9 line. **Auto mode:** if the project documents no regeneration command, do not
  guess — stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — merge=ours driver dropped <SOURCE_BRANCH>'s generated hunks
  (<files>); regeneration needs a human. Worktree preserved.`

**A regeneration that changes nothing is a satisfied remedy, not a spent one — and for a schema dump it is not evidence
either.** "Nothing to commit" means the merged tree already regenerates to what it carries, so return to the measurement
above and finalize on it; reporting the remedy as exhausted strands a fully-shipped issue on a question with a checkable
answer. Do not read the byte-identical result as proof of no loss: a dump regenerated from a database initialized from
the committed dump reproduces it by construction, and a migration numbered at or below the dump's recorded version is
never pending (Rails stamps those applied via `assume_migrated_upto_version`), so it cannot contribute regardless. The
dropped-delta diff is the independent check.

### `CONFLICT:` (or `RESUME:`)

The script merged `<SOURCE_BRANCH>` into the worktree branch inside `<WT_DIR>` and hit conflicts. The main checkout is
untouched and clean. Conflicted files are listed on stderr as worktree-relative paths.

1. For each conflicted file, read `<WT_DIR>/<path>`, understand both sides, and apply the resolution **with the `Edit`
   tool on the conflicted file** — marker by marker, or the whole file when one side wins outright. When one side
   clearly subsumes the other (the worktree branch removed code the source side modified, say), take the subsuming
   side. Do not take a side with `git checkout --ours`/`--theirs`, `git restore`, or a shell overwrite
   (`git show <ref>:<path> >| <path>`, `cp`): the hook allows the first two only on paths git lists as unmerged, and in
   an unattended run every one of them is adjudicated by the auto-mode classifier, which reads an overwrite of source
   files mid-merge as dangerous and denies it, while `Edit` inside the entered worktree never reaches it. A denial of one
   of those shortcuts is a denial of the shortcut, not of this step — switch to `Edit` and continue; it is not a
   `BLOCKED-ON-REVIEW`. Ask the user only when the right answer is genuinely ambiguous. **Auto mode:** when genuinely
   ambiguous, do not guess — run `git -C '<WT_DIR>' merge --abort` and stop with
   `BLOCKED-ON-REVIEW: <ISSUE-ID> — merge conflict needs a human (<files>). Worktree preserved.`
2. `git -C '<WT_DIR>' add <resolved-files>`
3. `pnpm check` from `<WT_DIR>` — green before committing. Red means the resolution introduced a regression: do not
   commit and do not re-invoke. Surface the failing output and let the user choose between fixing the resolution,
   aborting the merge (`git -C '<WT_DIR>' merge --abort`), or escalating to architect; the mid-merge state stays in the
   worktree for inspection. **Auto mode:** run `git -C '<WT_DIR>' merge --abort` and stop with
   `BLOCKED-ON-REVIEW: <ISSUE-ID> — conflict resolution broke pnpm check; merge aborted, worktree preserved for a human.`
4. `git -C '<WT_DIR>' commit -F '<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md'` — the prepared merge message.
5. Re-invoke the Step 9 line. It re-acquires the lock and fast-forwards the main checkout, then removes the worktree and
   branch. If source advanced during the resolution it re-merges the new delta, which may return **5** (gate the newly
   merged tree, § 5) or **2** again with a fresh conflict on that delta — repeat 1–5. This is expected under concurrent
   `/finish merge` sessions and converges, each round reconciling only the latest source delta.
6. On exit 0, continue with SKILL.md Step 9's exit-0 handling.

## 5 — `MERGED-SOURCE:` — gate the merged tree, then re-invoke

`<SOURCE_BRANCH>` advanced during the worktree's life and the script merged it into the worktree branch inside
`<WT_DIR>` without conflicts, then stopped before advancing source (lock released, main checkout untouched). Step 7's
`pnpm check` ran on the pre-merge tree, and a clean textual merge can still break the combination (two edits to one
method body, a rename landing beside a new caller). This is the **merged-tree gate**: what lets `related` siblings ship
in parallel without a `blocks` edge (`standards/issue-spec.md` § Certification includes collision edges).

1. `pnpm check` from `<WT_DIR>`.
2. **Green** → re-invoke the Step 9 line. The re-run finds the worktree branch already containing source and finalizes —
   or returns **5** or **2** again if source advanced meanwhile; repeat.
3. **Red** → the merge, not this issue's own change, broke the tree. Fix it in the worktree and commit (Step 7's bounds
   apply — **auto mode:** at most **2** fix delegations), then re-invoke. Still red → **auto mode:** stop with
   `BLOCKED-ON-REVIEW: <ISSUE-ID> — merged tree fails pnpm check after merging <SOURCE_BRANCH>; worktree preserved.`
   Interactive: surface the failing output and let the user decide. Never finalize around a red gate and never revert
   the merge commit — the source delta must land together with this issue's.
