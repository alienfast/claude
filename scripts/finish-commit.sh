#!/bin/bash
# finish-commit.sh — Commit pre-staged changes with a Linear-linked message,
# then push.
#
# Usage: finish-commit.sh <issue-id> <message-file> [--no-push]
#
# Contract: caller has already staged the files to commit (via `git add
# <files>`). This script does NOT stage anything — that decision is the
# caller's. It commits whatever is currently staged.
#
# Path selection by git state:
#   - Staged changes exist → commit -F <message-file>, then push.
#   - Nothing staged but unstaged tracked changes exist → error (caller
#     forgot to stage).
#   - Already committed, ahead of upstream → push only.
#   - In sync with upstream → no-op.
#
# Validates that the message contains the issue ID (Linear auto-linking
# requires it). Push is gated by --no-push.
#
# Exit codes:
#   0 success
#   1 validation error (bad ID, missing message file, ID not in message)
#   2 git/push failure or unstaged-only state

set -eo pipefail

if [ "$#" -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <issue-id> <message-file> [--no-push]" >&2
  exit 1
fi

issue_id="$1"
message_file="$2"
shift 2

no_push=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) no_push=1; shift ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if ! [[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue-id '$issue_id' must match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi

if [ ! -f "$message_file" ]; then
  echo "ERROR: message file '$message_file' does not exist" >&2
  exit 1
fi
if [ ! -s "$message_file" ]; then
  echo "ERROR: message file '$message_file' is empty" >&2
  exit 1
fi

if ! grep -q -F "$issue_id" "$message_file"; then
  echo "ERROR: commit message must contain '$issue_id' for Linear auto-linking." >&2
  echo "       Message file: $message_file" >&2
  exit 1
fi

# Probe state.
has_staged=0
if ! git diff --cached --quiet; then has_staged=1; fi

has_unstaged=0
if ! git diff --quiet; then has_unstaged=1; fi

ahead=0
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
fi

do_push() {
  if [ "$no_push" -eq 1 ]; then
    echo "Skipping push as requested. Push manually when ready: \`git push\`"
    return 0
  fi
  if ! git push; then
    echo "ERROR: git push failed" >&2
    return 2
  fi
}

if [ "$has_staged" -eq 1 ]; then
  if ! git commit -F "$message_file"; then
    echo "ERROR: git commit failed" >&2
    exit 2
  fi
  if ! do_push; then exit 2; fi
  exit 0
fi

if [ "$has_unstaged" -eq 1 ]; then
  echo "ERROR: tracked changes exist but nothing is staged." >&2
  echo "       Stage relevant files first (\`git add <files>\`), then re-run." >&2
  exit 2
fi

if [ "$ahead" -gt 0 ]; then
  echo "Already committed; $ahead commit(s) ahead of upstream."
  if ! do_push; then exit 2; fi
  exit 0
fi

echo "Code is already on remote — nothing to do."
exit 0
