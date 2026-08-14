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
#   its remedy row says to certify children and close the epic when they release — and it never
#   counts fleet-workable, certified or not (an epic carrying `specified` is the BF-504 shape
#   that burned two /auto worktree cycles on BF-95 before the label was removed).
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
# WHY A SCRIPT: the same silent-empty hazard as wt-baseline.sh — a mistranscribed inline filter
# prints nothing at exit 0, which reads as "nothing blocks the fleet". The summary/verdict lines
# make an empty result distinguishable from a broken run; the regression suite pins the
# classification.
#
# Usage:  fleet-blockers.sh --team <KEY>
# Output: `FOCUS: <n> unstarted — <w> fleet-workable · <a> need keeper action · <d> draining on their own`
#         `FOCUS-ACTION: <ID> [<state>] — <reason(; reason)>`               (the issue itself needs the keeper)
#         `FOCUS-ROOT: <ROOT> [<state>] (via <ID>) — <remedy> — unblocks <ID>, <ID> (<n> alone; co-gated with <ID>)`
#           (root causes, widest fan-out first; `via` = chain members this root reaches its
#           dependents through; the co-gate annotation stops a fan-out reading as frees-alone)
#         `PROMOTE-SET: <ID>[<gate>], <ID>, …`   (the deduped Backlog chain membership in full —
#           the required promotion batch; gates annotated inline, never filtered)
#         `FLEET-BLOCKED: <n>`, then one sorted line per stranded edge:
#         `<BLOCKED> [<state>] blocked by <BLOCKER> [<state>] — <reason(; reason)>`
# Exit:   0 when fetched and classified (counts may be 0); non-zero on fetch/parse failure.
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
  # Every reason the fleet cannot ship an issue, with the remedy. Shared by both sections so the
  # classifications cannot drift apart.
  def gate_reasons($v):
    [ (if ($v.labels | index("epic")) then "delegated epic (children carry the work — certify per child, close the epic when they release)" else empty end),
      (if ($v.labels | index("human")) then "human-labeled (human-performed; the fleet never ships it)" else empty end),
      (if ($v.labels | index("needs decision")) then "needs decision (decide and clear the label)" else empty end),
      (if ($v.labels | index("solo")) then "solo (targeted /auto in the quiet window)" else empty end),
      (if ($v.labels | index("stalled")) then "stalled (resume or release it)" else empty end),
      (if $v.stype == "triage" then "in Triage (groom via /spec)" else empty end),
      (if (($v.stype | IN("unstarted","backlog")) and (($v.labels | index("specified")) | not)
           and (($v.labels | index("epic")) | not))
         then "uncertified (/spec to certify)" else empty end) ];
  # Short gate tags for PROMOTE-SET annotations — the label a keeper acts on, not the remedy
  # prose. Gates ANNOTATE, never filter: filtering is the carve-out that buried BF-553.
  def gate_tags($v):
    [ (if ($v.labels | index("epic")) then "epic" else empty end),
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
  . as $nodes
  | ([ $nodes[] | {key: .identifier,
                   value: {sname: (.state.name // "?"), stype: (.state.type // "?"),
                           labels: [((.labels.nodes // [])[].name) | ascii_downcase]}} ]
     | from_entries) as $m
  | ([ $nodes[]
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
  | ([$summary] + $action_lines + $root_lines + [$promote_line] + ["FLEET-BLOCKED: \($edge_rows | length)"] + $edge_rows)
  | .[]
'
