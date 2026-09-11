#!/bin/bash
# mark-ready-for-release.sh — transition a Linear issue to "Ready For Release"
# and unassign it, then close any epic the release completes.
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
# Epic auto-close (keeper decision 2026-09-11): after the transition, walk UP the parent
# chain. A parent that carries the `epic` label and whose every child is terminal — Done,
# Canceled, Duplicate, or Ready for Release, by state type or name; In Review is NOT terminal
# here, a child awaiting human review keeps its epic open — is moved to Ready for Release
# through this same verified path and unassigned, and the walk repeats from it. Keyed on
# CHILDREN, never on blockers: an epic is a delegated container whose children carry the
# work, so the last child's release is the epic's release. A parent without the label is
# never touched, and a parent already terminal stops the walk. Best-effort like the unassign:
# a failure up the chain warns and never changes this issue's exit code. This is the ONE
# transition point /finish and the drainer share, which is why the walk lives here and not
# in either caller; /auto-prep's CLOSE-SET sweep (fleet-blockers.sh) catches epics that were
# already complete before this walk existed.
#
# Exit codes:
#   0 — issue VERIFIED in the resolved Ready-For-Release state by read-back (unassign and the
#       epic walk best-effort).
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# resolve_release_state <team> — prints the team's exact Ready-For-Release state name, or nothing.
resolve_release_state() {
  linear-cli statuses list -t "$1" --no-cache -o json 2>/dev/null \
    | jq -r '.statuses[]?.name // empty' 2>/dev/null \
    | grep -iE '^ready[ _-]?for[ _-]?(release|deploy|ship)$' \
    | head -1 || true
}

