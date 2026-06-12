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
# Maps each kind to its linear-cli invocation:
#   comment      → linear-cli issues comment <id> --body -      (body via stdin)
#   description  → linear-cli issues update  <id> --data  -      (JSON via stdin)
#
# linear-cli's `--description` flag takes no stdin, so the description path wraps the
# file as a `{description: ...}` JSON object and feeds it to `--data -`. This keeps
# arbitrarily large descriptions off the command line (no ARG_MAX risk) and preserves
# newlines/quotes. The comment path uses `--body -`, which reads stdin natively.
#
# Centralizes the boilerplate that previously appeared in /start (plan post,
# progress checkpoints, description checkoff) and /finish (completion
# comment, description checkoff). Errors to stderr; non-zero exit on failure.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

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
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 1; }
    # Wrap the file content as {description: <body>} and feed it to --data - (stdin).
    jq -Rs '{description: .}' "$body_file" | linear-cli issues update "$issue_id" --data -
    ;;
  *)
    echo "ERROR: unknown kind '$kind'; expected 'comment' or 'description'" >&2
    exit 1
    ;;
esac
