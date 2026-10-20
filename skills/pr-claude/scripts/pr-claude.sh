#!/usr/bin/env bash
# pr-claude.sh — carry uncommitted .claude/ edits from a checkout parked on the default branch onto a pushed branch,
# open (or extend) its PR, and return the checkout to a clean default branch.
#
#   pr-claude.sh survey
#   pr-claude.sh submit --slug <kebab> --title <title> --body-file <file> [--onto <branch>] [--allow-outside] [-- <path>...]
#   pr-claude.sh resume <branch>
#   pr-claude.sh settle
#
# Exit: 0 done · 1 refused (the REFUSED line says why) · 2 the edits conflict with the default branch · 3 usage
#       4 pushed, but the PR could not be opened — nothing was restored, and rerunning the same submit picks up there
#
# Everything is git plumbing: the edits are snapshotted through a temporary index, the commit is built with
# commit-tree, and that object is pushed straight to the branch ref. The checkout never switches branch, no worktree is
# made, and no commit hook runs — so nothing local changes until the restore at the very end. The reason the restore
# exists at all: /update skips the project pull whenever the tree is dirty, so edits left in place would silently
# freeze a non-engineer's checkout. It runs only after origin is confirmed to hold the pushed commit AND the working
# tree is unchanged since the snapshot, and a patch of the edits is kept under tmp/pr-claude/ either way.
set -euo pipefail

die() { echo "REFUSED: $*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" >&2; exit 3; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "this folder is not a git checkout"
cd "$ROOT"
SCRATCH="$ROOT/tmp/pr-claude"
DEFAULT=""

default_branch() {
  git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true
}

preflight() {
  local gd common f cur
  gd=$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$gd" = "$common" ] || die "this is a linked worktree — a worktree's changes ship with its issue (/finish), not from here"
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ ! -e "$gd/$f" ] || die "a git operation is half-finished in this checkout ($f) — that needs an engineer before anything else"
  done

  DEFAULT=$(default_branch)
  if [ -z "$DEFAULT" ]; then
    git remote set-head origin --auto >/dev/null 2>&1 || true
    DEFAULT=$(default_branch)
  fi
  [ -n "$DEFAULT" ] || die "cannot tell which branch is the default (origin/HEAD is unset and GitHub could not be asked)"
  git fetch --quiet origin "$DEFAULT" || die "could not reach GitHub (git fetch failed)"

  cur=$(git branch --show-current)
  [ "$cur" = "$DEFAULT" ] || die "this checkout is on '${cur:-a detached commit}', not '$DEFAULT' — work on a branch goes out with /pr-update"
  [ "$(git rev-list --count "origin/$DEFAULT..HEAD")" = 0 ] ||
    die "this checkout has commits on $DEFAULT that were never pushed — that needs an engineer to untangle first"
}

# <pathspec>... → the tree id of HEAD plus the working-tree state of those paths. A temporary index keeps the real one
# untouched, picks up untracked and deleted files alike, and honours every ignore rule.
snapshot() {
  mkdir -p "$SCRATCH"
  local idx="$SCRATCH/index.$$"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree HEAD
  GIT_INDEX_FILE="$idx" git add -A -- "$@"
  GIT_INDEX_FILE="$idx" git write-tree
  rm -f "$idx"
}

# Path lists are NUL-delimited throughout: line-oriented git output quotes any path holding a space, and a quoted
# path neither matches the .claude/ prefix nor names a real file.
changed_paths() { git diff -z --name-only --no-renames HEAD "$1"; }

