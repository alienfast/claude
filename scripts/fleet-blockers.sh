#!/bin/bash
# fleet-blockers.sh — audit whether an unattended fleet can drain the certified pool's blocker
# chains. Lists every `blocks` edge whose blocked side is a fleet candidate (workable state +
# `specified`, not label-hidden) but whose blocker nothing the fleet can pick will ever ship:
# labeled `human` / `needs decision` / `solo` / `stalled`, sitting in Triage or Backlog stage
# (stage-first ranking strands a dependent behind the whole Planned stage), or uncertified (the
# fleet runs `/next specified`, so an unlabeled blocker never ships unattended). Each row names
# the reason(s) with the remedy — the /auto-prep daytime attention list before a night fleet.
#
# Generalizes and replaces stage-inversions.sh: stage was only one of the ways a blocker escapes
# the fleet, and the label-gated ways are invisible to the deps graph (it carries no labels), so
# this script does its own one-query fetch (states + labels + relations).
#
# WHY A SCRIPT: the same silent-empty hazard as wt-baseline.sh — a mistranscribed inline filter
# prints nothing at exit 0, which reads as "nothing blocks the fleet". The verdict line makes an
# empty result distinguishable from a broken run; the regression suite pins the classification.
#
# Usage:  fleet-blockers.sh --team <KEY>
# Output: first line `FLEET-BLOCKED: <n>`, then one sorted line per stranded edge:
#         `<BLOCKED> [<state>] blocked by <BLOCKER> [<state>] — <reason(; reason)>`
# Exit:   0 when fetched and classified (n may be 0); non-zero on fetch/parse failure.
set -euo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

[ "${1:-}" = "--team" ] && [ -n "${2:-}" ] || { echo "usage: fleet-blockers.sh --team <KEY>" >&2; exit 1; }
team="$2"

# One paginated query: every non-terminal issue's state, labels, and outgoing relations. A
# terminal-state blocker is excluded by the filter, so its edges vanish — resolved by construction.
q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){nodes{identifier state{name type} labels{nodes{name}} relations{nodes{type relatedIssue{identifier}}}} pageInfo{hasNextPage endCursor}}}'
all='[]'
after=''
while :; do
  if [ -z "$after" ]; then
    out=$(linear-cli api query -q -o json -v team="$team" "$q" 2>/dev/null)
  else
    out=$(linear-cli api query -q -o json -v team="$team" -v after="$after" "$q" 2>/dev/null)
  fi
  [ -n "$out" ] || { echo "ERROR: issue fetch failed for team '$team' (auth? network?)" >&2; exit 1; }
  if [ "$(printf '%s' "$out" | jq 'has("errors")')" = "true" ]; then
    echo "ERROR: API errors for team '$team': $(printf '%s' "$out" | jq -c '.errors')" >&2; exit 1
  fi
  nodes=$(printf '%s' "$out" | jq -c '.data.issues.nodes // []')
  all=$(jq -n --argjson a "$all" --argjson b "$nodes" '$a + $b')
  has=$(printf '%s' "$out" | jq -r '.data.issues.pageInfo.hasNextPage // false')
  after=$(printf '%s' "$out" | jq -r '.data.issues.pageInfo.endCursor // empty')
  { [ "$has" = "true" ] && [ -n "$after" ]; } || break
done

printf '%s' "$all" | jq -r '
  . as $nodes
  | ([ $nodes[] | {key: .identifier,
                   value: {sname: (.state.name // "?"), stype: (.state.type // "?"),
                           labels: [((.labels.nodes // [])[].name) | ascii_downcase]}} ]
     | from_entries) as $m
  | [ $nodes[]
      | .identifier as $blocker
      | $m[$blocker] as $b
      | (.relations.nodes // [])[]
      | select(.type == "blocks" and .relatedIssue != null)
      | .relatedIssue.identifier as $blocked
      | ($m[$blocked] // null) as $t
      | select($t != null)
      # Blocked side must be a candidate the fleet could pick: workable state, certified, and not
      # itself hidden by a gate label (a hidden dependent is not reachable regardless of blockers).
      | select($t.sname | IN("Backlog","Planned","Todo"))
      | select($t.labels | index("specified"))
      | select([ $t.labels[] | select(IN("needs decision","human","solo")) ] | length == 0)
      # Blocker: every reason the fleet cannot ship it, with the remedy.
      | ([ (if ($b.labels | index("human")) then "human-labeled (human-performed; the fleet never ships it)" else empty end),
           (if ($b.labels | index("needs decision")) then "needs decision (decide and clear the label)" else empty end),
           (if ($b.labels | index("solo")) then "solo (targeted /auto in the quiet window)" else empty end),
           (if ($b.labels | index("stalled")) then "stalled (resume or release it)" else empty end),
           (if $b.stype == "triage" then "in Triage (groom via /spec)" else empty end),
           (if $b.stype == "backlog" then "in Backlog (promote to Planned)" else empty end),
           (if (($b.sname | IN("Backlog","Planned","Todo")) and (($b.labels | index("specified")) | not))
              then "uncertified (/spec to certify)" else empty end)
         ]) as $reasons
      | select($reasons | length > 0)
      | "\($blocked) [\($t.sname)] blocked by \($blocker) [\($b.sname)] — \($reasons | join("; "))"
    ]
  | sort
  | (["FLEET-BLOCKED: \(length)"] + .) | .[]
'
