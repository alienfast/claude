#!/bin/bash
# quality-review-write-verdict.sh — Persist the /quality-review verdict block
# so /finish (and /start Step 10) can find it across worktrees and sessions.
#
# Usage: quality-review-write-verdict.sh <ISSUE-ID> <VERDICT-BODY-FILE>
#
# Writes the verdict body atomically (mktemp + mv) to:
#   1. <current-worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   2. <main-checkout>/tmp/quality-review-verdict-<issue-lower>.md
#      (only if different from #1 — happens when invoked from a /start wt
#      worktree, so /finish run from the main checkout can still find it)
#
# Idempotent: re-running with the same inputs overwrites both files atomically.
#
# Exit codes:
#   0 = both writes succeeded (or only #1 if main checkout == current worktree)
#   1 = not in a git repo
#   2 = missing or unreadable inputs

set -eo pipefail

if [ $# -ne 2 ]; then
  echo "ERROR: usage: $(basename "$0") <ISSUE-ID> <VERDICT-BODY-FILE>" >&2
  exit 2
fi

issue_id="$1"
body_file="$2"

if [ ! -r "$body_file" ]; then
  echo "ERROR: verdict body file not readable: $body_file" >&2
  exit 2
fi

issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$worktree_root" ]; then
  echo "ERROR: not in a git repository" >&2
  exit 1
fi

# git-common-dir's parent is the main checkout's working tree (for a regular
# clone, it's the same as worktree_root; for a linked worktree, it differs).
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
main_checkout=""
if [ -n "$common_dir" ]; then
  # common_dir is .../<main>/.git ; its parent is the main working tree.
  main_checkout=$(dirname "$common_dir")
fi

write_atomic() {
  local dest_dir="$1"
  local dest_file="$dest_dir/quality-review-verdict-${issue_lower}.md"
  mkdir -p "$dest_dir"
  local tmp
  tmp=$(mktemp "${dest_dir}/.qr-verdict-XXXXXX")
  cp "$body_file" "$tmp"
  mv "$tmp" "$dest_file"
  printf 'wrote %s\n' "$dest_file"
}

write_atomic "$worktree_root/tmp"

if [ -n "$main_checkout" ] && [ "$main_checkout" != "$worktree_root" ]; then
  write_atomic "$main_checkout/tmp"
fi