outside_changes() {
  git status --porcelain=v1 -z --untracked-files=all --no-renames | while IFS= read -r -d '' line; do
    case "${line:3}" in .claude/*) ;; *) printf '%s\n' "$line" ;; esac
  done
}

blob_at() { git rev-parse -q --verify "$1:$2" 2>/dev/null || echo absent; }

prune_empty_dirs() {
  local d="$1"
  while [ "$d" != ".claude" ] && [ "$d" != "." ] && [ "$d" != "/" ]; do
    rmdir "$d" 2>/dev/null || break
    d=$(dirname "$d")
  done
}

restore_path() {
  if git cat-file -e "HEAD:$1" 2>/dev/null; then
    git checkout -q HEAD -- "$1"
  else
    git rm -q --cached --ignore-unmatch -- "$1" >/dev/null
    rm -f -- "$1"
    prune_empty_dirs "$(dirname "$1")"
  fi
}

cmd_survey() {
  preflight
  local tree login p num branch url
  echo "default $DEFAULT"
  echo "behind $(git rev-list --count "HEAD..origin/$DEFAULT")"
  login=$(gh api user --jq .login 2>/dev/null) || login=""
  echo "login ${login:-UNKNOWN — GitHub CLI is not signed in (gh auth login)}"

  tree=$(snapshot .claude)
  changed_paths "$tree" | while IFS= read -r -d '' p; do
    if [ "$(blob_at "$tree" "$p")" = "$(blob_at "origin/$DEFAULT" "$p")" ]; then
      echo "landed $p"
    else
      echo "changed $p"
    fi
  done
  outside_changes | while IFS= read -r p; do echo "outside $p"; done

  [ -n "$login" ] || return 0
  gh pr list --author "@me" --state open --json number,headRefName,url \
    --jq '.[] | select(.headRefName | test("/claude-")) | "\(.number)\t\(.headRefName)\t\(.url)"' 2>/dev/null |
    while IFS=$'\t' read -r num branch url; do
      echo "open-pr $num $branch $url"
      gh pr view "$num" --json files --jq '.files[].path' 2>/dev/null | while IFS= read -r p; do
        echo "open-pr-file $num $p"
      done
    done
}

cmd_submit() {
  local slug="" title="" body="" onto="" allow_outside=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) [ $# -ge 2 ] || usage; slug="$2"; shift 2 ;;
      --title) [ $# -ge 2 ] || usage; title="$2"; shift 2 ;;
      --body-file) [ $# -ge 2 ] || usage; body="$2"; shift 2 ;;
      --onto) [ $# -ge 2 ] || usage; onto="$2"; shift 2 ;;
      --allow-outside) allow_outside=1; shift ;;
      --) shift; break ;;
      -*) usage ;;
      *) break ;;
    esac
  done
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,39}$ ]] || usage
  [ -n "$title" ] || usage
  [ -f "$body" ] || usage
  # Nothing under .claude/ is built, tested or deployed by CI, and a merge into the default branch otherwise starts a
  # production deployment. The token rides the commit (no branch build) and the PR title, which this repo's merge
  # commits repeat as their body (merge_commit_message: PR_TITLE) — so the merge skips its build too.
  case "$title" in *"[skip ci]"*) ;; *) title="$title [skip ci]" ;; esac
  [ $# -gt 0 ] || set -- .claude
  local p
  for p in "$@"; do
    p="${p#./}"
    case "$p" in
      *..*) die "path '$p' may not contain '..'" ;;
      .claude | .claude/*) ;;
      *) die "'$p' is outside .claude/ — this command only ever submits Claude configuration" ;;
    esac
  done

  preflight
  local login branch tree outside head base new newtree out rc remote_tip url merged=0
  login=$(gh api user --jq .login 2>/dev/null) || die "the GitHub CLI is not signed in — run: gh auth login"
  if [ -n "$onto" ]; then
    branch="$onto"
    git fetch --quiet origin "refs/heads/$branch:refs/remotes/origin/$branch" || die "no branch named '$branch' on GitHub"
  else
    branch="$login/claude-$slug"
  fi

  tree=$(snapshot "$@")
  ! git diff --quiet HEAD "$tree" || die "nothing under .claude/ has changed"
  git diff --binary --full-index HEAD "$tree" >"$SCRATCH/$slug.patch"

  if [ "$allow_outside" = 0 ]; then
    outside=$(outside_changes)
    [ -z "$outside" ] || die "files outside .claude/ are modified too, and they would keep this checkout from updating:
$outside
Those are not Claude configuration. Look at them first; --allow-outside submits the .claude/ part and leaves them alone."
  fi

  head=$(git rev-parse HEAD)
  if [ -n "$onto" ]; then base=$(git rev-parse "origin/$branch"); else base=$(git rev-parse "origin/$DEFAULT"); fi
  if [ "$base" = "$head" ]; then
    newtree="$tree"
  else
    # The base moved on (the default branch advanced, or this adds to an open submission): three-way merge the edits
    # onto it, in the object database only.
    local snap
    snap=$(git commit-tree "$tree" -p "$head" -m "pr-claude snapshot")
    out=$(git merge-tree --write-tree "$base" "$snap" 2>&1) && rc=0 || rc=$?
    if [ "$rc" = 1 ]; then
      echo "CONFLICT: the same lines changed on GitHub since this checkout last updated. Nothing was pushed and nothing here was touched." >&2
      printf '%s\n' "$out" | sed -n '2,$p' >&2
      exit 2
    fi
    [ "$rc" = 0 ] || die "git could not merge these edits (git 2.38 or newer is required): $out"
    newtree=$(printf '%s\n' "$out" | sed -n '1p')
    merged=1
  fi
  [ "$newtree" != "$(git rev-parse "$base^{tree}")" ] || die "these edits are already on '$branch' — there is nothing new to submit"

  remote_tip=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
  if [ -z "$onto" ] && [ -n "$remote_tip" ]; then
    git fetch --quiet origin "refs/heads/$branch:refs/remotes/origin/$branch"
    [ "$(git rev-parse "$remote_tip^{tree}")" = "$newtree" ] ||
      die "a branch named '$branch' already exists on GitHub with different content — choose another slug, or pass --onto $branch to add to it"
    new="$remote_tip"
  else
    # A second parent on HEAD keeps GitHub's PR diff to these edits alone when an --onto merge pulled in newer default-branch content.
    if [ -n "$onto" ] && ! git merge-base --is-ancestor "$head" "$base"; then
      new=$(git commit-tree "$newtree" -p "$base" -p "$head" -m "$title")
    else
      new=$(git commit-tree "$newtree" -p "$base" -m "$title")
    fi
    git push --quiet origin "$new:refs/heads/$branch" || die "GitHub rejected the push to '$branch' (no write access, or the branch moved) — nothing here was touched"
  fi
  [ "$(git ls-remote origin "refs/heads/$branch" | cut -f1)" = "$new" ] || die "GitHub does not show the pushed commit on '$branch' — nothing here was touched"

  url=$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null) || url=""
  if [ -z "$url" ]; then
    url=$(gh pr create --base "$DEFAULT" --head "$branch" --title "$title" --body-file "$body" 2>/dev/null) || {
        echo "PUSHED-NO-PR $branch — the edits are safe on GitHub but the pull request could not be opened. Nothing here was restored; rerun the same submit." >&2
        exit 4
      }
  fi
  echo "PR $url"
  echo "BRANCH $branch"
  [ "$merged" = 0 ] || echo "MERGED-WITH-BASE the branch also carries newer content from GitHub; the edits merged cleanly"
  echo "RESCUE tmp/pr-claude/$slug.patch"

  if [ "$(snapshot "$@")" != "$tree" ]; then
    echo "NOT-RESTORED files under .claude/ changed while this ran, so they were left exactly as they are"
    return 0
  fi
  local n=0
  while IFS= read -r -d '' p; do
    restore_path "$p"
    n=$((n + 1))
  done < <(changed_paths "$tree")
  echo "RESTORED $n file(s) to the shared version"
}

cmd_resume() {
  [ $# -eq 1 ] || usage
  local branch="$1" patch="$SCRATCH/resume.$$.patch"
  preflight
  git fetch --quiet origin "refs/heads/$branch:refs/remotes/origin/$branch" || die "no branch named '$branch' on GitHub"
  mkdir -p "$SCRATCH"
  git diff --binary --full-index "origin/$DEFAULT...origin/$branch" -- .claude >"$patch"
  [ -s "$patch" ] || { rm -f "$patch"; die "'$branch' has nothing left to bring back — it looks merged already"; }
  git apply --check "$patch" 2>/dev/null || { rm -f "$patch"; die "the submitted edits no longer apply to the files here (they were edited again, or the shared version moved) — that needs a closer look"; }
  git apply "$patch"
  rm -f "$patch"
  echo "RESUMED the edits from '$branch' are back in the working files"
}

cmd_settle() {
  preflight
  local tree p n=0 behind
  tree=$(snapshot .claude)
  while IFS= read -r -d '' p; do
    if [ "$(blob_at "$tree" "$p")" = "$(blob_at "origin/$DEFAULT" "$p")" ]; then
      restore_path "$p"
      n=$((n + 1))
    fi
  done < <(changed_paths "$tree")
  echo "SETTLED $n file(s) whose edits are already on $DEFAULT"
  behind=$(git rev-list --count "HEAD..origin/$DEFAULT")
  if [ "$behind" != 0 ] && [ -z "$(git status --porcelain)" ]; then
    git pull --quiet --ff-only origin "$DEFAULT"
    echo "PULLED $behind commit(s)"
  fi
}

[ $# -gt 0 ] || usage
command="$1"
shift
case "$command" in
  survey) cmd_survey "$@" ;;
  submit) cmd_submit "$@" ;;
  resume) cmd_resume "$@" ;;
  settle) cmd_settle "$@" ;;
  *) usage ;;
esac
