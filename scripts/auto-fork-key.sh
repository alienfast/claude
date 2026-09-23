#!/usr/bin/env bash
# auto-fork-key.sh — steer one issue's /start wt onto an epic fleet's integration branch without moving the checkout.
#
# Usage: auto-fork-key.sh set <ISSUE-ID> <EPIC-ID>
#        auto-fork-key.sh unset <ISSUE-ID>
#
# /auto runs `set` before every `/full auto wt <ISSUE-ID>` dispatch of an epic-scoped run and `unset` once that
# dispatch's lifecycle tag is in. `set` reads the fleet marker <main-checkout>/tmp/fleet-deadline.json (written by
# fleet-launch.sh): when its `scope` is <EPIC-ID> and it records a `branch`, the per-issue key
# `start.<issue-lower>.wt-source-branch` is pointed at that branch — the same key /fleet-sequence's runner sets, which
# start-wt-setup.sh resolves ahead of the checkout's own branch, and start-wt-create.sh forks from the branch's REF.
# So the issue forks from and (finish-merge.sh, ref-only) merges into the integration branch while the main checkout
# stays on whatever branch its human is using, and a `/start wt` for any OTHER issue — an interactive one for an
# epic member included — still forks from the checkout's branch. This replaced the detached-HEAD posture
# fleet-launch.sh imposed until 2026-09-23 (checkout detached at the branch plus a checkout-wide
# start.wt-source-branch), which took the main checkout away from its human for the fleet's duration and steered
# their own /start wt onto the epic branch too.
#
# Output: one FORK-KEY: line on stdout. Exit 0 when the key was set, cleared, or there was nothing to steer (no
# marker, another scope, no branch recorded — the issue then forks from the checkout's branch, the unscoped
# behaviour). A recorded branch that no longer exists locally is the same fallback with a WARN in the line, not
# an error: a fleet whose human dropped the branch mid-run must keep shipping onto the checkout's branch rather
# than stall every session on SKIPPED-BLOCKED (2026-09-23: the BF-1826 branch was deleted under five running
# sessions). Exit 1 on a usage error or a per-issue key already naming a DIFFERENT branch (a /fleet-sequence
# runner's — never overwritten).
set -uo pipefail

usage() { echo "Usage: $0 set <ISSUE-ID> <EPIC-ID> | unset <ISSUE-ID>" >&2; exit 1; }

norm_id() { # <token> → uppercase issue id, or exit 1
  local id
  id=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  [[ "$id" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { echo "ERROR: '$1' does not name an issue (e.g. BF-123)" >&2; exit 1; }
  printf '%s' "$id"
}

action="${1:-}"
case "$action" in
  set)   [ $# -eq 3 ] || usage ;;
  unset) [ $# -eq 2 ] || usage ;;
  *) usage ;;
esac
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
issue_id=$(norm_id "$2") || exit 1
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')
key="start.${issue_lower}.wt-source-branch"

# The key is common-scope config: written through the main checkout so a worktree cwd lands it in the same place.
main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository" >&2; exit 1; }

if [ "$action" = "unset" ]; then
  cur=$(git -C "$main_checkout" config --get "$key" 2>/dev/null || true)
  if [ -n "$cur" ]; then
    git -C "$main_checkout" config --unset "$key"
    echo "FORK-KEY: cleared $key (was $cur)"
  else
    echo "FORK-KEY: nothing to clear — $key is not set"
  fi
  exit 0
fi

epic_id=$(norm_id "$3") || exit 1
marker="$main_checkout/tmp/fleet-deadline.json"
if ! [ -s "$marker" ]; then
  echo "FORK-KEY: none — no fleet marker at tmp/fleet-deadline.json; $issue_id forks from the checkout's own branch"
  exit 0
fi
scope=$(jq -r '.scope // empty' "$marker" 2>/dev/null || true)
branch=$(jq -r '.branch // empty' "$marker" 2>/dev/null || true)
if [ "$scope" != "$epic_id" ]; then
  echo "FORK-KEY: none — the fleet marker is scoped to '${scope:-nothing}', not $epic_id; $issue_id forks from the checkout's own branch"
  exit 0
fi
if [ -z "$branch" ]; then
  echo "FORK-KEY: none — epic $epic_id has no integration branch recorded (run /epic-prep $epic_id before launching); $issue_id forks from the checkout's own branch"
  exit 0
fi
git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || {
  echo "FORK-KEY: none — WARN: the fleet marker names integration branch '$branch' for epic $epic_id but no such local branch exists; $issue_id forks from the checkout's own branch (dropped on purpose → strip branch/base from tmp/fleet-deadline.json; by accident → git branch $branch <base> restores it for later picks)"
  exit 0
}
cur=$(git -C "$main_checkout" config --get "$key" 2>/dev/null || true)
if [ -n "$cur" ] && [ "$cur" != "$branch" ]; then
  echo "ERROR: $key is already '$cur' (a /fleet-sequence runner's?) — refusing to repoint it at '$branch'" >&2
  exit 1
fi
git -C "$main_checkout" config "$key" "$branch"
echo "FORK-KEY: $key=$branch (epic $epic_id — $issue_id forks from and merges into it by ref; the main checkout is not moved)"
