#!/usr/bin/env bash
# Regression suite for next-candidates.sh's RANKING — the ordering policy has so far only ever
# been verified against live Linear data, which shifts under every re-check (the 2026-08-05
# stage-first change was validated that way and needed three live probes to disentangle rank
# truncation from blocking). Fixtures pin: stage-first (Planned/Todo drains fully before Backlog,
# Urgent included), Urgent piercing label classes WITHIN a stage, security > bug > other,
# Ready-for-Release blockers resolving case-insensitively, open blockers hiding a candidate
# (restored by --include-blocked), the needs decision / solo / human hiding notes, and the Planned
# GATE (keeper ruling 2026-08-28): while the Planned/Todo column holds anything not claimed by
# another person, every Backlog candidate is withheld behind a PLANNED-HOLD note that classifies
# the held issues (pickable / releasing on their own / need the keeper); discovery listings are
# exempt; --no-stage-gate lifts it; with nothing pickable the headline says wait, not drained.
#
# Isolation: linear-cli is a PATH shim dispatching on query text; HOME points at an empty dir so
# both scripts' `export PATH="$HOME/.cargo/bin:$PATH"` prepend cannot resurrect the real CLI, and
# the keeper gate's `git -C $HOME/.claude` probe fails closed deterministically. GROW THIS SUITE
# WITH THE POLICY — every ordering change gets its expected sequence updated here, never re-verified
# only against live data.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-candidates.sh"
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

# ---- fixtures ----
FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

