#!/usr/bin/env bash
# auto-fork-key.sh — steer one issue's /start wt onto an epic fleet's integration branch without moving the checkout.
#
# Usage: auto-fork-key.sh set <ISSUE-ID> [<EPIC-ID>]
#        auto-fork-key.sh unset <ISSUE-ID>
#
# /auto runs `set` before every `/full auto wt <ISSUE-ID>` dispatch and `unset` once that dispatch's lifecycle tag is in.
# `set` reads the fleet markers lib/fleet-markers.sh describes — <main-checkout>/tmp/fleet-deadline-<slug>.json, one per
# fleet (written by fleet-launch.sh): with <EPIC-ID>, that epic's own marker; without one (a team-scoped or targeted run),
# every live epic marker, for the fleet whose `members` list the issue. When the marker records a `branch`, the per-issue
# key `start.<issue-lower>.wt-source-branch` is pointed at it — the same key /fleet-sequence's runner sets, which
# start-wt-setup.sh resolves ahead of the checkout's own branch, and start-wt-create.sh forks from the branch's REF. So
# the issue forks from and (finish-merge.sh, ref-only) merges into the integration branch while the main checkout stays
# on whatever branch its human is using, and an interactive `/start wt` still forks from the checkout's branch. The scan
# without an epic is what makes "first picker wins" safe across concurrent fleets (keeper decision 2026-10-28): a team
# session that claims an epic member before the epic's own fleet does still lands it on the epic's PR rather than
# splitting the epic's code across two branches. This replaced the detached-HEAD posture fleet-launch.sh imposed until
# 2026-09-23 (checkout detached at the branch plus a checkout-wide start.wt-source-branch), which took the main checkout
# away from its human for the fleet's duration and steered their own /start wt onto the epic branch too.
#
# Output: one FORK-KEY: line on stdout. Exit 0 when the key was set, cleared, or there was nothing to steer (no
# marker, no fleet listing the issue, no branch recorded — the issue then forks from the checkout's branch, the
# unscoped behaviour). A recorded branch that no longer exists locally is the same fallback with a WARN in the line,
# not an error: a fleet whose human dropped the branch mid-run must keep shipping onto the checkout's branch rather
# than stall every session on SKIPPED-BLOCKED (2026-09-23: the BF-1826 branch was deleted under five running
# sessions). Exit 1 on a usage error or a per-issue key already naming a DIFFERENT branch (a /fleet-sequence
# runner's — never overwritten).
set -uo pipefail

usage() { echo "Usage: $0 set <ISSUE-ID> [<EPIC-ID>] | unset <ISSUE-ID>" >&2; exit 1; }

norm_id() { # <token> → uppercase issue id, or exit 1
  local id
  id=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  [[ "$id" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { echo "ERROR: '$1' does not name an issue (e.g. BF-123)" >&2; exit 1; }
  printf '%s' "$id"
}

action="${1:-}"
case "$action" in
  set)   [ $# -eq 2 ] || [ $# -eq 3 ] || usage ;;
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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/../lib/fleet-markers.sh"

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

also_note=""
if [ $# -eq 3 ]; then
  epic_id=$(norm_id "$3") || exit 1
  marker=$(fleet_marker_path "$main_checkout" "$(fleet_slug "$epic_id")")
  if ! [ -s "$marker" ]; then
    echo "FORK-KEY: none — no fleet marker for epic $epic_id (tmp/$(basename "$marker")); $issue_id forks from the checkout's own branch"
    exit 0
  fi
  scope=$(jq -r '.scope // empty' "$marker" 2>/dev/null || true)
  if [ "$scope" != "$epic_id" ]; then
    echo "FORK-KEY: none — tmp/$(basename "$marker") is scoped to '${scope:-nothing}', not $epic_id; $issue_id forks from the checkout's own branch"
    exit 0
  fi
else
  # No epic named: the live epic fleet whose members list the issue. Two overlapping epics (a shared blocker) can both
  # list it; the first by slug steers and the line names the other, so the choice is visible rather than silent.
  marker=""; also=""
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    [ -n "$(jq -r '.scope // empty' "$mf" 2>/dev/null)" ] || continue
    jq -e --arg id "$issue_id" '(.members // []) | index($id) != null' "$mf" >/dev/null 2>&1 || continue
    if [ -z "$marker" ]; then marker="$mf"; else also="$also $(jq -r '.scope' "$mf")"; fi
  done < <(fleet_live_markers "$main_checkout")
  if [ -z "$marker" ]; then
    echo "FORK-KEY: none — no live epic fleet lists $issue_id as a member; it forks from the checkout's own branch"
    exit 0
  fi
  epic_id=$(jq -r '.scope' "$marker")
  [ -n "$also" ] && also_note="; also a member of$also — the first fleet by slug steers it"
fi
branch=$(jq -r '.branch // empty' "$marker" 2>/dev/null || true)
if [ -z "$branch" ]; then
  echo "FORK-KEY: none — epic $epic_id has no integration branch recorded (run /epic-prep $epic_id before launching); $issue_id forks from the checkout's own branch"
  exit 0
fi
git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || {
  echo "FORK-KEY: none — WARN: the fleet marker names integration branch '$branch' for epic $epic_id but no such local branch exists; $issue_id forks from the checkout's own branch (dropped on purpose → strip branch/base from tmp/$(basename "$marker"); by accident → git branch $branch <base> restores it for later picks)"
  exit 0
}
cur=$(git -C "$main_checkout" config --get "$key" 2>/dev/null || true)
if [ -n "$cur" ] && [ "$cur" != "$branch" ]; then
  echo "ERROR: $key is already '$cur' (a /fleet-sequence runner's?) — refusing to repoint it at '$branch'" >&2
  exit 1
fi
git -C "$main_checkout" config "$key" "$branch"
echo "FORK-KEY: $key=$branch (epic $epic_id — $issue_id forks from and merges into it by ref; the main checkout is not moved$also_note)"
