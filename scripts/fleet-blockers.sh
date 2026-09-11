#!/bin/bash
# fleet-blockers.sh — the pre-fleet attention audit, rooted at the release scope. Two sections:
#
#   FOCUS — every unstarted-stage issue (Planned/Todo: the committed release scope, which
#   stage-first ranking already drains first), classified for the keeper: fleet-workable now,
#   needing keeper action on the issue itself (gate labels, uncertified — FOCUS-ACTION rows), or
#   blocked — each blocked issue's chain is walked TRANSITIVELY to its root causes, grouped by
#   root with every dependent it unblocks (FOCUS-ROOT rows, widest fan-out first), so the
#   highest-value keeper hour is the first row. Every Backlog member of a blocking chain —
#   roots, intermediates, gated and uncertified members alike — is required release scope
#   (keeper ruling 2026-08-13): promotion is the default remedy for the FULL membership, gate
#   labels notwithstanding (labels decide who acts after the promotion, not scope), batch-ready
#   on the PROMOTE-SET line. Bulk "in Backlog (promote to Planned)" advice stays gone — FOCUS
#   dependents are unstarted-stage only, so the 68 ordinary Backlog-behind-Backlog chain edges
#   that advice mislabeled as fleet blockers never emit (keeper, 2026-08-10).
#
#   `epic`-labeled issues are delegated containers (BF-95; next-candidates' BF-504 de-rank):
#   certification is per CHILD, so an epic is never flagged "uncertified (/spec to certify)" —
#   its remedy row says to certify children — and it never counts fleet-workable, certified or
#   not (an epic carrying `specified` is the BF-504 shape that burned two /auto worktree cycles
#   on BF-95 before the label was removed). An epic closes ITSELF when its last child releases
#   (mark-ready-for-release.sh's parent walk, keeper decision 2026-09-11); the CLOSE-SET line
#   below is the one-time sweep for epics that were already complete before that walk existed.
#
#   CLOSE-SET — every fetched `epic` with at least one child and every child terminal (Done /
#   Canceled / Duplicate / Ready for Release, by state type or name — In Review is not terminal
#   here), ready to paste into `linear-set-state.sh 'Ready for Release' <IDs>`.
#
#   FLEET-BLOCKED — pool-drain hygiene, second-order: every `blocks` edge whose blocked side is
#   a certified fleet candidate (workable state + `specified`, not label-hidden) but whose
#   blocker nothing the fleet can pick will ever ship: labeled `human` / `needs decision` /
#   `solo` / `stalled`, sitting in Triage, or uncertified (the fleet runs `/next specified`, so
#   an unlabeled blocker never ships unattended). Sitting in Backlog is NOT a strand condition —
#   the fleet reaches Backlog once the unstarted stage drains.
#
# Label-gated strands are invisible to the deps graph (it carries no labels), so this script does
# its own one-query fetch (states + labels + relations).
#
# WHY A SCRIPT: the silent-empty hazard — a mistranscribed inline filter prints nothing at exit 0,
# which reads as "nothing blocks the fleet". The summary/verdict lines
# make an empty result distinguishable from a broken run; the regression suite pins the
# classification.
#
# Usage:  fleet-blockers.sh --team <KEY> | --root <EPIC-ID> [--team <KEY>]
#         --root audits an epic-scoped fleet's pool (what /fleet-launch epic:<ID> runs): the fetch is
#         cut to the epic's graph members right after it lands (epic-graph.sh — the epic, its
#         descendants, and their blockers, non-terminal only), the graph's teams are fetched on their
#         own, and a `SCOPE:` line leads. Fails closed: a root that is not an epic exits 1 with the reason.
# Output: `SCOPE: epic <ID> — <n> non-terminal member(s) across <teams>`   (scoped runs only)
#         `FOCUS: <n> unstarted — <w> fleet-workable · <a> need keeper action · <d> draining on their own`
#         `FOCUS-ACTION: <ID> [<state>] — <reason(; reason)>`               (the issue itself needs the keeper)
#         `FOCUS-ROOT: <ROOT> [<state>] (via <ID>) — <remedy> — unblocks <ID>, <ID> (<n> alone; co-gated with <ID>)`
#           (root causes, widest fan-out first; `via` = chain members this root reaches its
#           dependents through; the co-gate annotation stops a fan-out reading as frees-alone)
#         `PROMOTE-SET: <ID>[<gate>], <ID>, …`   (the deduped Backlog chain membership in full —
#           the required promotion batch; gates annotated inline, never filtered)
#         `CLOSE-SET: <ID>, …`   (epics whose every child is terminal — the auto-close sweep batch)
#         `FLEET-BLOCKED: <n>`, then one sorted line per stranded edge:
#         `<BLOCKED> [<state>] blocked by <BLOCKER> [<state>] — <reason(; reason)>`
# Exit:   0 when fetched and classified (counts may be 0); non-zero on fetch/parse failure.
set -euo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
team=""
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) [ -n "${2:-}" ] || { echo "ERROR: --team requires a value" >&2; exit 1; }; team="$2"; shift 2 ;;
    --root) [ -n "${2:-}" ] || { echo "ERROR: --root requires a value" >&2; exit 1; }
            root=$(printf '%s' "$2" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'); shift 2 ;;
    *) echo "usage: fleet-blockers.sh --team <KEY> | --root <EPIC-ID> [--team <KEY>]" >&2; exit 1 ;;
  esac
