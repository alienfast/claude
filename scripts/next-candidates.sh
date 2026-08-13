#!/bin/bash
# next-candidates.sh — Rank workable Linear issues and suggest what to do next.
#
# Usage:
#   next-candidates.sh [--team KEY[,KEY...]] [--completed PL-XX] [--limit N]
#                      [--no-parent-walk] [--label NAME] [--exclude-label NAME]
#                      [--include-triage] [--include-blocked]
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
# Within a tier: workflow stage first (Planned/Todo before Backlog — the only planning
# signal in the pool a human sets by hand; Urgent does NOT pierce stage — keeper
# decision 2026-08-05), then Urgent priority (a deliberate human escalation outranks
# any label within its stage) > security/bug
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
TERMINAL_STATES='["Done","Canceled","Cancelled","Duplicate","Ready For Release"]'
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

# Filter workable issues whose blockers are all in terminal states.
# Emit per-candidate metadata for ranking.
candidates_json=$(jq \
  --argjson workable "$WORKABLE_STATES" \
  --argjson terminal "$TERMINAL_STATES" \
  --slurpfile sm_doc "$state_map_file" \
  --slurpfile bm_doc "$blocker_map_file" \
  --slurpfile newly_doc "$newly_unblocked_file" \
  --arg me "${me_email:-}" \
  --arg label "$label" \
  --arg xlabel "$exclude_label" \
  --arg triage "$include_triage" \
  --arg blocked "$include_blocked" \
  --arg iskeeper "$is_keeper" '
    ($sm_doc[0]) as $sm
    | ($bm_doc[0]) as $bm
    | ($newly_doc[0]) as $newly
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
    map(
      . as $i
      | (.identifier) as $id
      | ($bm[$id] // []) as $blockers
      | ($blockers | map(select(($sm[.] // "Unknown") as $s | (($terminal | map(ascii_downcase)) | index($s | ascii_downcase)) == null))) as $unresolved
      | select((($workable | index($i.state)) != null) or (($triage == "1") and ($i.state_type == "triage")))
      | select(($blocked == "1") or ($unresolved | length == 0))
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
          # Backlog is a deliberate human deferral, and the only planning signal in the pool
          # a person sets by hand — so it outranks the class ordering AND priority, Urgent
          # included: Planned/Todo drains fully before any Backlog issue is offered (keeper
          # decision 2026-08-05 — bouncing work to Backlog has to actually defer it). Keyed on
          # state TYPE so a renamed workable state still sorts right; the name check covers a
          # team that renamed a state without changing its type. Triage is deliberately left
          # at 0 — the only mode that admits it is --include-triage grooming discovery (used
          # by /spec), where an unreviewed inbox item is the most worth surfacing.
          state_rank: (if ($i.state_type == "backlog") or (($i.state // "") | ascii_downcase) == "backlog" then 1 else 0 end),
          # Unstarted stage is never hidden by the --limit render cut (keeper policy
          # 2026-08-12 — below-cut Planned/Todo candidates emit in a trailing section);
          # matched like state_rank — by type, with a name fallback for a renamed state.
          is_unstarted: (($i.state_type == "unstarted") or ((($i.state // "") | ascii_downcase) | IN("planned", "todo"))),
          class_rank: ((($i.labels // []) | map(ascii_downcase)) as $ls
            | if ($ls | index("security")) != null then 0
              elif ($ls | index("bug")) != null then 1
              else 2 end),
          spread_penalty: (if ($i.parent != null) and (($hot | index($i.parent)) != null) then 1 else 0 end)
        }
    )
  ' "$list_file")

# Count what the keeper gate hid (from the fetched list, pre-filter) so the exclusion is
# visible on every output path — a silently thinner list reads as "nothing there".
keeper_hidden=0
if [ "$is_keeper" != "true" ]; then
  keeper_hidden=$(jq '[.[] | select(any((.labels // [])[]; ascii_downcase == "keeper"))] | length' "$list_file" 2>/dev/null || echo 0)
fi
keeper_note() {
  [ "$keeper_hidden" -gt 0 ] && printf '\n_%s keeper-gated improvement(s) hidden — this machine is not the ~/.claude keeper (setup: git -C ~/.claude config reflect.keeper true)._\n' "$keeper_hidden"
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

candidate_count=$(printf '%s' "$candidates_json" | jq 'length')
if [ "$candidate_count" -eq 0 ]; then
  filter_desc=""
  [ -n "$label" ] && filter_desc=" with label '$label'"
  [ -n "$exclude_label" ] && filter_desc="$filter_desc lacking label '$exclude_label'"
  team_word="team"
  [ ${#teams[@]} -gt 1 ] && team_word="teams"
  printf '## Suggested next\n\n_No workable issues%s in %s %s._\n' "$filter_desc" "$team_word" "$teams_label"
  keeper_note
  nd_note
  solo_note
  human_note
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
ranked_json=$(printf '%s' "$candidates_json" | jq '
  map(
    . + {
      tier: (
        if .is_reflection then 0
        elif .is_me then 1
        elif (.newly_unblocked and .unresolved_count == 0) then 2
        else 4
        end
      )
    }
    # keeper_rank orders WITHIN tier 0 only: keeper reflection edits the shared user-level
    # ~/.claude (every project benefits, and only the keeper machine can ship it — everywhere
    # else the pool excludes it), so it front-runs project-level reflection filings.
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
      (if .value.unresolved_count > 0 then " | Blocked: \(.value.unresolved_count) unresolved blocker(s)" else "" end))
  end'
keeper_note
nd_note
solo_note
human_note
