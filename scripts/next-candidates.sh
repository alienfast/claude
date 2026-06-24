#!/bin/bash
# next-candidates.sh — Rank workable Linear issues and suggest what to do next.
#
# Usage:
#   next-candidates.sh [--team KEY] [--completed PL-XX] [--limit N] [--no-parent-walk]
#
# Resolves the team key from --team or $LINEAR_TEAM.
# Fans out three parallel Linear CLI calls (workable list, deps graph, current
# cycle), filters to issues with all blockers resolved, buckets into 6 tiers
# (assigned-to-me → newly-unblocked-in-cycle → cycle-ready → newly-unblocked →
# sibling-under-completed-parent → priority-fallback), then walks parent chains
# for the top-K candidates to apply parent-status weighting (In Progress epic >
# Planned > Backlog > Triage). Emits a ranked markdown list to stdout.
#
# Exit codes: 0 success (incl. "no workable issues"), 1 arg error,
# 2 Linear/network failure, 3 missing dependency.
#
# Read-only — no Linear writes, no git mutations.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------- arg parsing ----------

team_arg=""
completed=""
limit=3
parent_walk=1

while [ $# -gt 0 ]; do
  case "$1" in
    --team) team_arg="$2"; shift 2 ;;
    --completed) completed="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --no-parent-walk) parent_walk=0; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -lt 1 ]; then
  echo "ERROR: --limit must be a positive integer" >&2
  exit 1
fi

