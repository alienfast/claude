#!/usr/bin/env bash
# Regression suite for fleet-blockers.sh. Fixture-pins every classification: the four gate labels
# (human / needs decision / solo / stalled), the two deferred stages (Triage by TYPE — a renamed
# "Inbox" still classifies — and Backlog), uncertified blockers, combined reasons on one blocker,
# clean and in-flight blockers NOT flagged, non-candidate blocked sides (uncertified or label-
# hidden) skipped, non-blocks edges ignored, and the FLEET-BLOCKED verdict line that makes an
# empty result distinguishable from a broken run. linear-cli is a PATH shim; HOME is an empty dir
# so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-blockers.sh"
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
 {"identifier":"TT-41","state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-40"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
if [ "\${1:-}" != "api" ]; then exit 0; fi
q="\${@: -1}"
case "\$q" in
  *labels*) cat "\$FIX/issues-page.json" ;;
  *) printf '%s' '{"errors":[{"message":"unexpected query in test shim"}]}'; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

OUT="$WORK/out.txt"
HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT" 2>"$OUT.err" \
  || { echo "FAIL: run exited $?"; cat "$OUT.err"; exit 1; }

ck "verdict line" "FLEET-BLOCKED: 7" "$(head -1 "$OUT")"
ck_has "needs-decision blocker" "TT-20 [Planned] blocked by TT-21 [Planned] — needs decision (decide and clear the label)" "$OUT"
ck_has "human blocker"          "TT-22 [Planned] blocked by TT-23 [Planned] — human-labeled (human-performed; the fleet never ships it)" "$OUT"
ck_has "solo blocker"           "TT-24 [Planned] blocked by TT-25 [Planned] — solo (targeted /auto in the quiet window)" "$OUT"
ck_has "renamed-triage blocker" "TT-26 [Todo] blocked by TT-27 [Inbox] — in Triage (groom via /spec)" "$OUT"
ck_has "backlog+uncertified combined" "TT-28 [Planned] blocked by TT-29 [Backlog] — in Backlog (promote to Planned); uncertified (/spec to certify)" "$OUT"
ck_has "uncertified planned blocker"  "TT-30 [Planned] blocked by TT-31 [Planned] — uncertified (/spec to certify)" "$OUT"
ck_has "stalled in-flight blocker"    "TT-32 [Planned] blocked by TT-33 [In Progress] — stalled (resume or release it)" "$OUT"
ck_lacks "clean blocker drains"        "TT-34" "$OUT"
ck_lacks "in-flight blocker resolves"  "TT-36" "$OUT"
ck_lacks "uncertified dependent skipped" "TT-38" "$OUT"
ck_lacks "hidden dependent skipped"      "TT-40" "$OUT"

# Verdict counts EDGES, so recount expectations: 7 flagged rows above vs verdict 6 would fail —
# assert consistency directly instead of trusting the hand count.
rows=$(grep -c 'blocked by' "$OUT")
verdict=$(head -1 "$OUT" | grep -oE '[0-9]+')
ck "verdict matches rows" "$rows" "$verdict"

# Fetch failure: exit non-zero, no verdict line (fail loud, never empty-as-clean).
rm "$FIX/issues-page.json"
OUT2="$WORK/out2.txt"
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" --team TT > "$OUT2" 2>"$OUT2.err"; then
  FAIL=$((FAIL+1)); echo "FAIL: broken fetch exited 0"
else
  PASS=$((PASS+1))
fi
ck_lacks "no verdict on failure" "FLEET-BLOCKED" "$OUT2"

if "$SCRIPT" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: no-args exited 0"; else PASS=$((PASS+1)); fi

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
