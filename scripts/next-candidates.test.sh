#!/usr/bin/env bash
# Regression suite for next-candidates.sh's RANKING — the ordering policy has so far only ever
# been verified against live Linear data, which shifts under every re-check (the 2026-08-05
# stage-first change was validated that way and needed three live probes to disentangle rank
# truncation from blocking). Fixtures pin: stage-first (Planned/Todo drains fully before Backlog,
# Urgent included), Urgent piercing label classes WITHIN a stage, security > bug > other,
# Ready-for-Release blockers resolving case-insensitively, open blockers hiding a candidate
# (restored by --include-blocked), and the needs decision / solo / human hiding notes.
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
  if grep -qF "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
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
 {"identifier":"TT-13","title":"human work","estimate":null,"priority":3,"state":{"name":"Planned","type":"unstarted"},"assignee":null,"labels":{"nodes":[{"name":"human"}]},"parent":null}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

# Deps page (linear-deps-graph.sh --team shape): TT-8 blocks TT-7, TT-10 blocks TT-9.
cat > "$FIX/deps-page.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-8","title":"shipped blocker","state":{"name":"Ready for Release","type":"completed"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-7"}}]}},
 {"identifier":"TT-10","title":"open blocker","state":{"name":"In Progress","type":"started"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-9"}}]}}
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

ck "stage-first order" "TT-3 TT-2 TT-4 TT-5 TT-7 TT-1 TT-6" "$(order_of "$OUT")"
ck_has  "rfr blocker resolved"  "TT-7" "$OUT"
ck_lacks "open blocker hidden"  "TT-9" "$OUT"
ck_lacks "blocker not candidate" "TT-8" "$OUT"
ck_has  "needs-decision note"   '1 issue(s) hidden awaiting a human decision (`needs decision` label; top: TT-11)' "$OUT"
ck_has  "solo note"             "1 issue(s) hidden as fleet-hostile" "$OUT"
ck_has  "human note"            "1 issue(s) hidden as human-owned work" "$OUT"
grep -E '^[0-9]+\. ' "$OUT" > "$WORK/ranked.txt"
ck_lacks "parked not ranked"    "TT-11" "$WORK/ranked.txt"
ck_lacks "solo hidden"          "TT-12" "$OUT"
ck_lacks "human hidden"         "TT-13" "$OUT"

# ---- --include-blocked: TT-9 restored (Low outranks TT-7's None), everything else unchanged ----
OUT2="$WORK/out2.md"
run "$OUT2" --limit 20 --include-blocked || { echo "FAIL: include-blocked run exited $?"; cat "$OUT2.err"; exit 1; }
ck "blocked order" "TT-3 TT-2 TT-4 TT-5 TT-9 TT-7 TT-1 TT-6" "$(order_of "$OUT2")"

# ---- label filter: only the security-labeled issues, stage-first within the filter ----
OUT3="$WORK/out3.md"
run "$OUT3" --limit 20 --label security || { echo "FAIL: label run exited $?"; cat "$OUT3.err"; exit 1; }
ck "label filter order" "TT-2 TT-6" "$(order_of "$OUT3")"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
