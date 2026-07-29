#!/bin/bash
# mark-ready-for-release.sh — transition a Linear issue to "Ready For Release"
# and unassign it.
#
# Usage: mark-ready-for-release.sh <ISSUE-ID>
#
# The single source of truth for the Ready-For-Release transition, shared by
# /finish Step 9 (after a merge lands synchronously) and merge-queue.sh's drainer
# (after it lands a deferred merge). Centralizing it guarantees both paths apply
# the same team-state resolution AND the same unassign, so a deferred merge reaches
# the same terminal state as an immediate one.
#
# It resolves the EXACT state name from the team's workflow states (never trusting
# `--state` to fuzzy-match), matching the same rule /finish Step 8 documents:
# exact "ready for <release|deploy|ship>" with flexible separators, never a bare
# "Ready" (too ambiguous) and never "Ready For Review". This avoids latching onto
# the wrong state on a team that has "Ready For Review" but not "...Release".
#
# After the transition it unassigns the issue (`issues assign` with no user):
# once work is done and queued for release the assignee no longer owns it, and a
# cleared assignee keeps "my issues" views focused on active work. Unassign is
# best-effort — its failure does NOT fail the script, because the merge has already
# landed and the state transition is the load-bearing outcome.
#
# Exit codes:
#   0 — issue VERIFIED in the resolved Ready-For-Release state by read-back (unassign best-effort).
#   1 — usage / no matching state / the state update failed or did not verify (read-back
#       mismatch and the raw-mutation fallback also missed). The caller
#       surfaces/notifies; the merge itself has already landed regardless.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

issue="${1:-}"
if [ -z "$issue" ]; then
  echo "usage: mark-ready-for-release.sh <ISSUE-ID>" >&2
  exit 1
fi

# Resolve the exact release-state name from the team's workflow states.
team="${issue%%-*}"
matched=$(linear-cli statuses list -t "$team" -o json 2>/dev/null \
  | jq -r '.statuses[]?.name // empty' 2>/dev/null \
  | grep -iE '^ready[ _-]?for[ _-]?(release|deploy|ship)$' \
  | head -1 || true)

if [ -z "$matched" ]; then
  echo "ERROR: no Ready-For-Release state found for team '$team' (issue $issue). Set it manually." >&2
  exit 1
fi

if ! linear-cli issues update "$issue" --state "$matched" >/dev/null 2>&1; then
  echo "ERROR: failed to move $issue to '$matched'. Set it manually." >&2
  exit 1
fi

# `issues update` can report success (exit 0, "+ Updated issue") while the state stays unchanged —
# skills/linear/SKILL.md gotcha #8, observed live during BF-492's /finish. This script is what /finish
# and the merge-queue drainer trust for the release transition, so success is declared only on a
# read-back, with the gotcha's raw-mutation fallback (whose response carries the resulting state) tried
# once before failing.
actual=$(linear-cli issues get "$issue" --no-cache -o json 2>/dev/null | jq -r '.state.name // empty' 2>/dev/null || true)
if [ "$actual" != "$matched" ]; then
  echo "WARN: issues update reported success but $issue reads '${actual:-unreadable}' (expected '$matched'); retrying via raw mutation..." >&2
  issue_uuid=$(linear-cli issues get "$issue" --no-cache -o json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
  state_uuid=$(linear-cli statuses list -t "$team" -o json 2>/dev/null \
    | jq -r --arg n "$matched" '.statuses[]? | select(.name == $n) | .id // empty' 2>/dev/null | head -1 || true)
  result=""
  if [ -n "$issue_uuid" ] && [ -n "$state_uuid" ]; then
    # api responses are data-wrapped ({"data":{"issueUpdate":...}}); the unwrapped path is kept as a
    # fallback so a linear-cli that starts unwrapping doesn't silently fail the verification.
    result=$(linear-cli api mutate 'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { state { name } } } }' \
      --variable id="$issue_uuid" --variable stateId="$state_uuid" 2>/dev/null \
      | jq -r '.data.issueUpdate.issue.state.name // .issueUpdate.issue.state.name // empty' 2>/dev/null || true)
  fi
  if [ "$result" != "$matched" ]; then
    echo "ERROR: $issue still not in '$matched' after the raw-mutation fallback. Set it manually." >&2
    exit 1
  fi
fi

# Unassign — best-effort. `issues assign <id>` with no user clears the assignee.
if ! linear-cli issues assign "$issue" >/dev/null 2>&1; then
  echo "WARN: $issue moved to '$matched' but unassign failed. Clear the assignee manually if needed." >&2
fi

# Drop a leftover `stalled` flag (/auto's abandoned-issue marker) — a shipped issue is no
# longer stalled, and the resume path (/start Step 3) isn't guaranteed to have run (e.g. a
# human re-ran /quality-review in the preserved worktree and finished directly). Best-effort.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! "$script_dir/linear-remove-label.sh" "$issue" stalled >/dev/null 2>&1; then
  echo "WARN: $issue moved to '$matched' but the stalled-label check/removal failed. Remove the label manually if present." >&2
fi

exit 0
