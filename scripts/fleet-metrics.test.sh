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
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
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

# Off-schema verdict: Verdict + Cycles present, no `Findings resolved:` line — the free-form-prose
# shape the 2026-08-03 fleet produced. Must flag as malformed, not silently count 0 findings.
cat > "$CHECKOUT/tmp/quality-review-verdict-tt-4.md" <<'EOF'
# Quality Review Verdict — TT-4

Verdict: passed-after-fixes
Cycles: 2

The review resolved two findings in prose form: a null deref in the handler and a race in the retry
loop. Both fixed and confirmed.
EOF

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
{"type":"assistant","timestamp":"2026-08-04T10:00:10Z","message":{"role":"assistant","id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":100000,"output_tokens":1000},"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"bg dispatch","prompt":"x"}}]}}
{"type":"assistant","timestamp":"2026-08-04T10:00:11Z","message":{"role":"assistant","id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":100000,"output_tokens":1000},"content":[{"type":"tool_use","id":"toolu_2","name":"Agent","input":{"description":"sync dispatch","prompt":"x","run_in_background":false}}]}}
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

# LEDGER-LESS session: a real /loop /auto run with NO tmp/auto-state-def45678.json. This is the
# 2026-08-04 shape — /auto's Step 0 GC deleted two drained ledgers, and the fleet then measured as
# two sessions instead of four. Must be discovered from the transcript and flagged, never dropped.
# Starts AFTER abc12345 so the span-ordered session list keeps abc12345 at index 0.
cat > "$TDIR/def45678-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T11:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T11:15:00Z","message":{"role":"assistant","id":"msg_N","model":"claude-nova-2","usage":{"input_tokens":10,"output_tokens":50},"content":[{"type":"text","text":"noted"}]}}
{"type":"assistant","timestamp":"2026-08-04T11:30:00Z","message":{"role":"assistant","id":"msg_D","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":300},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-7 done"},{"type":"text","text":"BLOCKED-ON-REVIEW: TT-8 — MAIN-CHECKOUT-CONTAMINATION: path(s) changed in the main checkout during this session (src/widget.ts) — most likely a mis-bound delegate; manual recovery required."},{"type":"text","text":"BLOCKED-ON-REVIEW: TT-8 — MAIN-CHECKOUT-CONTAMINATION: path(s) changed in the main checkout during /quality-review (src/widget.ts); manual recovery required."},{"type":"text","text":"planning to emit BLOCKED-ON-REVIEW: TT-9 — MAIN-CHECKOUT-CONTAMINATION if the diff flags anything"}]}}
EOF

# NOT an /auto session — an ordinary interactive session in the same project dir. The discovery
# pass must ignore it, or every retro invents sessions out of unrelated work.
cat > "$TDIR/99900001-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T12:00:00Z","message":{"role":"user","content":"fix the flaky spec in the payments suite"}}
{"type":"assistant","timestamp":"2026-08-04T12:01:00Z","message":{"role":"assistant","id":"msg_E","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":90},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-99 done"}]}}
EOF

# ---- run ----
JSON="$WORK/out.json"
MD="$WORK/out.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CHECKOUT" --all --json > "$JSON" 2>"$WORK/err" || { echo "FAIL: json run exited $?"; cat "$WORK/err"; exit 1; }
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CHECKOUT" --all > "$MD" 2>&1 || { echo "FAIL: md run exited $?"; exit 1; }

q() { python3 -c "import json,sys; d=json.load(open('$JSON')); print($1)"; }

# session metrics (pre-existing schema — regression guard)
ck "two sessions"       "2"        "$(q "len(d['sessions'])")"
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
ck "fleet token total"  "2800"     "$(q "sum(d['output_tokens'].values())")"

# full usage + cost: input/cache fields dedup by message id exactly like output (msg_A once), cost is
# price-weighted (input 5 + cache write 2x + cache read 0.1x + output 25, per MTok), the unknown
# model is named rather than silently dropped, and per-shipped normalizes over all 3 fleet ships.
# abc12345: opus (30*5 + 2000*10 + 100000*0.5 + 1750*25)/1e6 + sonnet (5*3 + 700*15)/1e6 = 0.1244.
ck "usage input dedup"  "30"       "$(q "d['sessions'][0]['usage']['main/claude-opus-5']['input']")"
ck "usage cache write"  "2000"     "$(q "d['sessions'][0]['usage']['main/claude-opus-5']['cache_write']")"
ck "usage cache read"   "100000"   "$(q "d['sessions'][0]['usage']['main/claude-opus-5']['cache_read']")"
ck "subagent usage"     "5"        "$(q "d['sessions'][0]['usage']['developer/claude-sonnet-5']['input']")"
ck "session est cost"   "0.1244"   "$(q "d['sessions'][0]['est_cost_usd']")"
ck "fleet est cost"     "0.132"    "$(q "d['est_cost_usd']")"
ck "unpriced named"     "['claude-nova-2']" "$(q "d['unpriced_models']")"
ck "per-shipped tokens" "933"      "$(q "d['per_shipped']['output_tokens']")"
ck "per-shipped cost"   "0.04"     "$(q "d['per_shipped']['est_cost_usd']")"

# thinking share: the residual after visible output (text + tool_use input chars at 4 chars/token).
# abc12345 main emits 274 visible chars against 1750 output tokens -> 1 - 68.5/1750 = 0.96.
ck "thinking share"     "0.96"     "$(q "d['sessions'][0]['main_thinking_share_est']")"

# ledger-less discovery: def45678 has no state file and must still be measured and flagged; the
# non-/auto session 99900001 must not appear at all (its SHIPPED tag is not a fleet ship).
ck "ledgerless found"    "1"        "$(q "len([s for s in d['sessions'] if s['ledger_missing']])")"
ck "ledgerless key"      "def45678" "$(q "[s['run_key'] for s in d['sessions'] if s['ledger_missing']][0]")"
ck "ledgerless ships"    "['TT-7']" "$(q "[s['observed_shipped'] for s in d['sessions'] if s['ledger_missing']][0]")"
ck "ledgerless no rec"   "[]"       "$(q "[s['recorded_shipped'] for s in d['sessions'] if s['ledger_missing']][0]")"
ck "stateful not flagged" "False"   "$(q "[s['ledger_missing'] for s in d['sessions'] if s['run_key']=='abc12345'][0]")"
ck "non-auto ignored"    "0"        "$(q "len([s for s in d['sessions'] if s['run_key']=='99900001'])")"
ck "non-auto ship excluded" "0"     "$(q "len([s for s in d['sessions'] if 'TT-99' in s['observed_shipped']])")"

# review churn: three verdicts; TT-1 matched to the session, TT-3 unmatched, TT-4 off-schema.
ck "churn rows"         "3"        "$(q "len(d['review_churn'])")"
ck "tt1 cycles"         "3"        "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['cycles']")"
ck "tt1 findings"       "4"        "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['findings_resolved']")"
ck "tt1 severity"       "{'CRIT': 1, 'HIGH': 1, 'MED': 2}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['severity']")"
ck "tt1 origins"        "{'impl': 1, 'plan': 1, 'test': 1, 'latent': 1}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['origin']")"
ck "tt1 filed"          "['TT-40', 'TT-41']" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['filed']")"
ck "tt1 run matched"    "abc12345" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['run']")"
ck "tt3 old-format sev" "{'HIGH': 1, 'MED': 1}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['severity']")"
ck "tt3 no origins"     "{}"       "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['origin']")"
ck "tt3 run unmatched"  "None"     "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['run']")"
ck "tt1 well-formed"    "[]"       "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['missing_fields']")"
ck "tt4 missing fields" "['Findings resolved']" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-4'][0]['missing_fields']")"

