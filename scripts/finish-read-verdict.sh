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
#   VERDICT_FILE=<absolute path, or empty if file absent>
#   VERDICT=passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect|malformed|none-found
#     - none-found  → no verdict file located at either probe path (file absent)
#     - malformed   → file exists but lacks a parseable `Verdict:` line, or the
#                     line contains the pipe-separated schema example, or the
#                     value is not one of the four recognized enums. /finish
#                     Step 8 must NOT proceed on this value — the user clearly
#                     ran /quality-review but something went wrong with the
#                     handoff; gate-bypass would defeat the safety check.
#   CYCLES=<integer, or empty if VERDICT in {none-found, malformed}>
#   SUB_ISSUES=<comma-separated PL-XX list of parent's current children, or empty>
#     (NOTE: these are all current children of the parent — not necessarily
#     filed by THIS /quality-review run. /finish must label accordingly.)
#   SUB_ISSUES_ERROR=<warning text if `linear i get` failed, else empty>
#
# Exit codes:
#   0 = success (even when VERDICT=none-found, VERDICT=malformed, or
#       SUB_ISSUES_ERROR is populated — these are non-fatal warnings)
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
  # Default: malformed unless we positively extract a single recognized enum.
  verdict="malformed"
  vline=$(grep -m1 -E '^Verdict:' "$verdict_file" || true)
  if [ -n "$vline" ]; then
    # Reject the schema-example shape ("Verdict: passed-clean | passed-after-fixes | ...")
    # — a literal `|` after the colon means the LLM wrote the schema verbatim
    # instead of substituting a resolved value. Treat as malformed so the gate
    # refuses, rather than silently taking the first token (passed-clean).
    if printf '%s' "$vline" | grep -q '|'; then
      verdict="malformed"
    else
      raw=$(printf '%s' "$vline" | awk -F'Verdict:' '{print $2}' | awk '{print $1}')
      case "$raw" in
        passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect)
          verdict="$raw"
          ;;
        *)
          verdict="malformed"
          ;;
      esac
    fi
  fi
  # Cycles line example: "Cycles: 3" or "Cycles: 3 (initial + 2 re-reviews)"
  cline=$(grep -m1 -E '^Cycles:' "$verdict_file" || true)
  if [ -n "$cline" ]; then
    cycles=$(printf '%s' "$cline" | awk -F'Cycles:' '{print $2}' | awk '{print $1}')
  fi
fi

# Query sub-issues via linear CLI. Use --format full --output json to get the
# children array. Tolerate the case where the issue doesn't exist, the CLI
# isn't authenticated, or the issue has no children — none of those should
# abort /finish (auth prompt fires in Step 2; missing-issue is surfaced
# elsewhere). Emit empty SUB_ISSUES and a warning instead.
sub_issues=""
sub_issues_error=""
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
  sub_issues_error="linear i get $issue_id failed (linear CLI installed? auth? missing issue?) — SUB_ISSUES unavailable"
  echo "WARN: $sub_issues_error" >&2
fi

printf 'VERDICT_FILE=%s\n' "$verdict_file"
printf 'VERDICT=%s\n' "$verdict"
printf 'CYCLES=%s\n' "$cycles"
printf 'SUB_ISSUES=%s\n' "$sub_issues"
printf 'SUB_ISSUES_ERROR=%s\n' "$sub_issues_error"
