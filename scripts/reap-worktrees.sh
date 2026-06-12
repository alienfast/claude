#!/bin/bash
# reap-worktrees.sh — reclaim completed/abandoned /start wt worktrees.
#
# /start wt creates a worktree at <repo>/.claude/worktrees/<issue-lower> (see start-wt-setup.sh).
# Two flows leave that worktree behind on purpose, and nothing reclaims it afterward:
#
#   1. `/finish pr` (worktree mode) — the PR merges asynchronously on GitHub *later*, so /finish
#      cannot clean up at the time it runs; the SHIPPED-PR tag tells the user to remove the worktree
#      after the PR lands, but that hand-off is manual and easily forgotten.
#   2. An issue Canceled/Done directly in Linear (no live /start session) — /start Step 8.5 only
#      surfaces cleanup while a session is running, so a cancel outside that window orphans the worktree.
#
# (The `/finish merge` flow does NOT leak — finish-merge.sh removes the worktree on a successful merge.)
#
# This is the missing reconciler: a local launchd job (reap-worktrees-cron.sh) runs it periodically.
# It mirrors the deferred-merge drainer (drain-merge-queue.sh + merge-queue.sh): pure shell + git,
# best-effort gh/linear, per-repo serialized via with-repo-lock.py against the SAME key finish-merge.sh
# uses, so a reap can never race an in-flight `/finish merge`.
#
# REAP DISCIPLINE — destroy only on positive evidence of completion, never on mere inactivity:
#   A worktree is reaped iff ALL hold:
#     • completion evidence (any one):
#         - its branch is an ancestor of its source branch or the repo default (merged), OR
#         - its PR state is MERGED (gh), OR
#         - its Linear issue state type is completed|canceled.
#     • no unsaved commits: every commit on the branch is reachable from a durable ref — it is
#       merged into mainline OR present on its origin remote-tracking branch (pushed).
#     • clean working tree: `git status --porcelain` is empty, i.e. no tracked modifications and no
#       untracked non-ignored files. We NEVER pass --force, so untracked work is never destroyed;
#       gitignored scratch (tmp/, node_modules) does not block removal.
#     • no in-flight deferred merge: no <repo>/.claude/merge-queue/<issue>.json marker.
#   ABANDONED-for-resumption worktrees (branch unmerged, PR open, issue still active) fail the
#   evidence test and are preserved automatically — no special-casing needed.
#
# Subcommands:
#   reap [<repo_root>]   Reap eligible worktrees. No arg → every registered repo (the launchd path).
#                        Mutating; serialized per repo under the common-git-dir lock.
#   list [<repo_root>]   Dry run: print the verdict for every worktree, mutate nothing, take no lock.
#   __reap_one <repo>    Internal: the per-repo body, invoked by `reap` under the lock.
#
# Registered repos are the union of two self-registering newline lists: ~/.claude/worktree-repos.txt
# (written by start-wt-setup.sh at every worktree birth — the complete set) and
# ~/.claude/merge-queue-repos.txt (repos that have deferred a merge — a subset, included for safety).

set -eo pipefail

SELF="$HOME/.claude/scripts/reap-worktrees.sh"
LOCK_HELPER="$HOME/.claude/scripts/with-repo-lock.py"
WT_SUBDIR=".claude/worktrees"
MQ_SUBDIR=".claude/merge-queue"
WT_REGISTRY="$HOME/.claude/worktree-repos.txt"
MQ_REGISTRY="$HOME/.claude/merge-queue-repos.txt"

err()  { echo "reap-worktrees.sh: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Absolute common-git-dir for a repo — the lock key finish-merge.sh uses (its §"Lock key" comment),
# so holding it here makes a reap mutually exclusive with any in-flight /finish merge of the same repo.
repo_key_for() {
  local repo="$1" common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) printf '%s\n' "$common" ;;
    *)  ( cd "$repo" && cd "$common" 2>/dev/null && pwd -P ) ;;
  esac
}

# Repo default branch: origin/HEAD's target, else a local main/master, else "main".
default_branch_for() {
  local repo="$1" ref
  ref=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#refs/remotes/origin/}"; return 0; fi
  local b
  for b in main master; do
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 && { printf '%s\n' "$b"; return 0; }
  done
  printf 'main\n'
}

# Is <child> an ancestor of <parent>? False (not erroring) when <parent> doesn't resolve.
is_ancestor() {
  local repo="$1" child="$2" parent="$3"
  git -C "$repo" rev-parse --verify --quiet "$parent" >/dev/null 2>&1 || return 1
  git -C "$repo" merge-base --is-ancestor "$child" "$parent" 2>/dev/null
}

