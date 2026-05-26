#!/bin/bash
# finish-merge.sh — Merge a /start wt worktree back to its source branch.
#
# Usage: finish-merge.sh <wt-dir> <source-branch> <worktree-branch> <message-file>
#
#   <message-file> is a markdown/text file whose contents become the merge
#   commit message if a merge commit is actually created. The merge runs as
#   `git merge -F <message-file>` — git fast-forwards when possible (the
#   common case for a single-commit worktree branch), and only consumes the
#   message when the branches have diverged. The caller (/finish Step 9)
#   should include the Linear issue ID in the subject (e.g. `Merge PL-13`)
#   for Linear's auto-linking to fire in the divergent-merge case.
#
# Must be run from the main repo checkout (cwd is the parent of .git's
# common dir). NOT from inside <wt-dir> — this script removes that
# directory on success.
#
# Preconditions (any failure aborts before touching the merge state):
#   1. source-branch exists locally
#   2. worktree directory still exists
#   3. worktree has no uncommitted tracked changes
#   4. worktree is not mid-merge / mid-rebase / mid-cherry-pick
#   5. main checkout (cwd) is clean
#
# On success: removes the worktree directory and (if removal succeeded) the
# worktree branch. On merge conflict: leaves the merge in progress (does NOT
# auto-abort) and exits 2 with the conflicted file list on stderr. The
# orchestrator resolves inline in the main checkout. Exit 1 is reserved for
# precondition failures, where the merge was never started.

set -eo pipefail

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

# Precondition 3: worktree has no uncommitted *tracked* changes. Untracked
# files (editor swap, tmp/ artifacts) do not block a merge — exclude them.
if ! git -C "$wt_dir" diff --quiet || ! git -C "$wt_dir" diff --cached --quiet; then
  echo "ERROR: worktree at $wt_dir has uncommitted tracked changes. Commit or stash before merging." >&2
  exit 1
fi

# Precondition 4: worktree is not in a mid-operation state.
# --absolute-git-dir (git ≥2.13) ensures the result is unambiguous regardless
# of cwd or git version.
rp_err=$(mktemp) || { echo "ERROR: mktemp failed; cannot capture rev-parse stderr." >&2; exit 1; }
wt_git_dir=$(git -C "$wt_dir" rev-parse --absolute-git-dir 2>"$rp_err")
if [ -z "$wt_git_dir" ]; then
  echo "ERROR: git rev-parse --absolute-git-dir failed (requires git >= 2.13):" >&2
  cat "$rp_err" >&2
  rm -f "$rp_err"
  exit 1
fi
rm -f "$rp_err"

if [ -e "$wt_git_dir/MERGE_HEAD" ] || [ -e "$wt_git_dir/CHERRY_PICK_HEAD" ] \
   || [ -d "$wt_git_dir/rebase-merge" ] || [ -d "$wt_git_dir/rebase-apply" ]; then
  echo "ERROR: worktree at $wt_dir is mid-merge / mid-rebase / mid-cherry-pick. Finish or abort it before /finish merge." >&2
  exit 1
fi

# Precondition 5: main checkout (cwd) is clean.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: main checkout has uncommitted changes. Commit, stash, or revert before running /finish merge." >&2
  echo "Worktree at $wt_dir is untouched." >&2
  exit 1
fi

# Best-effort fetch; offline is OK.
git fetch --quiet || true

if ! git checkout "$source_branch"; then
  echo "ERROR: git checkout $source_branch failed. Aborting before merge to avoid merging into the wrong branch." >&2
  exit 1
fi

if git merge -F "$message_file" "$worktree_branch"; then
  # Gate branch delete on worktree removal. Reverse (deleted branch + stale
  # dir) is worse than dangling-dir + intact-branch.
  if git worktree remove "$wt_dir"; then
    git branch -d "$worktree_branch"
    echo "Merged successfully. Worktree and branch removed."
  else
    echo "Merged successfully, but git worktree remove failed for $wt_dir."
    echo "Branch $worktree_branch left intact. Investigate and remove manually:"
    echo "  git worktree remove $wt_dir"
    echo "  git branch -d $worktree_branch"
  fi
  git --no-pager log --oneline -1
else
  # Conflict path: leave the merge in progress so the orchestrator can
  # resolve inline. Exit 2 to distinguish from precondition failures (exit 1).
  echo "CONFLICT: merge of $worktree_branch into $source_branch produced conflicts." >&2
  echo "Merge state is preserved in the main checkout for inline resolution." >&2
  echo "Conflicted files:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 2
fi