# Team-issue page (fetch_team_issues shape). The ranking pool:
#   TT-3 Planned Urgent            -> 1st (urgent pierces class within the Planned stage)
#   TT-2 Planned Normal security   -> 2nd
#   TT-4 Planned Normal bug        -> 3rd
#   TT-5 Planned High (no class)   -> 4th
#   TT-9 Planned Low, OPEN blocker -> hidden by default; 5th under --include-blocked
#   TT-7 Planned None, RFR blocker -> 5th (blocker resolved: "Ready for Release" is terminal,
#                                    case-insensitively vs the script's "Ready For Release")
#   TT-1 Backlog Urgent            -> 6th — BELOW every Planned issue (stage-first)
#   TT-6 Backlog Normal security   -> 7th (urgent still pierces within the Backlog stage)
#   TT-8 RFR / TT-10 In Progress   -> blockers only, never candidates
#   TT-11/12/13                    -> hidden by label (needs decision / solo / human) + notes
#   TT-14 Triage Urgent            -> absent by default; LAST STAGE under --include-triage —
#   TT-15 Triage Normal security      even Urgent never outranks Planned/Backlog (BF-34's shape)
#   TT-16 Planned Low, FOREIGN assignee -> hidden (assignment is a claim) + note; restored by
#                                     --include-claimed
#   TT-17 Backlog Low, assigned to VIEWER (t@t.test) -> tier 1, FIRST in every default list —
#                                     pins that the claim gate never hides your own issues
#   TT-18 Planned None, IN REVIEW blocker -> after TT-7 (blocker resolved: "In Review" is terminal
#                                     by name — completed-in-substance, keeper ruling 2026-08-21)
#   TT-19 In Review                   -> blocker only, never a candidate
#   TT-20 Backlog None, blocks Planned TT-21 -> INHERITS the Planned stage (release scope by
#                                     implication): after every Planned issue, before TT-1
#   TT-21 Planned Low, blocked by TT-20 -> hidden by default; restored under --include-blocked
#   TT-22 Backlog None, blocks RFR TT-8 (which blocks TT-7) -> NO inheritance: the walk stops
#                                     at a terminal blocker, so it stays in the Backlog stage
#   TT-23 Backlog -> TT-24 Backlog -> TT-25 Planned Normal -> TT-23 and TT-24 both inherit the
#                                     Planned stage transitively (TT-24 and TT-25 hidden as blocked)
#   TT-26 Backlog None, CHILD of Planned epic TT-27 -> inherits the Planned stage via its parent
#                                     (a child gates its epic the way a blocker gates a dependent)
#   TT-27 Planned epic (label `epic`) -> HIDDEN from every ranking (delegated container; note +
#                                     --label epic lists it); the gate note lists it as the keeper's
cat > "$FIX/issues-page.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-1","title":"urgent backlog","estimate":null,"priority":1,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-2","title":"planned security","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"security"}]},"parent":null},
 {"identifier":"TT-3","title":"planned urgent","estimate":null,"priority":1,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-4","title":"planned bug","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"bug"}]},"parent":null},
 {"identifier":"TT-5","title":"planned high","estimate":null,"priority":2,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-6","title":"backlog security","estimate":null,"priority":3,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[{"name":"security"}]},"parent":null},
 {"identifier":"TT-7","title":"planned rfr-blocked","estimate":null,"priority":0,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-8","title":"shipped blocker","estimate":null,"priority":0,"state":{"name":"Ready for Release","type":"completed"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-9","title":"planned open-blocked","estimate":null,"priority":4,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-10","title":"open blocker","estimate":null,"priority":0,"state":{"name":"In Progress","type":"started"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-11","title":"parked decision","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"needs decision"}]},"parent":null},
 {"identifier":"TT-12","title":"solo work","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"solo"}]},"parent":null},
 {"identifier":"TT-13","title":"human work","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"human"}]},"parent":null},
 {"identifier":"TT-14","title":"triage urgent inbox","estimate":null,"priority":1,"state":{"name":"Triage","type":"triage"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-15","title":"triage security inbox","estimate":null,"priority":3,"state":{"name":"Triage","type":"triage"},"assignee":null,"labels":{"nodes":[{"name":"security"}]},"parent":null},
 {"identifier":"TT-16","title":"claimed by another person","estimate":null,"priority":4,"state":{"name":"Planned","type":"unstarted"},"assignee":{"email":"blake@t.test"},"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-17","title":"mine already","estimate":null,"priority":4,"state":{"name":"Backlog","type":"backlog"},"assignee":{"email":"t@t.test"},"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-18","title":"planned review-blocked","estimate":null,"priority":0,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-19","title":"review blocker","estimate":null,"priority":0,"state":{"name":"In Review","type":"started"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-20","title":"backlog blocker of planned","estimate":null,"priority":0,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-21","title":"planned behind backlog blocker","estimate":null,"priority":4,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-22","title":"backlog behind shipped chain","estimate":null,"priority":0,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-23","title":"backlog chain head","estimate":null,"priority":0,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-24","title":"backlog chain middle","estimate":null,"priority":0,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-25","title":"planned chain tail","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-26","title":"backlog child of planned epic","estimate":null,"priority":0,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":{"identifier":"TT-27"}},
 {"identifier":"TT-27","title":"planned epic","estimate":null,"priority":0,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"epic"}]},"parent":null}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

# Deps page (linear-deps-graph.sh --team shape): TT-8 blocks TT-7, TT-10 blocks TT-9,
# TT-19 (In Review — terminal by name, keeper ruling 2026-08-21) blocks TT-18; TT-20 blocks
# TT-21, TT-22 blocks the shipped TT-8, and TT-23 → TT-24 → TT-25 is the transitive chain.
cat > "$FIX/deps-page.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-8","title":"shipped blocker","state":{"name":"Ready for Release","type":"completed"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-7"}}]}},
 {"identifier":"TT-10","title":"open blocker","state":{"name":"In Progress","type":"started"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-9"}}]}},
 {"identifier":"TT-19","title":"review blocker","state":{"name":"In Review","type":"started"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-18"}}]}},
 {"identifier":"TT-20","title":"backlog blocker of planned","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-21"}}]}},
 {"identifier":"TT-22","title":"backlog behind shipped chain","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-8"}}]}},
 {"identifier":"TT-23","title":"backlog chain head","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-24"}}]}},
 {"identifier":"TT-24","title":"backlog chain middle","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-25"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

# linear-cli shim: `api query` dispatches on the query text (its last argument); the parent
# walk's `issues get` no-ops (empty output is a tolerated skip in the walk).
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
if [ "\${1:-}" != "api" ]; then exit 0; fi
q="\${@: -1}"
case "\$q" in
  *viewer\{email\}*) printf '%s' '{"data":{"viewer":{"email":"t@t.test"}}}' ;;
  *relatedIssue*)    cat "\$FIX/deps-page.json" ;;
  *assignee*)        cat "\$FIX/issues-page.json" ;;
  *) printf '%s' '{"errors":[{"message":"unexpected query in test shim"}]}'; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <outfile> <extra args...>
  local out="$1"; shift
  HOME="$WORK/home" PATH="$WORK/bin:$PATH" LINEAR_TEAM="" "$SCRIPT" --team TT "$@" > "$out" 2>"$out.err"
}

