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
#     • NOT a live/in-progress worktree — BOTH liveness guards must pass (added after PL-459, where
#       this reaper removed a freshly-created worktree mid-implementation: a zero-commit branch is
#       trivially an ancestor of its source, so the "merged" evidence fired on a worktree whose owning
#       session had just set it up; its edits then landed in the main checkout because the worktree's
#       .git was gone):
#         - HAS COMMITTED WORK: the branch has ≥1 commit beyond its recorded start.baseline-sha. A
#           zero-commit branch (tip == baseline) is never "completed work" — it is just-forked or
#           unstarted, i.e. a session is (or is about to be) working in it. (Guard skipped when no
#           baseline is recorded — pre-identity-stamp/legacy worktrees fall through to prior behavior.)
#         - IDLE: no git activity in the worktree within WORKTREE_REAP_GRACE_MIN minutes (default 60) —
#           the per-worktree index mtime is stale, indicating no live session is touching it. A live
#           session's frequent git ops (checkpoints, add, status) keep the index fresh; it goes stale
#           only after the session ends.
#   ABANDONED-for-resumption worktrees (branch unmerged, PR open, issue still active) fail the
#   evidence test and are preserved automatically — no special-casing needed.
#
# KNOWN LIMITATIONS (accepted trade-offs; both lean toward keeping work safe):
#   • Liveness is approximated by index mtime, not a true session signal. A worktree whose work is
#     ALREADY merged/PR-merged/issue-terminal AND that then goes git-idle past the grace while its
#     session is still alive could still be reaped. This is narrow — a normally-active in-progress
#     session has not reached terminal evidence yet, so it is kept as "active" by the evidence test;
#     and active git ops keep the index fresh. The robust fix is a session-maintained heartbeat (the
#     owning session's job-dir mtime was evaluated and rejected: it tracks dir creation, not activity,
#     and WT_IDENTITY_OWNER's format is not a reliable job-dir key).
#   • A zero-commit worktree at a terminal state (e.g. an issue canceled before any commit) is kept by
#     the zero-progress guard indefinitely rather than reaped — surfaced by `list`, reap manually. We
#     prefer this benign leak over weakening the guard, which would re-expose reaping a live just-forked
#     worktree (the PL-459 failure).
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
# Liveness grace (minutes): a worktree whose index was touched within this window is treated as having
# a live session and is never reaped. Default 60 (= the launchd reap interval), so only worktrees idle
# for a full cycle are eligible. Override via env for testing or a different cadence. VALIDATED to a
# positive integer — a non-numeric or 0/negative value would otherwise make the arithmetic below
# evaluate to 0 (silently disabling the guard) or raise a `set -e` error that aborts the whole run.
REAP_GRACE_MIN="${WORKTREE_REAP_GRACE_MIN:-60}"
case "$REAP_GRACE_MIN" in
  '' | *[!0-9]* | 0 | 0[0-9]* )
    echo "reap-worktrees.sh: WORKTREE_REAP_GRACE_MIN='$REAP_GRACE_MIN' is not a positive integer; using 60." >&2
    REAP_GRACE_MIN=60 ;;
esac
# An all-digits value can still be too large: recent_activity()'s `REAP_GRACE_MIN * 60` is fixed-width
# shell arithmetic, and a huge value would wrap (possibly negative) instead of erroring — silently
# disabling liveness guard B. Cap at 7 digits (up to 9,999,999 minutes, ~19 years) and fall back the
# same way as the non-numeric case above.
if [ "${#REAP_GRACE_MIN}" -gt 7 ]; then
  echo "reap-worktrees.sh: WORKTREE_REAP_GRACE_MIN='$REAP_GRACE_MIN' is out of range; using 60." >&2
  REAP_GRACE_MIN=60
fi

