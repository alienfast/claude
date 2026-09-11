#!/bin/bash
# epic-graph.sh — an epic's working set as JSON: the epic, its transitive descendants, and the
# transitive blockers of any member — non-terminal only, cross-team included — plus the terminal
# nodes met on the walk, the member-to-member edges, and a boundary report of the outside issues
# a member blocks and the outside `related` partners.
#
# Usage: epic-graph.sh [--ids] [--any-root] <EPIC-ID>
#
#   --ids       print member identifiers one per line instead of the JSON document
#   --any-root  accept a root that does not carry the `epic` label (the default refuses it, so a
#               scope token that names the wrong issue fails closed at the ranking)
#
# Why this exists: linear-deps-graph.sh returns one issue's neighbors or a whole team, and
# next-candidates.sh walks parent chains and blocker chains separately for ranking. Neither
# assembles the membership an epic-scoped fleet is limited to — and membership is decided by
# keeper ruling (2026-09-11): dependents are NOT members. An outside issue a member blocks is
# enabled by the epic, not required by it, and `blocks` also carries same-method-collision
# meaning, so following that edge would pull unrelated work into the scope. Those edges, and
# every `related` edge that leaves the graph, are reported as the boundary for /epic-prep's
# human review instead.
#
# Walk: children are followed through terminal parents too (a Done parent can still hold open
# children); blockers are followed only from non-terminal nodes (a shipped blocker gates
# nothing, so its own chain is irrelevant). Terminal is state TYPE completed/canceled/duplicate
# or a state NAME in the set next-candidates.sh resolves blockers on — both, because BF's
# "Ready for Release" is type `completed` while "In Review" is type `started` and terminal by
# name only. Boundary nodes are fetched (never expanded) so terminal ones can be dropped from
# the report — a Done dependent is noise to a reviewer.
#
# Output: {root, members[{identifier,title,state,state_type,team,labels,parent,kind}],
#          terminal[{identifier,title,state,state_type,team,kind}], teams[], edges[{from,to,type}],
#          boundary:{dependents_outside[{identifier,title,state,state_type,team,blocked_by[]}],
#                    related_outside[{identifier,title,state,state_type,team,related_to[]}]}}
# `kind` is how the node was first reached: root | descendant | blocker. Members are in
# discovery order (root first). `edges` are member-to-member only; `related` edges are
# de-duplicated across their two storage directions.
#
# Fail closed: a graph is printed whole or not at all — one unreadable node exits 2 with nothing
# on stdout, because a partial membership silently narrows a fleet's scope.
#
# Exit codes: 0 success; 1 usage / root not found / root lacks `epic`; 2 a node could not be
# fetched after retries; 3 missing dependency.
#
# Read-only — no Linear writes.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

ids_only=0
any_root=0
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ids) ids_only=1 ;;
    --any-root) any_root=1 ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
    *)
      if [ -n "$root" ]; then echo "ERROR: exactly one epic id expected (got '$root' and '$1')" >&2; exit 1; fi
      root="$1" ;;
  esac
  shift
done
if [ -z "$root" ]; then
  echo "usage: epic-graph.sh [--ids] [--any-root] <EPIC-ID>" >&2
  exit 1
