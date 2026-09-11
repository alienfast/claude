#!/usr/bin/env bash
# Regression suite for epic-graph.sh — the membership rule an epic-scoped fleet is limited to
# (keeper ruling 2026-09-11). Fixtures pin: a descendant reached through a terminal parent, a
# cross-team blocker, a blocker chain stopping at a terminal node (whose own blocker is never
# fetched), a child that is both descendant and blocker appearing once, dependents excluded from
# members and listed in the boundary, `related` found in both storage directions and de-duplicated
# internally, terminal outside issues dropped from the boundary (by state type AND by name), the
# non-epic and missing-root refusals, the fail-closed exit on an unreadable node, and --ids.
#
# Isolation: linear-cli is a PATH shim dispatching on the `id=` variable and logging every fetch;
# HOME points at an empty dir so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/epic-graph.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
}

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

# node <ID> <title> <state> <type> <team> <labels-json> <parent|null> <children-json> <relations-json> <inverse-json>
node() {
  local parent='null'
  [ "$7" != "null" ] && parent="{\"identifier\":\"$7\"}"
  printf '{"data":{"issue":{"identifier":"%s","title":"%s","state":{"name":"%s","type":"%s"},"team":{"key":"%s"},"labels":{"nodes":%s},"parent":%s,"children":{"nodes":%s},"relations":{"nodes":%s},"inverseRelations":{"nodes":%s}}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$parent" "$8" "$9" "${10}" > "$FIX/$1.json"
}
kids() { local out="[" sep=""; for c in "$@"; do out="$out$sep{\"identifier\":\"$c\"}"; sep=","; done; printf '%s]' "$out"; }
rel() { printf '{"type":"%s","relatedIssue":{"identifier":"%s"}}' "$1" "$2"; }      # this node → other
inv() { printf '{"type":"%s","issue":{"identifier":"%s"}}' "$1" "$2"; }             # other → this node

# The graph under epic EP-1:
#   EP-2 (Backlog child) → child EP-5; blocks OT-1 (open), OT-2 (In Review — terminal by NAME), EP-6; related EP-4 (stored here) and EP-3 (a walked terminal node — never boundary)
#   EP-3 (Done child)    → child EP-6 (open grandchild through a terminal parent); blocked by OT-9 (never fetched: terminal nodes do not expand)
#   EP-4 (Planned child) → blocks EP-1 (chain tail → parent: both descendant and blocker); blocked by XT-7 (cross-team); related from OT-3 (stored on OT-3's side)
#   XT-7 (XT Backlog)    → blocked by XT-8 (Ready for Release, type completed — terminal by TYPE, stops the chain; XT-9 never fetched)
node EP-1 "the epic"          Planned unstarted EP '[{"name":"epic"}]' null "$(kids EP-2 EP-3 EP-4)" '[]' "[$(inv blocks EP-4)]"
node EP-2 "backlog child"     Backlog backlog   EP '[]' EP-1 "$(kids EP-5)" "[$(rel blocks OT-1),$(rel blocks OT-2),$(rel blocks EP-6),$(rel related EP-4),$(rel related EP-3)]" '[]'
node EP-3 "done child"        Done    completed EP '[]' EP-1 "$(kids EP-6)" '[]' "[$(inv blocks OT-9)]"
node EP-4 "planned child"     Planned unstarted EP '[{"name":"specified"}]' EP-1 '[]' "[$(rel blocks EP-1)]" "[$(inv blocks XT-7),$(inv related OT-3),$(inv related EP-2)]"
node EP-5 "grandchild"        Backlog backlog   EP '[]' EP-2 '[]' '[]' '[]'
node EP-6 "open under done"   Backlog backlog   EP '[]' EP-3 '[]' '[]' "[$(inv blocks EP-2)]"
node XT-7 "cross-team blocker" Backlog backlog  XT '[]' null '[]' "[$(rel blocks EP-4)]" "[$(inv blocks XT-8)]"
node XT-8 "shipped blocker"   "Ready for Release" completed XT '[]' null '[]' "[$(rel blocks XT-7)]" "[$(inv blocks XT-9)]"
node OT-1 "outside dependent" Planned unstarted OT '[]' null '[]' '[]' "[$(inv blocks EP-2)]"
node OT-2 "reviewed dependent" "In Review" started OT '[]' null '[]' '[]' "[$(inv blocks EP-2)]"
node OT-3 "outside related"   Backlog backlog   OT '[]' null '[]' "[$(rel related EP-4)]" '[]'
# EP-9: an epic whose child cannot be fetched (the shim errors on EP-FAIL) — fail closed.
node EP-9 "broken epic"       Planned unstarted EP '[{"name":"epic"}]' null "$(kids EP-FAIL)" '[]' '[]'

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
LOG="$WORK/fetch.log"
id=""
for a in "\$@"; do case "\$a" in id=*) id="\${a#id=}" ;; esac; done
printf '%s\n' "\$id" >> "\$LOG"
case "\$id" in
  EP-FAIL) exit 1 ;;
esac
if [ -f "\$FIX/\$id.json" ]; then cat "\$FIX/\$id.json"; exit 0; fi
printf '%s\n' '{"code":2,"details":[{"message":"Entity not found: Issue","path":["issue"]}],"error":true,"message":"GraphQL error"}'
exit 2
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <outfile> <args...> — stdout to <outfile>, stderr to <outfile>.err, echoes exit code
  local out="$1"; shift
  : > "$WORK/fetch.log"
  HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" "$@" > "$out" 2> "$out.err"
  echo "$?"
}
j() { jq -c "$2" "$1"; }

