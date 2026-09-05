#!/bin/bash
# next-candidates.sh — Rank workable Linear issues and suggest what to do next.
#
# Usage:
#   next-candidates.sh [--team KEY[,KEY...]] [--completed PL-XX] [--limit N]
#                      [--no-parent-walk] [--label NAME] [--exclude-label NAME]
#                      [--include-triage] [--include-blocked] [--include-claimed]
#                      [--no-stage-gate]
#
# Assignment is a claim (standards/linear-workflow.md): an issue assigned to anyone other
# than the viewer is hidden from every ranking — certifying and working alike — with a
# trailing hidden-count note; --include-claimed restores them. Assigned-to-me is tier 1.
#
# Teams: --team is repeatable and accepts comma lists; $LINEAR_TEAM may also be a
# comma list. With neither, EVERY team in the workspace is searched (discovered
# via `linear-cli teams list`) and candidates are ranked in one merged list —
# tiers, priority, and estimates are comparable across teams.
# Fans out two parallel Linear CLI calls per team (workable list, deps graph),
# filters to issues with all blockers resolved, buckets into tiers
# (reflection-improvement → assigned-to-me → newly-unblocked →
# sibling-under-completed-parent → priority-fallback), then walks parent chains for
# the top-K candidates to apply parent-status weighting (In Progress epic > Planned >
# Backlog > Triage).
# Within a tier: workflow stage first, as a STRICT three-way order — Planned/Todo, then
# Backlog, then (under --include-triage) the Triage inbox; Urgent does NOT pierce stage
# (keeper decisions 2026-08-05 and 2026-08-13) — then Urgent priority (a deliberate
# human escalation outranks any label within its stage) > security/bug
# label class > remaining priority > spread (a sibling under the same parent In
# Progress/In Review soft de-ranks the candidate — parallel /auto sessions collide in
# sibling files) > parent weight > estimate. A candidate
# whose children carry all the work (1+ children, none workable) is de-ranked below
# everything and annotated "Delegated" (BF-504 — epics kept `specified` by design
# recur as top picks with nothing to implement).
#
# Linear cycle membership is deliberately NOT a signal. On a team with Linear's
# auto-assign-on-start/complete settings it records what was already worked rather than
# what is planned, and cycle rollover keeps never-started issues in it indefinitely
# (BF-183, filed April, rolled forward for months while outranking the whole Planned
# column). Stage carries the planning signal instead.
#
# Stage is INHERITED down a blocking chain: a Backlog issue that transitively blocks a
# Planned/Todo issue ranks in the Planned stage (release scope by implication — an issue is
# scoped by what it gates, not by its column: keeper ruling 2026-08-13,
# standards/linear-workflow.md § Stage Priorities). The walk stops at terminal blockers and
# never lifts Triage. Without it a fleet drained every other Planned issue and then picked
# Backlog work by class and priority while the one issue gating a Planned item sat at Backlog
# rank — /auto-prep's PROMOTE-SET batch fixes the column at prep time, but chains wired
# between preps (review filings, a hand promotion of the dependent alone) re-created the
# inversion mid-run.
#
# The Planned GATE (keeper ruling 2026-08-28): every Planned/Todo issue is worked before any
# Backlog issue, and no usage is spent on Backlog while that column is not drained. Ordering
# alone only holds while a Planned issue is pickable this instant — the moment the rest of the
# column is blocked behind in-flight work or parked, ordering falls through to Backlog, which is
# exactly the usage the ruling forbids. So while the column holds anything not claimed by another
# person, every Backlog candidate is WITHHELD (inherited-stage blockers and children stay — they
# are Planned scope) and a PLANNED-HOLD note names what holds the gate: what releases on its own
# (blocked behind in-flight or fleet-eligible chains) and what needs the keeper (parked,
# uncertified, epics to close). With nothing pickable the caller waits — /auto treats it as a
# no-pick tick, never as drained. Discovery listings (--include-blocked, --include-triage, and
# the solo / needs decision / human label views) are exempt; --no-stage-gate lifts it to inspect
# what waits behind it.
#
# Emits a ranked markdown list to stdout. The --limit cut never hides unstarted-stage
# work: every Planned/Todo candidate below the cut is appended in a trailing
# "Planned/Todo below the cut" section carrying its true rank number (keeper policy
# 2026-08-12 — clearing the Planned queue is the standing priority, and truncation must
# never hide it). The limit governs top-list size, not Planned/Todo visibility.
#
# --label/--exclude-label filter candidates client-side by ASCII-case-insensitive label
# name (team-scoped duplicate labels share a name, not an id). --include-triage
# (matches Linear's triage STATE TYPE, so a renamed triage state still works) and
# --include-blocked (keeps issues with unresolved blockers, reporting each one's
# unresolved-blocker count) are both for /spec's grooming pick-list only — /next
# itself never uses these.
#
# `needs decision`-labeled issues are hidden from every ranking (a human must step in
# first — standards/issue-spec.md) unless the caller asks for that label itself via
# --label 'needs decision'. A trailing note reports the hidden count so the thinner
# list is never silent.
#
# `solo`-labeled issues are hidden the same way and surfaced via --label solo. They are
# unattended-shippable but fleet-hostile: the worktree isolates the working tree, not the
# merge point, the generated artifacts every sibling consumes, or the shared `pnpm check`
# gate every concurrent session blocks on. Hiding them from the ranking is what keeps a
# parallel fleet from picking one; a targeted run (/auto <ID>) while the fleet is quiet
# still ships it — targeted mode refuses only missing certification and the `human` label.
#
# `human`-labeled issues are hidden the same way and surfaced via --label human. The work
# itself is human-performed (standards/issue-spec.md), so unlike `solo` there is no
# targeted-mode carve-out: /auto refuses a human-labeled target in any mode.
#
# `epic`-labeled issues are hidden the same way and surfaced via --label epic: a delegated
# container whose children carry the work (BF-95 — certify per child, close the epic when they
# release), so it never counts fleet-workable, certified or not. fleet-blockers.sh and
# fleet-forecast.py already classify it so; here it was only the BF-504 de-rank, which the
# Planned gate made insufficient — with Backlog withheld, an all-children-shipped Planned epic
# sat one pick behind the workable Planned set instead of behind the whole Backlog.
#
# Issues behind an UNRESOLVED BLOCKER are dropped from the ranking (restored by --include-blocked)
# and, like every other exclusion, counted in a trailing note — one that classifies them the way the
# PLANNED-HOLD note does: releasing on their own (every blocker in the chain is in flight or
# fleet-eligible) or the keeper's. When the pick list is EMPTY, the Planned gate is open, and at least
# one hidden issue will release on its own, the headline is the BLOCKED-HOLD wait text rather than the
# drained text, and /auto keys on it to park instead of latching `drained`. Before this note existed
# the two cases printed byte-identical output: on the 2026-09-05 BFP fleet a session read a certified
# pool chained entirely behind a sibling's in-flight issue (BFP-8 → BFP-18 → BFP-19 → five more) as
# drained, confirmed it on the double-run, and quit with 10.4 of the fleet's 48 budgeted session-hours
# unspent while its siblings shipped all thirteen of those issues. Suppressed under a closed Planned
# gate, where PLANNED-HOLD is the one hold the caller waits on.
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
label=""
exclude_label=""
include_triage=0
include_blocked=0
include_claimed=0
stage_gate=1

