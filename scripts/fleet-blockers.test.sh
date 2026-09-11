#!/usr/bin/env bash
# Regression suite for fleet-blockers.sh. Fixture-pins both sections: FOCUS (the release-scope
# audit — gated/uncertified unstarted issues as keeper actions, transitive root-cause tracing
# with fan-out-first ordering, required-promotion framing with via/co-gate annotations and the
# full-membership PROMOTE-SET batch line, cycle termination, and
# clean planned/in-flight roots NOT flagged) and FLEET-BLOCKED (the four gate labels — human /
# needs decision / solo / stalled — Triage by TYPE so a renamed "Inbox" still classifies,
# uncertified blockers, clean and in-flight blockers NOT flagged, non-candidate blocked sides
# skipped in edges but surfaced in FOCUS, and NO bulk in-Backlog promotion advice). The
# summary/verdict lines make an empty result distinguishable from a broken run. linear-cli is a
# PATH shim; HOME is an empty dir so the script's cargo-bin PATH prepend cannot resurrect the
# real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-blockers.sh"
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

# Node shape mirrors the script's own query. Blocked sides TT-20..TT-40 (even) are Planned +
# specified unless noted; blockers classify per the comment on each pair.
cat > "$FIX/issues-page.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-20","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-21","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"needs decision"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-20"}}]}},
 {"identifier":"TT-22","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-23","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"human"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-22"}}]}},
 {"identifier":"TT-24","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-25","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"solo"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-24"}}]}},
 {"identifier":"TT-26","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-27","state":{"name":"Inbox","type":"triage"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-26"}}]}},
 {"identifier":"TT-28","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-29","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-28"}}]}},
 {"identifier":"TT-30","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-31","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-30"}}]}},
 {"identifier":"TT-32","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-33","state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"specified"},{"name":"stalled"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-32"}}]}},
 {"identifier":"TT-34","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-35","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-34"}},{"type":"related","relatedIssue":{"identifier":"TT-20"}}]}},
 {"identifier":"TT-36","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-37","state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-36"}}]}},
 {"identifier":"TT-38","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"relations":{"nodes":[]}},
 {"identifier":"TT-39","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-38"}}]}},
 {"identifier":"TT-40","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"needs decision"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-41","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-40"}}]}},
 {"identifier":"TT-70","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"epic"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-71","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"epic"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-72","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"epic"}]},"children":{"nodes":[{"state":{"name":"Done","type":"completed"}},{"state":{"name":"Ready for Release","type":"completed"}},{"state":{"name":"Canceled","type":"canceled"}}]},"relations":{"nodes":[]}},
 {"identifier":"TT-73","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"epic"}]},"children":{"nodes":[{"state":{"name":"Done","type":"completed"}},{"state":{"name":"In Review","type":"started"}}]},"relations":{"nodes":[]}},
 {"identifier":"TT-50","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-51","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-50"}}]}},
 {"identifier":"TT-52","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"},{"name":"needs decision"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-51"}}]}},
 {"identifier":"TT-54","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-56","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-57","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"},{"name":"needs decision"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-56"}}]}},
 {"identifier":"TT-58","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-57"}}]}},
 {"identifier":"TT-55","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-54"}}]}},
 {"identifier":"TT-60","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-61"}}]}},
 {"identifier":"TT-61","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-60"}}]}},
 {"identifier":"TT-80","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"assignee":{"email":"other@test"},"relations":{"nodes":[]}},
 {"identifier":"TT-81","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"assignee":{"email":"keeper@test"},"relations":{"nodes":[]}},
 {"identifier":"TT-82","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"assignee":{"email":"other@test"},"relations":{"nodes":[]}},
 {"identifier":"TT-90","state":{"name":"In Review","type":"started"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-91"}}]}},
 {"identifier":"TT-91","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

# Per-issue nodes for epic-graph.sh's walk (the --root case), consistent with the page above: epic
# TT-70's graph is itself, children TT-50 and TT-51, and TT-52 (a member because it blocks TT-51).
gnode() { # gnode <ID> <state> <type> <labels-json> <children-json> <relations-json> <inverse-json>
  printf '{"data":{"issue":{"identifier":"%s","title":"t","state":{"name":"%s","type":"%s"},"team":{"key":"TT"},"labels":{"nodes":%s},"parent":null,"children":{"nodes":%s},"relations":{"nodes":%s},"inverseRelations":{"nodes":%s}}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$FIX/node-$1.json"
}
gnode TT-70 Planned unstarted '[{"name":"epic"}]' '[{"identifier":"TT-50"},{"identifier":"TT-51"}]' '[]' '[]'
gnode TT-50 Planned unstarted '[{"name":"specified"}]' '[]' '[]' '[{"type":"blocks","issue":{"identifier":"TT-51"}}]'
gnode TT-51 Planned unstarted '[{"name":"specified"}]' '[]' '[{"type":"blocks","relatedIssue":{"identifier":"TT-50"}}]' '[{"type":"blocks","issue":{"identifier":"TT-52"}}]'
gnode TT-52 Backlog backlog '[{"name":"specified"},{"name":"needs decision"}]' '[]' '[{"type":"blocks","relatedIssue":{"identifier":"TT-51"}}]' '[]'
gnode TT-20 Planned unstarted '[{"name":"specified"}]' '[]' '[]' '[]'

# The graph walk's query is the only one carrying `inverseRelations` — matched FIRST, since it also
# carries `labels` like the team page.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
if [ "\${1:-}" != "api" ]; then exit 0; fi
q="\${@: -1}"
case "\$q" in
  *viewer*) printf '%s' '{"data":{"viewer":{"email":"keeper@test"}}}' ;;
  *inverseRelations*)
    id=""; for a in "\$@"; do case "\$a" in id=*) id="\${a#id=}" ;; esac; done
    if [ -f "\$FIX/node-\$id.json" ]; then cat "\$FIX/node-\$id.json"
    else printf '%s' '{"code":2,"details":[{"message":"Entity not found: Issue"}],"error":true}'; exit 2; fi ;;
  *labels*) cat "\$FIX/issues-page.json" ;;
  *) printf '%s' '{"errors":[{"message":"unexpected query in test shim"}]}'; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

OUT="$WORK/out.txt"
HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT" 2>"$OUT.err" \
  || { echo "FAIL: run exited $?"; cat "$OUT.err"; exit 1; }

# ---- FOCUS section: the release-scope audit is the primary output and leads ----
# TT-54 (blocked only by clean-Backlog TT-55) counts as attention, not draining: the promotion
# is required release scope (keeper ruling 2026-08-13), so its dependent waits on the batch.
ck "focus summary leads" "FOCUS: 29 unstarted — 2 fleet-workable · 23 need keeper action · 4 draining on their own" "$(head -1 "$OUT")"
# TT-91's only blocker is In Review TT-90 — completed-in-substance, so the edge never exists:
# TT-91 counts fleet-workable (not draining) and neither issue appears in any row.
ck "in-review blocker resolved by construction" "0" "$(grep -c 'TT-90' "$OUT")"
ck "in-review-blocked issue emits no rows" "0" "$(grep -c 'TT-91' "$OUT")"
ck_has "gated planned is a keeper action"      "FOCUS-ACTION: TT-21 [Planned] — needs decision (decide and clear the label)" "$OUT"
ck_has "uncertified planned is a keeper action" "FOCUS-ACTION: TT-31 [Planned] — uncertified (/spec to certify)" "$OUT"
ck_has "hidden dependent surfaces in focus"    "FOCUS-ACTION: TT-40 [Planned] — needs decision (decide and clear the label)" "$OUT"
# Epic-labeled issues are delegated containers (BF-95/BF-504): the remedy is per-child
# certification + closure on release — never "/spec the epic" — and a CERTIFIED epic still
# needs keeper action rather than counting fleet-workable.
ck_has "uncertified epic gets the epic remedy" "FOCUS-ACTION: TT-70 [Planned] — delegated epic (children carry the work — certify per child; it closes itself when the last child releases)" "$OUT"
ck "epic is never flagged uncertified"         "0" "$(grep -F 'TT-70' "$OUT" | grep -c 'uncertified')"
ck_has "certified epic is keeper action, not fleet-workable" "FOCUS-ACTION: TT-71 [Planned] — delegated epic (children carry the work — certify per child; it closes itself when the last child releases)" "$OUT"
# Epic auto-close (keeper decision 2026-09-11): an epic whose every child is already terminal is the
# one-time sweep's batch — a Planned one is a FOCUS action pointing at CLOSE-SET, a Backlog one is
# in the set without a FOCUS row, and In Review does NOT count as terminal (TT-73 stays out).
ck_has "complete epic points at the sweep"     "FOCUS-ACTION: TT-72 [Planned] — delegated epic — every child is terminal; close it (CLOSE-SET below)" "$OUT"
ck_has "close-set lists the complete epics"    "CLOSE-SET: TT-72" "$OUT"
ck "close-set excludes an epic with an In Review child" "0" "$(grep '^CLOSE-SET' "$OUT" | grep -c 'TT-73')"
ck "close-set excludes childless epics"        "0" "$(grep '^CLOSE-SET' "$OUT" | grep -c 'TT-70')"
ck_has "transitive root with fan-out"          "FOCUS-ROOT: TT-52 [Backlog] (via TT-51) — needs decision (decide and clear the label) — unblocks TT-50, TT-51" "$OUT"
ck_has "direct gated root"                     "FOCUS-ROOT: TT-21 [Planned] — needs decision (decide and clear the label) — unblocks TT-20" "$OUT"
ck_has "triage root under a Todo dependent"    "FOCUS-ROOT: TT-27 [Inbox] — in Triage (groom via /spec) — unblocks TT-26" "$OUT"
ck_has "stalled in-flight root"                "FOCUS-ROOT: TT-33 [In Progress] — stalled (resume or release it) — unblocks TT-32" "$OUT"
ck_has "clean backlog root is required promotion" "FOCUS-ROOT: TT-55 [Backlog] — required release scope (gates the unstarted stage) — promote in the batch — unblocks TT-54" "$OUT"
# The BF-553 shape: a mandatory gate MID-chain (TT-57 is itself blocked by clean TT-58) must
# still surface — the walk collects the full ancestry, not just chain leaves. Both chain
# members carry the co-gate annotation so neither fan-out reads as frees-alone.
ck_has "mid-chain mandatory gate surfaces"     "FOCUS-ROOT: TT-57 [Backlog] — needs decision (decide and clear the label) — unblocks TT-56 (0 alone; co-gated with TT-58)" "$OUT"
ck_has "clean ancestor above the gate is required too" "FOCUS-ROOT: TT-58 [Backlog] (via TT-57) — required release scope (gates the unstarted stage) — promote in the batch — unblocks TT-56 (0 alone; co-gated with TT-57)" "$OUT"
# Widest fan-out first: TT-52 (2 dependents) must sort above every 1-dependent root.
ck "fan-out ordering" "TT-52" "$(grep '^FOCUS-ROOT' "$OUT" | head -1 | grep -oE 'TT-[0-9]+' | head -1)"
ck_lacks "clean planned root not flagged"      "FOCUS-ROOT: TT-35" "$OUT"
ck_lacks "clean in-flight root not flagged"    "FOCUS-ROOT: TT-37" "$OUT"
ck_lacks "cycle yields no root row"            "FOCUS-ROOT: TT-60" "$OUT"
ck_lacks "cycle yields no root row (mirror)"   "FOCUS-ROOT: TT-61" "$OUT"
# Assignment is a claim (standards/linear-workflow.md): an issue assigned to someone other than
# the viewer is its owner's — surfaced as claimed, never as /spec work, whatever its
# certification state (auto-prep misdirected four /spec interviews at teammates' claimed High
# issues, 2026-08-15). Self-assigned keeps the /spec remedy: the viewer owns their own claims.
ck_has "claimed uncertified leads with the claim"  "FOCUS-ACTION: TT-80 [Planned] — claimed by other@test" "$OUT"
ck "claimed issue never gets the /spec remedy"     "0" "$(grep -F 'TT-80' "$OUT" | grep -c 'uncertified')"
ck_has "self-assigned stays /spec-recommendable"   "FOCUS-ACTION: TT-81 [Planned] — uncertified (/spec to certify)" "$OUT"
ck_has "claimed certified is not fleet-workable"   "FOCUS-ACTION: TT-82 [Planned] — claimed by other@test" "$OUT"

# PROMOTE-SET: the deduped Backlog chain membership in FULL — intermediates and gate-labeled
# members included with inline annotations, never filtered (the carve-out that buried BF-553).
ck_has "promote-set carries the full membership" "PROMOTE-SET: TT-29[uncertified], TT-39[uncertified], TT-41[uncertified], TT-52[needs decision], TT-55, TT-57[needs decision], TT-58" "$OUT"

# ---- FLEET-BLOCKED section: pool-drain edges, bulk Backlog promotion advice gone ----
ck "verdict line" "FLEET-BLOCKED: 9" "$(grep -m1 '^FLEET-BLOCKED' "$OUT")"
ck_has "needs-decision blocker" "TT-20 [Planned] blocked by TT-21 [Planned] — needs decision (decide and clear the label)" "$OUT"
ck_has "human blocker"          "TT-22 [Planned] blocked by TT-23 [Planned] — human-labeled (human-performed; the fleet never ships it)" "$OUT"
ck_has "solo blocker"           "TT-24 [Planned] blocked by TT-25 [Planned] — solo (targeted /auto in the quiet window)" "$OUT"
ck_has "renamed-triage blocker" "TT-26 [Todo] blocked by TT-27 [Inbox] — in Triage (groom via /spec)" "$OUT"
ck_has "backlog blocker flags only real reasons" "TT-28 [Planned] blocked by TT-29 [Backlog] — uncertified (/spec to certify)" "$OUT"
ck_has "uncertified planned blocker"  "TT-30 [Planned] blocked by TT-31 [Planned] — uncertified (/spec to certify)" "$OUT"
ck_has "stalled in-flight blocker"    "TT-32 [Planned] blocked by TT-33 [In Progress] — stalled (resume or release it)" "$OUT"
ck_lacks "bulk promote advice removed" "in Backlog (promote to Planned)" "$OUT"
ck_lacks "clean backlog blocker is not an edge" "TT-54 [Planned] blocked by" "$OUT"
ck_lacks "clean blocker drains"        "TT-34" "$OUT"
ck_lacks "in-flight blocker resolves"  "TT-36" "$OUT"
ck_lacks "uncertified dependent skipped in edges" "TT-38 [Planned] blocked by" "$OUT"
ck_lacks "hidden dependent skipped in edges"      "TT-40 [Planned] blocked by" "$OUT"

# Verdict counts EDGES, so recount expectations: 7 flagged rows above vs verdict 6 would fail —
# assert consistency directly instead of trusting the hand count.
rows=$(grep -c 'blocked by' "$OUT")
verdict=$(grep -m1 '^FLEET-BLOCKED' "$OUT" | grep -oE '[0-9]+')
ck "verdict matches rows" "$rows" "$verdict"

# ---- --root: the audit scoped to an epic's graph — every row describes members only ----
OUTR="$WORK/outr.txt"
HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --root tt-70 > "$OUTR" 2>"$OUTR.err" \
  || { echo "FAIL: scoped run exited $?"; cat "$OUTR.err"; exit 1; }
ck "scope line leads"   "SCOPE: epic TT-70 — 4 non-terminal member(s) across TT" "$(head -1 "$OUTR")"
ck "scoped focus counts members only" "FOCUS: 3 unstarted — 0 fleet-workable · 3 need keeper action · 0 draining on their own" "$(sed -n 2p "$OUTR")"
ck_has "scoped epic action row"        "FOCUS-ACTION: TT-70 [Planned] — delegated epic" "$OUTR"
ck_has "scoped root with fan-out"      "FOCUS-ROOT: TT-52 [Backlog] (via TT-51) — needs decision (decide and clear the label) — unblocks TT-50, TT-51" "$OUTR"
ck_has "scoped promote-set"            "PROMOTE-SET: TT-52[needs decision]" "$OUTR"
ck "scoped verdict counts member edges only" "FLEET-BLOCKED: 1" "$(grep -m1 '^FLEET-BLOCKED' "$OUTR")"
ck_has "scoped stranded edge"          "TT-51 [Planned] blocked by TT-52 [Backlog] — needs decision" "$OUTR"
ck_lacks "outside gated issue absent"  "TT-21" "$OUTR"
ck_lacks "outside root absent"         "TT-27" "$OUTR"
ck_lacks "outside promote member absent" "TT-55" "$OUTR"
# Fail closed: a non-epic root refuses before any fetch — no FOCUS line in the scope's place.
OUTR2="$WORK/outr2.txt"
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --root TT-20 > "$OUTR2" 2>"$OUTR2.err"; then
  FAIL=$((FAIL+1)); echo "FAIL: non-epic root exited 0"
else
  PASS=$((PASS+1))
fi
ck_has "non-epic root names the label" "does not carry the 'epic' label" "$OUTR2.err"
ck_lacks "non-epic root prints no audit" "FOCUS" "$OUTR2"
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --root TT-404 > "$OUTR2" 2>"$OUTR2.err"; then
  FAIL=$((FAIL+1)); echo "FAIL: missing root exited 0"
else
  PASS=$((PASS+1))
fi
ck_has "missing root named" "issue 'TT-404' not found" "$OUTR2.err"

# Fetch failure: exit non-zero, no verdict line (fail loud, never empty-as-clean).
rm "$FIX/issues-page.json"
OUT2="$WORK/out2.txt"
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT2" 2>"$OUT2.err"; then
  FAIL=$((FAIL+1)); echo "FAIL: broken fetch exited 0"
else
  PASS=$((PASS+1))
fi
ck_lacks "no verdict on failure" "FLEET-BLOCKED" "$OUT2"
# The shim's failed `cat` is the silent shape — empty stdout, exit 1 — which set -e used to turn into a bare
# exit 1 with nothing on stderr; the guard must get to name it.
ck_has "fetch failure is named" "ERROR: issue fetch failed for team 'TT'" "$OUT2.err"
ck_lacks "no promote-set on failure" "PROMOTE-SET" "$OUT2"
ck_lacks "no close-set on failure" "CLOSE-SET" "$OUT2"

if "$SCRIPT" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: no-args exited 0"; else PASS=$((PASS+1)); fi

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
