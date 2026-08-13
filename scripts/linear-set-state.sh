#!/bin/bash
# linear-set-state.sh — batch state setter whose success is a VERIFIED transition, not a
# reported one: wrapped `issues update --state` → `--no-cache` read-back → raw-mutation
# fallback (skills/linear/SKILL.md gotcha #8), echoing the resulting state per issue.
# Generalizes mark-ready-for-release.sh's verified-transition pattern for the batch
# promotions /auto-prep makes (fleet-blockers.sh's PROMOTE-SET line is built to paste here).
#
# Usage: linear-set-state.sh <state-name> <ISSUE-ID> [<ISSUE-ID> ...]
#
# The state name must match one of the team's workflow states exactly (case-insensitive) —
# `--state` is never trusted to fuzzy-match. The team comes from each issue's key prefix, so
# a batch may span teams; a team whose states can't be resolved (or that lacks the state)
# aborts the run with exit 1 — issues already verified stand, and their lines say so.
#
# Output: one `<ID> -> <state>` line per issue; failures print `<ID> -> FAILED (...)`.
# Exit:   0 — every issue verified in the target state by read-back (or the fallback's own
#             response, which carries the resulting state).
#         1 — usage error, or a team's states could not be resolved / state name not found.
#         2 — at least one issue failed to verify; the per-issue lines say which.
set -uo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -lt 2 ]; then
  echo "usage: linear-set-state.sh <state-name> <ISSUE-ID> [<ISSUE-ID> ...]" >&2
  exit 1
fi
state_arg="$1"
shift

# One team's resolution cached at a time — batches are near-always single-team.
cached_team=""
state_name=""
state_uuid=""

resolve_state() { # $1 = team key; sets cached_team/state_name/state_uuid or returns 1
  local team="$1" json
  json=$(linear-cli statuses list -t "$team" -o json 2>/dev/null) || json=""
  if [ -z "$json" ]; then
    echo "ERROR: could not list workflow states for team '$team' (auth? team key?)" >&2
    return 1
  fi
  state_name=$(printf '%s' "$json" | jq -r --arg n "$state_arg" \
    '[.statuses[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].name // empty')
  state_uuid=$(printf '%s' "$json" | jq -r --arg n "$state_arg" \
    '[.statuses[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].id // empty')
  if [ -z "$state_name" ] || [ -z "$state_uuid" ]; then
    echo "ERROR: team '$team' has no state named '$state_arg'. Available: $(printf '%s' "$json" | jq -r '[.statuses[]?.name] | join(", ")')" >&2
    return 1
  fi
  cached_team="$team"
}

rc=0
for issue in "$@"; do
  team="${issue%%-*}"
  if [ "$team" = "$issue" ] || [ -z "$team" ]; then
    echo "$issue -> FAILED (not an issue key)"
    rc=2
    continue
  fi
  if [ "$team" != "$cached_team" ]; then
    resolve_state "$team" || exit 1
  fi

  linear-cli issues update "$issue" --state "$state_name" >/dev/null 2>&1
  read_json=$(linear-cli issues get "$issue" --no-cache -o json 2>/dev/null || true)
  got=$(printf '%s' "$read_json" | jq -r '.state.name // empty' 2>/dev/null || true)
  if [ "$got" != "$state_name" ]; then
    issue_uuid=$(printf '%s' "$read_json" | jq -r '.id // empty' 2>/dev/null || true)
    got=""
    if [ -n "$issue_uuid" ]; then
      # api responses are data-wrapped ({"data":{"issueUpdate":...}}); the unwrapped path is kept
      # as a fallback so a linear-cli that starts unwrapping doesn't silently fail verification.
      got=$(linear-cli api mutate 'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { state { name } } } }' \
        --variable id="$issue_uuid" --variable stateId="$state_uuid" 2>/dev/null \
        | jq -r '.data.issueUpdate.issue.state.name // .issueUpdate.issue.state.name // empty' 2>/dev/null || true)
    fi
    if [ "$got" != "$state_name" ]; then
      echo "$issue -> FAILED (reads '${got:-unreadable}', wanted '$state_name')"
      rc=2
      continue
    fi
  fi
  echo "$issue -> $got"
done

exit $rc
