#!/bin/bash
# linear-post.sh — Post a comment or update a description on a Linear issue.
#
# Usage: linear-post.sh <kind> <issue-id> <body-file>
#   kind:      "comment" | "description"
#   issue-id:  e.g., PL-13
#   body-file: path to file containing the comment/description body.
#              Must be a real file; stdin (`-`) is NOT supported because the
#              underlying linear-stdin.sh uses `< "$file"` which treats `-`
#              as a literal filename.
#
# Wraps linear-stdin.sh with the correct subcommand and flag for each kind:
#   comment      → linear issues comment <id> --body -
#   description  → linear issues update  <id> --description -
#
# Centralizes the boilerplate that previously appeared in /start (plan post,
# progress checkpoints, description checkoff) and /finish (completion
# comment, description checkoff). Errors to stderr; non-zero exit on failure.

set -eo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <comment|description> <issue-id> <body-file>" >&2
  exit 1
fi

kind="$1"
issue_id="$2"
body_file="$3"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$body_file" != "-" ] && [ ! -f "$body_file" ]; then
  echo "ERROR: body file not found: $body_file" >&2
  exit 1
fi

case "$kind" in
  comment)
    exec "$SCRIPT_DIR/linear-stdin.sh" "$body_file" issues comment "$issue_id" --body -
    ;;
  description)
    exec "$SCRIPT_DIR/linear-stdin.sh" "$body_file" issues update "$issue_id" --description -
    ;;
  *)
    echo "ERROR: unknown kind '$kind'; expected 'comment' or 'description'" >&2
    exit 1
    ;;
esac