# contamination halts: the tagged hard-stop line in def45678 counts once per issue despite two
# renders (chat print + Step 10 summary); the mid-line prose mention of TT-9 must NOT count (the
# line anchor); abc12345 emitted none.
ck "contam halts dedup" "['TT-8']" "$(q "[s['contamination_halts'] for s in d['sessions'] if s['run_key']=='def45678'][0]")"
ck "contam clean"       "[]"       "$(q "d['sessions'][0]['contamination_halts']")"
ck_has "contam column"       "| cls | contam | dangling |" "$MD"
ck_has "contam flag"         "\`def45678\` hit 1 contamination halt(s)** (TT-8)" "$MD"
ck_has "contam totals"       "1 contamination halt(s)" "$MD"

# filed-per-shipped pairs THIS fleet's filings (TT-1's two) with its ships (TT-1, TT-2); TT-3's
# filing stays out of the numerator.
# Denominator is 3 now — TT-7 comes from the ledger-less session, which is exactly the point: a
# discovered session's ships count toward the fleet's totals like any other.
ck "filed per shipped"  "0.67"     "$(q "d['filed_per_shipped']")"

# markdown-mode sections and flags
ck_has "churn table row"     "| TT-1 | \`abc12345\` | passed-after-fixes | 3 | 4 | 1/1/2 |" "$MD"
ck_has "origin cell"         "impl:1" "$MD"
ck_has "tokens table"        "| main | claude-opus-5 | 2,050 | 73% | \$0.12 |" "$MD"
ck_has "cost cell"           "| developer | claude-sonnet-5 | 700 | 25% | \$0.01 |" "$MD"
ck_has "unpriced cell"       "| main | claude-nova-2 | 50 | 2% | unpriced |" "$MD"
ck_has "cost footer"         "\$0.13 at list prices" "$MD"
ck_has "per-shipped footer"  "\$0.04 / 933 output tokens per shipped issue (3 shipped)" "$MD"
# Fleet-level share (all sessions' main tiers), so def45678's contamination-halt text dilutes it;
# the per-session 0.96 assertion above still pins abc12345's math.
ck_has "thinking footer"     "thinking ≈ 91% of its output tokens" "$MD"
ck_has "unpriced footer"     "excluded from \$ (no price row): claude-nova-2" "$MD"
ck_has "no-verdict flag"     "Shipped with no persisted review verdict**: TT-2" "$MD"
ck_has "off-schema flag"     "Off-schema verdict body**: TT-4 (no Findings resolved line)" "$MD"
ck_has "off-schema ? render" "| TT-4 | \`-\` | passed-after-fixes | 2 | ? |" "$MD"
ck_has "origin coverage"     "origin-tagged 4/6" "$MD"
ck_has "ledgerless flag"     "\`def45678\` ran without a surviving ledger" "$MD"
ck_has "ledgerless names it" "no \`tmp/auto-state-def45678.json\`" "$MD"
ck_has "ledgerless rec dash" "| \`def45678\`  ⚠ | 0.5h | -/1 | -/0 |" "$MD"
# "Step 4 never ran" is the wrong diagnosis for a deleted ledger — Step 4 did run. Not double-flagged.
ck_lacks "no double flag"    "\`def45678\` shipped without recording it" "$MD"