fi
root=$(printf '%s' "$root" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
if ! [[ "$root" =~ ^[A-Z0-9]+-[0-9]+$ ]]; then
  echo "ERROR: epic id '$root' does not match ^[A-Z0-9]+-[0-9]+\$" >&2
  exit 1
fi

for cmd in linear-cli jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 3
  fi
done

# Same name set as next-candidates.sh's TERMINAL_STATES — a blocker resolved there is terminal here.
TERMINAL_NAMES='["Done","Canceled","Cancelled","Duplicate","Ready For Release","In Review"]'
TERMINAL_TYPES='["completed","canceled","duplicate"]'
# Bounds the walk: an epic graph past this is a modeling problem, not a fleet scope.
MAX_NODES=500

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

Q='query($id:String!){issue(id:$id){identifier title state{name type} team{key} labels{nodes{name}} parent{identifier} children{nodes{identifier}} relations{nodes{type relatedIssue{identifier}}} inverseRelations{nodes{type issue{identifier}}}}}'

# fetch_node <ID> — writes the normalized node to $tmpdir/n.<ID>.json, or touches missing.<ID> /
# fail.<ID>. A missing issue answers with linear-cli's own error envelope (`Entity not found`,
# exit 2), distinct from the `{"errors":…}` GraphQL envelope and from an empty rate-limited
# response, so it is recognized on the first attempt and never retried.
fetch_node() {
  local id="$1" out attempt
  for attempt in 1 2 3; do
    out=$(linear-cli api query -q -o json -v id="$id" "$Q" 2>/dev/null) || true
    if printf '%s' "$out" | grep -q 'Entity not found'; then
      : > "$tmpdir/missing.$id"
      return 0
    fi
    if [ -n "$out" ] && printf '%s' "$out" | jq -e '.data.issue != null' >/dev/null 2>&1; then
      # A normalization failure is a fetch failure: an empty node file would read as a labelless,
      # childless issue and silently narrow the graph.
      if ! printf '%s' "$out" | jq -c --argjson tn "$TERMINAL_NAMES" --argjson tt "$TERMINAL_TYPES" '
        .data.issue
        | {identifier, title,
           state: (.state.name // "?"), state_type: (.state.type // "?"),
           team: (.team.key // "?"),
           labels: ((.labels.nodes // []) | map(.name)),
           parent: (.parent.identifier // null),
           children: ((.children.nodes // []) | map(.identifier)),
           blockers: [ (.inverseRelations.nodes // [])[] | select(.type == "blocks" and .issue != null) | .issue.identifier ],
           blocks:   [ (.relations.nodes // [])[] | select(.type == "blocks" and .relatedIssue != null) | .relatedIssue.identifier ],
           related: ([ (.relations.nodes // [])[] | select(.type == "related" and .relatedIssue != null) | .relatedIssue.identifier ]
                     + [ (.inverseRelations.nodes // [])[] | select(.type == "related" and .issue != null) | .issue.identifier ] | unique)}
        | . + {terminal: ((.state_type as $st | ($tt | index($st)) != null)
                          or ((.state | ascii_downcase) as $sn | (($tn | map(ascii_downcase)) | index($sn)) != null))}
      ' > "$tmpdir/n.$id.json.tmp" 2>/dev/null; then
        : > "$tmpdir/fail.$id"
        return 0
      fi
      mv "$tmpdir/n.$id.json.tmp" "$tmpdir/n.$id.json"
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  : > "$tmpdir/fail.$id"
}

# check_fetched <ID> <kind> — every failure mode is fatal (fail closed), with the root's
# not-found as a usage-class exit.
check_fetched() {
  local id="$1" kind="$2"
  if [ -e "$tmpdir/fail.$id" ]; then
    echo "ERROR: could not fetch $id (reached as $kind) after retries — refusing to print a partial graph (auth? network? rate limit?)" >&2
    exit 2
  fi
  if [ -e "$tmpdir/missing.$id" ]; then
    if [ "$kind" = "root" ]; then
      echo "ERROR: issue '$root' not found" >&2
      exit 1
    fi
    echo "ERROR: $id (reached as $kind from the graph) does not exist or is not readable — refusing to print a partial graph" >&2
    exit 2
  fi
}

# fetch_level — one parallel fetch per BFS level over $tmpdir/level ("ID<TAB>kind" lines).
fetch_level() {
  local id kind p
  pids=()
  while IFS=$'\t' read -r id kind; do
    [ -n "$id" ] || continue
    fetch_node "$id" &
    pids+=($!)
  done < "$tmpdir/level"
  for p in "${pids[@]}"; do wait "$p" || true; done
}

# enqueue <ID> <kind> — first sighting wins; later sightings of the same node are ignored.
enqueue() {
  grep -qxF -- "$1" "$tmpdir/seen" && return 0
  printf '%s\n' "$1" >> "$tmpdir/seen"
  printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/kinds"
  printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/level"
  seen_count=$((seen_count + 1))
}

# ---------- the walk ----------

: > "$tmpdir/seen"
: > "$tmpdir/kinds"
: > "$tmpdir/level"
seen_count=0
enqueue "$root" root
while [ -s "$tmpdir/level" ]; do
  if [ "$seen_count" -gt "$MAX_NODES" ]; then
    echo "ERROR: the graph under $root exceeds $MAX_NODES nodes — not a fleet scope" >&2
    exit 1
  fi
  fetch_level
  cp "$tmpdir/level" "$tmpdir/level.done"
  : > "$tmpdir/level"
  while IFS=$'\t' read -r id kind; do
    [ -n "$id" ] || continue
    check_fetched "$id" "$kind"
    n="$tmpdir/n.$id.json"
    if [ "$kind" = "root" ] && [ "$any_root" -eq 0 ]; then
      if [ "$(jq -r 'any(.labels[]; ascii_downcase == "epic")' "$n")" != "true" ]; then
        echo "ERROR: $root does not carry the 'epic' label — not an epic (pass --any-root to walk it anyway)" >&2
        exit 1
      fi
    fi
    case "$kind" in
      root|descendant)
        while IFS= read -r c; do [ -n "$c" ] && enqueue "$c" descendant; done < <(jq -r '.children[]' "$n") ;;
    esac
    if [ "$(jq -r '.terminal' "$n")" != "true" ]; then
      while IFS= read -r b; do [ -n "$b" ] && enqueue "$b" blocker; done < <(jq -r '.blockers[]' "$n")
    fi
  done < "$tmpdir/level.done"
done

# ---------- boundary: fetch the outside endpoints, never expand them ----------

cp "$tmpdir/kinds" "$tmpdir/kinds.walk"
: > "$tmpdir/level"
while IFS=$'\t' read -r id kind; do
  [ -n "$id" ] || continue
  n="$tmpdir/n.$id.json"
  [ "$(jq -r '.terminal' "$n")" = "true" ] && continue
  while IFS= read -r o; do [ -n "$o" ] && enqueue "$o" boundary; done < <(jq -r '(.blocks + .related)[]' "$n")
done < "$tmpdir/kinds.walk"
if [ -s "$tmpdir/level" ]; then
  fetch_level
  while IFS=$'\t' read -r id kind; do
    [ -n "$id" ] || continue
    check_fetched "$id" "$kind"
  done < "$tmpdir/level"
fi

# ---------- assemble ----------

graph=$(while IFS=$'\t' read -r id kind; do
  [ -n "$id" ] || continue
  cat "$tmpdir/n.$id.json"; printf '\n'
done < "$tmpdir/kinds" | jq -s --arg root "$root" --rawfile kinds "$tmpdir/kinds" '
  ($kinds | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $k
  | map(. + {kind: $k[.identifier]})
  | (map(select(.kind != "boundary" and (.terminal | not)))) as $members
  | (map(select(.kind != "boundary" and .terminal))) as $terminal
  | (map(select(.kind == "boundary")) | map({key: .identifier, value: .}) | from_entries) as $outside
  | ($members | map(.identifier)) as $mids
  # Terminal on either side of the line — a walked terminal node (a shipped sibling a member is
  # `related` to) is as much noise to the boundary reviewer as a Done outside dependent.
  | (map(select(.terminal)) | map(.identifier)) as $tids
  | def member($x): (($mids | index($x)) != null);
    def live($x): (($tids | index($x)) == null);
    def outside_row($o): ($outside[$o] // {}) | {title, state, state_type, team};
    {
      root: $root,
      members: ($members | map({identifier, title, state, state_type, team, labels, parent, kind})),
      terminal: ($terminal | map({identifier, title, state, state_type, team, kind})),
      teams: ($members | map(.team) | unique),
      edges: ([ $members[] as $m | $m.blocks[] | select(member(.)) | {from: $m.identifier, to: ., type: "blocks"} ]
        + ([ $members[] as $m | $m.related[] | select(member(.))
             | {from: ([$m.identifier, .] | min), to: ([$m.identifier, .] | max), type: "related"} ] | unique)),
      boundary: {
        dependents_outside: ([ $members[] as $m | $m.blocks[] | select((member(.) | not) and live(.)) | {id: ., by: $m.identifier} ]
          | group_by(.id)
          | map({identifier: .[0].id} + outside_row(.[0].id) + {blocked_by: (map(.by) | unique)})),
        related_outside: ([ $members[] as $m | $m.related[] | select((member(.) | not) and live(.)) | {id: ., by: $m.identifier} ]
          | group_by(.id)
          | map({identifier: .[0].id} + outside_row(.[0].id) + {related_to: (map(.by) | unique)}))
      }
    }')

if [ "$ids_only" -eq 1 ]; then
  printf '%s' "$graph" | jq -r '.members[].identifier'
else
  printf '%s\n' "$graph"
fi
