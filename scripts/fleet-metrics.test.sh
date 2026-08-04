#!/usr/bin/env bash
# Regression suite for fleet-metrics.py. Builds a fixture checkout + transcript tree carrying the REAL
# transcript row shapes (verified against live basefund fleet transcripts 2026-08-04: duplicated
# message ids with verbatim-identical usage, subagent .meta.json sidecars, tool_use/tool_result
# pairing) and asserts the emitted numbers. GROW THIS SUITE WITH THE SCHEMA — every column added to
# the script gets an assertion here; never quietly redefine what an existing one means.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-metrics.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}

# ---- fixture: a checkout with state + verdict files, and a projects dir with transcripts ----
CHECKOUT="$WORK/checkout"
mkdir -p "$CHECKOUT/tmp"
git -C "$CHECKOUT" init -q 2>/dev/null
git -C "$CHECKOUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-1: fix the widget"

cat > "$CHECKOUT/tmp/auto-state-abc12345.json" <<'EOF'
{"status": "halted", "reason": "test", "shipped": ["TT-1", "TT-2"], "canceled": [], "skipped": [], "failed": []}
EOF

# New-format verdict: origin-tagged severities, two filed issues. TT-1 is shipped by the session.
cat > "$CHECKOUT/tmp/quality-review-verdict-tt-1.md" <<'EOF'
Verdict: passed-after-fixes
Cycles: 3 (initial + 2 re-reviews)
Findings resolved: 4 (CRIT/impl: null deref in handler; HIGH/plan: missed absorbed criterion; MEDIUM/test: unpinned branch; MED/latent: adjacent gap)
Deferred fixed in-session: 1 (comment fix)
Deferred filed as issues: TT-40, TT-41 (sub-issues of TT-9)
Deferred dropped: none
Open items: none
EOF

# Old-format verdict (pre-origin): bare severities, nothing filed. TT-3 was shipped by no session in
# the window — its filing volume must stay out of the filed-per-shipped numerator.
cat > "$CHECKOUT/tmp/quality-review-verdict-tt-3.md" <<'EOF'
Verdict: passed-after-fixes
Cycles: 2 (initial + 1 re-review)
Findings resolved: 2 (HIGH: race in retry loop; MED: unchecked cast)
Deferred fixed in-session: none
Deferred filed as issues: TT-50
Deferred dropped: none
Open items: none
EOF

# TT-2 is shipped but has NO verdict file — the shipped-with-no-verdict flag must fire.

# Mangle from git's resolved toplevel, not $CHECKOUT — the script resolves through git rev-parse,
# and on macOS mktemp's /var/folders is a symlink to /private/var/folders, so the two differ.
MANGLED="$(git -C "$CHECKOUT" rev-parse --show-toplevel | tr / -)"
TDIR="$WORK/projects/$MANGLED"
SUBDIR="$TDIR/abc12345-0000/subagents"
mkdir -p "$SUBDIR"

# Main transcript: loop firing, ScheduleWakeup, one bg + one sync Agent dispatch, a blind and a marker
# sleep (tool_use -> tool_result 300s/60s apart), a SHIPPED tag, and THREE usage rows across TWO
# message ids — the duplicated id must be counted once (the double-count bug this suite pins).
cat > "$TDIR/abc12345-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T10:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T10:00:10Z","message":{"role":"assistant","id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1000},"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"bg dispatch","prompt":"x"}}]}}
{"type":"assistant","timestamp":"2026-08-04T10:00:11Z","message":{"role":"assistant","id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1000},"content":[{"type":"tool_use","id":"toolu_2","name":"Agent","input":{"description":"sync dispatch","prompt":"x","run_in_background":false}}]}}
{"type":"user","timestamp":"2026-08-04T10:01:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"},{"type":"tool_result","tool_use_id":"toolu_2","content":"done"}]}}
{"type":"assistant","timestamp":"2026-08-04T10:02:00Z","message":{"role":"assistant","id":"msg_B","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"sleep 300"}},{"type":"tool_use","id":"toolu_4","name":"Bash","input":{"command":"until [ -f tmp/run.done ]; do sleep 10; done"}}]}}
{"type":"user","timestamp":"2026-08-04T10:07:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"ok"}]}}
{"type":"user","timestamp":"2026-08-04T10:08:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_4","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-04T10:09:00Z","message":{"role":"assistant","id":"msg_C","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":250},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-1 done"},{"type":"tool_use","id":"toolu_5","name":"ScheduleWakeup","input":{"delaySeconds":1200,"reason":"idle"}}]}}
{"type":"user","timestamp":"2026-08-04T10:09:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_5","content":"armed"}]}}
EOF

# Subagent transcript + meta sidecar: tokens must land under developer/claude-sonnet-5.
cat > "$SUBDIR/agent-t1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-08-04T10:03:00Z","agentId":"t1","isSidechain":true,"message":{"role":"assistant","id":"msg_S","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":700},"content":[{"type":"text","text":"fixed"}]}}
EOF
cat > "$SUBDIR/agent-t1.meta.json" <<'EOF'
{"agentType":"developer","description":"fix batch","toolUseId":"toolu_1","spawnDepth":1}
EOF