err()  { echo "reap-worktrees.sh: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Reuse the shared worktree-identity loader (defines wt_identity_load, which prefers a path-validated
# sidecar and falls back to per-worktree git config). Guarded so a missing library never aborts the
# reaper — recorded_baseline falls back to a direct git-config read when the loader is unavailable.
# shellcheck source=/dev/null
[ -f "$HOME/.claude/scripts/wt-identity.sh" ] && . "$HOME/.claude/scripts/wt-identity.sh"

# Absolute common-git-dir for a repo — the lock key finish-merge.sh uses (its "Lock key" comment),
# so holding it here makes a reap mutually exclusive with any in-flight /finish merge of the same repo.
# --path-format=absolute returns git's own absolute form, identical from any worktree or the main
# checkout, and avoids the MSYS `pwd -P` divergence the old `cd … && pwd -P` had (see standards/git.md
# "Windows Git Bash: comparing paths").
repo_key_for() {
  local repo="$1" key
  key=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  { [ -n "$key" ] && [ "$key" != "/" ]; } || return 1
  printf '%s\n' "$key"
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

# True iff <dir> is its OWN registered linked worktree. A linked worktree carries its own .git
# gitdir-pointer FILE and its git dir is <main>/.git/worktrees/<name>; an orphaned remnant (a partial
# Windows removal that deleted the pointer but couldn't unlink locked node_modules / long paths) has
# no .git, so `git -C "$dir" rev-parse` silently resolves UP to the main checkout's .git — every git
# query in evaluate_worktree would then read MAIN's state (notably a constantly-fresh index, which
# recent_activity() misreads as "active"). We detect this via git's own structure (the absolute git
# dir sits under a worktrees/ admin dir), NOT a path-string comparison: on Windows/MSYS `pwd -P`
# normalizes inconsistently across C:/ vs /c/ vs mount aliases (e.g. /tmp), so resolved-path equality
# is unreliable. The `.git`-pointer gate is what actually rejects an orphan (it has none, so rev-parse
# would walk up to main); the pattern then confirms the resolved git dir is worktree-shaped —
# `*/worktrees/*` covers both the standard layout (…/.git/worktrees/<name>) and submodule /
# separate-git-dir repos (…/.git/modules/<name>/worktrees/<name>), rather than hard-coding a `.git` name.
is_registered_worktree() {
  local dir="$1" gd
  [ -e "$dir/.git" ] || return 1
  gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  case "$gd" in */worktrees/*) return 0 ;; *) return 1 ;; esac
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

# The baseline (fork-point) commit /start recorded for this worktree, or empty if none is recorded.
# Reuses wt_identity_load when available (it prefers a sidecar whose recorded WT_DIR matches this
# worktree — so a stale same-issue sidecar can't supply a wrong baseline — and falls back to per-
# worktree git config). Falls back to a direct git-config read if the loader isn't sourced. Empty ⇒
# legacy/pre-stamp worktree, and the zero-commit guard then no-ops.
recorded_baseline() {
  local repo="$1" dir="$2" slug="$3"
  if declare -f wt_identity_load >/dev/null 2>&1 && wt_identity_load "$dir" "$slug"; then
    printf '%s' "$WTID_BASELINE"
    return 0
  fi
  git -C "$dir" config --worktree --get start.baseline-sha 2>/dev/null || true
}

# True when the worktree's index was modified within REAP_GRACE_MIN minutes — a cheap liveness proxy
# (a live session's git ops keep the index fresh; it goes stale only after the session ends). MUST be
# called BEFORE any index-writing git op in evaluate_worktree (e.g. `git status`) to avoid self-poison.
# Caller (evaluate_worktree) guarantees a registered worktree via is_registered_worktree first, so
# --absolute-git-dir resolves to THIS worktree's index, not the main checkout's ever-fresh one.
# Resolves the index via --absolute-git-dir (the worktree's own git dir, guaranteed absolute on git
# >=2.13) — unambiguous, unlike `rev-parse --git-path index` whose relative form is .git-dir-relative.
recent_activity() {
  local dir="$1" gd idx mtime now grace
  gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  idx="$gd/index"
  [ -f "$idx" ] || return 1
  # GNU-first is the safe order: BSD rejects -c cleanly (no stdout), while GNU "accepts" -f as
  # filesystem-status and pollutes stdout despite failing — reversed order corrupts mtime silently.
  mtime=$(stat -c %Y "$idx" 2>/dev/null || stat -f %m "$idx" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) mtime= ;; esac
  [ -n "$mtime" ] || return 1
  now=$(date +%s)
  grace=$(( REAP_GRACE_MIN * 60 ))
  [ "$(( now - mtime ))" -lt "$grace" ]
}

# Evaluate one worktree dir. mode=list prints the verdict only; mode=reap also removes when eligible.
# Assumes (reap mode) the per-repo lock is held by the caller.
evaluate_worktree() {
  local repo="$1" dir="$2" mode="$3"
  local slug issue branch source reason merged_ref ltype dirty baseline

  slug=$(basename "$dir")
  issue=$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')

  # Must be its OWN registered linked worktree. A stray dir (admin pruned, manual rm, or a partial
  # Windows removal that left content but deleted the .git pointer) resolves rev-parse UP to the main
  # checkout, so every git query below would silently read MAIN's state (a fresh index → false
  # "active", HEAD → main, etc.). Surface it with cleanup guidance and never `rm -rf` an arbitrary path.
  if ! is_registered_worktree "$dir"; then
    printf '  %-12s %s\n' "$issue" "STRAY — orphaned worktree remnant, not a registered worktree ($dir). Likely a partial removal (Windows locked files/long paths). Inspect for unsaved work, then: rm -rf '$dir' && git -C '$repo' worktree prune"
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

  # Liveness guard A — zero committed work. A branch with no commits beyond its recorded baseline is
  # not "completed work" (a done worktree always has commits) — it is just-forked or unstarted, so a
  # session is, or is about to be, working in it. The completion-evidence test below would otherwise
  # fire on it (a zero-commit branch is trivially an ancestor of source), reaping a live worktree and
  # landing its edits in the main checkout (PL-459). No-op when no baseline is recorded (legacy).
  baseline=$(recorded_baseline "$repo" "$dir" "$slug")
  if [ -n "$baseline" ] && git -C "$dir" cat-file -e "${baseline}^{commit}" 2>/dev/null \
     && [ "$(git -C "$dir" rev-list --count "${baseline}..HEAD" 2>/dev/null || echo 1)" = "0" ]; then
    printf '  %-12s %s\n' "$issue" "KEEP — no commits since baseline (just-forked/unstarted); a live session likely owns it."
    return 0
  fi

  # Liveness guard B — recent activity. The worktree's index was touched within REAP_GRACE_MIN minutes,
  # so a session is actively using it. Checked BEFORE the `git status` below, which can rewrite the
  # index and would otherwise reset this signal.
  if recent_activity "$dir"; then
    printf '  %-12s %s\n' "$issue" "KEEP — active within ${REAP_GRACE_MIN}m (index recently modified); deferring reap to avoid a live session."
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