order_of() { grep -E '^[0-9]+\. ' "$1" | grep -oE 'TT-[0-9]+' | tr '\n' ' ' | sed 's/ $//'; }

# ---- default run: stage-first ordering, RFR blocker resolved, open blocker hidden ----
OUT="$WORK/out.md"
run "$OUT" --limit 20 || { echo "FAIL: default run exited $?"; cat "$OUT.err"; exit 1; }
# Ranked lines only — the PLANNED-HOLD note legitimately NAMES hidden issues, so "hidden" checks read this.
grep -E '^[0-9]+\. ' "$OUT" > "$WORK/ranked.txt"

# The Planned column is not drained, so every Backlog candidate — TT-17 (tier 1, assigned to the
# viewer), TT-1 (Urgent), TT-6 (security), TT-22 — is withheld; inherited-stage TT-20/TT-23 stay.
ck "stage-first order under the gate" "TT-3 TT-2 TT-4 TT-5 TT-7 TT-18 TT-20 TT-23 TT-26" "$(order_of "$OUT")"
ck_has  "epic note" '1 issue(s) hidden as delegated epics (`epic` label' "$OUT"
ck_lacks "epic hidden" "TT-27" "$WORK/ranked.txt"
ck_has  "planned-hold note" "_PLANNED-HOLD: Backlog withheld — the Planned/Todo column is not drained (13 issue(s) hold the gate: 6 pickable now; 3 will release on their own — TT-9, TT-21, TT-25; 4 need the keeper — TT-11 [needs decision], TT-12 [solo], TT-13 [human], TT-27 [epic — certify per child, close it when they release]). 4 Backlog candidate(s) wait behind the gate; it opens when the column drains — pass --no-stage-gate to list them._" "$OUT"
ck_lacks "claimed planned does not hold the gate" "TT-16 [" "$OUT"
ck_has  "rfr blocker resolved"  "TT-7" "$OUT"
ck_has  "in-review blocker resolved" "TT-18" "$OUT"
ck_lacks "in-review blocker not candidate" "TT-19" "$OUT"
ck_lacks "open blocker hidden"  "TT-9" "$WORK/ranked.txt"
ck_lacks "blocker not candidate" "TT-8" "$OUT"
ck_has  "needs-decision note"   '1 issue(s) hidden awaiting a human decision (`needs decision` label; top: TT-11)' "$OUT"
ck_has  "solo note"             "1 issue(s) hidden as fleet-hostile" "$OUT"
ck_has  "human note"            "1 issue(s) hidden as human-owned work" "$OUT"
ck_lacks "parked not ranked"    "TT-11" "$WORK/ranked.txt"
ck_lacks "solo hidden"          "TT-12" "$WORK/ranked.txt"
ck_lacks "human hidden"         "TT-13" "$WORK/ranked.txt"

# ---- inherited stage: a Backlog issue that transitively blocks Planned work ranks in the
# ---- Planned stage (annotated), its blocked dependents stay hidden, and a chain through a
# ---- terminal blocker inherits nothing ----
ck "inherited-stage annotations" "3" "$(grep -c 'Stage inherited: Backlog, but it gates Planned/Todo' "$OUT")"
ck_has  "direct blocker annotated"  "Stage inherited: Backlog, but it gates Planned/Todo TT-21 (as blocker or child)" "$OUT"
ck_has  "chain head names the planned tail only" "Stage inherited: Backlog, but it gates Planned/Todo TT-25 (as blocker or child)" "$OUT"
ck_has  "epic child annotated" "Stage inherited: Backlog, but it gates Planned/Todo TT-27 (as blocker or child)" "$OUT"
ck_lacks "blocked planned dependent hidden" "TT-21" "$WORK/ranked.txt"
ck_lacks "blocked chain members hidden"     "TT-24" "$WORK/ranked.txt"

