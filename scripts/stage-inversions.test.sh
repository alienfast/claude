#!/usr/bin/env bash
# Regression suite for stage-inversions.sh. Pins the classification with a fixture deps graph:
# name-matched blocked side (Planned/Todo), TYPE-matched blocker side (backlog/triage — a renamed
# Triage state still classifies), non-blocks edges and terminal-state blockers ignored, unknown
# nodes tolerated, and the INVERSIONS verdict line that makes an empty result distinguishable from
# a broken run. Same isolation as next-candidates.test.sh: linear-cli is a PATH shim and HOME is
# an empty dir so the deps script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/stage-inversions.sh"
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

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

# Deps page (linear-deps-graph.sh --team shape). Edges derive from each node's relations:
#   TT-21 (Backlog)          blocks TT-20 (Planned) -> inversion
#   TT-23 (Inbox, type triage) blocks TT-22 (Todo)  -> inversion (renamed Triage classifies by TYPE)
#   TT-25 (Planned)          blocks TT-24 (Planned) -> not an inversion (same stage)
#   TT-27 (Backlog)          blocks TT-26 (Backlog) -> not (blocked side not Planned/Todo)
#   TT-29 (RFR, type started) blocks TT-28 (Planned) -> not (blocker not deferred-stage)
#   TT-21 related TT-20                              -> ignored (not a blocks edge)
#   TT-31 (Backlog)          blocks TT-99 (absent)  -> tolerated, no match, no crash
cat > "$FIX/deps-page.json" <<'EOF'
{"data":{"issues":{"nodes":[
 {"identifier":"TT-20","title":"planned dependent","state":{"name":"Planned","type":"unstarted"},"relations":{"nodes":[]}},
 {"identifier":"TT-21","title":"backlog blocker","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-20"}},{"type":"related","relatedIssue":{"identifier":"TT-20"}}]}},
 {"identifier":"TT-22","title":"todo dependent","state":{"name":"Todo","type":"unstarted"},"relations":{"nodes":[]}},
 {"identifier":"TT-23","title":"renamed triage blocker","state":{"name":"Inbox","type":"triage"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-22"}}]}},
 {"identifier":"TT-24","title":"planned dependent same-stage","state":{"name":"Planned","type":"unstarted"},"relations":{"nodes":[]}},
 {"identifier":"TT-25","title":"planned blocker","state":{"name":"Planned","type":"unstarted"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-24"}}]}},
 {"identifier":"TT-26","title":"backlog dependent","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[]}},
 {"identifier":"TT-27","title":"backlog blocker two","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-26"}}]}},
 {"identifier":"TT-28","title":"planned dependent rfr","state":{"name":"Planned","type":"unstarted"},"relations":{"nodes":[]}},
 {"identifier":"TT-29","title":"shipped blocker","state":{"name":"Ready for Release","type":"started"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-28"}}]}},
 {"identifier":"TT-31","title":"blocker of absent node","state":{"name":"Backlog","type":"backlog"},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-99"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
if [ "\${1:-}" != "api" ]; then exit 0; fi
q="\${@: -1}"
case "\$q" in
  *relatedIssue*) cat "\$FIX/deps-page.json" ;;
  *) printf '%s' '{"errors":[{"message":"unexpected query in test shim"}]}'; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

OUT="$WORK/out.txt"
HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT" 2>"$OUT.err" \
  || { echo "FAIL: run exited $?"; cat "$OUT.err"; exit 1; }

ck "verdict line" "INVERSIONS: 2" "$(head -1 "$OUT")"
ck_has  "backlog inversion"        "TT-20 [Planned] blocked by TT-21 [Backlog]" "$OUT"
ck_has  "renamed-triage inversion" "TT-22 [Todo] blocked by TT-23 [Inbox]" "$OUT"
ck_lacks "same-stage excluded"     "TT-24" "$OUT"
ck_lacks "backlog dependent excluded" "TT-26" "$OUT"
ck_lacks "terminal blocker excluded"  "TT-28" "$OUT"
ck_lacks "absent node tolerated"      "TT-99" "$OUT"

# Fetch failure must exit non-zero with an error, never print a verdict (fail loud, not empty).
rm "$FIX/deps-page.json"
OUT2="$WORK/out2.txt"
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT2" 2>"$OUT2.err"; then
  FAIL=$((FAIL+1)); echo "FAIL: broken fetch exited 0"
else
  PASS=$((PASS+1))
fi
ck_lacks "no verdict on failure" "INVERSIONS" "$OUT2"

# Usage errors.
if "$SCRIPT" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: no-args exited 0"; else PASS=$((PASS+1)); fi

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
