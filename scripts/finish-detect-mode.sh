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
#
# Exit codes:
#   0 success
#   1 incompatible argument combination
#   2 merge/pr requested outside a /start wt worktree

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

if [ -z "$source_branch" ] && [ -n "$action" ]; then
  echo "ERROR: '$action' is only valid inside a /start wt worktree." >&2
  echo "Current branch is '$worktree_branch' but no start.source-branch is recorded." >&2
  echo "For the standard push-to-current flow, run /finish without 'merge'/'pr'." >&2
  exit 2
fi

printf 'ACTION=%s\n' "$action"
printf 'SOURCE_BRANCH=%s\n' "$source_branch"
printf 'WORKTREE_BRANCH=%s\n' "$worktree_branch"
printf 'WT_DIR=%s\n' "$wt_dir"
printf 'REPO_ROOT=%s\n' "$repo_root"
printf 'NO_PUSH=%s\n' "$no_push"
