#!/bin/bash
# linear-deps-graph.sh — Emit a Linear dependency graph as JSON, reproducing the
# shape the previous CLI's `linear deps` produced: {nodes:[{identifier,title,state}],
# edges:[{from,to,type}]}.
#
# Finesssee linear-cli has no `deps` command — relationships live per-issue under
# `relations list`, with no team-wide graph or blocker/blocking flags. This rebuilds
# the graph from the raw GraphQL API (issue/issues `relations` + `inverseRelations`),
# so the digest, /next, /deps, and /link-deps keep a single stable graph contract.
#
# Usage:
#   linear-deps-graph.sh <ISSUE-ID>      # local graph: the issue + its neighbors
#   linear-deps-graph.sh --team <KEY>    # whole-team graph (active issues, capped 250)
#
# Edge direction: an edge {from, to, type:"blocks"} means `from` blocks `to`. So the
# blockers of X are edges with to==X; the issues X blocks are edges with from==X —
# identical to the old `linear deps` semantics the downstream jq already assumes.
#
# Output: JSON to stdout. Errors to stderr; non-zero exit on failure.
# Read-only — no Linear writes.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

mode="issue"
target=""
case "${1:-}" in
  --team) mode="team"; target="${2:-}" ;;
  -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "" ) echo "usage: linear-deps-graph.sh <ISSUE-ID> | --team <KEY>" >&2; exit 1 ;;
  -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  *) target="$1" ;;
esac
if [ -z "$target" ]; then
  echo "ERROR: missing ${mode} argument" >&2
  exit 1
fi

if [ "$mode" = "team" ]; then
  # All active (non-terminal) issues for the team, each with the relations it is the
  # source of. Iterating every issue captures every "blocks" edge from its source, so
  # inverseRelations are unnecessary here. PAGINATE through every page — a silent cap
  # would drop blocker edges and let /next recommend a still-blocked issue.
  page_q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){nodes{identifier title state{name type} relations{nodes{type relatedIssue{identifier}}}} pageInfo{hasNextPage endCursor}}}'
  all_nodes='[]'
  after=''
  while :; do
    if [ -z "$after" ]; then
      out=$(linear-cli api query -q -o json -v team="$target" "$page_q" 2>/dev/null)
    else
      out=$(linear-cli api query -q -o json -v team="$target" -v after="$after" "$page_q" 2>/dev/null)
    fi
    [ -n "$out" ] || { echo "ERROR: failed to fetch dependency graph for team '$target'" >&2; exit 1; }
    if [ "$(printf '%s' "$out" | jq 'has("errors")')" = "true" ]; then
      echo "ERROR: API errors for team '$target': $(printf '%s' "$out" | jq -c '.errors')" >&2; exit 1
    fi
    nodes=$(printf '%s' "$out" | jq -c '.data.issues.nodes // []')
    all_nodes=$(jq -n --argjson a "$all_nodes" --argjson b "$nodes" '$a + $b')
    has=$(printf '%s' "$out" | jq -r '.data.issues.pageInfo.hasNextPage // false')
    after=$(printf '%s' "$out" | jq -r '.data.issues.pageInfo.endCursor // empty')
    { [ "$has" = "true" ] && [ -n "$after" ]; } || break
  done
  printf '%s' "$all_nodes" | jq '{
    nodes: [.[] | {identifier, title, state}],
    edges: [.[] as $i | ($i.relations.nodes // [])[] | select(.relatedIssue != null) | {from: $i.identifier, to: .relatedIssue.identifier, type: .type}]
  }'
else
  # Local graph: the issue plus its direct neighbors in both relation directions.
  q='query($id:String!){issue(id:$id){identifier title state{name type} relations{nodes{type relatedIssue{identifier title state{name type}}}} inverseRelations{nodes{type issue{identifier title state{name type}}}}}}'
  out=$(linear-cli api query -q -o json -v id="$target" "$q" 2>/dev/null) || {
    echo "ERROR: failed to fetch dependency graph for '$target'" >&2; exit 1; }
  if [ "$(printf '%s' "$out" | jq 'has("errors")')" = "true" ]; then
    echo "ERROR: API errors for '$target': $(printf '%s' "$out" | jq -c '.errors')" >&2; exit 1
  fi
  if [ "$(printf '%s' "$out" | jq '.data.issue == null')" = "true" ]; then
    echo "ERROR: issue '$target' not found" >&2; exit 1
  fi
  printf '%s' "$out" | jq '.data.issue as $self | {
    nodes: ([{identifier: $self.identifier, title: $self.title, state: $self.state}]
      + [($self.relations.nodes // [])[].relatedIssue | select(. != null) | {identifier, title, state}]
      + [($self.inverseRelations.nodes // [])[].issue | select(. != null) | {identifier, title, state}]) | unique_by(.identifier),
    edges: ([($self.relations.nodes // [])[] | select(.relatedIssue != null) | {from: $self.identifier, to: .relatedIssue.identifier, type: .type}]
      + [($self.inverseRelations.nodes // [])[] | select(.issue != null) | {from: .issue.identifier, to: $self.identifier, type: .type}])
  }'
fi