echo "epic-graph.sh —"

# ---- the full graph under EP-1 ----
OUT="$WORK/ep1.json"
rc=$(run "$OUT" EP-1)
ck "EP-1: exit"                 "0" "$rc"
ck "EP-1: root"                 '"EP-1"' "$(j "$OUT" '.root')"
ck "EP-1: members in discovery order, non-terminal only" '["EP-1","EP-2","EP-4","EP-5","EP-6","XT-7"]' "$(j "$OUT" '[.members[].identifier]')"
ck "EP-1: kinds (first sighting wins — EP-4 is a descendant, not a blocker)" '["root","descendant","descendant","descendant","descendant","blocker"]' "$(j "$OUT" '[.members[].kind]')"
ck "EP-1: terminal nodes met on the walk" '["EP-3","XT-8"]' "$(j "$OUT" '[.terminal[].identifier]')"
ck "EP-1: terminal by TYPE and by NAME both recognized" '["completed","completed"]' "$(j "$OUT" '[.terminal[].state_type]')"
ck "EP-1: teams from members, cross-team included" '["EP","XT"]' "$(j "$OUT" '.teams')"
ck "EP-1: member fields" '{"identifier":"EP-4","title":"planned child","state":"Planned","state_type":"unstarted","team":"EP","labels":["specified"],"parent":"EP-1","kind":"descendant"}' "$(j "$OUT" '.members[2]')"
ck "EP-1: internal edges (blocks in order, related de-duplicated across both storage sides)" \
   '[{"from":"EP-2","to":"EP-6","type":"blocks"},{"from":"EP-4","to":"EP-1","type":"blocks"},{"from":"XT-7","to":"EP-4","type":"blocks"},{"from":"EP-2","to":"EP-4","type":"related"}]' \
   "$(j "$OUT" '.edges')"
ck "EP-1: outside dependents — open one listed, In Review one dropped" '[{"identifier":"OT-1","title":"outside dependent","state":"Planned","state_type":"unstarted","team":"OT","blocked_by":["EP-2"]}]' "$(j "$OUT" '.boundary.dependents_outside')"
ck "EP-1: outside related, found from the partner's storage side; a walked terminal partner (EP-3) is not boundary" '[{"identifier":"OT-3","title":"outside related","state":"Backlog","state_type":"backlog","team":"OT","related_to":["EP-4"]}]' "$(j "$OUT" '.boundary.related_outside')"
ck "EP-1: dependents are not members" "0" "$(j "$OUT" '[.members[] | select(.identifier == "OT-1")] | length')"
ck_lacks "EP-1: a terminal node never expands its blockers (OT-9)" "OT-9" "$WORK/fetch.log"
ck_lacks "EP-1: the chain stops at a terminal blocker (XT-9)" "XT-9" "$WORK/fetch.log"
ck "EP-1: every node fetched exactly once" "1" "$(grep -cx 'EP-4' "$WORK/fetch.log")"
ck "EP-1: fetch count = 8 walked + 3 boundary" "11" "$(grep -c . "$WORK/fetch.log")"

# ---- --ids ----
OUT2="$WORK/ids.txt"
rc=$(run "$OUT2" --ids EP-1)
ck "--ids: exit" "0" "$rc"
ck "--ids: member identifiers one per line" "EP-1 EP-2 EP-4 EP-5 EP-6 XT-7" "$(tr '\n' ' ' < "$OUT2" | sed 's/ $//')"

# ---- refusals ----
OUT3="$WORK/nonepic.json"
rc=$(run "$OUT3" EP-2)
ck "non-epic root: exit 1" "1" "$rc"
ck "non-epic root: nothing on stdout" "0" "$(wc -c < "$OUT3" | tr -d ' ')"
ck_has "non-epic root: names the label" "does not carry the 'epic' label" "$OUT3.err"

OUT4="$WORK/anyroot.json"
rc=$(run "$OUT4" --any-root ep-2)
ck "--any-root: exit (lowercase id normalized)" "0" "$rc"
ck "--any-root: members" '["EP-2","EP-5"]' "$(j "$OUT4" '[.members[].identifier]')"
ck "--any-root: EP-6 is now an outside dependent" '["EP-6","OT-1"]' "$(j "$OUT4" '[.boundary.dependents_outside[].identifier]')"
ck "--any-root: EP-4 is now outside related" '["EP-4"]' "$(j "$OUT4" '[.boundary.related_outside[].identifier]')"

OUT5="$WORK/missing.json"
rc=$(run "$OUT5" EP-404)
ck "missing root: exit 1" "1" "$rc"
ck_has "missing root: message" "issue 'EP-404' not found" "$OUT5.err"
ck "missing root: not retried" "1" "$(grep -c . "$WORK/fetch.log")"

OUT6="$WORK/broken.json"
rc=$(run "$OUT6" EP-9)
ck "unreadable node: exit 2 (fail closed)" "2" "$rc"
ck "unreadable node: nothing on stdout" "0" "$(wc -c < "$OUT6" | tr -d ' ')"
ck_has "unreadable node: names the node and its kind" "could not fetch EP-FAIL (reached as descendant)" "$OUT6.err"

OUT7="$WORK/badid.json"
rc=$(run "$OUT7" foo)
ck "malformed id: exit 1" "1" "$rc"
ck "malformed id: no fetch" "0" "$(grep -c . "$WORK/fetch.log")"
rc=$(run "$OUT7")
ck "no args: exit 1" "1" "$rc"
rc=$(run "$OUT7" EP-1 EP-2)
ck "two ids: exit 1" "1" "$rc"

echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
