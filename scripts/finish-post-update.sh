#!/bin/bash
# finish-post-update.sh — Post the updated description and completion comment
# to a Linear issue in one call.
#
# Usage: finish-post-update.sh <issue-id> <description-file> <comment-file>
#
# Convenience wrapper that calls linear-post.sh twice (description, then
# comment). Used by /finish to collapse Steps 3 + 5.
#
# Caller is responsible for:
#   - Writing the full updated description (with checkboxes already toggled)
#     to <description-file>.
#   - Writing the completion-comment body to <comment-file>.
#
# Exit codes:
#   0 success
#   1 validation error (bad ID, missing/empty files)
#   2 underlying linear-post.sh failure

set -eo pipefail

if [ "$#" -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ $# -ne 3 ]; then
  echo "Usage: $0 <issue-id> <description-file> <comment-file>" >&2
  exit 1
fi

issue_id="$1"
description_file="$2"
comment_file="$3"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if ! [[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue-id '$issue_id' must match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi

for f in "$description_file" "$comment_file"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: file '$f' does not exist" >&2
    exit 1
  fi
  if [ ! -s "$f" ]; then
    echo "ERROR: file '$f' is empty" >&2
    exit 1
  fi
done

if ! "$SCRIPT_DIR/linear-post.sh" description "$issue_id" "$description_file"; then
  echo "ERROR: failed to update description for $issue_id" >&2
  exit 2
fi

if ! "$SCRIPT_DIR/linear-post.sh" comment "$issue_id" "$comment_file"; then
  echo "ERROR: failed to post comment for $issue_id" >&2
  exit 2
fi
