#!/bin/bash
# stage-inversions.sh — list `blocks` edges where a workable-stage candidate (Planned/Todo) is
# blocked by a deferred-stage blocker (Backlog/Triage). Under stage-first ranking the dependent
# outranks its blocker, so it is stranded until the blocker is promoted (or groomed, for Triage) —
# /auto-prep Step 4 surfaces these and proposes the promotion.
#
# WHY A SCRIPT: this began as a jq recipe inlined in auto-prep SKILL.md prose — the transcription-
# drift shape wt-baseline.sh exists to prevent, made worse here by the failure direction: a
# mistranscribed filter or a drifted deps-graph contract prints NOTHING at exit 0, which reads as
# "no inversions". The verdict line makes empty output distinguishable from a broken run, and the
# regression suite (stage-inversions.test.sh) pins the classification.
#
# Sides match differently on purpose: the blocked side by NAME (Planned/Todo — mirroring
# next-candidates.sh's name-based WORKABLE_STATES, minus Backlog), the blocker side by state TYPE
# (backlog/triage — so a renamed Triage state like "Inbox" still classifies, and a started-type
# state can never false-positive).
#
# Usage:  stage-inversions.sh --team <KEY>
# Output: first line `INVERSIONS: <n>`, then one line per inversion:
#         `<BLOCKED> [<state>] blocked by <BLOCKER> [<state>]`
# Exit:   0 when the graph was fetched and classified (n may be 0); non-zero on fetch/parse failure.
set -euo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

[ "${1:-}" = "--team" ] && [ -n "${2:-}" ] || { echo "usage: stage-inversions.sh --team <KEY>" >&2; exit 1; }
team="$2"

graph=$("$SCRIPT_DIR/linear-deps-graph.sh" --team "$team") || {
  echo "ERROR: linear-deps-graph.sh --team $team failed" >&2; exit 1; }

printf '%s' "$graph" | jq -r '
  ([.nodes[] | {key: .identifier, value: .state}] | from_entries) as $s
  | [ .edges[]
      | select(.type == "blocks")
      | ($s[.from] // {}) as $b | ($s[.to] // {}) as $t
      | select((($t.name // "") | IN("Planned","Todo")) and (($b.type // "") | IN("backlog","triage")))
      | "\(.to) [\($t.name)] blocked by \(.from) [\($b.name)]" ]
  | (["INVERSIONS: \(length)"] + .) | .[]
'
