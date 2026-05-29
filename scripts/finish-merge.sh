#!/bin/bash
# finish-merge.sh — Merge a /start wt worktree back to its source branch.
#
# Usage: finish-merge.sh <wt-dir> <source-branch> <worktree-branch> <message-file>
#
# Strategy: bring the worktree branch up to source's tip INSIDE the worktree
# (where conflict resolution is possible even from a background session, and
# where no lock is needed because the worktree is private to this session),
# then advance source to it. The advance never merges or leaves the main
# checkout mid-merge — eliminating the "merge into an unclean directory" race —
# and never switches the main checkout's HEAD:
#   - if the main checkout is ON source: `git merge --ff-only` (updates the ref
#     AND its working tree atomically);
#   - otherwise: a compare-and-swap `git update-ref` (advances the ref only; the
#     main checkout's other branch / detached HEAD and working tree are untouched).
#
# The advance is an optimistic re-check loop, not a one-shot: source can advance
# (another /finish session that finalized while our lock was released for
# conflict resolution, or a local human/CI update) between our worktree merge
# and our advance. Before each advance we re-verify, while holding the lock, that
# the worktree branch still descends from source's CURRENT tip; if it moved we
# re-merge the new delta and loop (the ff / CAS also fails closed and loops). A
# clean re-merge converges on the next pass; a conflicting one exits 2 for
# worktree resolution and re-invocation.
#
#   <message-file> is a markdown/text file whose contents become the merge
#   commit message ONLY in the divergent case (source moved during the
#   worktree's life). The common case fast-forwards with no merge commit. The
#   caller (/finish Step 9) should include the Linear issue ID in the subject
#   (e.g. `Merge PL-13`) for Linear's auto-linking to fire.
#
# Must be run from the main repo checkout (cwd is the parent of .git's
# common dir). NOT from inside <wt-dir> — this script removes that directory
# on success.
#
# Preconditions (any failure aborts before touching the merge state):
#   1. source-branch exists locally
#   2. worktree directory still exists
#   3. worktree is checked out on <worktree-branch>
#   4. worktree is not mid-merge/rebase/cherry-pick (a mid-merge of source is
#      treated as an in-progress resolution → exit 2, not a hard failure)
#   5. worktree has no uncommitted tracked changes
#   6. main checkout (cwd) is clean and not mid-merge/rebase/cherry-pick
#
# Exit codes:
#   0 — done: worktree branch fast-forwarded into source, worktree + branch removed.
#   1 — precondition failure (setup issue; the merge was never completed).
#   2 — worktree merge conflict: state preserved IN THE WORKTREE; the orchestrator
#       resolves there (git -C <wt-dir> add/commit) and re-invokes this script.

set -eo pipefail