done
[ -n "$team" ] || [ -n "$root" ] || { echo "usage: fleet-blockers.sh --team <KEY> | --root <EPIC-ID> [--team <KEY>]" >&2; exit 1; }

# The scope resolves first: its members decide which teams to fetch, and its refusals (missing root,
# no `epic` label, unreadable node) end the run before any fetch — never an unscoped audit in its place.
graph=""
members='[]'
teams="$team"
if [ -n "$root" ]; then
  graph=$("$script_dir/epic-graph.sh" "$root") || { echo "ERROR: --root $root did not validate — refusing to audit an unscoped pool in its place" >&2; exit 1; }
  members=$(printf '%s' "$graph" | jq -c '[.members[].identifier]')
  for t in $(printf '%s' "$graph" | jq -r '.teams[]'); do
    case " $teams " in *" $t "*) ;; *) teams="${teams:+$teams }$t" ;; esac
  done
fi

# One paginated query per team: every non-terminal issue's state, labels, and outgoing relations. A
# terminal-state blocker is excluded by the filter, so its edges vanish — resolved by construction.
q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){nodes{identifier state{name type} assignee{email} labels{nodes{name}} children(first:250){nodes{state{name type}}} relations{nodes{type relatedIssue{identifier}}}} pageInfo{hasNextPage endCursor}}}'
all='[]'
for team in $teams; do
  after=''
  while :; do
    # `|| true` on each capture: under set -e a failing linear-cli would exit on the assignment itself, before the
    # guard below can name the failure — measured 2026-08-28 as exit 1 with empty stderr, indistinguishable from a broken run.
    if [ -z "$after" ]; then
      out=$(linear-cli api query -q -o json -v team="$team" "$q" 2>/dev/null) || true
    else
      out=$(linear-cli api query -q -o json -v team="$team" -v after="$after" "$q" 2>/dev/null) || true
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
done

# The scope cut lands before anything reads the nodes, so FOCUS, the roots, PROMOTE-SET, and
# FLEET-BLOCKED all describe the epic alone. A member's blocker is a member or terminal by
# construction, so no edge is lost to the cut; edges to outside dependents drop with them.
if [ -n "$root" ]; then
  all=$(printf '%s' "$all" | jq -c --argjson m "$members" 'map(select(.identifier as $i | ($m | index($i)) != null))')
  printf '%s' "$graph" | jq -r '"SCOPE: epic \(.root) — \(.members | length) non-terminal member(s) across \(.teams | join(", "))"'
fi

# Assignment is a claim (standards/linear-workflow.md, same rule next-candidates.sh enforces at
# pick time): an assignee other than the viewer means a person owns the issue — never
# fleet-releasable, never /spec-recommendation material. Viewer unresolvable → every assigned
# issue reads claimed, failing toward respecting the claim.
me_email=$(linear-cli api query -q -o json 'query{viewer{email}}' 2>/dev/null | jq -r '.data.viewer.email // empty' || true)

