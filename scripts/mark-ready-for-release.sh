#!/bin/bash
# mark-ready-for-release.sh — transition a Linear issue to "Ready For Release".
#
# Usage: mark-ready-for-release.sh <ISSUE-ID>
#
# The single source of truth for the Ready-For-Release transition, shared by
# /finish Step 9 (after a merge lands synchronously) and merge-queue.sh's drainer
# (after it lands a deferred merge). Centralizing it guarantees both paths apply
# the same team-state resolution, so a deferred merge reaches the same terminal
# state as an immediate one.
#
# It resolves the EXACT state name from the team's workflow states (never trusting
# `--state` to fuzzy-match), matching the same rule /finish Step 8 documents:
# exact "ready for <release|deploy|ship>" with flexible separators, never a bare
# "Ready" (too ambiguous) and never "Ready For Review". This avoids latching onto
# the wrong state on a team that has "Ready For Review" but not "...Release".
#
# Exit codes:
#   0 — issue is now in the resolved Ready-For-Release state.
#   1 — usage / no matching state / the CLI failed. The caller surfaces/notifies;
#       the merge itself has already landed regardless.

set -eo pipefail

issue="${1:-}"
if [ -z "$issue" ]; then
  echo "usage: mark-ready-for-release.sh <ISSUE-ID>" >&2
  exit 1
fi

# Resolve the exact release-state name from the team's workflow states.
team="${issue%%-*}"
matched=""
while IFS= read -r line; do
  # Lines look like:  "  Ready For Release [started] - <uuid>" — take the name
  # (strip leading space, then everything from " [" onward). Header/rule lines
  # ("WORKFLOW STATES (9)", "────") simply fail the regex below.
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  name="${line%% \[*}"
  [ -n "$name" ] || continue
  if printf '%s' "$name" | grep -qiE '^ready[ _-]?for[ _-]?(release|deploy|ship)$'; then
    matched="$name"
    break
  fi
done < <(linear teams states "$team" 2>/dev/null || true)

if [ -z "$matched" ]; then
  echo "ERROR: no Ready-For-Release state found for team '$team' (issue $issue). Set it manually." >&2
  exit 1
fi

if linear issues update "$issue" --state "$matched" >/dev/null 2>&1; then
  exit 0
fi

echo "ERROR: failed to move $issue to '$matched'. Set it manually." >&2
exit 1
