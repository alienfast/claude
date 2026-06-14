#!/bin/bash
# finish-detect-mode.sh — Detect /finish worktree mode and emit context vars.
#
# Usage: finish-detect-mode.sh [merge|pr] [--no-push]
#
# Probes git for /start wt worktree state, validates incompatible argument
# combinations, and emits KEY=value lines on stdout for the /finish skill to
# read. Both args optional; order doesn't matter.
#
# Output (stdout):
#   ACTION=<merge|pr|"">
#   SOURCE_BRANCH=<branch | "">
#   WORKTREE_BRANCH=<current branch>
#   WT_DIR=<git toplevel>
#   REPO_ROOT=<parent of .git common dir>
#   NO_PUSH=<0|1>
#   CORRUPTION=<0|1>                  (1 only on exit 4)
#   IDENTITY_SOURCE=<job-dir|repo-fallback|git-config|none>
#   On exit 4 also: CORRUPTION_REASON, EXPECTED_BRANCH, EXPECTED_BASELINE, EXPECTED_SOURCE_BRANCH
#
# Exit codes:
#   0 success
#   1 incompatible argument combination
#   2 merge requested outside a /start wt worktree
#   4 corruption: the worktree no longer matches the identity /start stamped
#     (branch swapped, HEAD reset off the baseline, or source-branch config wiped
#     while an immune sidecar still proves this is a /start wt worktree). The
#     /finish skill routes this to finish-recover.sh. Detected only when a
#     VERIFIABLE identity exists; legacy/pre-stamp worktrees fall through to 0/2.

set -eo pipefail

action=""
no_push=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --no-push) no_push=1; shift ;;
    *)
      lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      case "$lower" in
        merge|pr)
          if [ -n "$action" ] && [ "$action" != "$lower" ]; then
            echo "ERROR: 'merge' and 'pr' are mutually exclusive" >&2
            exit 1
          fi
          if [ "$action" = "$lower" ]; then
            echo "ERROR: duplicate action token '$lower'" >&2
            exit 1
          fi
          action="$lower"
          shift
          ;;
        *)
          echo "ERROR: unknown arg '$1' (expected: merge | pr | --no-push)" >&2
          exit 1
          ;;
      esac
      ;;
  esac
done

if [ "$action" = "pr" ] && [ "$no_push" -eq 1 ]; then
  echo "ERROR: \`/finish pr\` requires pushing the branch. Remove 'no push' or use '/finish merge'." >&2
  exit 1
fi

source_branch=$(git config --worktree --get start.source-branch 2>/dev/null || true)
worktree_branch=$(git branch --show-current 2>/dev/null || true)
wt_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$common_dir" ]; then
  repo_root=$(cd "$common_dir/.." && pwd)
else
  repo_root=""
fi

# --- Worktree-identity check: detect a worktree hijacked by a parallel session. ---
# Load the immune identity stamped at /start (sidecar → git config) and compare it
# to the worktree's CURRENT state. A mismatch means another session reset this
# worktree's branch/HEAD or wiped its config; we surface that as exit 4 (routed to
# finish-recover.sh) instead of the opaque exit-2 "not a worktree" below. Detection
# is gated on a VERIFIABLE identity, so legacy/pre-stamp worktrees and non-worktrees
# fall through to the unchanged logic.
# shellcheck source=/dev/null
. "$(dirname "$0")/wt-identity.sh"
corruption=0
corruption_reason=""
identity_source="none"
expected_branch=""
expected_baseline=""
expected_source_branch=""
if [ -n "$wt_dir" ] && wt_identity_load "$wt_dir"; then
  identity_source="$WTID_SOURCE"
  expected_branch="$WTID_BRANCH"
  expected_baseline="$WTID_BASELINE"
  expected_source_branch="$WTID_SOURCE_BRANCH"
  wt_identity_verify "$wt_dir"
  corruption="$WTID_CORRUPTION"
  corruption_reason="$WTID_CORRUPTION_REASON"
  # If the live config source-branch was wiped but the sidecar still carries it,
  # prefer the sidecar value so the recovery context still names the real source.
  if [ -z "$source_branch" ] && [ -n "$expected_source_branch" ]; then
    source_branch="$expected_source_branch"
  fi
fi

if [ "$corruption" = "1" ]; then
  echo "CORRUPTION: worktree '$wt_dir' no longer matches the identity /start stamped." >&2
  echo "  reason: $corruption_reason (identity from: $identity_source)" >&2
  echo "  expected branch:   $expected_branch" >&2
  echo "  current  branch:   $worktree_branch" >&2
  echo "  expected baseline: $expected_baseline" >&2
  echo "  A parallel session likely reset this worktree. /finish routes this to recovery (finish-recover.sh)." >&2
  action_out="$action"; [ -z "$action_out" ] && action_out="merge"
  printf 'ACTION=%s\n' "$action_out"
  printf 'SOURCE_BRANCH=%s\n' "$source_branch"
  printf 'WORKTREE_BRANCH=%s\n' "$worktree_branch"
  printf 'WT_DIR=%s\n' "$wt_dir"
  printf 'REPO_ROOT=%s\n' "$repo_root"
  printf 'NO_PUSH=%s\n' "$no_push"
  printf 'CORRUPTION=1\n'
  printf 'CORRUPTION_REASON=%s\n' "$corruption_reason"
  printf 'IDENTITY_SOURCE=%s\n' "$identity_source"
  printf 'EXPECTED_BRANCH=%s\n' "$expected_branch"
  printf 'EXPECTED_BASELINE=%s\n' "$expected_baseline"
  printf 'EXPECTED_SOURCE_BRANCH=%s\n' "$expected_source_branch"
  exit 4
fi

if [ -z "$source_branch" ] && [ "$action" = "merge" ]; then
  echo "ERROR: 'merge' is only valid inside a /start wt worktree." >&2
  echo "Current branch is '$worktree_branch' but no start.source-branch is recorded." >&2
  echo "For the standard flow run /finish with no action token; to open a PR run /finish pr." >&2
  exit 2
fi

# Default to merge when in a worktree and no explicit action was requested.
# PR mode requires explicit `/finish pr`.
if [ -z "$action" ] && [ -n "$source_branch" ]; then
  action="merge"
fi

printf 'ACTION=%s\n' "$action"
printf 'SOURCE_BRANCH=%s\n' "$source_branch"
printf 'WORKTREE_BRANCH=%s\n' "$worktree_branch"
printf 'WT_DIR=%s\n' "$wt_dir"
printf 'REPO_ROOT=%s\n' "$repo_root"
printf 'NO_PUSH=%s\n' "$no_push"
printf 'CORRUPTION=0\n'
printf 'IDENTITY_SOURCE=%s\n' "$identity_source"
