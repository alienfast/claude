#!/bin/bash
# quality-review-write-verdict.sh — Persist the /quality-review verdict block
# so /finish (and /start Step 10) can find it across worktrees and sessions.
#
# Usage: quality-review-write-verdict.sh <ISSUE-ID> [<VERDICT-BODY-FILE>|-]
#
#   -           read the body from stdin (heredoc) — ONE call, no staging file
#   omitted     default to <worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   <file>      read the body from that path
#
# PREFER STDIN. A staged file that is never published is invisible: it lives in
# the worktree, and /finish merge deletes the worktree with it. Measured on the
# 2026-08-03 fleet, 4 of 12 shipped issues lost their verdict exactly that way —
# every one had staged the file correctly and simply never made the second call.
# Stdin removes the intermediate state that failure needs.
#
# In a /start wt worktree the harness BLOCKS a direct write to the main
# checkout's tmp/ ("this session is now isolated in <worktree>"). This script is
# the sanctioned way across that boundary — it is not subject to the guard.
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
#   2 = missing or unreadable inputs, or an empty body

set -eo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "ERROR: usage: $(basename "$0") <ISSUE-ID> [<VERDICT-BODY-FILE>|-]" >&2
  exit 2
fi

issue_id="$1"
body_file="${2-}"

issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$worktree_root" ]; then
  echo "ERROR: not in a git repository" >&2
  exit 1
fi

# Body resolution happens here, not at argument parsing, because the default
# path is relative to the worktree root discovered above.
stdin_tmp=""
# The `return 0` is load-bearing: an EXIT trap's final status becomes the script's
# exit status, so without it every non-stdin run ends on the failed [ -n "" ] test
# and reports 1 — turning a successful publish, and a deliberate exit 2, into 1.
cleanup() { [ -n "$stdin_tmp" ] && rm -f "$stdin_tmp"; return 0; }
trap cleanup EXIT

if [ -z "$body_file" ]; then
  body_file="$worktree_root/tmp/quality-review-verdict-${issue_lower}.md"
elif [ "$body_file" = "-" ]; then
  stdin_tmp=$(mktemp "${TMPDIR:-/tmp}/qr-verdict-stdin-XXXXXX")
  cat > "$stdin_tmp"
  body_file="$stdin_tmp"
fi

if [ ! -r "$body_file" ]; then
  echo "ERROR: verdict body file not readable: $body_file" >&2
  exit 2
fi

# An empty body is always a caller bug — an unquoted heredoc that expanded to
# nothing, or a staging file that was never written. Publishing it would satisfy
# /finish Step 1.5's existence check with a file carrying no Verdict: line,
# which finish-read-verdict.sh reports as none-found anyway. Fail loudly instead.
if [ ! -s "$body_file" ]; then
  echo "ERROR: verdict body is empty: $body_file" >&2
  exit 2
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
  # mktemp creates 0600; without this, the atomic mv preserves 0600 on the
  # final artifact, which surprises any other user/process expecting the
  # umask default. Force 0644 so the file is readable to group/other (verdict
  # files are review findings, not secrets, and other processes/users on a
  # shared machine may want to inspect them).
  chmod 644 "$tmp"
  mv "$tmp" "$dest_file"
  printf 'wrote %s\n' "$dest_file"
}

write_atomic "$worktree_root/tmp"

if [ -n "$main_checkout" ] && [ "$main_checkout" != "$worktree_root" ]; then
  write_atomic "$main_checkout/tmp"
fi
