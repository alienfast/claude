#!/bin/bash
# detect-issue-id.sh — Resolve a Linear-style issue identifier (e.g., PL-13).
#
# Usage: detect-issue-id.sh [--input <ID>] [--validate-only]
#
# Default (extract) mode: try --input → current git branch → latest commit
# subject. Used by /finish and /checkpoint.
#
# --validate-only: requires --input; just normalizes to uppercase and validates
# the ^[A-Z]+-[0-9]+$ shape. Used by /start (no branch/commit fallback because
# /start creates the branch).
#
# stdout (success): the normalized identifier, single line (e.g., PL-13).
# stderr (failure): one-line diagnostic.
#
# Branch sources skipped: main, master, develop.
#
# Exit codes:
#   0 = found and printed to stdout
#   1 = not found / invalid format / refused

set -eo pipefail

input=""
validate_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    --validate-only) validate_only=1; shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

normalize() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

is_valid() {
  [[ "$1" =~ ^[A-Z]+-[0-9]+$ ]]
}

# 1. user input
if [ -n "$input" ]; then
  norm=$(normalize "$input")
  if is_valid "$norm"; then
    printf '%s\n' "$norm"
    exit 0
  fi
  echo "ERROR: --input '$input' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi

if [ "$validate_only" -eq 1 ]; then
  echo "ERROR: --validate-only requires --input" >&2
  exit 1
fi

# 2. branch name
branch=$(git branch --show-current 2>/dev/null || true)
case "$branch" in
  main|master|develop|"")
    ;;
  *)
    if [[ "$branch" =~ (^|/)([A-Za-z]+-[0-9]+)(-|$) ]]; then
      norm=$(normalize "${BASH_REMATCH[2]}")
      if is_valid "$norm"; then
        printf '%s\n' "$norm"
        exit 0
      fi
    fi
    ;;
esac

# 3. latest commit subject
subject=$(git log -1 --format=%s 2>/dev/null || true)
if [ -n "$subject" ]; then
  if [[ "$subject" =~ ([A-Za-z]+-[0-9]+) ]]; then
    norm=$(normalize "${BASH_REMATCH[1]}")
    if is_valid "$norm"; then
      printf '%s\n' "$norm"
      exit 0
    fi
  fi
fi

# 4. fail
if [ -n "$branch" ]; then
  echo "ERROR: no issue ID found (branch='$branch', commit subject='$subject')" >&2
else
  echo "ERROR: no issue ID found (not in a git repo or no current branch)" >&2
fi
exit 1