# Echo the first durable ref the branch is merged into (local/remote source, local/remote default),
# or nothing. Empty result ⇒ not merged anywhere we consider mainline.
merged_into() {
  local repo="$1" branch="$2" source="$3" def ref
  def=$(default_branch_for "$repo")
  for ref in "$source" "origin/$source" "$def" "origin/$def"; do
    [ -n "$ref" ] || continue
    if is_ancestor "$repo" "$branch" "$ref"; then printf '%s\n' "$ref"; return 0; fi
  done
  return 1
}

# True when every commit on <branch> is present on its origin remote-tracking branch (pushed).
# Uses refs/remotes/origin/<branch> directly rather than @{upstream}, so it holds even when /finish
# pushed without -u (no upstream configured). Branch names with slashes (rosskevin/pl-380-…) are fine.
is_pushed() {
  local repo="$1" branch="$2" rb="refs/remotes/origin/$2" ahead
  git -C "$repo" rev-parse --verify --quiet "$rb" >/dev/null 2>&1 || return 1
  ahead=$(git -C "$repo" rev-list --count "$rb..$branch" 2>/dev/null || echo 1)
  [ "$ahead" = 0 ]
}

# Best-effort: is the branch's PR merged on GitHub? Empty/!MERGED/offline/no-gh ⇒ non-zero (unknown).
pr_is_merged() {
  local repo="$1" branch="$2" state
  have gh || return 1
  state=$(cd "$repo" && gh pr view "$branch" --json state --jq .state 2>/dev/null || true)
  [ "$state" = "MERGED" ]
}

# Best-effort Linear state type for an issue (completed|canceled|started|…); empty on any failure.
linear_state_type() {
  local issue="$1"
  # linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
  export PATH="$HOME/.cargo/bin:$PATH"
  have linear-cli || return 0
  have jq || return 0
  # `issues get -o json` omits state.type (only state.name); query it via the API.
  linear-cli api query -q -o json -v id="$issue" \
    'query($id:String!){issue(id:$id){state{type}}}' 2>/dev/null \
    | jq -r '.data.issue.state.type // empty' 2>/dev/null || true
}

# Evaluate one worktree dir. mode=list prints the verdict only; mode=reap also removes when eligible.
# Assumes (reap mode) the per-repo lock is held by the caller.
evaluate_worktree() {
  local repo="$1" dir="$2" mode="$3"
  local slug issue branch source reason merged_ref ltype dirty

  slug=$(basename "$dir")
  issue=$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')

  # Must be a real linked worktree. A stray directory (admin dir pruned, manual rm) is left untouched
  # and surfaced — we never `rm -rf` an arbitrary path.
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  %-12s %s\n' "$issue" "STRAY — not a git worktree ($dir); left for manual inspection."
    return 0
  fi

  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    printf '  %-12s %s\n' "$issue" "SKIP — detached HEAD; cannot reason about it safely."
    return 0
  fi

  source=$(git -C "$dir" config --worktree --get start.source-branch 2>/dev/null || true)
  [ -n "$source" ] || source=$(default_branch_for "$repo")

  # Safety: a deferred merge owns this worktree — the drainer will remove it when the merge lands.
  if [ -f "$repo/$MQ_SUBDIR/$slug.json" ]; then
    printf '  %-12s %s\n' "$issue" "SKIP — merge queued; the merge-queue drainer owns this worktree."
    return 0
  fi

  dirty=0
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && dirty=1

  # Completion evidence. The local merged check is free; only consult gh/linear-cli when not locally
  # merged AND the tree is clean (a dirty worktree is never auto-reaped, so the network can't change
  # the outcome to a reap — skip it).
  reason=""
  if merged_ref=$(merged_into "$repo" "$branch" "$source"); then
    reason="branch merged into $merged_ref"
  elif [ "$dirty" = 0 ]; then
    if pr_is_merged "$repo" "$branch"; then
      reason="PR merged"
    else
      ltype=$(linear_state_type "$issue")
      case "$ltype" in
        completed|canceled) reason="Linear issue $ltype" ;;
      esac
    fi
  fi

  if [ -z "$reason" ]; then
    printf '  %-12s %s\n' "$issue" "KEEP — active (not merged, no merged PR, issue not terminal)."
    return 0
  fi

  # Eligible by evidence — now the safety gates that protect work.
  if ! { [ -n "$merged_ref" ] || is_pushed "$repo" "$branch"; }; then
    printf '  %-12s %s\n' "$issue" "KEEP — $reason, but the branch has local-only commits (not merged, not pushed). Resolve manually."
    return 0
  fi
  if [ "$dirty" = 1 ]; then
    printf '  %-12s %s\n' "$issue" "KEEP — $reason, but the worktree is dirty (uncommitted/untracked). To clear: git -C '$repo' worktree remove --force '$dir' && git -C '$repo' branch -D '$branch'"
    return 0
  fi

  if [ "$mode" = "list" ]; then
    printf '  %-12s %s\n' "$issue" "REAP-ELIGIBLE — $reason."
    return 0
  fi

  # mode=reap: remove without --force (the clean check guarantees nothing untracked is lost). Gate the
  # branch delete on a successful worktree removal — a deleted branch beside a stale dir is the worse
  # half-state. -D is safe: we proved the branch is merged or fully pushed, so no commit is orphaned.
  if git -C "$repo" worktree remove "$dir"; then
    git -C "$repo" branch -D "$branch" 2>/dev/null \
      || echo "    WARN: removed worktree but could not delete branch $branch; delete manually: git -C '$repo' branch -D '$branch'" >&2
    git -C "$repo" worktree prune 2>/dev/null || true
    printf '  %-12s %s\n' "$issue" "REAPED — $reason; worktree and branch removed."
  else
    printf '  %-12s %s\n' "$issue" "FAILED — $reason, but git worktree remove refused; left intact for inspection."
  fi
}