# ---- run ----
JSON="$WORK/out.json"
MD="$WORK/out.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CHECKOUT" --all --json > "$JSON" 2>"$WORK/err" || { echo "FAIL: json run exited $?"; cat "$WORK/err"; exit 1; }
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CHECKOUT" --all > "$MD" 2>&1 || { echo "FAIL: md run exited $?"; exit 1; }

q() { python3 -c "import json,sys; d=json.load(open('$JSON')); print($1)"; }

# session metrics (pre-existing schema — regression guard)
ck "one session"        "1"        "$(q "len(d['sessions'])")"
ck "loop firing"        "1"        "$(q "d['sessions'][0]['loop_firings']")"
ck "wakeups"            "1"        "$(q "d['sessions'][0]['wakeups']")"
ck "dispatch bg"        "1"        "$(q "d['sessions'][0]['dispatch'].get('background',0)")"
ck "dispatch sync"      "1"        "$(q "d['sessions'][0]['dispatch'].get('sync',0)")"
ck "blind sleep hours"  "0.08"     "$(q "d['sessions'][0]['sleep_blind_h']")"
ck "marker sleep hours" "0.1"      "$(q "d['sessions'][0]['sleep_marker_h']")"
ck "observed ship tag"  "['TT-1']" "$(q "d['sessions'][0]['observed_shipped']")"

# token attribution: msg_A counted ONCE (1000, not 2000) despite two rows; main = 1000+500+250.
ck "main tokens dedup"  "1750"     "$(q "d['sessions'][0]['output_tokens']['main/claude-opus-5']")"
ck "subagent tokens"    "700"      "$(q "d['sessions'][0]['output_tokens']['developer/claude-sonnet-5']")"
ck "fleet token total"  "2450"     "$(q "sum(d['output_tokens'].values())")"

# review churn: two verdicts; TT-1 matched to the session, TT-3 unmatched.
ck "churn rows"         "2"        "$(q "len(d['review_churn'])")"
ck "tt1 cycles"         "3"        "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['cycles']")"
ck "tt1 findings"       "4"        "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['findings_resolved']")"
ck "tt1 severity"       "{'CRIT': 1, 'HIGH': 1, 'MED': 2}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['severity']")"
ck "tt1 origins"        "{'impl': 1, 'plan': 1, 'test': 1, 'latent': 1}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['origin']")"
ck "tt1 filed"          "['TT-40', 'TT-41']" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['filed']")"
ck "tt1 run matched"    "abc12345" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['run']")"
ck "tt3 old-format sev" "{'HIGH': 1, 'MED': 1}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['severity']")"
ck "tt3 no origins"     "{}"       "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['origin']")"
ck "tt3 run unmatched"  "None"     "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['run']")"

# filed-per-shipped pairs THIS fleet's filings (TT-1's two) with its ships (TT-1, TT-2); TT-3's
# filing stays out of the numerator.
ck "filed per shipped"  "1.0"      "$(q "d['filed_per_shipped']")"

# markdown-mode sections and flags
ck_has "churn table row"     "| TT-1 | \`abc12345\` | passed-after-fixes | 3 | 4 | 1/1/2 |" "$MD"
ck_has "origin cell"         "impl:1" "$MD"
ck_has "tokens table"        "| developer | claude-sonnet-5 | 700 |" "$MD"
ck_has "no-verdict flag"     "Shipped with no persisted review verdict**: TT-2" "$MD"
ck_has "origin coverage"     "origin-tagged 4/6" "$MD"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