# Value-taking flags must fail loudly, not silently: a missing value makes the `shift 2`
# below fail under set -e with no stderr, and an empty value (e.g. --label "") must not
# be read as "no filter" — that would fail a certification gate open instead of closed.
require_value() {
  local flag="$1" remaining="$2" val="$3"
  if [ "$remaining" -lt 2 ] || [ -z "$val" ]; then
    echo "ERROR: $flag requires a non-empty value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --team) require_value --team "$#" "${2:-}"; team_arg="${team_arg:+$team_arg,}$2"; shift 2 ;;
    --completed) require_value --completed "$#" "${2:-}"; completed="$2"; shift 2 ;;
    --limit) require_value --limit "$#" "${2:-}"; limit="$2"; shift 2 ;;
    --no-parent-walk) parent_walk=0; shift ;;
    --label) require_value --label "$#" "${2:-}"; label="$2"; shift 2 ;;
    --exclude-label) require_value --exclude-label "$#" "${2:-}"; exclude_label="$2"; shift 2 ;;
    --include-triage) include_triage=1; shift ;;
    --include-blocked) include_blocked=1; shift ;;
    --include-claimed) include_claimed=1; shift ;;
    --no-stage-gate) stage_gate=0; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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

teams_raw="$team_arg"
if [ -z "$teams_raw" ] && [ -n "${LINEAR_TEAM:-}" ]; then
  teams_raw="$LINEAR_TEAM"
fi
# Explicitly-requested teams (flag or env) fail hard when their fetch fails; discovered
# teams degrade to a warning so one flaky team cannot zero the whole workspace run.
teams_explicit=1
[ -z "$teams_raw" ] && teams_explicit=0
if [ -z "$teams_raw" ]; then
  # No team pinned anywhere → search the whole workspace. Sorted for deterministic output.
  teams_raw=$(linear-cli teams list -o json -q 2>/dev/null \
    | jq -r '[.. | objects | select(has("key")) | .key] | unique | sort | join(",")' 2>/dev/null || true)
  if [ -z "$teams_raw" ]; then
    echo "ERROR: no team resolved and workspace team discovery failed (auth? network?) — pass --team or set \$LINEAR_TEAM" >&2
    exit 2
  fi
fi

teams=()
seen_teams=""
teams_label=""
# Commas AND whitespace both separate keys — "PL BF" must become two teams, never silently
# concatenate into a bogus single key "PLBF" that scans an empty backlog.
IFS=$' \t\n' read -ra _team_parts <<< "$(printf '%s' "$teams_raw" | tr ',' ' ')"
for t in "${_team_parts[@]}"; do
  t=$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')
  [ -z "$t" ] && continue
  if ! [[ "$t" =~ ^[A-Z0-9]+$ ]]; then
    echo "ERROR: team key '$t' does not match ^[A-Z0-9]+\$" >&2
    exit 1
  fi
  case ",$seen_teams," in *",$t,"*) continue ;; esac
  seen_teams="${seen_teams:+$seen_teams,}$t"
  teams+=("$t")
  teams_label="${teams_label:+$teams_label, }$t"