# transition <ISSUE-ID> <state-name> — the verified transition: wrapped update, --no-cache
# read-back, raw-mutation fallback. Returns 0 only when the read-back (or the fallback's own
# response) shows the state. Diagnostics name the issue so the epic walk's lines are legible.
transition() {
  local id="$1" target="$2" team="${1%%-*}" actual issue_uuid state_uuid result
  if ! linear-cli issues update "$id" --state "$target" >/dev/null 2>&1; then
    echo "ERROR: failed to move $id to '$target'. Set it manually." >&2
    return 1
  fi
  # `issues update` can report success (exit 0, "+ Updated issue") while the state stays unchanged —
  # skills/linear/SKILL.md gotcha #8, observed live during BF-492's /finish. This script is what /finish
  # and the merge-queue drainer trust for the release transition, so success is declared only on a
  # read-back, with the gotcha's raw-mutation fallback (whose response carries the resulting state) tried
  # once before failing.
  actual=$(linear-cli issues get "$id" --no-cache -o json 2>/dev/null | jq -r '.state.name // empty' 2>/dev/null || true)
  if [ "$actual" != "$target" ]; then
    echo "WARN: issues update reported success but $id reads '${actual:-unreadable}' (expected '$target'); retrying via raw mutation..." >&2
    issue_uuid=$(linear-cli issues get "$id" --no-cache -o json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
    state_uuid=$(linear-cli statuses list -t "$team" --no-cache -o json 2>/dev/null \
      | jq -r --arg n "$target" '.statuses[]? | select(.name == $n) | .id // empty' 2>/dev/null | head -1 || true)
    result=""
    if [ -n "$issue_uuid" ] && [ -n "$state_uuid" ]; then
      # api responses are data-wrapped ({"data":{"issueUpdate":...}}); the unwrapped path is kept as a
      # fallback so a linear-cli that starts unwrapping doesn't silently fail the verification.
      result=$(linear-cli api mutate 'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { state { name } } } }' \
        --variable id="$issue_uuid" --variable stateId="$state_uuid" 2>/dev/null \
        | jq -r '.data.issueUpdate.issue.state.name // .issueUpdate.issue.state.name // empty' 2>/dev/null || true)
    fi
    if [ "$result" != "$target" ]; then
      echo "ERROR: $id still not in '$target' after the raw-mutation fallback. Set it manually." >&2
      return 1
    fi
  fi
  return 0
}

# Resolve the exact release-state name from the team's workflow states.
team="${issue%%-*}"
matched=$(resolve_release_state "$team")
if [ -z "$matched" ]; then
  echo "ERROR: no Ready-For-Release state found for team '$team' (issue $issue). Set it manually." >&2
  exit 1
fi

transition "$issue" "$matched" || exit 1

# Unassign — best-effort. `issues assign <id>` with no user clears the assignee.
if ! linear-cli issues assign "$issue" >/dev/null 2>&1; then
  echo "WARN: $issue moved to '$matched' but unassign failed. Clear the assignee manually if needed." >&2
fi

# Drop a leftover `stalled` flag (/auto's abandoned-issue marker) — a shipped issue is no
# longer stalled, and the resume path (/start Step 3) isn't guaranteed to have run (e.g. a
# human re-ran /quality-review in the preserved worktree and finished directly). Best-effort.
if ! "$script_dir/linear-remove-label.sh" "$issue" stalled >/dev/null 2>&1; then
  echo "WARN: $issue moved to '$matched' but the stalled-label check/removal failed. Remove the label manually if present." >&2
fi

# ---------- epic auto-close: walk up the parent chain ----------

# One query per hop: the parent, its label set, and every child's state. `children(first:250)`
# because the connection defaults to 50 and a silently truncated child list would read an open
# child as absent — closing an epic with live work in it.
PARENT_Q='query($id:String!){issue(id:$id){parent{identifier state{name type} labels{nodes{name}} children(first:250){nodes{identifier state{name type}}}}}}'
# The four terminal states the ruling names, matched by type and by name (BF registers
# "Ready for Release" as type completed and "Duplicate" as type duplicate; a team may name
# them differently). "In Review" is deliberately absent — see the header.
CLOSE_TERMINAL='def closed: ((.type // "") | IN("completed","canceled","duplicate")) or ((.name // "") | ascii_downcase | IN("done","canceled","cancelled","duplicate","ready for release"));'

child="$issue"
hops=0
while [ "$hops" -lt 10 ]; do
  hops=$((hops + 1))
  pj=$(linear-cli api query -q -o json -v id="$child" "$PARENT_Q" 2>/dev/null) || pj=""
  parent=$(printf '%s' "$pj" | jq -r '.data.issue.parent.identifier // empty' 2>/dev/null || true)
  [ -n "$parent" ] || break
  verdict=$(printf '%s' "$pj" | jq -r "$CLOSE_TERMINAL"'
    .data.issue.parent
    | if (any((.labels.nodes // [])[]; (.name | ascii_downcase) == "epic") | not) then "not-epic"
      elif (.state | closed) then "parent-terminal"
      elif ((.children.nodes // []) | length) == 0 then "no-children"
      elif (all((.children.nodes // [])[]; .state | closed) | not)
        then "open: " + ([ (.children.nodes // [])[] | select(.state | closed | not) | "\(.identifier) [\(.state.name)]" ] | join(", "))
      else "close" end' 2>/dev/null || echo "unreadable")
  case "$verdict" in
    close) ;;
    open:*) echo "NOTE: epic $parent stays open — ${verdict#open: } still open" >&2; break ;;
    *) break ;;
  esac
  parent_team="${parent%%-*}"
  parent_state="$matched"
  [ "$parent_team" = "$team" ] || parent_state=$(resolve_release_state "$parent_team")
  if [ -z "$parent_state" ]; then
    echo "WARN: epic $parent is complete (every child terminal) but team '$parent_team' has no Ready-For-Release state — close it manually." >&2
    break
  fi
  if ! transition "$parent" "$parent_state"; then
    echo "WARN: epic $parent is complete (every child terminal) but could not be moved to '$parent_state' — close it manually." >&2
    break
  fi
  linear-cli issues assign "$parent" >/dev/null 2>&1 || true
  echo "NOTE: epic $parent moved to '$parent_state' — its last child ($child) released"
  child="$parent"
done

exit 0
