#!/bin/bash
# finish-read-verdict.sh — Locate the most-recent /quality-review verdict
# artifact for an issue and report sub-issues filed under it.
#
# Usage: finish-read-verdict.sh <ISSUE-ID>
#
# Looks for the verdict file in this order (first hit wins):
#   1. <current-worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   2. <main-checkout>/tmp/quality-review-verdict-<issue-lower>.md
#      (the main checkout when the current cwd is a linked worktree)
#
# Emits KEY=value lines on stdout:
#   VERDICT_FILE=<absolute path, or empty if none found>
#   VERDICT=passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect|none-found
#   CYCLES=<integer, or empty if VERDICT=none-found>
#   SUB_ISSUES=<comma-separated PL-XX list of children, or empty>
#
# Exit codes:
#   0 = success (even when VERDICT=none-found)
#   1 = linear CLI failure when querying sub-issues
#   2 = missing ISSUE-ID argument or not in a git repo

set -eo pipefail

if [ $# -ne 1 ]; then
  echo "ERROR: usage: $(basename "$0") <ISSUE-ID>" >&2
  exit 2
fi

issue_id="$1"
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$worktree_root" ]; then
  echo "ERROR: not in a git repository" >&2
  exit 2
fi

common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
main_checkout=""
if [ -n "$common_dir" ]; then
  main_checkout=$(dirname "$common_dir")
fi

verdict_file=""
for candidate in \
  "$worktree_root/tmp/quality-review-verdict-${issue_lower}.md" \
  "${main_checkout:+$main_checkout/tmp/quality-review-verdict-${issue_lower}.md}"
do
  if [ -n "$candidate" ] && [ -r "$candidate" ]; then
    verdict_file="$candidate"
    break
  fi
done

verdict="none-found"
cycles=""
if [ -n "$verdict_file" ]; then
  # Verdict line example: "Verdict: passed-after-fixes"
  vline=$(grep -m1 -E '^Verdict:' "$verdict_file" || true)
  if [ -n "$vline" ]; then
    # Take the first whitespace-separated token after "Verdict:" — the enum is
    # a single dash-separated identifier; ignore any "| other | values" still
    # present in the block (those are part of the schema-example template).
    verdict=$(printf '%s' "$vline" | awk -F'Verdict:' '{print $2}' | awk '{print $1}')
  fi
  # Cycles line example: "Cycles: 3" or "Cycles: 3 (initial + 2 re-reviews)"
  cline=$(grep -m1 -E '^Cycles:' "$verdict_file" || true)
  if [ -n "$cline" ]; then
    cycles=$(printf '%s' "$cline" | awk -F'Cycles:' '{print $2}' | awk '{print $1}')
  fi
fi

# Query sub-issues via linear CLI. Use --format full --output json to get
# the children array. Tolerate the case where the issue doesn't exist or
# has no children.
sub_issues=""
if json=$(linear i get "$issue_id" --format full --output json 2>/dev/null); then
  sub_issues=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ch = d.get("children") or []
ids = [c.get("identifier") for c in ch if c.get("identifier")]
print(",".join(ids))
' 2>/dev/null || true)
else
  echo "ERROR: linear i get $issue_id failed" >&2
  exit 1
fi

printf 'VERDICT_FILE=%s\n' "$verdict_file"
printf 'VERDICT=%s\n' "$verdict"
printf 'CYCLES=%s\n' "$cycles"
printf 'SUB_ISSUES=%s\n' "$sub_issues"