done
if [ ${#teams[@]} -eq 0 ]; then
  echo "ERROR: no valid team keys in '$teams_raw'" >&2
  exit 1
fi

# ---------- parallel fetch ----------

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

list_file="$tmpdir/list.json"
deps_file="$tmpdir/deps.json"

# Paginated team-issue fetch via the api. `issues list` omits `estimate`, returns
# assignee.name (a display name on real workspaces — NOT the email the ranking compares
# against), and silently caps at the page size; the api gives estimate + assignee.email
# and pages through everything. Writes the array already in the shape the ranking
# pipeline expects (state→name string + state_type, assignee→email string) directly to
# $out. Pages accumulate in "$out.pages" on disk, one JSON array per line, rather than in
# a shell variable passed through --argjson each iteration — that hits ARG_MAX (~1MB on
# macOS) on a large team's issue list.
fetch_team_issues() {
  # pages_file is assigned on its own line deliberately: within a single `local` declaration
  # bash expands every word before assigning, so pages_file="$out.pages" sees an EMPTY $out
  # and becomes the literal `.pages` — one shared CWD file that parallel team fetches then
  # race (truncate/append/rm), corrupting each other's pages.
  local team="$1" out="$2" after='' page nodes has attempt pages_file
  pages_file="$out.pages"
  local q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){nodes{identifier title estimate priority state{name type} assignee{email} labels{nodes{name}} parent{identifier}} pageInfo{hasNextPage endCursor}}}'
  : > "$pages_file"
  while :; do
    # The 2×N-team parallel fan-out can trip Linear's rate limiting, which surfaces as an
    # empty/error response on an otherwise-healthy team — retry each page before failing.
    page=''
    for attempt in 1 2 3; do
      if [ -z "$after" ]; then
        page=$(linear-cli api query -q -o json -v team="$team" "$q" 2>/dev/null)
      else
        page=$(linear-cli api query -q -o json -v team="$team" -v after="$after" "$q" 2>/dev/null)
      fi
      if [ -n "$page" ] && [ "$(printf '%s' "$page" | jq 'has("errors")')" != "true" ]; then
        break
      fi
      page=''
      [ "$attempt" -lt 3 ] && sleep 2
    done
    [ -n "$page" ] || return 1
    nodes=$(printf '%s' "$page" | jq -c '.data.issues.nodes // []')
    printf '%s\n' "$nodes" >> "$pages_file"
    has=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage // false')
    after=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor // empty')
    { [ "$has" = "true" ] && [ -n "$after" ]; } || break
  done
  jq -s 'add' "$pages_file" | jq '[ .[]
    | {identifier, title, state:(.state.name // "?"), state_type:(.state.type // "?"),
       priority:(.priority // 0), estimate:(.estimate // 0), assignee:(.assignee.email // null),
       labels:((.labels.nodes // []) | map(.name)), parent:(.parent.identifier // null)} ]' > "$out"
  rm -f "$pages_file"
}

# Both fetch kinds fan out per team in parallel (2 × N background jobs), then merge.
# Deps graph goes via the api-backed helper (paginated internally; no `deps` command).
list_pids=()
deps_pids=()
for i in "${!teams[@]}"; do
  t="${teams[$i]}"
  fetch_team_issues "$t" "$tmpdir/list.$t.json" &
  list_pids[$i]=$!
  "$SCRIPT_DIR/linear-deps-graph.sh" --team "$t" >"$tmpdir/deps.raw.$t.json" 2>"$tmpdir/deps.err.$t" &
  deps_pids[$i]=$!
done

# Wait for every team's pair of fetches, tolerating per-team failure: a team whose issue
# fetch or deps fetch fails (after fetch_team_issues' own retries) is excluded from the
# merge with a warning. Failure is fatal only when the team was explicitly requested, or
# when every team failed — a discovered team's transient rate-limit must not zero the run.
ok_teams=()
failed_teams=()
for i in "${!teams[@]}"; do
  t="${teams[$i]}"
  team_ok=1
  wait "${list_pids[$i]}" || { team_ok=0; echo "WARNING: team-issue fetch (team $t) failed after retries" >&2; }
  if ! wait "${deps_pids[$i]}"; then
    team_ok=0
    echo "WARNING: linear-deps-graph.sh (team $t) failed:" >&2
    cat "$tmpdir/deps.err.$t" >&2
  fi
  if [ "$team_ok" = 1 ]; then
    ok_teams+=("$t")
  else
    failed_teams+=("$t")
  fi
done
if [ "${#failed_teams[@]}" -gt 0 ]; then
  if [ "$teams_explicit" = 1 ] || [ "${#ok_teams[@]}" -eq 0 ]; then
    echo "ERROR: team fetch failed for: ${failed_teams[*]} (auth? network? rate limit?)" >&2
    exit 2
  fi
  echo "WARNING: results exclude team(s): ${failed_teams[*]} — partial workspace ranking" >&2
fi

# Merge per-team results and normalize into the pipeline shapes (team order = ranking-input
# order; the tier sort downstream is what actually orders candidates).
#   list  → one array (already normalized by fetch_team_issues)
#   deps  → {nodes:[{identifier, state:<name>}], edges:[{from,to,type}]}
list_parts=()
deps_parts=()
for t in "${ok_teams[@]}"; do
  list_parts+=("$tmpdir/list.$t.json")
  deps_parts+=("$tmpdir/deps.raw.$t.json")
done
jq -s 'add' "${list_parts[@]}" > "$list_file"
jq -s '{nodes: [ .[] | (.nodes // [])[] | {identifier, state: (.state.name // .state // "?")} ],
        edges: [ .[] | (.edges // [])[] ]}' "${deps_parts[@]}" >"$deps_file"

# ---------- my email ----------

me_email=$(linear-cli api query -q -o json 'query{viewer{email}}' 2>/dev/null | jq -r '.data.viewer.email // empty' || true)

# ---------- jq pipeline: workable filter + tiering ----------

# State sets — keep terminal states defensive across teams. Terminal matching is
# case-insensitive: workspaces vary the casing (BF's state is "Ready for Release"),
# and an exact match silently treats a shipped blocker as unresolved forever.
# "In Review" is terminal by keeper ruling (2026-08-21): the work is done and awaiting human
# review, so it resolves blocks — a kick-back moves the issue out of the state, reinstating them.
# It sits here by NAME because Linear registers the state as type `started` and a state's type
# cannot be changed after creation (WorkflowStateUpdateInput carries no `type` field).
TERMINAL_STATES='["Done","Canceled","Cancelled","Duplicate","Ready For Release","In Review"]'
# Triage (Linear's `type: "triage"` state) is deliberately NOT workable: it's the unreviewed-inbox
# bucket, so an issue there hasn't been accepted for work yet and must never be surfaced as "next".
# (Parent epics can still be in Triage — the parent-weight scale below keeps handling that; this
# exclusion is about a candidate's OWN state.) --include-triage is the one escape hatch: /spec's
# grooming pick-list targets exactly that inbox. Matched by STATE TYPE, not name, below — a team
# that renamed its triage state (e.g. "Inbox") still gets excluded/included correctly.
WORKABLE_STATES='["Backlog","Planned","Todo"]'

# The derived maps live on disk and reach jq via --slurpfile, not --argjson: the fetch
# layer already avoids argv for the issue list (ARG_MAX), and a workspace-wide multi-team
# run makes these maps scale the same way.

# Build a canonical state map from BOTH the deps graph (covers blockers that
# may live outside the workable list) and the team list (richer fields). The
# fetch step above normalized `state` to a name string in both files, so no
# object/string coercion is needed here — but `linear-cli issues get` returns
# {name,...} so we coerce in the parent walk later.
state_map_file="$tmpdir/state_map.json"
jq -s '
  (.[0].nodes // []) as $nodes
  | (.[1] // []) as $issues
  | ($nodes | map({key: .identifier, value: .state}))
    + ($issues | map({key: .identifier, value: .state}))
  | from_entries
' "$deps_file" "$list_file" > "$state_map_file"

# Blocker map: to_id -> [from_ids] where edge.type == "blocks".
blocker_map_file="$tmpdir/blocker_map.json"
jq '
  (.edges // [])
  | map(select(.type == "blocks"))
  | group_by(.to)
  | map({key: .[0].to, value: (map(.from) | unique)})
  | from_entries
' "$deps_file" > "$blocker_map_file"

# Reverse map: from_id -> [to_ids] (for transitive unblocking BFS).
reverse_blocker_map_file="$tmpdir/reverse_blocker_map.json"
jq '
  (.edges // [])
  | map(select(.type == "blocks"))
  | group_by(.from)
  | map({key: .[0].from, value: (map(.to) | unique)})
  | from_entries
' "$deps_file" > "$reverse_blocker_map_file"

# ---------- transitive unblocking (BFS) ----------

newly_unblocked_file="$tmpdir/newly_unblocked.json"
if [ -n "$completed" ]; then
  jq -n \
    --arg root "$completed" \
    --slurpfile rev_doc "$reverse_blocker_map_file" \
    --slurpfile sm_doc "$state_map_file" \
    --argjson terminal "$TERMINAL_STATES" '
      ($rev_doc[0]) as $rev
    | ($sm_doc[0]) as $sm
    |
      # Transitive reachability walk (BFS) from the completed issue over the reverse-blocker
      # map — it visits every descendant, not just newly-unblocked ones. The final filter
      # below drops nodes already in a terminal state; whether a candidate is actually
      # unblocked is enforced downstream, by the $unresolved blocker check in the
      # candidate-select stage.
      def bfs($frontier; $visited):
        if ($frontier | length) == 0 then $visited
        else
          ($frontier | map($rev[.] // []) | add // []) as $next
          | ($next | unique) as $candidates
          | ($candidates | map(select(($visited | index(.)) == null))) as $fresh
          | bfs($fresh; ($visited + $fresh) | unique)
        end;
      [bfs([$root]; []) | .[] | select(. != $root)]
      | map(select(($sm[.] // "Unknown") as $s | (($terminal | map(ascii_downcase)) | index($s | ascii_downcase)) == null))
    ' > "$newly_unblocked_file"
else
  printf '[]' > "$newly_unblocked_file"
fi

# ---------- candidate set ----------

# Keeper gate: `keeper`-labeled issues are /reflect filings that edit the SHARED user-level
# ~/.claude repo — that work belongs to the machine whose clone the keeper reviews and pushes
# from (one-time setup: git -C ~/.claude config reflect.keeper true). On every other machine
# they are excluded from the pool entirely (an /auto pull there would ship global-config edits
# outside the keeper's review flow), with a trailing note so the hiding is never silent.
is_keeper=$(git -C "$HOME/.claude" config --get reflect.keeper 2>/dev/null || true)

# Every issue that passes the state, claim, label, and gate-label filters — blocked or not — with
# its per-candidate ranking metadata. The blocker filter is applied afterwards, so the Planned gate
# below can classify a blocked Planned issue by its chain.
eligible_json=$(jq \
  --argjson workable "$WORKABLE_STATES" \
  --argjson terminal "$TERMINAL_STATES" \
  --slurpfile sm_doc "$state_map_file" \
  --slurpfile bm_doc "$blocker_map_file" \
  --slurpfile rbm_doc "$reverse_blocker_map_file" \
  --slurpfile newly_doc "$newly_unblocked_file" \
  --arg me "${me_email:-}" \
  --arg label "$label" \
  --arg xlabel "$exclude_label" \
  --arg triage "$include_triage" \
  --arg blocked "$include_blocked" \
  --arg claimed "$include_claimed" \
  --arg iskeeper "$is_keeper" '
    ($sm_doc[0]) as $sm
    | ($bm_doc[0]) as $bm
    | ($rbm_doc[0]) as $rbm
    | ($newly_doc[0]) as $newly
    # Stage by identifier for the inherited-stage walk: the fetch carries every non-terminal
    # team issue, so a Planned dependent is present whether or not it is itself a candidate.
    | (map({key: .identifier, value: {t: .state_type, s: .state}}) | from_entries) as $stage
    | (map({key: .identifier, value: .parent}) | from_entries) as $parent_of
    # Hot parents: a sibling In Progress/In Review under the same parent means a live
    # session is likely editing nearby files — feeds the soft spread de-rank below.
    | ([ .[] | select(.state_type == "started" and (.parent != null)) | .parent ] | unique) as $hot
    | def priority_label(p):
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
    def is_terminal($x): ((($terminal | map(ascii_downcase)) | index((($sm[$x] // "Unknown") | ascii_downcase))) != null);
    def is_unstarted_id($x): (($stage[$x].t == "unstarted") or ((($stage[$x].s // "") | ascii_downcase) | IN("planned", "todo")));
    # Everything reachable DOWN the blocks graph from the frontier through non-terminal issues —
    # the work those issues gate. A terminal node neither counts nor propagates: a chain through
    # a shipped issue gates nothing. $seen guards cycles.
    def gated($frontier; $seen):
      ([ $frontier[] | ($rbm[.] // [])[] ] | unique
       | map(select(. as $x | (($seen | index($x)) == null) and (is_terminal($x) | not)))) as $next
      | if ($next | length) == 0 then $seen else gated($next; $seen + $next) end;
    # Every ancestor UP the parent chain within the fetched pool — a child gates its epic the way a
    # blocker gates its dependent, so it inherits the same stage. Depth-capped like the parent walk.
    def lineage($x; $seen): ($parent_of[$x] // null) as $p
      | if ($p == null) or (($seen | index($p)) != null) or (($seen | length) > 10) then []
        else [$p] + lineage($p; $seen + [$p]) end;
    map(
      . as $i
      | (.identifier) as $id
      | ($bm[$id] // []) as $blockers
      | ($blockers | map(select(($sm[.] // "Unknown") as $s | (($terminal | map(ascii_downcase)) | index($s | ascii_downcase)) == null))) as $unresolved
      | select((($workable | index($i.state)) != null) or (($triage == "1") and ($i.state_type == "triage")))
      # Assignment is a claim (standards/linear-workflow.md): an assignee means a person has
      # claimed the work or is investigating it, so an issue assigned to anyone ELSE is never
      # a candidate — for certifying or for working. Assigned-to-me stays (that is tier 1),
      # and with the viewer unresolvable every assigned issue reads as claimed by a person
      # and hides, which fails toward respecting the claim.
      | select(($claimed == "1") or (($i.assignee // "") == "") or (($me != "") and ($i.assignee == $me)))
      # any() over an empty label array is false and all() is true, so unlabeled issues
      # correctly fail a --label requirement and pass an --exclude-label one.
      | select(($label == "") or (any(($i.labels // [])[]; ascii_downcase == ($label | ascii_downcase))))
      | select(($xlabel == "") or (all(($i.labels // [])[]; ascii_downcase != ($xlabel | ascii_downcase))))
      | select(($iskeeper == "true") or (all(($i.labels // [])[]; ascii_downcase != "keeper")))
      # needs-decision gate: a human must step in first (standards/issue-spec.md) —
      # hidden from every ranking unless the caller asked for this label itself, or for
      # the human label (both listings are human-facing discovery views and an issue can
      # carry both labels — hiding one from the other would recreate the count-vs-listing
      # confusion the trailing notes exist to prevent).
      | select((($label | ascii_downcase) | . == "needs decision" or . == "human") or (all(($i.labels // [])[]; ascii_downcase != "needs decision")))
      # solo gate: shippable unattended but not concurrently (standards/issue-spec.md) —
      # same hide-unless-asked-for contract, so no ranking ever hands one to a fleet.
      # It also yields to a `needs decision` or `human` listing: an issue can carry both
      # labels (a durable decline in /auto labels whatever it declined, solo included),
      # and those listings are how /spec and a human owner find parked work — no
      # apostrophes in here, the jq program is one single-quoted string and one would end
      # it mid-filter.
      | select((($label | ascii_downcase) | . == "solo" or . == "needs decision" or . == "human") or (all(($i.labels // [])[]; ascii_downcase != "solo")))
      # human gate: the work itself is human-performed (standards/issue-spec.md) — no agent
      # path exists at any time, so it is hidden from every ranking and never offered to
      # /auto in any mode. Yields to its own listing and to a needs-decision listing, but
      # NOT to a solo listing — that one is a running order for targeted /auto, and a
      # human-labeled issue must never appear runnable there.
      | select((($label | ascii_downcase) | . == "human" or . == "needs decision") or (all(($i.labels // [])[]; ascii_downcase != "human")))
      # epic gate: a delegated container — its children carry the work — so it is never a pick
      # (fleet-blockers.sh / fleet-forecast.py agree); the delegated de-rank below still covers
      # an unlabeled parent. Listed only by --label epic.
      | select((($label | ascii_downcase) == "epic") or (all(($i.labels // [])[]; ascii_downcase != "epic")))
      # Planned/Todo issues this Backlog candidate gates — transitively blocks, or descends from —
      # non-empty means it inherits the Planned stage below. Computed for Backlog candidates only;
      # a Planned or Triage candidate has nothing to inherit.
      | (if ($i.state_type == "backlog") or (($i.state // "") | ascii_downcase) == "backlog"
         then ([ (gated([$id]; [$id])[] | select(. != $id)), (lineage($id; [$id])[]) ]
               | map(select(is_unstarted_id(.))) | unique)
         else [] end) as $gates_unstarted
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
          newly_unblocked: (($newly | index($id)) != null),
          unresolved_count: ($unresolved | length),
          is_reflection: ((($i.labels // []) | map(ascii_downcase)) as $ls
            | (($ls | index("specified")) != null and ($ls | index("reflection")) != null)),
          is_keeper: (((($i.labels // []) | map(ascii_downcase)) | index("keeper")) != null),
          # Urgent — and only Urgent — pierces the class ordering below WITHIN a stage: it is
          # a rare, deliberate human "drop everything" escalation, and a bulk-applied category
          # label must not overrule it (BF-583). It does NOT pierce workflow stage — see
          # state_rank, which sorts ahead of it (keeper decision 2026-08-05, narrowing the
          # BF-583 pierce-everything rule: an Urgent Backlog issue is still deferred work).
          urgent_first: (if $i.priority == 1 then 0 else 1 end),
          # Stage is the senior signal, and it is a STRICT three-way order (keeper decision
          # 2026-08-13, superseding the 2026-08-05 decision that deliberately left Triage at
          # 0): Planned/Todo drains fully, then Backlog, and the Triage inbox ranks last —
          # measured cost of the old tie: under --include-triage a prioritized inbox report
          # (BF-34, Urgent) outranked every unprioritized Planned issue and /spec recommended
          # certifying Triage over the Planned queue the keeper is draining. Stage outranks
          # class AND priority, Urgent included (bouncing work to Backlog has to actually
          # defer it; an unreviewed inbox item has not even been accepted for work). Backlog
          # is keyed on state TYPE with a name fallback for a team that renamed the state
          # without changing its type; Triage needs no name fallback — its only admission
          # path (--include-triage) is already type-keyed. A Backlog issue that transitively
          # blocks Planned/Todo work inherits stage 0 — release scope by implication (keeper
          # ruling 2026-08-13, standards/linear-workflow.md § Stage Priorities): the fleet must
          # reach it before any deferred Backlog work whether or not its column was promoted.
          # NO apostrophes in this comment block: it lives inside the single-quoted jq program,
          # and one ends the shell string mid-script.
          state_rank: (if ($i.state_type == "triage") then 2
            elif ($i.state_type == "backlog") or (($i.state // "") | ascii_downcase) == "backlog"
              then (if ($gates_unstarted | length) > 0 then 0 else 1 end)
            else 0 end),
          # Unstarted stage is never hidden by the --limit render cut (keeper policy
          # 2026-08-12 — below-cut Planned/Todo candidates emit in a trailing section);
          # matched like state_rank — by type, with a name fallback for a renamed state — and
          # an inherited-stage blocker is surfaced there too, since it is part of that queue.
          is_unstarted: (($i.state_type == "unstarted") or ((($i.state // "") | ascii_downcase) | IN("planned", "todo"))
            or (($gates_unstarted | length) > 0)),
          gates_unstarted: $gates_unstarted,
          class_rank: ((($i.labels // []) | map(ascii_downcase)) as $ls
            | if ($ls | index("security")) != null then 0
              elif ($ls | index("bug")) != null then 1
              else 2 end),
          spread_penalty: (if ($i.parent != null) and (($hot | index($i.parent)) != null) then 1 else 0 end)
        }
    )
  ' "$list_file")

candidates_json=$(printf '%s' "$eligible_json" | jq --arg blocked "$include_blocked" \
  'map(select(($blocked == "1") or (.unresolved_count == 0)))')

# ---------- Planned gate: no Backlog usage while the Planned/Todo column is not drained ----------
#
# A FILTER, not an ordering (see the header): while the column holds anything not claimed by another
# person, Backlog candidates (state_rank 1 — inherited-stage issues keep rank 0 and stay) are withheld,
# and the PLANNED-HOLD note classifies every held issue as pickable now, releasing on its own (every
# unresolved blocker in its chain is in flight or fleet-eligible), or the keeper's (a gate label, an
# epic, uncertified under the label filter, or a chain through such a blocker). The claimed-by-another
# carve-out is the only one — that work is neither the fleet's nor the keeper's to drain.
label_lc=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')
gate_on=0
if [ "$stage_gate" -eq 1 ] && [ "$include_blocked" -eq 0 ] && [ "$include_triage" -eq 0 ] \
   && [ "$label_lc" != "solo" ] && [ "$label_lc" != "needs decision" ] && [ "$label_lc" != "human" ]; then
  gate_on=1
fi
gate_closed=0
withheld=0
hold_line=""
# Eligible-issue map (id → unresolved blocker count): the Planned gate and the blocked note below both
# classify a hidden issue by walking its blocker chain through it.
eligible_map_file="$tmpdir/eligible_map.json"
printf '%s' "$eligible_json" | jq -c 'map({key: .id, value: .unresolved_count}) | from_entries' > "$eligible_map_file"
# jq defs shared by both classifiers, spliced into their single-quoted programs — so no apostrophe may
# appear in here. Names the caller binds first: $sm state map, $bm blocker map, $el eligible map, $m the
# fetched list by identifier, $terminal, $me, $label, $iskeeper.
CHAIN_DEFS='def is_terminal($x): ((($terminal | map(ascii_downcase)) | index((($sm[$x] // "Unknown") | ascii_downcase))) != null);
      def claimed_other($i): ((($i.assignee // "") != "") and (($me == "") or ($i.assignee != $me)));
      def unstarted($i): (($i.state_type == "unstarted") or ((($i.state // "") | ascii_downcase) | IN("planned", "todo")));
      def lbl($i; $n): (any(($i.labels // [])[]; ascii_downcase == $n));
      # Why a held issue is the keeper to move — empty when the fleet could pick it (now or once unblocked).
      def self_reason($i):
        if lbl($i; "epic") then "epic — certify per child, close it when they release"
        elif lbl($i; "needs decision") then "needs decision"
        elif lbl($i; "human") then "human"
        elif lbl($i; "solo") then "solo"
        elif (($iskeeper != "true") and lbl($i; "keeper")) then "keeper-gated"
        elif ($el[$i.identifier] == null) then (if ($label != "") then "lacks label \($label)" else "filtered out" end)
        else "" end;
      # Walk the unresolved blocker chain: a blocker in flight (started, not stalled) or fleet-eligible
      # releases on its own; the first keeper-owned one names the reason. $seen guards cycles.
      def chain_reason($ids; $seen):
        if ($ids | length) == 0 then ""
        else ($ids[0]) as $b | ($m[$b] // null) as $bi
          | (if (($seen | index($b)) != null) or is_terminal($b) then ""
             elif $bi == null then "blocked by \($b) (outside the fetched teams)"
             elif ($bi.state_type == "started") then (if lbl($bi; "stalled") then "blocked by \($b) [stalled]" else "" end)
             elif ($el[$b] != null) and (lbl($bi; "epic") | not) then chain_reason(($bm[$b] // []); $seen + [$b])
             else "blocked by \($b) [\(self_reason($bi) | if . == "" then ($bi.state // "?") else . end)]" end) as $r
          | if $r != "" then $r else chain_reason($ids[1:]; $seen + [$b]) end
        end;
'
if [ "$gate_on" -eq 1 ]; then
  pickable_file="$tmpdir/pickable.json"
  printf '%s' "$candidates_json" | jq -c 'map(.id)' > "$pickable_file"
  held_json=$(jq -c \
    --argjson terminal "$TERMINAL_STATES" \
    --slurpfile sm_doc "$state_map_file" \
    --slurpfile bm_doc "$blocker_map_file" \
    --slurpfile el_doc "$eligible_map_file" \
    --slurpfile pk_doc "$pickable_file" \
    --arg me "${me_email:-}" --arg claimed "$include_claimed" --arg label "$label" --arg iskeeper "$is_keeper" '
    ($sm_doc[0]) as $sm | ($bm_doc[0]) as $bm | ($el_doc[0]) as $el | ($pk_doc[0]) as $pk
    | (map({key: .identifier, value: .}) | from_entries) as $m
    | '"$CHAIN_DEFS"'
      [ .[] | select(unstarted(.)) | select(($claimed == "1") or (claimed_other(.) | not)) | . as $i
        | self_reason($i) as $sr
        # $i.identifier throughout: inside `$pk | index(…)` the pipe rebinds `.` to the array.
        | (if $sr != "" then {id: $i.identifier, kind: "keeper", reason: $sr}
           elif (($pk | index($i.identifier)) != null) then {id: $i.identifier, kind: "pickable", reason: ""}
           else (chain_reason(($bm[$i.identifier] // []); [$i.identifier])) as $cr
             | (if $cr == "" then {id: $i.identifier, kind: "releasing", reason: ""}
                else {id: $i.identifier, kind: "keeper", reason: $cr} end)
           end) ]
  ' "$list_file")
  if [ "$(printf '%s' "$held_json" | jq 'length')" -gt 0 ]; then
    gate_closed=1
    withheld=$(printf '%s' "$candidates_json" | jq '[.[] | select(.state_rank == 1)] | length')
    candidates_json=$(printf '%s' "$candidates_json" | jq 'map(select(.state_rank != 1))')
    hold_line=$(printf '%s' "$held_json" | jq -r --argjson w "$withheld" '
      ([.[] | select(.kind == "pickable")] | length) as $p
      | [.[] | select(.kind == "releasing") | .id] as $r
      | [.[] | select(.kind == "keeper") | "\(.id) [\(.reason)]"] as $k
      | "_PLANNED-HOLD: Backlog withheld — the Planned/Todo column is not drained (\(length) issue(s) hold the gate: \($p) pickable now"
        + (if ($r | length) > 0 then "; \($r | length) will release on their own — \($r | join(", "))" else "" end)
        + (if ($k | length) > 0 then "; \($k | length) need the keeper — \($k | join(", "))" else "" end)
        + "). \($w) Backlog candidate(s) wait behind the gate; it opens when the column drains — pass --no-stage-gate to list them._"')
  fi
fi
hold_note() {
  [ "$gate_closed" -eq 1 ] && printf '\n%s\n' "$hold_line"
  return 0
}

# Count what the keeper gate hid (from the fetched list, pre-filter) so the exclusion is
# visible on every output path — a silently thinner list reads as "nothing there".
keeper_hidden=0
if [ "$is_keeper" != "true" ]; then
  keeper_hidden=$(jq '[.[] | select(any((.labels // [])[]; ascii_downcase == "keeper"))] | length' "$list_file" 2>/dev/null || echo 0)
fi
keeper_note() {
  [ "$keeper_hidden" -gt 0 ] && printf '\n_%s keeper-gated improvement(s) hidden — this machine is not the ~/.claude keeper. Run /keeper to propose your own filings upstream as a PR._\n' "$keeper_hidden"
  return 0
}

# Same visibility contract for the needs-decision gate. The footer names the top hidden
# IDs (priority-ordered) — a bare count buries identity, and the /spec pick-mode roster
# reads this output, so the parked issues must be identifiable without a second invocation.
nd_hidden=0
nd_top=""
if [ "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" != "needs decision" ]; then
  nd_hidden=$(jq '[.[] | select(any((.labels // [])[]; ascii_downcase == "needs decision"))] | length' "$list_file" 2>/dev/null || echo 0)
  nd_top=$(jq -r '[.[] | select(any((.labels // [])[]; ascii_downcase == "needs decision"))]
    | sort_by(if .priority == 0 then 5 else .priority end) | .[0:4] | map(.identifier) | join(", ")' "$list_file" 2>/dev/null || true)
fi
nd_note() {
  if [ "$nd_hidden" -gt 0 ]; then
    printf '\n_%s issue(s) hidden awaiting a human decision (`needs decision` label; top: %s) — list with --label "needs decision", resolve via /spec <ID> or by deciding and removing the label._\n' "$nd_hidden" "$nd_top"
  fi
  return 0
}

# Same visibility contract for the claimed gate. Counted over workable-stage issues only
# (plus Triage when included) — unlike the label notes, which span every fetched state:
# nearly every In Progress issue is assigned, so an all-states count would drown the signal.
claimed_hidden=0
if [ "$include_claimed" != "1" ]; then
  claimed_hidden=$(jq --arg me "${me_email:-}" --arg triage "$include_triage" '
    [.[] | . as $i
     | select(((["Backlog","Planned","Todo"] | index($i.state)) != null) or (($triage == "1") and ($i.state_type == "triage")))
     | select((($i.assignee // "") != "") and ($i.assignee != $me))] | length' "$list_file" 2>/dev/null || echo 0)
fi
claimed_note() {
  [ "$claimed_hidden" -gt 0 ] && printf '\n_%s issue(s) hidden as claimed by a person (assignee set — claimed or under investigation, standards/linear-workflow.md); pass --include-claimed to list them._\n' "$claimed_hidden"
  return 0
}

# Same visibility contract for the solo gate.
solo_hidden=0
if [ "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" != "solo" ]; then
  solo_hidden=$(jq '[.[] | select(any((.labels // [])[]; ascii_downcase == "solo"))] | length' "$list_file" 2>/dev/null || echo 0)
fi
solo_note() {
  [ "$solo_hidden" -gt 0 ] && printf '\n_%s issue(s) hidden as fleet-hostile (`solo` label) — list with --label solo, ship one at a time via /auto <ID> or /full <ID> while no fleet is running._\n' "$solo_hidden"
  return 0
}

# Same visibility contract for the human gate.
human_hidden=0
if [ "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" != "human" ]; then
  human_hidden=$(jq '[.[] | select(any((.labels // [])[]; ascii_downcase == "human"))] | length' "$list_file" 2>/dev/null || echo 0)
fi
human_note() {
  [ "$human_hidden" -gt 0 ] && printf '\n_%s issue(s) hidden as human-owned work (`human` label) — list with --label human; agents never work these, in any mode._\n' "$human_hidden"
  return 0
}

# Epic gate note — counted over workable stages only, like the claimed note (a shipped or in-flight
# epic is not what the reader is missing from a pick list).
epic_hidden=0
if [ "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" != "epic" ]; then
  epic_hidden=$(jq '[.[] | . as $i | select((["Backlog","Planned","Todo"] | index($i.state)) != null) | select(any(($i.labels // [])[]; ascii_downcase == "epic"))] | length' "$list_file" 2>/dev/null || echo 0)
fi
epic_note() {
  [ "$epic_hidden" -gt 0 ] && printf '\n_%s issue(s) hidden as delegated epics (`epic` label — the children carry the work; certify per child, close the epic when they release) — list with --label epic._\n' "$epic_hidden"
  return 0
}

candidate_count=$(printf '%s' "$candidates_json" | jq 'length')

# ---------- Blocked note: the last silent exclusion (see the header) ----------
#
# Every eligible issue with an unresolved blocker, classified by the chain walk the Planned gate uses.
# Suppressed under --include-blocked (the listing shows them) and under a closed Planned gate (the
# PLANNED-HOLD note is the one hold the caller waits on; a second hold headline would fight it).
# BLOCKED-HOLD — the wait headline — needs an empty pick list AND at least one releasing issue: a pool
# blocked only behind keeper-owned work is genuinely drained for the fleet, and says so.
blocked_hidden=0
blocked_releasing=0
blocked_hold=0
blocked_line=""
if [ "$include_blocked" -eq 0 ] && [ "$gate_closed" -eq 0 ]; then
  blocked_json=$(jq -c \
    --argjson terminal "$TERMINAL_STATES" \
    --slurpfile sm_doc "$state_map_file" \
    --slurpfile bm_doc "$blocker_map_file" \
    --slurpfile el_doc "$eligible_map_file" \
    --arg me "${me_email:-}" --arg label "$label" --arg iskeeper "$is_keeper" '
    ($sm_doc[0]) as $sm | ($bm_doc[0]) as $bm | ($el_doc[0]) as $el
    | (map({key: .identifier, value: .}) | from_entries) as $m
    | '"$CHAIN_DEFS"'
      [ .[] | select(($el[.identifier] // 0) > 0) | . as $i
        | (chain_reason(($bm[$i.identifier] // []); [$i.identifier])) as $cr
        # The direct open blockers, each with its state, so a releasing entry says what it waits on.
        | (($bm[$i.identifier] // []) | map(select(is_terminal(.) | not)) | map("\(.) [\($sm[.] // "?")]") | join(", ")) as $on
        | (if $cr == "" then {id: $i.identifier, kind: "releasing", reason: $on}
           else {id: $i.identifier, kind: "keeper", reason: $cr} end) ]
      | sort_by(.id)
  ' "$list_file")
  blocked_hidden=$(printf '%s' "$blocked_json" | jq 'length')
  blocked_releasing=$(printf '%s' "$blocked_json" | jq '[.[] | select(.kind == "releasing")] | length')
  if [ "$candidate_count" -eq 0 ] && [ "$blocked_releasing" -gt 0 ]; then
    blocked_hold=1
  fi
  if [ "$blocked_hidden" -gt 0 ]; then
    blocked_line=$(printf '%s' "$blocked_json" | jq -r --arg hold "$blocked_hold" '
      [.[] | select(.kind == "releasing") | "\(.id) behind \(.reason)"] as $r
      | [.[] | select(.kind == "keeper") | "\(.id) [\(.reason)]"] as $k
      | ([ (if ($r | length) > 0 then "\($r | length) will release on their own (\($r | join(", ")))" else empty end),
           (if ($k | length) > 0 then "\($k | length) need the keeper (\($k | join(", ")))" else empty end) ] | join("; ")) as $clauses
      | "_" + (if $hold == "1" then "BLOCKED-HOLD: " else "" end)
        + "\(length) issue(s) hidden behind unresolved blockers — \($clauses). Pass --include-blocked to list them._"')
  fi
fi
blocked_note() {
  [ -n "$blocked_line" ] && printf '\n%s\n' "$blocked_line"
  return 0
}

if [ "$candidate_count" -eq 0 ]; then
  filter_desc=""
  [ -n "$label" ] && filter_desc=" with label '$label'"
  [ -n "$exclude_label" ] && filter_desc="$filter_desc lacking label '$exclude_label'"
  team_word="team"
  [ ${#teams[@]} -gt 1 ] && team_word="teams"
  if [ "$gate_closed" -eq 1 ]; then
    # Deliberately not the drained text: /auto keys on this headline to wait instead of latching drained.
    printf '## Suggested next\n\n_Nothing pickable right now%s in %s %s — the Planned/Todo column is not drained, so Backlog is withheld (PLANNED-HOLD below). Wait for a release or act on the held issues; do not pick Backlog._\n' "$filter_desc" "$team_word" "$teams_label"
  elif [ "$blocked_hold" -eq 1 ]; then
    # Same contract as the Planned hold: chained behind in-flight work is not drained, and the note names the chain.
    printf '## Suggested next\n\n_Nothing pickable right now%s in %s %s — every remaining candidate waits behind an unresolved blocker, and %s will release on their own (BLOCKED-HOLD below). Wait for a sibling to ship; do not latch drained._\n' "$filter_desc" "$team_word" "$teams_label" "$blocked_releasing"
  else
    printf '## Suggested next\n\n_No workable issues%s in %s %s._\n' "$filter_desc" "$team_word" "$teams_label"
  fi
  hold_note
  blocked_note
  keeper_note
  nd_note
  claimed_note
  solo_note
  human_note
  epic_note
  exit 0
fi

# ---------- pre-rank into tiers (parent-agnostic) ----------

# Tier assignment (without parent data yet — tier 3 deferred to step 7).
# Tier 0: certified reflection improvement (`specified` + `reflection` labels, /reflect's
#         filings) — config/process fixes change how every later issue runs, so they ship
#         ahead of the work they improve
# Tier 1: assigned to me + workable
# Tier 2: newly unblocked + no open blockers
# Tier 4: anything else workable (tier 3 reassignment happens post-parent-walk)
#
# The unresolved_count==0 guard on tier 2 matters only under --include-blocked (a no-op
# otherwise, since the candidate select above already requires it): newly_unblocked marks
# descendants of the completed issue in the blocks-graph, not "fully unblocked" — a candidate
# can be newly_unblocked and still have another, unrelated open blocker.
#
# Most candidates land in tier 4, so the within-tier order below is what actually ranks the
# pool: state_rank (Planned/Todo 0 drains fully before Backlog 1 — Urgent included) >
# urgent_first > class_rank (security 0 > bug 1 > other 2 — defects ship before improvements,
# but within a stage) > priority > spread_penalty (sibling in flight under the same parent) >
# estimate.
ranked_json=$(printf '%s' "$candidates_json" | jq --arg iskeeper "$is_keeper" '
  map(
    . + {
      tier: (
        if .is_reflection then 0
        elif (.is_keeper and $iskeeper == "true") then 0
        elif .is_me then 1
        elif (.newly_unblocked and .unresolved_count == 0) then 2
        else 4
        end
      )
    }
    # keeper_rank orders WITHIN tier 0 only: keeper reflection edits the shared user-level
    # ~/.claude (every project benefits, and only the keeper machine can ship it — everywhere
    # else the pool excludes it), so it front-runs project-level reflection filings.
    #
    # A keeper batch reaches tier 0 on its `keeper` label alone, NOT via is_reflection: it files
    # uncertified (`keeper` instead of `specified`, so /auto skips it — BF-591), and is_reflection
    # requires both `specified` and `reflection`. Gating tier 0 on is_reflection alone left every
    # real keeper filing in tier 4 with keeper_rank 1 — below the filings it was meant to outrank.
    | . + { keeper_rank: (if .tier == 0 and .is_keeper then 0 else 1 end) }
  )
  | sort_by([.tier, .keeper_rank, .state_rank, .urgent_first, .class_rank, .priority_rank, .spread_penalty, .estimate])
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
  # delegated_json: id -> {total, workable, open} child counts, from the same fetched
  # payload (zero extra API calls). A candidate with children but no workable child has
  # no independent work of its own (BF-504) — de-ranked below everything in the re-sort.
  delegated_json="{}"

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ ! -s "$fetch_dir/$id.json" ]; then continue; fi
    kid_info=$(jq -c --argjson workable "$WORKABLE_STATES" --argjson terminal "$TERMINAL_STATES" '
      [(.children.nodes // [])[] | (.state.name // .state // "?")] as $ks
      | {total: ($ks | length),
         workable: ([ $ks[] | select(. as $s | ($workable | index($s)) != null) ] | length),
         open: ([ $ks[] | select(. as $s | (($terminal | map(ascii_downcase)) | index($s | ascii_downcase)) == null) ] | length)}
    ' "$fetch_dir/$id.json" 2>/dev/null) || kid_info='{"total":0,"workable":0,"open":0}'
    delegated_json=$(jq -c --arg id "$id" --argjson v "$kid_info" '. + {($id): $v}' <<< "$delegated_json")
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

  # Step 3: apply parent weight + tier 3 (sibling under completed parent).
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
    --argjson del "$delegated_json" \
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
        # Tier 3: sibling under the completed issue'\''s parent.
        | (if ($completed != "")
              and ($completed_parent_id != "")
              and ($direct_parent != null)
              and ($direct_parent.identifier == $completed_parent_id)
            then 3 else null end) as $sibling_tier
        | ($del[$c.id] // null) as $kids
        | . + {
            parent_chain: $chain,
            parent_root: $root,
            parent_direct: $direct_parent,
            parent_weight: $pw,
            tier: (if $sibling_tier != null and .tier > 3 then $sibling_tier else .tier end),
            delegated_penalty: (if $kids != null and $kids.total > 0 and $kids.workable == 0 then 1 else 0 end),
            delegated_open: (if $kids != null then $kids.open else 0 end)
          }
      )
      | sort_by([.delegated_penalty, .tier, .keeper_rank, .state_rank, .urgent_first, .class_rank, .priority_rank, .spread_penalty,
                 .parent_weight, .estimate])
    ')
fi

# ---------- emit markdown ----------

printf '## Suggested next\n\n'
printf '%s' "$ranked_json" | jq -r --argjson lim "$limit" '
  def tier_reason(c):
    if c.tier == 0 then
      (if c.keeper_rank == 0
        then "certified keeper reflection improvement — shared ~/.claude config; only this machine can ship it"
        else "certified reflection improvement — affects how future work runs" end)
    elif c.tier == 1 then "assigned to you"
    elif c.tier == 2 then "newly unblocked"
    elif c.tier == 3 then "sibling under completed parent"
    else "highest-priority workable"
    end;
  .[0:$lim] | to_entries | .[] |
    "\(.key + 1). **\(.value.id)** — \"\(.value.title)\"" +
    "\n   - State: \(.value.state)" +
    " | Priority: \(.value.priority_label)" +
    (if .value.class_rank == 0 then " | security" elif .value.class_rank == 1 then " | bug" else "" end) +
    (if .value.estimate != null and .value.estimate != 0 then " | Estimate: \(.value.estimate)" else "" end) +
    (if .value.is_me then " | _assigned to you_" else "" end) +
    (if .value.parent_direct then
      "\n   - Parent: **\(.value.parent_direct.identifier)** \"\(.value.parent_direct.title)\" _(\(.value.parent_direct.state))_"
      + (if .value.parent_root and .value.parent_root.identifier != .value.parent_direct.identifier then
          " · Epic: **\(.value.parent_root.identifier)** _(\(.value.parent_root.state))_"
        else "" end)
    else "" end) +
    "\n   - Tier \(.value.tier): \(tier_reason(.value))" +
    (if (.value.delegated_penalty // 0) > 0 then
      (if (.value.delegated_open // 0) > 0
        then "\n   - Delegated: \(.value.delegated_open) open sub-issue(s) carry the work — de-ranked, no independent work of its own"
        else "\n   - Delegated: all sub-issues shipped/terminal — de-ranked; the epic likely needs closing, not implementation" end)
    else "" end) +
    (if (.value.spread_penalty // 0) > 0 then "\n   - Spread: a sibling under the same parent is in flight — soft de-rank to reduce file collisions" else "" end) +
    (if ((.value.gates_unstarted // []) | length) > 0 then "\n   - Stage inherited: Backlog, but it gates Planned/Todo \(.value.gates_unstarted | join(", ")) (as blocker or child) — release scope by implication, ranked in the Planned stage" else "" end) +
    (if .value.unresolved_count > 0 then "\n   - Blocked: \(.value.unresolved_count) unresolved blocker(s)" else "" end)
'

# Note remaining candidates as a trailing line.
remaining=$(printf '%s' "$ranked_json" | jq --argjson lim "$limit" 'length - $lim')
if [ "$remaining" -gt 0 ]; then
  printf '\n_%s more workable candidate(s) available; pass --limit to see more._\n' "$remaining"
fi

# Keeper policy 2026-08-12: the Planned/Todo queue is never hidden by the render cut.
# Below-cut unstarted-stage candidates surface here with their true rank numbers, in a
# compact form (entries beyond K carry no parent-walk data, and raising the cut itself
# was measured dragging the entire 171-item pool along whenever a delegated-penalized
# Planned epic sat at the bottom). The top list and its limit stay untouched, so /next's
# small default limit keeps fleet pick steps cheap.
printf '%s' "$ranked_json" | jq -r --argjson lim "$limit" '
  [to_entries | .[$lim:] | .[] | select(.value.is_unstarted)] | if length == 0 then empty else
    "\n### Planned/Todo below the cut — always surfaced\n",
    (.[] |
      "\(.key + 1). **\(.value.id)** — \"\(.value.title)\"" +
      "\n   - State: \(.value.state) | Priority: \(.value.priority_label)" +
      (if .value.class_rank == 0 then " | security" elif .value.class_rank == 1 then " | bug" else "" end) +
      (if ((.value.gates_unstarted // []) | length) > 0 then " | Gates Planned/Todo: \(.value.gates_unstarted | join(", "))" else "" end) +
      (if .value.unresolved_count > 0 then " | Blocked: \(.value.unresolved_count) unresolved blocker(s)" else "" end))
  end'
hold_note
blocked_note
keeper_note
nd_note
claimed_note
solo_note
human_note
epic_note