# Body of a per-repo reap, run under the common-git-dir lock by cmd_reap. A best-effort fetch refreshes
# remote-tracking refs so the merged/pushed checks see the current origin state (offline is fine).
cmd_reap_one() {
  local repo="$1" wt_root="$1/$WT_SUBDIR" dir had_any=0
  [ -d "$wt_root" ] || { echo "$repo — no worktrees directory"; return 0; }
  git -C "$repo" fetch --quiet 2>/dev/null || true
  echo "$repo:"
  shopt -s nullglob
  for dir in "$wt_root"/*/; do
    dir="${dir%/}"
    had_any=1
    evaluate_worktree "$repo" "$dir" reap
  done
  shopt -u nullglob
  [ "$had_any" = 1 ] || echo "  (no worktrees)"
}

# Resolve the repo set: an explicit arg, else the deduped union of both registries. Missing dirs are
# skipped with a warning so a stale registry entry can't abort the run.
resolve_repos() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then printf '%s\n' "$arg"; return 0; fi
  { [ -f "$WT_REGISTRY" ] && cat "$WT_REGISTRY"; [ -f "$MQ_REGISTRY" ] && cat "$MQ_REGISTRY"; } 2>/dev/null \
    | awk 'NF && !seen[$0]++'
}

cmd_reap() {
  local repos=() repo key
  while IFS= read -r repo; do [ -n "$repo" ] && repos+=("$repo"); done < <(resolve_repos "${1:-}")
  [ "${#repos[@]}" -gt 0 ] || { echo "reap-worktrees: no repos registered ($WT_REGISTRY / $MQ_REGISTRY)"; return 0; }
  for repo in "${repos[@]}"; do
    [ -d "$repo" ] || { err "registered repo missing, skipping: $repo"; continue; }
    if ! key=$(repo_key_for "$repo"); then err "not a git repo, skipping: $repo"; continue; fi
    # Serialize per repo on the SAME key finish-merge.sh locks (absolute common git dir), so a reap and
    # an in-flight /finish merge of this repo never overlap. The lock helper re-execs SELF under flock.
    "$LOCK_HELPER" "$key" "$SELF" __reap_one "$repo"
  done
}

cmd_list() {
  local repos=() repo dir had_any
  while IFS= read -r repo; do [ -n "$repo" ] && repos+=("$repo"); done < <(resolve_repos "${1:-}")
  [ "${#repos[@]}" -gt 0 ] || { echo "reap-worktrees: no repos registered ($WT_REGISTRY / $MQ_REGISTRY)"; return 0; }
  for repo in "${repos[@]}"; do
    [ -d "$repo" ] || { echo "$repo — MISSING (stale registry entry)"; continue; }
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$repo — not a git repo"; continue; }
    [ -d "$repo/$WT_SUBDIR" ] || continue
    git -C "$repo" fetch --quiet 2>/dev/null || true
    echo "$repo:"
    had_any=0
    shopt -s nullglob
    for dir in "$repo/$WT_SUBDIR"/*/; do
      dir="${dir%/}"; had_any=1
      evaluate_worktree "$repo" "$dir" list
    done
    shopt -u nullglob
    [ "$had_any" = 1 ] || echo "  (no worktrees)"
  done
}

sub="${1:-}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  reap)        cmd_reap "$@" ;;
  __reap_one)  cmd_reap_one "$@" ;;   # internal: invoked under the repo lock by cmd_reap
  list|"")     cmd_list "$@" ;;
  *)           err "unknown subcommand: $sub (expected reap|list)"; exit 1 ;;
esac