# Self-serialize against the parent repo. The lock helper re-execs this script
# with the OS holding an exclusive flock on $repo_key. The sentinel is PID-tied
# (exec preserves PID, so the post-exec check matches; a stray exported
# _FINISH_MERGE_LOCK_PID in the environment will not match $$ and is treated as
# unset). Lock releases on script exit — including conflict exits (code 2),
# which is exactly when we want it released: the slow LLM conflict resolution
# then runs lock-free in the private worktree with the main checkout clean.
#
# Lock key = absolute path to the common git dir (e.g. /repo/.git), so every
# worktree of the same parent repo shares one key, and distinct repos —
# including bare repos under a common parent — never collide.
if [ "$_FINISH_MERGE_LOCK_PID" != "$$" ]; then
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "ERROR: finish-merge.sh: not inside a git repository (cwd: $PWD)" >&2
    exit 1
  }
  if [ -z "$common_dir" ]; then
    echo "ERROR: finish-merge.sh: git rev-parse --git-common-dir returned empty (cwd: $PWD)" >&2
    exit 1
  fi
  case "$common_dir" in
    /*) repo_key="$common_dir" ;;
    *)  repo_key=$(cd "$common_dir" 2>/dev/null && pwd -P) ;;
  esac
  if [ -z "$repo_key" ] || [ "$repo_key" = "/" ]; then
    echo "ERROR: finish-merge.sh: refusing degenerate repo_key='$repo_key' (common_dir='$common_dir')" >&2
    exit 1
  fi
  export _FINISH_MERGE_LOCK_PID=$$
  exec "$HOME/.claude/scripts/with-repo-lock.py" "$repo_key" \
       "$HOME/.claude/scripts/finish-merge.sh" "$@"
fi

if [ $# -ne 4 ]; then
  echo "Usage: $0 <wt-dir> <source-branch> <worktree-branch> <message-file>" >&2
  exit 1
fi

wt_dir="$1"
source_branch="$2"
worktree_branch="$3"
message_file="$4"

if [ ! -f "$message_file" ]; then
  echo "ERROR: merge-message file '$message_file' does not exist or is not a regular file." >&2
  exit 1
fi
if [ ! -s "$message_file" ]; then
  echo "ERROR: merge-message file '$message_file' is empty. The merge commit needs a subject (must include the issue ID for Linear auto-linking)." >&2
  exit 1
fi

# Precondition 1: source branch exists locally.
if ! git rev-parse --verify "$source_branch" >/dev/null 2>&1; then
  echo "ERROR: source branch $source_branch no longer exists locally. Cannot merge." >&2
  echo "Recovery: fetch or re-create the branch, then re-run /finish merge." >&2
  exit 1
fi

# Precondition 2: worktree still exists.
if [ ! -d "$wt_dir" ]; then
  echo "ERROR: worktree at $wt_dir no longer exists. A concurrent session may have removed it." >&2
  exit 1
fi

# Precondition 3: worktree is checked out on the expected branch. The merge
# below runs `git -C <wt-dir> merge`, which merges INTO whatever is checked out
# there — so a wrong/detached HEAD would silently merge into the wrong branch.
wt_head=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ "$wt_head" != "$worktree_branch" ]; then
  echo "ERROR: worktree at $wt_dir is on '${wt_head:-(detached HEAD)}', expected '$worktree_branch'. Cannot merge safely." >&2
  exit 1
fi

# --absolute-git-dir (git >= 2.13) ensures the worktree's git dir is unambiguous
# regardless of cwd or git version. Used by preconditions 4 and 5.
rp_err=$(mktemp) || { echo "ERROR: mktemp failed; cannot capture rev-parse stderr." >&2; exit 1; }
wt_git_dir=$(git -C "$wt_dir" rev-parse --absolute-git-dir 2>"$rp_err")
if [ -z "$wt_git_dir" ]; then
  echo "ERROR: git rev-parse --absolute-git-dir failed (requires git >= 2.13):" >&2
  cat "$rp_err" >&2
  rm -f "$rp_err"
  exit 1
fi
rm -f "$rp_err"

# Precondition 4: worktree is not mid-operation — UNLESS it is mid-merge of the
# source branch, which is this flow's own in-progress conflict resolution. We
# checked this BEFORE the uncommitted-changes check so the resolution guidance
# wins over a generic "uncommitted changes" message.
if [ -d "$wt_git_dir/rebase-merge" ] || [ -d "$wt_git_dir/rebase-apply" ] \
   || [ -e "$wt_git_dir/CHERRY_PICK_HEAD" ]; then
  echo "ERROR: worktree at $wt_dir is mid-rebase / mid-cherry-pick. Finish or abort it before /finish merge." >&2
  exit 1
fi
if [ -e "$wt_git_dir/MERGE_HEAD" ]; then
  merge_head=$(git -C "$wt_dir" rev-parse --verify --quiet MERGE_HEAD || true)
  # Our own resolution iff the in-progress merge is merging source (its tip, or
  # an older source tip now subsumed by the current source branch).
  if [ -n "$merge_head" ] && git -C "$wt_dir" merge-base --is-ancestor "$merge_head" "$source_branch"; then
    echo "RESUME: worktree at $wt_dir has an in-progress /finish merge of $source_branch to resolve." >&2
    echo "Resolve conflicts there, then: git -C '$wt_dir' add <files> && git -C '$wt_dir' commit -F '$message_file'" >&2
    echo "Then re-run /finish merge." >&2
    if git -C "$wt_dir" diff --name-only --diff-filter=U | grep -q .; then
      echo "Unresolved files (worktree-relative):" >&2
      git -C "$wt_dir" diff --name-only --diff-filter=U >&2
    fi
    exit 2
  fi
  echo "ERROR: worktree at $wt_dir is mid-merge of an unrelated branch (MERGE_HEAD=$merge_head). Finish or abort it before /finish merge." >&2
  exit 1
fi

# Precondition 5: worktree has no uncommitted *tracked* changes. Untracked
# files (editor swap, tmp/ artifacts) do not block a merge — exclude them.
if ! git -C "$wt_dir" diff --quiet || ! git -C "$wt_dir" diff --cached --quiet; then
  echo "ERROR: worktree at $wt_dir has uncommitted tracked changes. Commit or stash before merging." >&2
  exit 1
fi

# Precondition 6: main checkout (cwd) is clean AND not mid-operation. The new
# flow never leaves the main checkout mid-merge, so a mid-operation here is a
# foreign/manual state the user must resolve. Use --absolute-git-dir (not
# literal .git/) so this works for bare-repo and worktree-as-main setups.
main_git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
  echo "ERROR: main checkout: not a git repository (cwd: $PWD)" >&2
  exit 1
}
if [ -e "$main_git_dir/MERGE_HEAD" ] || [ -e "$main_git_dir/CHERRY_PICK_HEAD" ] \
   || [ -d "$main_git_dir/rebase-merge" ] || [ -d "$main_git_dir/rebase-apply" ]; then
  echo "ERROR: main checkout at $PWD is mid-merge / mid-rebase / mid-cherry-pick." >&2
  echo "This flow never leaves the main checkout mid-operation, so resolve or abort it first, then re-run /finish merge." >&2
  echo "Worktree at $wt_dir is untouched." >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: main checkout has uncommitted changes. Commit, stash, or revert before running /finish merge." >&2
  echo "Worktree at $wt_dir is untouched." >&2
  exit 1
fi

# Best-effort fetch; offline is OK. (Updates remote-tracking refs; the merge
# itself reconciles against the LOCAL source branch.)
git fetch --quiet || true

# Capture the worktree branch's ORIGINAL tip once, before any merge round, so
# the divergent-case reconstruction below can name the issue's own work as the
# merge commit's second parent even after several re-merge rounds have moved the
# branch (a live `^1` would drift to a prior merge commit). Stored in a
# per-branch ref under refs/finish-merge/. Reused across re-invocations; reset
# if a stale ref from an unrelated prior run is not in this branch's history.
orig_ref="refs/finish-merge/$(printf '%s' "$worktree_branch" | tr '/' '-')-orig"
if git show-ref --verify --quiet "$orig_ref" \
   && git merge-base --is-ancestor "$orig_ref" "$worktree_branch"; then
  orig_tip=$(git rev-parse "$orig_ref")
else
  git update-ref "$orig_ref" "$worktree_branch"
  orig_tip=$(git rev-parse "$orig_ref")
fi

# Bring the worktree branch up to source's tip, resolving in the worktree if
# needed. is-ancestor is true when the worktree branch already contains all of
# source (the common case — nothing to do).
if ! git merge-base --is-ancestor "$source_branch" "$worktree_branch"; then
  if ! git -C "$wt_dir" merge --no-edit "$source_branch"; then
    echo "CONFLICT: merging $source_branch into $worktree_branch produced conflicts in the worktree." >&2
    echo "Resolve in the worktree, then: git -C '$wt_dir' add <files> && git -C '$wt_dir' commit -F '$message_file'" >&2
    echo "Then re-run /finish merge. (No lock needed — the worktree is private to this session.)" >&2
    echo "Conflicted files (worktree-relative):" >&2
    git -C "$wt_dir" diff --name-only --diff-filter=U >&2
    exit 2
  fi
fi

# Finalize loop (under the lock): advance source to include the worktree branch,
# re-merging in the worktree if source advanced under us. We do NOT `git
# checkout` source — advancing the ref directly avoids wedging when source is
# checked out in another worktree and never moves the user's HEAD, so an exit-2
# below always leaves the main checkout exactly as the user left it. Bounded
# only as a backstop against pathological continuous contention — a clean
# re-merge loops silently and converges; it does NOT hard-fail on transient races.
cur_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
max_finalize_attempts=50
attempt=0
while : ; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt "$max_finalize_attempts" ]; then
    echo "ERROR: source branch kept advancing across $max_finalize_attempts attempts (continuous contention)." >&2
    echo "Re-run /finish merge when the source branch settles. The worktree is intact." >&2
    exit 1
  fi

  # Re-verify, while holding the lock, that the worktree branch still descends
  # from source's CURRENT tip. If source advanced, reconcile the new delta in
  # the worktree and loop. A conflict here exits 2 with the main checkout still
  # pristine — we have not touched it.
  if ! git merge-base --is-ancestor "$source_branch" "$worktree_branch"; then
    if ! git -C "$wt_dir" merge --no-edit "$source_branch"; then
      echo "CONFLICT: source advanced; merging $source_branch into $worktree_branch produced conflicts in the worktree." >&2
      echo "Resolve in the worktree, then: git -C '$wt_dir' add <files> && git -C '$wt_dir' commit -F '$message_file'" >&2
      echo "Then re-run /finish merge." >&2
      echo "Conflicted files (worktree-relative):" >&2
      git -C "$wt_dir" diff --name-only --diff-filter=U >&2
      exit 2
    fi
    continue
  fi

  # Decide the tip source should advance to.
  src_old=$(git rev-parse --verify "$source_branch")
  if git merge-base --is-ancestor "$source_branch" "$orig_tip"; then
    # No divergence: worktree branch is a linear descendant of source. Advancing
    # to it collapses to the issue's commit(s) with no merge commit.
    target=$(git rev-parse --verify "$worktree_branch")
  elif [ "$(git rev-parse "${worktree_branch}^{tree}")" = "$(git rev-parse "${source_branch}^{tree}")" ]; then
    # The worktree's work is already fully present in source (merged
    # independently, then source moved). Advancing would create a zero-diff
    # merge commit — skip it; just clean up.
    target="$src_old"
  else
    # Divergent: rebuild a merge commit with conventional parent order
    # [source, orig_tip], reusing the worktree's resolved tree, so source's
    # first-parent line stays on the mainline. Build against $src_old (not the
    # live ref) so the new commit's first parent matches the compare-and-swap.
    new=$(git commit-tree "${worktree_branch}^{tree}" \
            -p "$src_old" -p "$orig_tip" -F "$message_file") || {
      echo "ERROR: git commit-tree failed during merge reconstruction." >&2
      exit 1
    }
    target=$(git rev-parse --verify "$new")
  fi

  # Advance source to $target WITHOUT switching the main checkout's HEAD.
  if [ "$target" = "$src_old" ]; then
    :   # already-merged: nothing to advance.
  elif [ "$cur_branch" = "$source_branch" ]; then
    # Main checkout is on source: fast-forward updates ref AND working tree
    # atomically. A failed ff (source moved) is a clean no-op → loop.
    git merge --ff-only "$target" || continue
  else
    # Main checkout is on another branch (or detached). Refuse if source is
    # checked out in a *different* worktree (moving its ref would desync that
    # checkout); otherwise advance the ref with a compare-and-swap so a
    # concurrent move is detected and retried.
    elsewhere=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$source_branch" '/^worktree /{wt=$2} /^branch /{if ($2==b) print wt}' || true)
    if [ -n "$elsewhere" ]; then
      echo "ERROR: $source_branch is checked out in another worktree ($elsewhere); cannot advance it from here without desyncing that checkout." >&2
      echo "Run /finish merge from $elsewhere (or switch that worktree off $source_branch), then retry. The worktree is intact." >&2
      exit 1
    fi
    git update-ref "refs/heads/$source_branch" "$target" "$src_old" || continue
  fi
  break
done

# Verify the worktree branch's work is fully contained in source before
# deleting. Either the branch is now an ancestor of source (linear ff) or its
# tree matches source's (divergent reconstruction, or already-merged) — both
# mean no unmerged work is lost. Use -D: the divergent/already-merged tips are
# siblings of source, not ancestors, so -d would refuse (and -d's HEAD-relative
# check is meaningless here since we never checked out source).
if git merge-base --is-ancestor "$worktree_branch" "$source_branch" \
   || [ "$(git rev-parse "${worktree_branch}^{tree}")" = "$(git rev-parse "${source_branch}^{tree}")" ]; then
  : # work confirmed in source
else
  echo "ERROR: refusing to remove worktree/branch — $worktree_branch is not verified as merged into $source_branch." >&2
  echo "Inspect, then remove manually once confirmed." >&2
  exit 1
fi

# Cleanup. Gate branch delete on worktree removal (reverse — deleted branch +
# stale dir — is worse than dangling dir + intact branch). Guard each step so a
# late failure can't abort (set -e) before the orig-ref is cleaned.
if git worktree remove "$wt_dir"; then
  git branch -D "$worktree_branch" || echo "WARN: could not delete branch $worktree_branch; remove manually: git branch -D $worktree_branch" >&2
  git update-ref -d "$orig_ref" 2>/dev/null || true
  echo "Merged successfully. Worktree and branch removed."
else
  echo "Merged successfully, but git worktree remove failed for $wt_dir."
  echo "Branch $worktree_branch left intact. Investigate and remove manually:"
  echo "  git worktree remove $wt_dir"
  echo "  git branch -D $worktree_branch"
  echo "  git update-ref -d $orig_ref"
fi
git --no-pager log --oneline -1 "$source_branch"