printf '%s' "$all" | jq -r --arg me "${me_email:-}" '
  def claimed($v): (($v.assignee // "") != "") and (($me == "") or ($v.assignee != $me));
  # Every reason the fleet cannot ship an issue, with the remedy. Shared by both sections so the
  # classifications cannot drift apart. Claimed leads and suppresses the /spec remedy: the owner
  # certifies (or ships) their own claim — auto-prep once recommended four /spec interviews on
  # teammates'"'"' claimed High issues (2026-08-15).
  def gate_reasons($v):
    [ (if claimed($v) then "claimed by \($v.assignee) (assignment is a claim — their work, not fleet-releasable, no keeper action)" else empty end),
      (if ($v.labels | index("epic")) then
         (if $v.closeable then "delegated epic — every child is terminal; close it (CLOSE-SET below)"
          else "delegated epic (children carry the work — certify per child; it closes itself when the last child releases)" end)
       else empty end),
      (if ($v.labels | index("human")) then "human-labeled (human-performed; the fleet never ships it)" else empty end),
      (if ($v.labels | index("needs decision")) then "needs decision (decide and clear the label)" else empty end),
      (if ($v.labels | index("solo")) then "solo (targeted /auto in the quiet window)" else empty end),
      (if ($v.labels | index("stalled")) then "stalled (resume or release it)" else empty end),
      (if $v.stype == "triage" then "in Triage (groom via /spec)" else empty end),
      (if (($v.stype | IN("unstarted","backlog")) and (($v.labels | index("specified")) | not)
           and (($v.labels | index("epic")) | not) and (claimed($v) | not))
         then "uncertified (/spec to certify)" else empty end) ];
  # Short gate tags for PROMOTE-SET annotations — the label a keeper acts on, not the remedy
  # prose. Gates ANNOTATE, never filter: filtering is the carve-out that buried BF-553.
  def gate_tags($v):
    [ (if claimed($v) then "claimed" else empty end),
      (if ($v.labels | index("epic")) then "epic" else empty end),
      (if ($v.labels | index("needs decision")) then "needs decision" else empty end),
      (if ($v.labels | index("human")) then "human" else empty end),
      (if ($v.labels | index("solo")) then "solo" else empty end),
      (if ($v.labels | index("stalled")) then "stalled" else empty end),
      (if ((($v.labels | index("specified")) | not) and (($v.labels | index("epic")) | not)) then "uncertified" else empty end) ];
  # Every transitive blocker above $id — the full ancestry, NOT just chain leaves. A
  # mandatory-gated blocker sitting mid-chain strands its dependents exactly as hard as a leaf
  # (measured on BF: decision-gated BF-553 blocks two Planned issues while itself blocked by
  # clean issues — a leaves-only walk hid it behind its own ancestors). $seen guards cycles.
  def ancestors($up; $id; $seen):
    [ ($up[$id] // [])[] | . as $b | select(($seen | index($b)) | not) ] as $fresh
    | if ($fresh | length) == 0 then []
      else $fresh + ([ $fresh[] | ancestors($up; .; $seen + $fresh) ] | add)
      end;
  # The terminal set the epic auto-close walk uses (mark-ready-for-release.sh): by type and by name,
  # In Review deliberately excluded — a child awaiting human review keeps its epic open.
  def closed: ((.type // "") | IN("completed","canceled","duplicate"))
    or ((.name // "") | ascii_downcase | IN("done","canceled","cancelled","duplicate","ready for release"));
  . as $nodes
  | ([ $nodes[] | {key: .identifier,
                   value: {sname: (.state.name // "?"), stype: (.state.type // "?"),
                           assignee: (.assignee.email // ""),
                           labels: [((.labels.nodes // [])[].name) | ascii_downcase],
                           closeable: (((.children.nodes // []) | length) > 0 and all((.children.nodes // [])[]; .state | closed))}} ]
     | from_entries) as $m
  | ([ $nodes[]
       # "In Review" is completed-in-substance (keeper ruling 2026-08-21): its outgoing blocks are
       # resolved like the terminal states the fetch filter drops. Matched by NAME — Linear has the
       # state registered as type `started`, and state types cannot be changed after creation.
       | select(((.state.name // "") | ascii_downcase) != "in review")
       | .identifier as $blocker
       | (.relations.nodes // [])[]
       | select(.type == "blocks" and .relatedIssue != null)
       | select($m[.relatedIssue.identifier] != null)
       | {blocker: $blocker, blocked: .relatedIssue.identifier} ]) as $edges
  | ($edges | group_by(.blocked)
     | map({key: .[0].blocked, value: ([.[].blocker] | unique)}) | from_entries) as $up
  # ---- FOCUS: the release scope (unstarted stage), certified or not, gated or not ----
  | ([ $nodes[] | select(.state.type == "unstarted") | .identifier ] | sort) as $focus
  | ([ $focus[] | . as $f | $m[$f] as $fv
       | gate_reasons($fv) as $selfr
       | select($selfr | length > 0)
       | "FOCUS-ACTION: \($f) [\($fv.sname)] — \($selfr | join("; "))" ]) as $action_lines
  | ([ $focus[] | . as $f
       | select((($up[$f] // []) | length) > 0)
       | (ancestors($up; $f; [$f]) | unique) as $anc
       | $anc[] as $r
       | select($r != $f)
       | $m[$r] as $rv
       | gate_reasons($rv) as $rr
       | (if ($rr | length) > 0 then $rr
          elif $rv.stype == "backlog" then ["required release scope (gates the unstarted stage) — promote in the batch"]
          else null end) as $reasons
       | select($reasons != null)
       # via = chain members between this root and the dep (ancestors of the dep that the root
       # itself transitively blocks) — so a deep root is not read as directly gating the dep.
       | {root: $r, dep: $f, reasons: $reasons, mandatory: (($rr | length) > 0),
          via: [ $anc[] | select(. != $r) | select((ancestors($up; .; [.]) | unique) | index($r)) ]} ]) as $pairs
  # Gated roots (gate/uncertified/triage/stalled — the fleet can NEVER resolve them; they need
  # keeper action beyond promotion) sort above the clean-Backlog promotions: the keeper reads
  # top-down, decisions first. Every row is must-do — a clean Backlog root is required release
  # scope like the rest (keeper ruling 2026-08-13); its remedy is just the batch promotion.
  | ($pairs | group_by(.dep)
     | map({key: .[0].dep, value: ([.[].root] | unique)}) | from_entries) as $deproots
  | ($pairs | group_by(.root)
     | map({root: .[0].root, reasons: .[0].reasons, mandatory: .[0].mandatory,
            deps: ([.[].dep] | unique | sort),
            via: ([.[].via[]] | unique | sort)})
     | map(. as $row
       | $row + {alone: ([ $row.deps[] | select(((($deproots[.] // []) - [$row.root]) | length) == 0) ] | length),
                 cogates: ([ $row.deps[] | (($deproots[.] // []) - [$row.root])[] ] | unique | sort)})
     | sort_by([(if .mandatory then 0 else 1 end), -(.deps | length), .root])) as $rootrows
  | ([ $rootrows[]
       | "FOCUS-ROOT: \(.root) [\($m[.root].sname)]"
         + (if (.via | length) > 0 then " (via \(.via | join(", ")))" else "" end)
         + " — \(.reasons | join("; ")) — unblocks \(.deps | join(", "))"
         + (if (.cogates | length) > 0 then " (\(.alone) alone; co-gated with \(.cogates | join(", ")))" else "" end) ]) as $root_lines
  # The full Backlog chain membership, deduped, ready for the batch state update
  # (linear-set-state.sh Planned <IDs>). Gated and uncertified members stay IN with the gate
  # annotated inline — hand-derived "roots-only" / "ungated-only" subsets are the two misreads
  # this line exists to remove (keeper ruling 2026-08-13).
  | ([ $rootrows[] | select($m[.root].stype == "backlog") | .root ] | unique | sort) as $promote
  | (if ($promote | length) > 0
     then "PROMOTE-SET: " + ([ $promote[] | . as $p
            | gate_tags($m[$p]) as $t
            | $p + (if ($t | length) > 0 then "[\($t | join("; "))]" else "" end) ] | join(", "))
     else "PROMOTE-SET: (none)" end) as $promote_line
  # Every fetched epic already complete — the one-time sweep batch (linear-set-state.sh "Ready for
  # Release" <IDs>); from here on mark-ready-for-release.sh closes them when the last child releases.
  # No apostrophes in this block — the jq program is one single-quoted shell string.
  | ([ $m | to_entries[] | select(.value.closeable and (.value.labels | index("epic"))) | .key ] | sort) as $closeable
  | (if ($closeable | length) > 0 then "CLOSE-SET: " + ($closeable | join(", ")) else "CLOSE-SET: (none)" end) as $close_line
  | ([ $focus[] | . as $f | $m[$f] as $fv
       | select((($up[$f] // []) | length) == 0)
       | select((gate_reasons($fv) | length) == 0)
       | $f ]) as $workable
  # Attention = issues that cannot reach the fleet without the keeper: self-gated, or blocked
  # behind ANY flagged root — a clean-Backlog blocker needs the batch promotion too (required
  # release scope, keeper ruling 2026-08-13), so its dependents count. Draining = blocked only
  # by clean in-scope or in-flight work the fleet resolves on its own.
  | ([ ($pairs[] | .dep),
       ($focus[] | . as $f | select((gate_reasons($m[$f]) | length) > 0) | $f) ] | unique) as $attention
  | "FOCUS: \($focus | length) unstarted — \($workable | length) fleet-workable · \($attention | length) need keeper action · \(($focus | length) - ($workable | length) - ($attention | length)) draining on their own" as $summary
  # ---- FLEET-BLOCKED: certified-candidate edges whose blocker the fleet can never pick ----
  | ([ $edges[]
       | $m[.blocked] as $t
       | $m[.blocker] as $b
       # Blocked side must be a candidate the fleet could pick: workable state, certified, and not
       # itself hidden by a gate label (a hidden dependent surfaces in FOCUS, not here).
       | select($t.sname | IN("Backlog","Planned","Todo"))
       | select($t.labels | index("specified"))
       | select([ $t.labels[] | select(IN("needs decision","human","solo")) ] | length == 0)
       | gate_reasons($b) as $reasons
       | select($reasons | length > 0)
       | "\(.blocked) [\($t.sname)] blocked by \(.blocker) [\($b.sname)] — \($reasons | join("; "))"
     ] | sort) as $edge_rows
  | ([$summary] + $action_lines + $root_lines + [$promote_line, $close_line] + ["FLEET-BLOCKED: \($edge_rows | length)"] + $edge_rows)
  | .[]
'