if [ -n "$completed" ]; then
  completed=$(printf '%s' "$completed" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  if ! [[ "$completed" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "ERROR: --completed '$completed' does not match ^[A-Z]+-[0-9]+\$" >&2
    exit 1
  fi
fi

for cmd in linear-cli jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 3
  fi
done

# ---------- team resolution ----------

team_key="$team_arg"
if [ -z "$team_key" ] && [ -n "${LINEAR_TEAM:-}" ]; then
  team_key="$LINEAR_TEAM"
fi
if [ -z "$team_key" ]; then
  echo "ERROR: team key not resolved (pass --team or set \$LINEAR_TEAM)" >&2
  exit 1
fi

# ---------- parallel fetch ----------

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

list_file="$tmpdir/list.json"
deps_file="$tmpdir/deps.json"
deps_err="$tmpdir/deps.err"
deps_raw="$tmpdir/deps.raw.json"
cycle_file="$tmpdir/cycle.json"
cycle_raw="$tmpdir/cycle.raw.json"
cycle_err="$tmpdir/cycle.err"

# Paginated team-issue fetch via the api. `issues list` omits `estimate`, returns
# assignee.name (a display name on real workspaces — NOT the email the ranking compares
# against), and silently caps at the page size; the api gives estimate + assignee.email
# and pages through everything. Writes the array already in the shape the ranking
# pipeline expects (state→name string, assignee→email string) directly to $out.
fetch_team_issues() {
  local team="$1" out="$2" after='' all='[]' page nodes has
  local q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){nodes{identifier title estimate priority state{name} assignee{email}} pageInfo{hasNextPage endCursor}}}'
  while :; do
    if [ -z "$after" ]; then
      page=$(linear-cli api query -q -o json -v team="$team" "$q" 2>/dev/null)
    else
      page=$(linear-cli api query -q -o json -v team="$team" -v after="$after" "$q" 2>/dev/null)
    fi
    [ -n "$page" ] || return 1
    [ "$(printf '%s' "$page" | jq 'has("errors")')" = "true" ] && return 1
    nodes=$(printf '%s' "$page" | jq -c '.data.issues.nodes // []')
    all=$(jq -n --argjson a "$all" --argjson b "$nodes" '$a + $b')
    has=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage // false')
    after=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor // empty')
    { [ "$has" = "true" ] && [ -n "$after" ]; } || break
  done
  printf '%s' "$all" | jq '[ .[]
    | {identifier, title, state:(.state.name // "?"), priority:(.priority // 0),
       estimate:(.estimate // 0), assignee:(.assignee.email // null)} ]' > "$out"
}

fetch_team_issues "$team_key" "$list_file" &
list_pid=$!

# Dependency graph via the api-backed helper (paginated internally; no `deps` command).
"$SCRIPT_DIR/linear-deps-graph.sh" --team "$team_key" >"$deps_raw" 2>"$deps_err" &
deps_pid=$!

# Current-cycle issue ids via the active-cycle filter (a cycle's issue count is small,
# so a single page is fine). Allowed to fail / be empty (team may have no active cycle).
linear-cli api query -q -o json -v team="$team_key" \
  'query($team:String!){issues(filter:{team:{key:{eq:$team}}, cycle:{isActive:{eq:true}}}, first:250){nodes{identifier}}}' \
  >"$cycle_raw" 2>"$cycle_err" &
cycle_pid=$!

wait "$list_pid" || { echo "ERROR: team-issue fetch (team $team_key) failed (auth? network?)" >&2; exit 2; }
wait "$deps_pid" || { echo "ERROR: linear-deps-graph.sh (team $team_key) failed:" >&2; cat "$deps_err" >&2; exit 2; }
wait "$cycle_pid" || printf '{}' >"$cycle_raw"   # no active cycle is not fatal — tiers 2/3 collapse

# Normalize deps + cycle into the pipeline shapes (the list is already normalized above).
#   deps  → {nodes:[{identifier, state:<name>}], edges:[{from,to,type}]}
#   cycle → array of {identifier}
jq '{nodes: [ (.nodes // [])[] | {identifier, state: (.state.name // .state // "?")} ],
     edges: (.edges // [])}' "$deps_raw" >"$deps_file"
jq '[ (.data.issues.nodes // [])[] | {identifier} ]' "$cycle_raw" >"$cycle_file" 2>/dev/null \
  || printf '[]' >"$cycle_file"

# ---------- my email ----------

me_email=$(linear-cli api query -q -o json 'query{viewer{email}}' 2>/dev/null | jq -r '.data.viewer.email // empty' || true)

# ---------- jq pipeline: workable filter + tiering ----------

# State sets — keep terminal states defensive across teams.
TERMINAL_STATES='["Done","Canceled","Cancelled","Duplicate","Ready For Release"]'
WORKABLE_STATES='["Triage","Backlog","Planned","Todo"]'
ACTIVE_STATES='["In Progress"]'

# Build a canonical state map from BOTH the deps graph (covers blockers that
# may live outside the workable list) and the team list (richer fields). The
# fetch step above normalized `state` to a name string in both files, so no
# object/string coercion is needed here — but `linear-cli issues get` returns
# {name,...} so we coerce in the parent walk later.
state_map_json=$(jq -s '
  (.[0].nodes // []) as $nodes
  | (.[1] // []) as $issues
  | ($nodes | map({key: .identifier, value: .state}))
    + ($issues | map({key: .identifier, value: .state}))
  | from_entries
' "$deps_file" "$list_file")

# Blocker map: to_id -> [from_ids] where edge.type == "blocks".
blocker_map_json=$(jq '
  (.edges // [])
  | map(select(.type == "blocks"))
  | group_by(.to)
  | map({key: .[0].to, value: (map(.from) | unique)})
  | from_entries
' "$deps_file")

# Reverse map: from_id -> [to_ids] (for transitive unblocking BFS).
reverse_blocker_map_json=$(jq '
  (.edges // [])
  | map(select(.type == "blocks"))
  | group_by(.from)
  | map({key: .[0].from, value: (map(.to) | unique)})
  | from_entries
' "$deps_file")

# Cycle set: identifiers in current cycle (empty if cycle fetch failed/empty).
cycle_set_json=$(jq '[.[] | .identifier]' "$cycle_file" 2>/dev/null || echo '[]')
if [ -z "$cycle_set_json" ]; then cycle_set_json='[]'; fi

# ---------- transitive unblocking (BFS) ----------

if [ -n "$completed" ]; then
  newly_unblocked_json=$(jq -n \
    --arg root "$completed" \
    --argjson rev "$reverse_blocker_map_json" \
    --argjson sm "$state_map_json" \
    --argjson terminal "$TERMINAL_STATES" '
      # BFS over reverse blocker map from $root, but only descend into nodes
      # whose blockers are now all resolved (terminal states). This matches
      # the "newly unblocked" definition: an issue whose *last* unresolved
      # blocker was the completed issue (or transitively unblocked by it).
      def all_terminal($ids): all($ids[]; ($sm[.] // "Unknown") as $s | ($terminal | index($s)) != null);
      def bfs($frontier; $visited):
        if ($frontier | length) == 0 then $visited
        else
          ($frontier | map($rev[.] // []) | add // []) as $next
          | ($next | unique) as $candidates
          | ($candidates | map(select(($visited | index(.)) == null))) as $fresh
          | bfs($fresh; ($visited + $fresh) | unique)
        end;
      [bfs([$root]; []) | .[] | select(. != $root)]
      | map(select(($sm[.] // "Unknown") as $s | ($terminal | index($s)) == null))
    ')
else
  newly_unblocked_json='[]'
fi

# ---------- candidate set ----------

# Filter workable issues whose blockers are all in terminal states.
# Emit per-candidate metadata for ranking.
candidates_json=$(jq \
  --argjson workable "$WORKABLE_STATES" \
  --argjson terminal "$TERMINAL_STATES" \
  --argjson active "$ACTIVE_STATES" \
  --argjson sm "$state_map_json" \
  --argjson bm "$blocker_map_json" \
  --argjson cycle "$cycle_set_json" \
  --argjson newly "$newly_unblocked_json" \
  --arg me "${me_email:-}" \
  --arg completed "$completed" '
    def priority_label(p):
      if p == 1 then "Urgent"
      elif p == 2 then "High"
      elif p == 3 then "Normal"
      elif p == 4 then "Low"
      else "None" end;
    def priority_rank(p):
      # Lower rank = higher priority; Urgent(1)→1, High(2)→2, Normal(3)→3, Low(4)→4, None(0)→5.
      if p == 1 then 1
      elif p == 2 then 2
      elif p == 3 then 3
      elif p == 4 then 4
      else 5 end;
    map(
      . as $i
      | (.identifier) as $id
      | ($bm[$id] // []) as $blockers
      | ($blockers | map(select(($sm[.] // "Unknown") as $s | ($terminal | index($s)) == null))) as $unresolved
      | select(($workable | index($i.state)) != null)
      | select($unresolved | length == 0)
      | {
          id: $id,
          title: $i.title,
          state: $i.state,
          priority: $i.priority,
          priority_label: priority_label($i.priority),
          priority_rank: priority_rank($i.priority),
          estimate: ($i.estimate // 0),
          assignee: $i.assignee,
          is_me: (($me != "") and ($i.assignee == $me)),
          in_cycle: (($cycle | index($id)) != null),
          newly_unblocked: (($newly | index($id)) != null),
          blocker_count_total: ($blockers | length)
        }
    )
  ' "$list_file")

candidate_count=$(printf '%s' "$candidates_json" | jq 'length')
if [ "$candidate_count" -eq 0 ]; then
  printf '## Suggested next\n\n_No workable issues in team %s._\n' "$team_key"
  exit 0
fi

# ---------- pre-rank into tiers (parent-agnostic) ----------

# Tier assignment (without parent data yet — tier 5 deferred to step 7).
# Tier 1: assigned to me + workable
# Tier 2: in current cycle + newly unblocked
# Tier 3: in current cycle (ready)
# Tier 4: newly unblocked (any)
# Tier 6: anything else workable (tier 5 reassignment happens post-parent-walk)
ranked_json=$(printf '%s' "$candidates_json" | jq '
  map(
    . + {
      tier: (
        if .is_me then 1
        elif (.in_cycle and .newly_unblocked) then 2
        elif .in_cycle then 3
        elif .newly_unblocked then 4
        else 6
        end
      )
    }
  )
  | sort_by([.tier, .priority_rank, (if .in_cycle then 0 else 1 end), .estimate])
')

# ---------- parent walk for top-K ----------

# K = limit + 2 so we have a runner-up cushion and can reshuffle into tier 5
# after parent data arrives.
K=$((limit + 2))
top_ids=$(printf '%s' "$ranked_json" | jq -r --argjson k "$K" '.[0:$k] | .[].id')

parent_cache_file="$tmpdir/parent_cache.json"
printf '{}' > "$parent_cache_file"

if [ "$parent_walk" -eq 1 ] && [ -n "$top_ids" ]; then
  # Step 1: fan-out fetch direct parents of top-K in parallel.
  fetch_dir="$tmpdir/get"
  mkdir -p "$fetch_dir"
  pids=()
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    (linear-cli issues get "$id" -o json >"$fetch_dir/$id.json" 2>/dev/null || true) &
    pids+=($!)
  done <<< "$top_ids"
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  # Step 2: extract parent chains (climb via repeated linear-cli issues get on each
  # ancestor). Cache hits skip the fetch. Bounded by max_depth=10.
  max_depth=10

  # ancestors_json: id -> [{identifier, title, state}, ...] (root-to-direct-parent order)
  ancestors_json="{}"

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ ! -s "$fetch_dir/$id.json" ]; then continue; fi
    # Start with this candidate's direct parent (if any).
    chain="[]"
    cur=$(jq -r '.parent.identifier // ""' "$fetch_dir/$id.json")
    depth=0
    visited="|$id|"
    while [ -n "$cur" ] && [ "$depth" -lt "$max_depth" ]; do
      if [[ "$visited" == *"|$cur|"* ]]; then
        break
      fi
      visited="${visited}${cur}|"
      # Try cache.
      cached=$(jq -r --arg k "$cur" '.[$k] // empty' "$parent_cache_file")
      if [ -n "$cached" ] && [ "$cached" != "null" ]; then
        cur_json="$cached"
      else
        if [ ! -s "$fetch_dir/$cur.json" ]; then
          (linear-cli issues get "$cur" -o json >"$fetch_dir/$cur.json" 2>/dev/null || true)
        fi
        if [ ! -s "$fetch_dir/$cur.json" ]; then break; fi
        # Normalize state to a string (linear-cli issues get returns {name, ...}).
        cur_json=$(jq -c '{
          identifier: .identifier,
          title: .title,
          state: (.state | if type == "object" then (.name // "?") else (. // "?") end),
          parent_id: (.parent.identifier // null)
        }' "$fetch_dir/$cur.json")
        # Update cache.
        tmp_cache=$(mktemp "$tmpdir/cache-XXXXXX")
        jq --arg k "$cur" --argjson v "$cur_json" '. + {($k): $v}' "$parent_cache_file" > "$tmp_cache"
        mv "$tmp_cache" "$parent_cache_file"
      fi
      chain=$(jq -c --argjson ent "$cur_json" '. + [{identifier: $ent.identifier, title: $ent.title, state: $ent.state}]' <<< "$chain")
      cur=$(jq -r '.parent_id // ""' <<< "$cur_json")
      depth=$((depth + 1))
    done
    ancestors_json=$(jq -c --arg id "$id" --argjson chain "$chain" '. + {($id): $chain}' <<< "$ancestors_json")
  done <<< "$top_ids"

  # Step 3: apply parent weight + tier 5 (sibling under completed parent).
  # parent_weight: lower = better (matches priority_rank convention).
  #   In Progress=1, Planned=2, Backlog=3, Triage=4, none/other=5.
  # Use the deepest-found ancestor's state (root of the chain).
  if [ -n "$completed" ]; then
    completed_parent_id=$(jq -r --arg c "$completed" '.[$c] // [] | (.[0].identifier // "")' <<< "$ancestors_json")
  else
    completed_parent_id=""
  fi

  ranked_json=$(printf '%s' "$ranked_json" | jq \
    --argjson anc "$ancestors_json" \
    --arg completed "$completed" \
    --arg completed_parent_id "$completed_parent_id" '
      def weight(s):
        if s == "In Progress" then 1
        elif s == "Planned" then 2
        elif s == "Backlog" then 3
        elif s == "Triage" then 4
        else 5
        end;
      map(
        . as $c
        | ($anc[$c.id] // []) as $chain
        | (if ($chain | length) > 0 then $chain[-1] else null end) as $root
        | (if ($chain | length) > 0 then $chain[0] else null end) as $direct_parent
        | (if $root then weight($root.state) else 5 end) as $pw
        # Tier 5: sibling under the completed issue'\''s parent.
        | (if ($completed != "")
              and ($completed_parent_id != "")
              and ($direct_parent != null)
              and ($direct_parent.identifier == $completed_parent_id)
            then 5 else null end) as $sibling_tier
        | . + {
            parent_chain: $chain,
            parent_root: $root,
            parent_direct: $direct_parent,
            parent_weight: $pw,
            tier: (if $sibling_tier != null and .tier > 5 then $sibling_tier else .tier end)
          }
      )
      | sort_by([.tier, .parent_weight, .priority_rank, (if .in_cycle then 0 else 1 end), .estimate])
    ')
fi

# ---------- emit markdown ----------

printf '## Suggested next\n\n'
printf '%s' "$ranked_json" | jq -r --argjson lim "$limit" '
  def tier_reason(c):
    if c.tier == 1 then "assigned to you"
    elif c.tier == 2 then "in current cycle + newly unblocked"
    elif c.tier == 3 then "in current cycle"
    elif c.tier == 4 then "newly unblocked"
    elif c.tier == 5 then "sibling under completed parent"
    else "highest-priority workable"
    end;
  .[0:$lim] | to_entries | .[] |
    "\(.key + 1). **\(.value.id)** — \"\(.value.title)\"" +
    "\n   - State: \(.value.state)" +
    (if .value.in_cycle then " (in cycle)" else "" end) +
    " | Priority: \(.value.priority_label)" +
    (if .value.estimate != null and .value.estimate != 0 then " | Estimate: \(.value.estimate)" else "" end) +
    (if .value.is_me then " | _assigned to you_" else "" end) +
    (if .value.parent_direct then
      "\n   - Parent: **\(.value.parent_direct.identifier)** \"\(.value.parent_direct.title)\" _(\(.value.parent_direct.state))_"
      + (if .value.parent_root and .value.parent_root.identifier != .value.parent_direct.identifier then
          " · Epic: **\(.value.parent_root.identifier)** _(\(.value.parent_root.state))_"
        else "" end)
    else "" end) +
    "\n   - Tier \(.value.tier): \(tier_reason(.value))"
'

# Note remaining candidates as a trailing line.
remaining=$(printf '%s' "$ranked_json" | jq --argjson lim "$limit" 'length - $lim')
if [ "$remaining" -gt 0 ]; then
  printf '\n_%s more workable candidate(s) available; pass --limit to see more._\n' "$remaining"
fi