# ---- --include-blocked: TT-9 restored (Low outranks TT-7's None), everything else unchanged ----
OUT2="$WORK/out2.md"
run "$OUT2" --limit 20 --include-blocked || { echo "FAIL: include-blocked run exited $?"; cat "$OUT2.err"; exit 1; }
ck "blocked order" "TT-17 TT-3 TT-2 TT-4 TT-5 TT-25 TT-9 TT-21 TT-7 TT-18 TT-20 TT-23 TT-24 TT-26 TT-1 TT-6 TT-22" "$(order_of "$OUT2")"
ck_lacks "discovery listing is gate-exempt" "PLANNED-HOLD" "$OUT2"

# ---- label filter: only the security-labeled issues, stage-first within the filter ----
OUT3="$WORK/out3.md"
run "$OUT3" --limit 20 --label security || { echo "FAIL: label run exited $?"; cat "$OUT3.err"; exit 1; }
ck "label filter order under the gate" "TT-2" "$(order_of "$OUT3")"
ck_has  "label filter still gated" "1 Backlog candidate(s) wait behind the gate" "$OUT3"
OUT3b="$WORK/out3b.md"
run "$OUT3b" --limit 20 --label epic || { echo "FAIL: epic label run exited $?"; cat "$OUT3b.err"; exit 1; }
ck "epic listing" "TT-27" "$(order_of "$OUT3b")"
ck_lacks "no epic note on its own listing" "hidden as delegated epics" "$OUT3b"

# ---- stage is a strict three-way order: Triage is absent by default, and under
# ---- --include-triage the whole inbox — Urgent included — ranks below every Planned AND
# ---- every Backlog issue (within Triage, urgent still pierces class: TT-14 before TT-15) ----
ck_lacks "triage absent by default" "TT-14" "$OUT"
OUT5="$WORK/out5.md"
run "$OUT5" --limit 20 --include-triage || { echo "FAIL: include-triage run exited $?"; cat "$OUT5.err"; exit 1; }
ck "triage ranks last" "TT-17 TT-3 TT-2 TT-4 TT-5 TT-7 TT-18 TT-20 TT-23 TT-26 TT-1 TT-6 TT-22 TT-14 TT-15" "$(order_of "$OUT5")"
ck_lacks "triage listing is gate-exempt" "PLANNED-HOLD" "$OUT5"

# ---- assignment is a claim: a foreign assignee hides the issue from every ranking (with the
# ---- note), --include-claimed restores it, and the viewer's own claim is never hidden ----
ck_lacks "foreign-claimed hidden" "TT-16" "$OUT"
ck_has  "claimed note"  "1 issue(s) hidden as claimed by a person" "$OUT"
OUT6="$WORK/out6.md"
run "$OUT6" --limit 20 --include-claimed || { echo "FAIL: include-claimed run exited $?"; cat "$OUT6.err"; exit 1; }
ck "claimed restored in place" "TT-3 TT-2 TT-4 TT-5 TT-16 TT-7 TT-18 TT-20 TT-23 TT-26" "$(order_of "$OUT6")"
ck_has  "restored claim counts as pickable" "14 issue(s) hold the gate: 7 pickable now" "$OUT6"
ck_lacks "no claimed note when included" "hidden as claimed" "$OUT6"

# ---- the limit cut never hides Planned/Todo: --limit 1 keeps a one-item top list but
# ---- surfaces every below-cut Planned issue (true rank numbers) in the trailing section,
# ---- while the Backlog tail stays cut ----
OUT4="$WORK/out4.md"
run "$OUT4" --limit 1 || { echo "FAIL: limit-floor run exited $?"; cat "$OUT4.err"; exit 1; }
ck "planned never hidden"   "TT-3 TT-2 TT-4 TT-5 TT-7 TT-18 TT-20 TT-23 TT-26" "$(order_of "$OUT4")"
ck_has  "planned-below section" "### Planned/Todo below the cut — always surfaced" "$OUT4"
ck_has  "inherited blocker surfaces below the cut" "| Gates Planned/Todo: TT-21" "$OUT4"
ck_has  "remaining note"        "8 more workable candidate(s) available" "$OUT4"