# ---- total-loss fixture: every ledger GC'd, transcripts intact ----
# The worst case of the 2026-08-04 fault, taken to its limit. Before the discovery pass this exited
# 1 with "No auto-state files", i.e. a fleet that shipped real work reported as never having run.
CK2="$WORK/checkout2"
mkdir -p "$CK2/tmp"
git -C "$CK2" init -q 2>/dev/null
git -C "$CK2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
M2="$(git -C "$CK2" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M2"
cat > "$WORK/projects/$M2/aaa11111-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T09:00:00Z","message":{"role":"user","content":"<command-name>/auto</command-name><command-args>TT-5</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T09:40:00Z","message":{"role":"assistant","id":"msg_F","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":120},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-5 done"}]}}
EOF
J2="$WORK/out2.json"
if CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK2" --all --json > "$J2" 2>/dev/null; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL: total-loss run exited non-zero — a ledger-less fleet must still report"
fi
q2() { python3 -c "import json,sys; d=json.load(open('$J2')); print($1)"; }
ck "total-loss session"  "1"        "$(q2 "len(d['sessions'])")"
ck "total-loss flagged"  "True"     "$(q2 "d['sessions'][0]['ledger_missing']")"
ck "total-loss ships"    "['TT-5']" "$(q2 "d['sessions'][0]['observed_shipped']")"
ck "total-loss per-ship" "120"      "$(q2 "d['per_shipped']['output_tokens']")"

# ---- windowed-out ledger fixture: the file EXISTS, it just predates the cutoff ----
# The 2026-08-06 fault. The two discovery passes filter on different mtimes — pass 1 on the state
# file's, pass 2 on the transcript's — so a session that worked inside the window while its ledger
# last changed before the cutoff reached pass 2 with the file still on disk and was flagged "ran
# without a surviving ledger". That flag means /auto Step 4 never ran, which the retro chases as a
# real fault; it fired 6 times on that fleet, more than every genuine fault combined. The ledger must
# be adopted, not guessed at, so recorded-vs-observed still catches a genuine unrecorded ship.
CK3="$WORK/checkout3"
mkdir -p "$CK3/tmp"
git -C "$CK3" init -q 2>/dev/null
git -C "$CK3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-6: land it"
M3="$(git -C "$CK3" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M3"

cat > "$CK3/tmp/auto-state-bbb22222.json" <<'EOF'
{"status": "drained", "reason": "deadline", "shipped": ["TT-6"], "canceled": [], "skipped": [], "failed": []}
EOF
cat > "$WORK/projects/$M3/bbb22222-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T09:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T09:30:00Z","message":{"role":"assistant","id":"msg_G","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":400},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-6 done"}]}}
EOF
# Ledger 10 days stale, transcript touched now: any --hours window straddles the two.
touch -t 202607250000 "$CK3/tmp/auto-state-bbb22222.json"

J3="$WORK/out3.json"
MD3="$WORK/out3.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK3" --hours 24 --json > "$J3" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK3" --hours 24 > "$MD3" 2>&1
q3() { python3 -c "import json,sys; d=json.load(open('$J3')); print($1)"; }
ck "windowed-out found"    "1"        "$(q3 "len(d['sessions'])")"
ck "windowed-out NOT flagged" "False" "$(q3 "d['sessions'][0]['ledger_missing']")"
ck "windowed-out reads ledger" "['TT-6']" "$(q3 "d['sessions'][0]['recorded_shipped']")"
ck_lacks "no false ledger flag" "ran without a surviving ledger" "$MD3"

# A genuinely absent ledger in the same window still flags — the fix must not blanket-suppress.
cat > "$WORK/projects/$M3/ccc33333-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T13:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T13:30:00Z","message":{"role":"assistant","id":"msg_H","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":60},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-11 done"}]}}
EOF
J4="$WORK/out4.json"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK3" --hours 24 --json > "$J4" 2>/dev/null
q4() { python3 -c "import json,sys; d=json.load(open('$J4')); print($1)"; }
ck "real gap still flags"  "['ccc33333']" "$(q4 "sorted(s['run_key'] for s in d['sessions'] if s['ledger_missing'])")"
ck "both sessions present" "2"            "$(q4 "len(d['sessions'])")"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