# ---- --no-stage-gate lifts the filter: the withheld Backlog tail returns, stage-first, no note ----
OUT7="$WORK/out7.md"
run "$OUT7" --limit 20 --no-stage-gate || { echo "FAIL: no-stage-gate run exited $?"; cat "$OUT7.err"; exit 1; }
ck "gate lifted order" "TT-17 TT-3 TT-2 TT-4 TT-5 TT-7 TT-18 TT-20 TT-23 TT-26 TT-1 TT-6 TT-22" "$(order_of "$OUT7")"
ck_lacks "no note when lifted" "PLANNED-HOLD" "$OUT7"

# ---- gate OPEN: the Planned column holds only a claimed issue, so Backlog is offered normally ----
cat > "$FIX/issues-open.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-16","title":"claimed by another person","estimate":null,"priority":4,"state":{"name":"Planned","type":"unstarted"},"assignee":{"email":"blake@t.test"},"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-1","title":"urgent backlog","estimate":null,"priority":1,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-6","title":"backlog security","estimate":null,"priority":3,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[{"name":"security"}]},"parent":null}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
cat > "$FIX/deps-empty.json" <<'EOF'
{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
cp "$FIX/issues-page.json" "$FIX/issues-main.json"; cp "$FIX/deps-page.json" "$FIX/deps-main.json"
cp "$FIX/issues-open.json" "$FIX/issues-page.json"; cp "$FIX/deps-empty.json" "$FIX/deps-page.json"
OUT8="$WORK/out8.md"
run "$OUT8" --limit 20 || { echo "FAIL: gate-open run exited $?"; cat "$OUT8.err"; exit 1; }
ck "gate open order" "TT-1 TT-6" "$(order_of "$OUT8")"
ck_lacks "gate open has no note" "PLANNED-HOLD" "$OUT8"

# ---- gate CLOSED with nothing pickable: the headline says wait (never the drained text), and the
# ---- note splits what releases on its own from what needs the keeper ----
cat > "$FIX/issues-hold.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-11","title":"parked decision","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"needs decision"}]},"parent":null},
 {"identifier":"TT-9","title":"planned open-blocked","estimate":null,"priority":4,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-10","title":"open blocker","estimate":null,"priority":0,"state":{"name":"In Progress","type":"started"},"assignee":null,"labels":{"nodes":[]},"parent":null},
 {"identifier":"TT-1","title":"urgent backlog","estimate":null,"priority":1,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]},"parent":null}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
cat > "$FIX/deps-hold.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-10","title":"open blocker","state":{"name":"In Progress","type":"started"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-9"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
cp "$FIX/issues-hold.json" "$FIX/issues-page.json"; cp "$FIX/deps-hold.json" "$FIX/deps-page.json"
OUT9="$WORK/out9.md"
run "$OUT9" --limit 20 || { echo "FAIL: hold run exited $?"; cat "$OUT9.err"; exit 1; }
ck "hold lists nothing" "" "$(order_of "$OUT9")"
ck_has  "hold headline"  "_Nothing pickable right now in team TT — the Planned/Todo column is not drained, so Backlog is withheld (PLANNED-HOLD below). Wait for a release or act on the held issues; do not pick Backlog._" "$OUT9"
ck_lacks "hold is not drained" "No workable issues" "$OUT9"
ck_has  "hold note splits releasing from keeper" "(2 issue(s) hold the gate: 0 pickable now; 1 will release on their own — TT-9; 1 need the keeper — TT-11 [needs decision]). 1 Backlog candidate(s) wait behind the gate" "$OUT9"
cp "$FIX/issues-main.json" "$FIX/issues-page.json"; cp "$FIX/deps-main.json" "$FIX/deps-page.json"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
