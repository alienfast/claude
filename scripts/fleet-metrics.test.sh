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
ts_ago() { python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

# ---- fixture: a checkout with state + verdict files, and a projects dir with transcripts ----
CHECKOUT="$WORK/checkout"
mkdir -p "$CHECKOUT/tmp"
git -C "$CHECKOUT" init -q 2>/dev/null
git -C "$CHECKOUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-1: fix the widget"

cat > "$CHECKOUT/tmp/auto-state-abc12345.json" <<'EOF'
{"status": "halted", "reason": "test", "shipped": ["TT-1", "TT-2"], "canceled": [], "skipped": [], "failed": []}
EOF

# New-format verdict: origin-tagged severities (the NICE-TO-HAVE tag pins V_ORIGIN's widened
# alternation — dropped compliant tags were invisible, BF-1248), two filed issues. TT-1 is shipped
# by the session.
cat > "$CHECKOUT/tmp/quality-review-verdict-tt-1.md" <<'EOF'
Verdict: passed-after-fixes
Cycles: 3 (initial + 2 re-reviews)
Findings resolved: 4 (CRIT/impl: null deref in handler; HIGH/plan: missed absorbed criterion; MEDIUM/test: unpinned branch; MED/latent: adjacent gap; NICE-TO-HAVE/plan: cosmetic rename)
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
{"type":"assistant","timestamp":"2026-08-04T10:00:11Z","message":{"role":"assistant","id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":100000,"output_tokens":1000},"content":[{"type":"tool_use","id":"toolu_2","name":"Agent","input":{"description":"sync dispatch","prompt":"x","run_in_background":false}},{"type":"tool_use","id":"toolu_6","name":"Agent","input":{"description":"ignored dispatch","prompt":"x","run_in_background":false}},{"type":"tool_use","id":"toolu_7","name":"Agent","input":{"description":"dangling bg dispatch","prompt":"x"}}]}}
{"type":"user","timestamp":"2026-08-04T10:01:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Async agent launched successfully (agentId: t1)"},{"type":"tool_result","tool_use_id":"toolu_2","content":"done"},{"type":"tool_result","tool_use_id":"toolu_6","content":"Async agent launched successfully (agentId: t9)"}]}}
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
# Ground-truth census: mode comes from the tool RESULT (async-launch line vs inline report), never
# from the typed value — toolu_1 (async result) and dangling toolu_7 (typed-intent fallback) are the
# 2 background; toolu_2's inline report is the 1 sync DESPITE also typing false; toolu_6 typed false
# and got the async line anyway — the ignored bucket, the per-dispatch parameter-less-harness signal.
ck "dispatch bg"        "2"        "$(q "d['sessions'][0]['dispatch'].get('background',0)")"
ck "dispatch sync"      "1"        "$(q "d['sessions'][0]['dispatch'].get('sync',0)")"
ck "dispatch ignored"   "1"        "$(q "d['sessions'][0]['dispatch'].get('ignored',0)")"
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
ck "thinking share"     "0.94"     "$(q "d['sessions'][0]['main_thinking_share_est']")"

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
ck "tt1 origins"        "{'impl': 1, 'plan': 2, 'test': 1, 'latent': 1}" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['origin']")"
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
ck_has "thinking footer"     "thinking ≈ 90% of its output tokens" "$MD"
ck_has "unpriced footer"     "excluded from \$ (no price row): claude-nova-2" "$MD"
ck_has "no-verdict flag"     "Shipped with no persisted review verdict**: TT-2" "$MD"
ck_has "off-schema flag"     "Off-schema verdict body**: TT-4 (no Findings resolved line)" "$MD"
ck_has "off-schema ? render" "| TT-4 | \`-\` | passed-after-fixes | 2 | ? |" "$MD"
ck_has "origin coverage"     "origin-tagged 5/6" "$MD"
ck_has "ledgerless flag"     "\`def45678\` ran without a surviving ledger" "$MD"
ck_has "ledgerless names it" "no \`tmp/auto-state-def45678.json\`" "$MD"
ck_has "ledgerless rec dash" "| \`def45678\`  ⚠ | 0.5h | 0% | -/1 | -/0 |" "$MD"
# "Step 4 never ran" is the wrong diagnosis for a deleted ledger — Step 4 did run. Not double-flagged.
ck_lacks "no double flag"    "\`def45678\` shipped without recording it" "$MD"

# context distribution: per-call prompt tokens (input + cache write + cache read) bucketed by size,
# message-id-deduped like every other usage field — msg_A counts once (102,010 -> 50_150k); the
# small calls (msg_B 10, msg_C 10, subagent msg_S 5) pool in lt50k.
ck "ctx buckets"        "{'lt50k': 25, '50_150k': 102010}" "$(q "d['sessions'][0]['context_volume_tokens']")"
ck "ctx ge200k share"   "0.0"      "$(q "d['sessions'][0]['ctx_share_ge200k']")"
ck "fleet ctx ge150k"   "0.0"      "$(q "d['context_distribution']['share_ge150k']")"
ck_has "ctx column"          "| run | span | ctx>=200k |" "$MD"
ck_has "ctx totals line"     "**Context distribution**" "$MD"

# provenance without a Linear export: every ship classes unknown, and the md names the files to write.
ck "prov all unknown"   "{'unknown': 3}" "$(q "d['shipped_provenance']['counts']")"
ck_has "prov pointer"        "no Linear export found" "$MD"

# history: --all sweeps are never recorded (an all-time pool is not a fleet).
ck "no history on --all" "0"       "$(q "len(d['history'])")"
ck_has "trend not recorded"  "not recorded for --all sweeps" "$MD"

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
# Activity must be genuinely IN-window (dynamic timestamps): the scenario is "the session worked
# inside the window, only its ledger file predates the cutoff" — hardcoded old row timestamps would
# turn it into the stale-session shape below and the activity gate would rightly drop it.
cat > "$WORK/projects/$M3/bbb22222-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 7200)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 5400)","message":{"role":"assistant","id":"msg_G","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":400},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-6 done"}]}}
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
cat > "$WORK/projects/$M3/ccc33333-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 3600)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 1800)","message":{"role":"assistant","id":"msg_H","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":60},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-11 done"}]}}
EOF
J4="$WORK/out4.json"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK3" --hours 24 --json > "$J4" 2>/dev/null
q4() { python3 -c "import json,sys; d=json.load(open('$J4')); print($1)"; }
ck "real gap still flags"  "['ccc33333']" "$(q4 "sorted(s['run_key'] for s in d['sessions'] if s['ledger_missing'])")"
ck "both sessions present" "2"            "$(q4 "len(d['sessions'])")"

# ---- quota-stall fixture: the RECOVERED shape, from the 2026-08-06 basefund fleet ----
# Three sessions stop within 3 minutes of each other (04:44/04:45/04:47), stay dark 10.7h, resume
# within 60s of each other (15:28) and drain NORMALLY with terminal tags. The pre-2026-08-07
# detector keyed on last-activity + absence of a terminal tag and so reported no stall at all,
# while 47% of that fleet's capacity had been lost. A fourth session runs straight through and must
# stay OUT of the group.
CK5="$WORK/checkout5"
mkdir -p "$CK5/tmp"
git -C "$CK5" init -q 2>/dev/null
M5="$(git -C "$CK5" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M5"

for run in aa111111 bb222222 cc333333; do
  cat > "$CK5/tmp/auto-state-$run.json" <<EOF
{"status": "drained", "reason": "fleet deadline reached", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF
done
cat > "$CK5/tmp/auto-state-dd444444.json" <<'EOF'
{"status": "drained", "reason": "fleet deadline reached", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF

mk_stalled() { # mk_stalled <run> <quiet-at> ; resumes at a common 15:28, ends tagged
  cat > "$WORK/projects/$M5/$1-0000.jsonl" <<EOF
{"type":"user","timestamp":"2026-08-07T00:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-07T02:00:00Z","message":{"role":"assistant","id":"msg_$1a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"$2","message":{"role":"assistant","id":"msg_$1b","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"mid-issue"}]}}
{"type":"assistant","timestamp":"2026-08-07T15:28:38Z","message":{"role":"assistant","id":"msg_$1c","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":40},"content":[{"type":"text","text":"deadline passed"}]}}
{"type":"assistant","timestamp":"2026-08-07T15:30:00Z","message":{"role":"assistant","id":"msg_$1d","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":40},"content":[{"type":"text","text":"AUTO-HALTED: fleet deadline"}]}}
EOF
}
mk_stalled aa111111 "2026-08-07T04:44:01Z"
mk_stalled bb222222 "2026-08-07T04:45:30Z"
mk_stalled cc333333 "2026-08-07T04:47:00Z"

# The survivor: continuous activity across the same window, ending tagged. Never in a stall group.
cat > "$WORK/projects/$M5/dd444444-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-07T00:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-07T04:44:10Z","message":{"role":"assistant","id":"msg_dda","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"still going"}]}}
{"type":"assistant","timestamp":"2026-08-07T09:00:00Z","message":{"role":"assistant","id":"msg_ddb","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"still going"}]}}
{"type":"assistant","timestamp":"2026-08-07T13:00:00Z","message":{"role":"assistant","id":"msg_ddc","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"still going"}]}}
{"type":"assistant","timestamp":"2026-08-07T15:30:00Z","message":{"role":"assistant","id":"msg_ddd","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":40},"content":[{"type":"text","text":"AUTO-HALTED: fleet deadline"}]}}
EOF

J5="$WORK/out5.json"
MD5="$WORK/out5.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK5" --since 2026-08-06 --json > "$J5" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK5" --since 2026-08-06 > "$MD5" 2>&1
q5() { python3 -c "import json,sys; d=json.load(open('$J5')); print($1)"; }
ck "recovered stall detected"  "1" "$(q5 "len(d['windows']['quota_stall_groups'])")"
ck "stall names the 3 stalled" "['aa111111', 'bb222222', 'cc333333']" \
   "$(q5 "sorted(d['windows']['quota_stall_groups'][0]['runs'])")"
ck "survivor excluded"         "False" \
   "$(q5 "'dd444444' in d['windows']['quota_stall_groups'][0]['runs']")"
ck "stall kind recovered"      "recovered" "$(q5 "d['windows']['quota_stall_groups'][0]['kind']")"
ck "stall quiet_at earliest"   "2026-08-07T04:44:01Z" "$(q5 "d['windows']['quota_stall_groups'][0]['quiet_at']")"
ck "stall resumed_at"          "2026-08-07T15:28:38Z" "$(q5 "d['windows']['quota_stall_groups'][0]['resumed_at']")"
ck "lost session-hours summed" "32.2" "$(q5 "d['windows']['quota_stall_groups'][0]['lost_session_hours']")"
ck_has "stall reported in md"  "quota-stall fingerprint" "$MD5"
ck_has "md says drained clean" "drained normally" "$MD5"

# ---- quota-stall fixture: RECOVERED with SPREAD ONSET, from the 2026-08-08 basefund fleet ----
# Same recovered shape as above, but the sessions go quiet 56.2 minutes apart (09:23:48 / 10:14:01 /
# 10:20:00 — consecutive deltas 3013s and 359s) because each kept emitting until its own last
# in-flight delegate drained. They resume 2.1 minutes apart (18:42:04 / 18:40:17 / 18:39:58 — deltas
# 19s and 107s), since the allowance frees at one wall-clock moment account-wide. Onset-only
# clustering at 120s grouped NOTHING here and the retro reported a clean run while 26.1 session-hours
# were dead — and, worse, reported the output peak as a floor when the cutoff makes it a ceiling.
CK7="$WORK/checkout7"
mkdir -p "$CK7/tmp"
git -C "$CK7" init -q 2>/dev/null
M7="$(git -C "$CK7" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M7"

mk_spread() { # mk_spread <run> <quiet-at> <resume-at> <throttled|selfended>
  cat > "$CK7/tmp/auto-state-$1.json" <<EOF
{"status": "drained", "reason": "fleet deadline reached", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF
  # The quiet row is what makes the session go dark: for a THROTTLED session it carries the harness
  # limit message, for a SELF-ENDED one a terminal tag plus ScheduleWakeup(stop:true). Both then sit
  # silent for hours and resume together, so the silence alone cannot tell them apart.
  if [ "$4" = "throttled" ]; then
    QUIET_TEXT="You have hit your weekly limit - resets Aug 11 at 5pm (America/Chicago)"
    QUIET_EXTRA=""
  else
    QUIET_TEXT="AUTO-HALTED: fleet deadline 04:40 CDT reached with 18 minutes left - too little to ship an issue."
    QUIET_EXTRA=$'\n'"{\"type\":\"assistant\",\"timestamp\":\"$2\",\"message\":{\"role\":\"assistant\",\"id\":\"msg_$1s\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5},\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_$1\",\"name\":\"ScheduleWakeup\",\"input\":{\"stop\":true}}]}}"
  fi
  # The 06:00 row lands inside the 5h window ENDING at the earliest THROTTLED quiet (05:14-10:14); the
  # 02:00 row predates it. Both are needed to prove cutoff_trailing_5h windows rather than totals.
  cat > "$WORK/projects/$M7/$1-0000.jsonl" <<EOF
{"type":"user","timestamp":"2026-08-08T00:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-08T02:00:00Z","message":{"role":"assistant","id":"msg_$1a","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":500},"content":[{"type":"text","text":"early"}]}}
{"type":"assistant","timestamp":"2026-08-08T06:00:00Z","message":{"role":"assistant","id":"msg_$1b","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":1000},"content":[{"type":"text","text":"in cutoff window"}]}}
{"type":"assistant","timestamp":"$2","message":{"role":"assistant","id":"msg_$1c","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":700},"content":[{"type":"text","text":"$QUIET_TEXT"}]}}$QUIET_EXTRA
{"type":"assistant","timestamp":"$3","message":{"role":"assistant","id":"msg_$1d","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":40},"content":[{"type":"text","text":"resumed"}]}}
{"type":"assistant","timestamp":"2026-08-08T19:00:00Z","message":{"role":"assistant","id":"msg_$1e","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":40},"content":[{"type":"text","text":"AUTO-HALTED: fleet deadline"}]}}
EOF
}
# r1111111 is ed644317: it read the deadline with 18 minutes left, judged that too little to ship, and
# wound down properly. Its 9.3h of correct silence must NOT be billed as lost capacity.
mk_spread r1111111 "2026-08-08T09:23:48Z" "2026-08-08T18:42:04Z" selfended
mk_spread r2222222 "2026-08-08T10:14:01Z" "2026-08-08T18:40:17Z" throttled
mk_spread r3333333 "2026-08-08T10:20:00Z" "2026-08-08T18:39:58Z" throttled

J7="$WORK/out7.json"
MD7="$WORK/out7.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK7" --since 2026-08-07 --json > "$J7" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK7" --since 2026-08-07 > "$MD7" 2>&1
q7() { python3 -c "import json,sys; d=json.load(open('$J7')); print($1)"; }
ck "spread-onset stall detected" "1" "$(q7 "len(d['windows']['quota_stall_groups'])")"
# The self-ended session is excluded; only the two the harness actually refused are in the group.
ck "spread names the 2 throttled" "['r2222222', 'r3333333']" \
   "$(q7 "sorted(d['windows']['quota_stall_groups'][0]['runs'])")"
ck "self-ended loop excluded"    "False" \
   "$(q7 "'r1111111' in d['windows']['quota_stall_groups'][0]['runs']")"
ck "spread kind recovered"       "recovered" "$(q7 "d['windows']['quota_stall_groups'][0]['kind']")"
ck "spread quiet_at earliest"    "2026-08-08T10:14:01Z" "$(q7 "d['windows']['quota_stall_groups'][0]['quiet_at']")"
ck "spread resumed_at latest"    "2026-08-08T18:40:17Z" "$(q7 "d['windows']['quota_stall_groups'][0]['resumed_at']")"
ck "lost hours exclude self-end" "16.8" "$(q7 "d['windows']['quota_stall_groups'][0]['lost_session_hours']")"
# The limit is READ from the harness message, never inferred from the silence — weekly and 5-hour
# produce the same fingerprint and carry opposite levers (duration vs concurrency).
ck "limit kind read from msg"    "['weekly']" "$(q7 "d['windows']['quota_stall_groups'][0]['limit_kind']")"
ck_has "md names the limit"      "Limit named by the harness: **weekly**" "$MD7"
ck_has "md names weekly lever"   "duration / total session-hours" "$MD7"
# Cutoff meters read the 5h ENDING at the earliest THROTTLED quiet (05:14-10:14): three 06:00 rows
# (1000 output each), r1111111's 09:23:48 row (700), r2222222's own 10:14:01 boundary row (700), and
# NOT the 02:00 rows nor r3333333's 10:20:00 row, which falls after the window closes. r1111111's
# stop-call record sits at 09:23:48 too and carries 5 output / 15 billable of its own, so the totals
# are 4405 / 5000 / 9465 rather than 4400 / 5000 / 9450 — the meters count every credited message in
# the window, including a session the STALL logic excluded. That is correct: the allowance was spent
# by the whole account, so a session that wound down voluntarily still consumed part of the window.
ck "cutoff meters emitted"       "1" "$(q7 "len(d['windows']['cutoff_trailing_5h'])")"
ck "cutoff at earliest quiet"    "2026-08-08T10:14:01Z" "$(q7 "d['windows']['cutoff_trailing_5h'][0]['at']")"
ck "cutoff output windowed"      "4405" "$(q7 "d['windows']['cutoff_trailing_5h'][0]['output_tokens']")"
ck "cutoff cache-read windowed"  "5000" "$(q7 "d['windows']['cutoff_trailing_5h'][0]['cache_read_tokens']")"
ck "cutoff billable windowed"    "9465" "$(q7 "d['windows']['cutoff_trailing_5h'][0]['total_billable_tokens']")"
ck_has "md flips to CEILINGS"    "CEILINGS, not floors" "$MD7"
ck_has "md prints cutoff meters" "cutoff-window meters" "$MD7"
ck_lacks "md drops floor claim"  "Both peaks are FLOORS" "$MD7"

# A run that was NOT cut off keeps the floor framing and emits no cutoff meters.
ck_lacks "clean run has no cutoff meters" "cutoff-window meters" "$MD"
ck_has  "clean run keeps floor framing"   "Both peaks are FLOORS" "$MD"

# The UNRECOVERED shape must still fire — the fix widens the detector, it does not replace it.
CK6="$WORK/checkout6"
mkdir -p "$CK6/tmp"
git -C "$CK6" init -q 2>/dev/null
M6="$(git -C "$CK6" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M6"
for run in ee555555 ff666666; do
  cat > "$CK6/tmp/auto-state-$run.json" <<EOF
{"status": "running", "reason": "", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF
done
# Activity must stay DENSE right up to the death: an unrecovered stall is trailing silence, which
# leaves no internal gap to find. A sparse fixture would fake one and misclassify as recovered.
mk_dead() { # mk_dead <run> <final-row-time>
  cat > "$WORK/projects/$M6/$1-0000.jsonl" <<EOF
{"type":"user","timestamp":"2026-08-07T04:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-07T04:15:00Z","message":{"role":"assistant","id":"msg_$1a","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"2026-08-07T04:30:00Z","message":{"role":"assistant","id":"msg_$1b","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"$2","message":{"role":"assistant","id":"msg_$1c","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500},"content":[{"type":"text","text":"mid-issue"}]}}
EOF
}
mk_dead ee555555 "2026-08-07T04:44:00Z"
mk_dead ff666666 "2026-08-07T04:45:00Z"
J6="$WORK/out6.json"
MD6="$WORK/out6.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK6" --since 2026-08-06 --json > "$J6" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK6" --since 2026-08-06 > "$MD6" 2>&1
q6() { python3 -c "import json,sys; d=json.load(open('$J6')); print($1)"; }
ck "unrecovered stall detected" "1" "$(q6 "len(d['windows']['quota_stall_groups'])")"
ck "unrecovered kind"           "unrecovered" "$(q6 "d['windows']['quota_stall_groups'][0]['kind']")"
ck "unrecovered no resume"      "None" "$(q6 "d['windows']['quota_stall_groups'][0]['resumed_at']")"
ck_has "md says never recovered" "never recovered" "$MD6"

# ---- LIVE-SESSION fixture (BF-1029): a retro run against a fleet that has not finished ----
# A session mid-run has no long silence and no terminal tag, so before the min_silence_s gate it fell
# through to the `unrecovered` arm marked at its last activity — which is ~now. Two live sessions are
# therefore always within cluster_s of each other and always formed a bogus group (0 lost hours, no
# limit_kind), which flipped the sizing banner to CEILINGS and pointed /fleet-launch at cutoff-window
# meters describing no cutoff. These timestamps MUST derive from the current clock: hardcoded, the
# fixture decays into a stale-session fixture the next day and silently stops testing this path.
CK8="$WORK/checkout8"
mkdir -p "$CK8/tmp"
git -C "$CK8" init -q 2>/dev/null
M8="$(git -C "$CK8" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M8"
TS_A="$(ts_ago 2400)"   # 40 min ago
TS_B="$(ts_ago 1500)"   # 25 min ago — every internal gap stays under min_silence_s (30 min)
TS_C="$(ts_ago 10)"     # seconds ago: what a LIVE session's last activity looks like
for run in aa777777 bb888888; do
  cat > "$CK8/tmp/auto-state-$run.json" <<EOF
{"status": "active", "reason": "", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF
  cat > "$WORK/projects/$M8/$run-0000.jsonl" <<EOF
{"type":"user","timestamp":"$TS_A","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$TS_B","message":{"role":"assistant","id":"msg_${run}a","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":500},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"$TS_C","message":{"role":"assistant","id":"msg_${run}b","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":500},"content":[{"type":"text","text":"mid-issue"}]}}
EOF
done
J8="$WORK/out8.json"
MD8="$WORK/out8.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK8" --hours 2 --json > "$J8" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK8" --hours 2 > "$MD8" 2>&1
q8() { python3 -c "import json,sys; d=json.load(open('$J8')); print($1)"; }
ck "live sessions form no group"  "0" "$(q8 "len(d['windows']['quota_stall_groups'])")"
ck "live run emits no cutoff meters" "0" "$(q8 "len(d['windows']['cutoff_trailing_5h'])")"
ck_has  "live run keeps floor framing" "Both peaks are FLOORS" "$MD8"
ck_lacks "live run does not flip banner" "CEILINGS, not floors" "$MD8"
ck_lacks "live run prints no meters"     "cutoff-window meters" "$MD8"

# ---- developer-lanes fixture: implementation vs fix-batch attribution, and the tier join ----
# The 2026-08-09 basefund retro read the by-model token table as "72% of developer output ran on
# sonnet" and routed its impl-heavy origin mix at developer model — but 86% of that row was
# /quality-review fix batches (pinned to sonnet by design) and 14 of 23 issues were implemented at
# the opus default. Lane membership is decided by dispatch start vs the issue's first
# quality-reviewer dispatch; the issue id comes from the meta description, else the modal id in the
# dispatch prompt; an issue shipped with dispatch records but no impl dispatch is main-loop work.
CK9="$WORK/checkout9"
mkdir -p "$CK9/tmp"
git -C "$CK9" init -q 2>/dev/null
git -C "$CK9" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
M9="$(git -C "$CK9" rev-parse --show-toplevel | tr / -)"
SUB9="$WORK/projects/$M9/gg999999-0000/subagents"
mkdir -p "$SUB9"

cat > "$CK9/tmp/auto-state-gg999999.json" <<'EOF'
{"status": "drained", "reason": "deadline", "shipped": ["TT-20", "TT-21"], "canceled": [], "skipped": [], "failed": []}
EOF
cat > "$CK9/tmp/quality-review-verdict-tt-20.md" <<'EOF'
Verdict: passed-after-fixes
Cycles: 2 (initial + 1 re-review)
Findings resolved: 3 (HIGH/impl: guard missing; MED/impl: stale cache path; MED/test: unpinned branch)
Deferred filed as issues: none
EOF
cat > "$CK9/tmp/quality-review-verdict-tt-21.md" <<'EOF'
Verdict: passed
Cycles: 1
Findings resolved: 1 (MED/impl: off-by-one in pager)
Deferred filed as issues: none
EOF

cat > "$WORK/projects/$M9/gg999999-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T10:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-04T10:30:00Z","message":{"role":"assistant","id":"msg_gga","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":80},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-20 done"}]}}
{"type":"assistant","timestamp":"2026-08-04T11:00:00Z","message":{"role":"assistant","id":"msg_ggb","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":70},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-21 done"}]}}
EOF

# TT-20's implementation (opus, before its review start), the review that sets the lane boundary,
# and the post-review fix batch (sonnet). Descriptions carry the issue id.
cat > "$SUB9/agent-i1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-08-04T10:05:00Z","agentId":"i1","isSidechain":true,"message":{"role":"assistant","id":"msg_i1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":100},"content":[{"type":"text","text":"built"}]}}
EOF
cat > "$SUB9/agent-i1.meta.json" <<'EOF'
{"agentType":"developer","description":"Implement TT-20 widget","toolUseId":"tu_i1","spawnDepth":1}
EOF
cat > "$SUB9/agent-r1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-08-04T10:10:00Z","agentId":"r1","isSidechain":true,"message":{"role":"assistant","id":"msg_r1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":50},"content":[{"type":"text","text":"reviewed"}]}}
EOF
cat > "$SUB9/agent-r1.meta.json" <<'EOF'
{"agentType":"quality-reviewer","description":"Adversarial review TT-20","toolUseId":"tu_r1","spawnDepth":1}
EOF
cat > "$SUB9/agent-f1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-08-04T10:15:00Z","agentId":"f1","isSidechain":true,"message":{"role":"assistant","id":"msg_f1","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":200},"content":[{"type":"text","text":"fixed"}]}}
EOF
cat > "$SUB9/agent-f1.meta.json" <<'EOF'
{"agentType":"developer","description":"Fix TT-20 review findings","toolUseId":"tu_f1","spawnDepth":1}
EOF
# Issue-less developer dispatch (no id in description, no user row): must land in `unattributed`,
# never guessed into a lane.
cat > "$SUB9/agent-u1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-08-04T10:12:00Z","agentId":"u1","isSidechain":true,"message":{"role":"assistant","id":"msg_u1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":30},"content":[{"type":"text","text":"measured"}]}}
EOF
cat > "$SUB9/agent-u1.meta.json" <<'EOF'
{"agentType":"developer","description":"probe reachability","toolUseId":"tu_u1","spawnDepth":1}
EOF
# Description names no issue but the dispatch prompt does (modal id wins; TT-9 is a context
# mention) — the fallback path. TT-22 has no reviewer dispatch, so this is impl by definition.
cat > "$SUB9/agent-p1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-04T10:07:00Z","agentId":"p1","isSidechain":true,"message":{"role":"user","content":"Task for developer: TT-22 needs the resolver converged. TT-22's plan is the latest comment; context in TT-9."}}
{"type":"assistant","timestamp":"2026-08-04T10:08:00Z","agentId":"p1","isSidechain":true,"message":{"role":"assistant","id":"msg_p1","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":40},"content":[{"type":"text","text":"converged"}]}}
EOF
cat > "$SUB9/agent-p1.meta.json" <<'EOF'
{"agentType":"developer","description":"Converge the resolver","toolUseId":"tu_p1","spawnDepth":1}
EOF

J9="$WORK/out9.json"
MD9="$WORK/out9.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK9" --all --json > "$J9" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK9" --all > "$MD9" 2>&1
q9() { python3 -c "import json,sys; d=json.load(open('$J9')); print($1)"; }
ck "impl lane by model"   "{'claude-opus-5': 100, 'claude-sonnet-5': 40}" "$(q9 "d['developer_lanes']['impl']")"
ck "fix lane by model"    "{'claude-sonnet-5': 200}" "$(q9 "d['developer_lanes']['fix']")"
ck "unattributed lane"    "{'claude-opus-5': 30}"    "$(q9 "d['developer_lanes']['unattributed']")"
ck "tt20 implemented_by"  "['claude-opus-5']" "$(q9 "[v for v in d['review_churn'] if v['issue']=='TT-20'][0]['implemented_by']")"
ck "tt21 main-loop"       "['main-loop']"     "$(q9 "[v for v in d['review_churn'] if v['issue']=='TT-21'][0]['implemented_by']")"
ck "tier join opus"       "{'n': 1, 'mean': 2.0, 'median': 2, 'values': [2]}" "$(q9 "d['impl_origin_by_tier']['opus']")"
ck "tier join main-loop"  "{'n': 1, 'mean': 1.0, 'median': 1, 'values': [1]}" "$(q9 "d['impl_origin_by_tier']['main-loop']")"
ck_has "churn impl-by header" "| filed | impl by |" "$MD9"
ck_has "tt20 row impl by"     "| TT-20 | \`gg999999\` | passed-after-fixes | 2 | 3 | 0/1/2 | impl:2 test:1 | 0 | opus |" "$MD9"
ck_has "tt21 row main-loop"   "| TT-21 | \`gg999999\` | passed | 1 | 1 | 0/0/1 | impl:1 | 0 | main-loop |" "$MD9"
ck_has "join line groups"     "opus n=1 · mean 2.0 · median 2.0" "$MD9"
ck_has "lanes line split"     "implementation 140 (claude-opus-5 100, claude-sonnet-5 40) · post-review fix 200 (claude-sonnet-5 200) · unattributed 30" "$MD9"

# First fixture's new fields: agent-t1 ("fix batch", no issue id, no prompt row) stays unattributed;
# TT-1 shipped by a session WITH dispatch records but no impl dispatch -> main-loop; TT-3's session
# is unknown -> attribution honestly absent, and its old-format verdict (origin-untagged, 2 findings)
# must stay OUT of the tier join rather than counting as zero impl findings.
ck "t1 stays unattributed" "{'claude-sonnet-5': 700}" "$(q "d['developer_lanes']['unattributed']")"
ck "tt1 main-loop fallback" "['main-loop']" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-1'][0]['implemented_by']")"
ck "tt3 attribution unknown" "None" "$(q "[v for v in d['review_churn'] if v['issue']=='TT-3'][0]['implemented_by']")"
# A {…,…} literal at the $(q …) call site is brace-expanded: bash's textual brace pass cannot see
# that the braces sit inside a nested quoted string, so the word splits at the comma and q runs twice
# on the halves, each a python error → empty $3. A variable passes through intact — parameter
# expansion runs after brace expansion.
TIER_JOIN_EXPR="{k: v['values'] for k, v in d['impl_origin_by_tier'].items()}"
ck "untagged verdict out of join" "{'main-loop': [1]}" "$(q "$TIER_JOIN_EXPR")"

# ---- stale-session fixture: file touched in-window, last ACTIVITY long before it ----
# The 2026-08-13 fault. Transcript trailing metadata (ai-title/agent-name rows) touched a session
# whose last real message was Aug 10 05:56 UTC, and the adoption pass's transcript-mtime filter
# pooled it into an Aug 13 retro: 25 shipped reported for a fleet that shipped 19, 49.8
# session-hours for 36.9, and a 12.9h/1.05M-token session inside every fleet total and both peak
# windows. mtime is not activity — the window gates on the measured last message timestamp and
# reports the exclusion. Fixture files are created NOW (fresh mtimes) with hardcoded old row
# timestamps, which is exactly the bug's shape and stays stale for any future clock.
CK10="$WORK/checkout10"
mkdir -p "$CK10/tmp"
git -C "$CK10" init -q 2>/dev/null
git -C "$CK10" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-30: current work"
M10="$(git -C "$CK10" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M10"

cat > "$CK10/tmp/auto-state-stale0001.json" <<'EOF'
{"status": "stopped", "reason": "an earlier fleet's deadline", "shipped": ["TT-90"], "canceled": [], "skipped": [], "failed": []}
EOF
cat > "$WORK/projects/$M10/stale0001-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-08-01T09:00:00Z","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"2026-08-01T21:00:00Z","message":{"role":"assistant","id":"msg_ST","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":5000},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-90 done"}]}}
EOF

# With ONLY the stale session matched, the run must refuse with a diagnosis naming it — an empty
# report or a zero-division would read as "no fleet ran" against a tree that plainly has one.
if CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK10" --hours 24 --json > "$WORK/out10a.json" 2>"$WORK/err10a"; then
  FAIL=$((FAIL+1)); echo "FAIL: all-stale run must exit non-zero"
else
  PASS=$((PASS+1))
fi
ck_has "all-stale names the run" "stale0001" "$WORK/err10a"

# A live session alongside it: the stale one is excluded and REPORTED; every total is live-only.
cat > "$CK10/tmp/auto-state-live0001.json" <<'EOF'
{"status": "halted", "reason": "deadline", "shipped": ["TT-30"], "canceled": [], "skipped": [], "failed": []}
EOF
cat > "$WORK/projects/$M10/live0001-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 7000)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 3000)","message":{"role":"assistant","id":"msg_LV","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":800},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-30 done"}]}}
EOF
J10="$WORK/out10.json"
MD10="$WORK/out10.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK10" --hours 24 --json > "$J10" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK10" --hours 24 > "$MD10" 2>&1
q10() { python3 -c "import json,sys; d=json.load(open('$J10')); print($1)"; }
ck "stale session excluded"      "['live0001']" "$(q10 "sorted(s['run_key'] for s in d['sessions'])")"
ck "exclusion reported"          "stale0001"    "$(q10 "d['excluded_stale'][0]['run_key']")"
ck "exclusion carries end time"  "2026-08-01T21:00:00Z" "$(q10 "d['excluded_stale'][0]['ended']")"
ck "fleet tokens live-only"      "800"          "$(q10 "sum(d['output_tokens'].values())")"
ck "per-shipped live-only"       "800"          "$(q10 "d['per_shipped']['output_tokens']")"
ck "peak window live-only"       "800"          "$(q10 "d['windows']['peak_5h_output_tokens']")"
ck_has "md notes the exclusion"  "Excluded from the window" "$MD10"
ck_has "md names the stale run"  "\`stale0001\` (ended 2026-08-01T21:00:00Z)" "$MD10"
ck_lacks "stale row absent from table" "| \`stale0001\`" "$MD10"
# An --all run has no cutoff and must keep the stale session — the gate is the window's, not global.
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK10" --all --json > "$WORK/out10b.json" 2>/dev/null
ck "--all keeps both" "2" "$(python3 -c "import json; print(len(json.load(open('$WORK/out10b.json'))['sessions']))")"

# ---- trend + provenance fixture: history ledger, ctx buckets at scale, Linear join ----
# The 2026-08-14 finding this schema extension exists for: cost-per-issue climbed $90 -> $161 across
# five fleets whose reports nothing diffed, with 91% of billable volume at >200k context and a
# growing share of ships being issues the pipeline filed for itself. Three assertions pin the three
# gauges: the history row (recorded, deduped by session set, appended per new set), the >=200k
# context share, and the shipped-issue provenance classes.
CK11="$WORK/checkout11"
mkdir -p "$CK11/tmp"
git -C "$CK11" init -q 2>/dev/null
git -C "$CK11" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-70: land it"
M11="$(git -C "$CK11" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M11"

cat > "$CK11/tmp/auto-state-ee555555.json" <<'EOF'
{"status": "drained", "reason": "deadline", "shipped": ["TT-70"], "canceled": [], "skipped": [], "failed": []}
EOF
# ctx per call: 450,010 (ge400k) + 250,010 (200_400k) + 10 (lt50k) -> ge200k share ~1.0.
cat > "$WORK/projects/$M11/ee555555-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 7200)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 7000)","message":{"role":"assistant","id":"msg_P","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":450000,"output_tokens":100},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-70 done"}]}}
{"type":"assistant","timestamp":"$(ts_ago 6900)","message":{"role":"assistant","id":"msg_Q","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":250000,"output_tokens":100},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"$(ts_ago 6800)","message":{"role":"assistant","id":"msg_R","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100},"content":[{"type":"text","text":"AUTO-HALTED: deadline"}]}}
EOF
# Linear export for the provenance join: TT-70 created 3 days before the fleet started, by the
# review pipeline's own filing — the week_before class, fresh share 1.0.
cat > "$CK11/tmp/fleet-shipped-issues.json" <<EOF
{"data":{"issues":{"nodes":[{"identifier":"TT-70","createdAt":"$(ts_ago 259200)","creator":{"name":"quality-review-bot"}}]}}}
EOF

J11="$WORK/out11.json"
MD11="$WORK/out11.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --hours 24 --json > "$J11" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --hours 24 > "$MD11" 2>&1
q11() { python3 -c "import json,sys; d=json.load(open('$J11')); print($1)"; }
ck "ctx ge400k bucket"     "450010" "$(q11 "d['sessions'][0]['context_volume_tokens']['ge400k']")"
ck "ctx 200_400k bucket"   "250010" "$(q11 "d['sessions'][0]['context_volume_tokens']['200_400k']")"
ck "fleet ge200k share"    "1.0"    "$(q11 "d['context_distribution']['share_ge200k']")"
ck "prov class"            "week_before" "$(q11 "d['shipped_provenance']['issues']['TT-70']['class']")"
ck "prov creator"          "quality-review-bot" "$(q11 "d['shipped_provenance']['issues']['TT-70']['creator']")"
ck "prov fresh share"      "1.0"    "$(q11 "d['shipped_provenance']['fresh_shipped_share']")"
ck_has "md ctx cell 100%"       "| 100% |" "$MD11"
ck_has "md prov week-before"    "1 in the 7 days before launch" "$MD11"
ck_has "md prov fresh share"    "Fresh share **100%**" "$MD11"
ck_has "md prov creator"        "quality-review-bot (1)" "$MD11"
ck_has "md trend section"       "## Cross-run trend" "$MD11"
ck_has "md trend current mark"  " ←" "$MD11"
# History: the json + md runs above measured the SAME session set -> one row, not two (dedupe).
ck "history dedupes rerun"  "1" "$(wc -l < "$CK11/tmp/fleet-metrics-history.jsonl" | tr -d ' ')"
ck "history in json"        "1" "$(q11 "len(d['history'])")"
# (30 input x $5 + 700,000 cache-read x $0.50 + 300 output x $25) / 1e6 = $0.36, over 1 ship.
ck "history cost/ship"      "0.36" "$(q11 "d['history'][0]['cost_per_shipped_usd']")"
ck "history ge200k share"   "1.0"  "$(q11 "d['history'][0]['ctx_share_ge200k']")"

# A second session joins the fleet: the set changes, so the next run APPENDS a row (two fleets, two
# rows) instead of replacing the first — the trend is per-fleet, not last-writer-wins.
cat > "$CK11/tmp/auto-state-ff666666.json" <<'EOF'
{"status": "drained", "reason": "deadline", "shipped": [], "canceled": [], "skipped": [], "failed": []}
EOF
cat > "$WORK/projects/$M11/ff666666-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 3600)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 3000)","message":{"role":"assistant","id":"msg_T","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":50},"content":[{"type":"text","text":"AUTO-HALTED: deadline"}]}}
EOF
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --hours 24 > /dev/null 2>&1
ck "history appends new set" "2" "$(wc -l < "$CK11/tmp/fleet-metrics-history.jsonl" | tr -d ' ')"

# ---- exact-set and --until scoping: overlapping fleets in one window ----
# The 2026-08-18 retro's gap: three fleets overlapped the window, no invocation could isolate the
# one under review, and the history append stamped a 12-session row with the PREVIOUS fleet's
# start. A fleet is a session set, not a time range — --sessions selects exactly that set, and the
# history row (keyed by session_set) then describes the selected fleet, replacing its own earlier
# row rather than minting a mislabeled one. CK11 carries two sessions with distinct starts
# (ee555555 ~2h ago, ff666666 ~1h ago), so it doubles as the overlap fixture.
J12="$WORK/out12.json"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --sessions ee555555 --json > "$J12" 2>/dev/null
q12() { python3 -c "import json,sys; d=json.load(open('$J12')); print($1)"; }
ck "exact set selects one"    "['ee555555']" "$(q12 "sorted(s['run_key'] for s in d['sessions'])")"
ck "exact set replaces its history row" "2" "$(wc -l < "$CK11/tmp/fleet-metrics-history.jsonl" | tr -d ' ')"
ck "history row keyed to the set" "1" "$(python3 -c "
import json
rows=[json.loads(l) for l in open('$CK11/tmp/fleet-metrics-history.jsonl')]
print(len([r for r in rows if r['session_set']=='ee555555']))")"

# A requested key with nothing on disk is a hard error — a silent drop would report a smaller
# fleet than requested, the exact mislabeling --sessions exists to prevent.
if CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --sessions ee555555,nosuchkey --json > /dev/null 2>"$WORK/err12"; then
  FAIL=$((FAIL+1)); echo "FAIL: unknown --sessions key must exit non-zero"
else
  PASS=$((PASS+1))
fi
ck_has "missing key named" "nosuchkey" "$WORK/err12"

# An explicitly named key overrides the is_auto_session probe (the operator named it), and the
# verdict sweep scopes to the selected set's own activity span — CHECKOUT's three verdict files
# have fresh mtimes while 99900001's span is 2026-08-04, so none may pool in.
J13="$WORK/out13.json"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CHECKOUT" --sessions 99900001 --json > "$J13" 2>/dev/null
q13() { python3 -c "import json,sys; d=json.load(open('$J13')); print($1)"; }
ck "named key skips auto probe" "['99900001']" "$(q13 "sorted(s['run_key'] for s in d['sessions'])")"
ck "verdicts scoped to set span" "0" "$(q13 "len(d['review_churn'])")"

# --until excludes the later fleet's session by its own FIRST ACTIVITY (mtimes are last-writes),
# and reports the exclusion as a late start rather than pooling it into this fleet's totals.
J14="$WORK/out14.json"
MD14="$WORK/out14.md"
UNTIL="$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=5000)).strftime('%Y-%m-%dT%H:%M:%S'))")"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --hours 24 --until "$UNTIL" --json > "$J14" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK11" --hours 24 --until "$UNTIL" > "$MD14" 2>&1
q14() { python3 -c "import json,sys; d=json.load(open('$J14')); print($1)"; }
ck "--until keeps the earlier fleet" "['ee555555']" "$(q14 "sorted(s['run_key'] for s in d['sessions'])")"
ck "--until reports the late start"  "ff666666"     "$(q14 "d['excluded_stale'][0]['run_key']")"
ck "late exclusion says started"     "1"            "$(q14 "len([e for e in d['excluded_stale'] if 'started' in e])")"
ck_has "md reports late exclusion"   "started " "$MD14"

# ---- launch_epoch boundary: a PRIOR fleet's ledger must not ride this fleet's numbers ----
# Measured 2026-08-21 on jarvis: a prior session's ledger mtime tied fleet-deadline.json's
# launch_epoch to the second (1787271573). Both the `-lt`/`<` comparison and the session filter alone
# let it through, so a finished 4.6h session with 2 pre-launch ships rode a whole retro as a fleet
# member — shipped 5 -> 7, session-hours 7.4 -> 12.0, churn 5 reviews -> 7, severity 0/3/19 -> 1/5/28
# — and /fleet-status showed it ALIVE, sending the operator after a phantom idle session for four
# consecutive checks. Three arms, because the bug had three independent limbs.
CK12="$WORK/checkout12"
mkdir -p "$CK12/tmp"
git -C "$CK12" init -q 2>/dev/null
git -C "$CK12" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "TT-40: fleet work"
M12="$(git -C "$CK12" rev-parse --show-toplevel | tr / -)"
mkdir -p "$WORK/projects/$M12"

LAUNCH=$(python3 -c "import time; print(int(time.time()) - 7200)")
cat > "$CK12/tmp/fleet-deadline.json" <<EOF
{"deadline_epoch": $((LAUNCH + 43200)), "deadline": "test", "count": 1, "launch_epoch": $LAUNCH}
EOF

for run in prior001 fleet001; do
  cat > "$CK12/tmp/auto-state-$run.json" <<EOF
{"status": "drained", "reason": "deadline", "shipped": ["TT-$run"], "canceled": [], "skipped": [], "failed": []}
EOF
  cat > "$WORK/projects/$M12/$run-0000.jsonl" <<EOF
{"type":"user","timestamp":"$(ts_ago 6000)","message":{"role":"user","content":"<command-name>/loop</command-name><command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(ts_ago 1200)","message":{"role":"assistant","id":"msg_$run","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":400},"content":[{"type":"text","text":"SHIPPED-MERGE: TT-$run done"}]}}
EOF
done
cat > "$CK12/tmp/quality-review-verdict-tt-prior.md" <<'EOF'
# /quality-review verdict — TT-PRIOR
Verdict: passed-after-fixes
Cycles: 2
Findings resolved: 6 (HIGH/impl: prior fleet finding)
EOF
cat > "$CK12/tmp/quality-review-verdict-tt-fleet.md" <<'EOF'
# /quality-review verdict — TT-FLEET
Verdict: passed-after-fixes
Cycles: 1
Findings resolved: 2 (MED/plan: this fleet finding)
EOF

# The tie itself, carried with a SUB-SECOND remainder. launch_epoch is whole seconds while st_mtime
# is a float, so a raw `<=` compares ...573.448 against ...573 and passes the prior ledger through —
# the first fix for this bug was inert for exactly that reason and its suite went green anyway.
python3 - "$CK12" "$LAUNCH" <<'PY'
import os, sys, pathlib
ck, launch = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for name, mt in (("tmp/auto-state-prior001.json", launch + 0.448),
                 ("tmp/quality-review-verdict-tt-prior.md", launch + 0.9),
                 ("tmp/auto-state-fleet001.json", launch + 60),
                 ("tmp/quality-review-verdict-tt-fleet.md", launch + 60)):
    os.utime(ck / name, (mt, mt))
PY

J12="$WORK/out12.json"; MD12="$WORK/out12.md"
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK12" --hours 24 --json > "$J12" 2>/dev/null
CLAUDE_PROJECTS_DIR="$WORK/projects" "$SCRIPT" --checkout "$CK12" --hours 24 > "$MD12" 2>&1
q12() { python3 -c "import json,sys; d=json.load(open('$J12')); print($1)"; }
ck "launch tie: prior ledger excluded"   "['fleet001']" "$(q12 "sorted(s['run_key'] for s in d['sessions'])")"
# The ledgerless pass re-adopts an excluded state file straight off disk, so pass-1 filtering alone
# changes nothing — this arm is what catches that limb regressing.
ck "launch tie: not re-added as ledgerless" "0" "$(q12 "len(d.get('ledgerless', []))")"
ck "launch tie: tokens fleet-only"       "400" "$(q12 "sum(d['output_tokens'].values())")"
# Verdicts are globbed off disk, not attributed through the session set, so they need their own gate.
ck "launch tie: prior verdict excluded"  "['TT-FLEET']" "$(q12 "sorted(v['issue'] for v in d['review_churn'])")"
ck "launch tie: fleet verdict kept"      "2"   "$(q12 "d['review_churn'][0]['findings_resolved']")"
ck_lacks "launch tie: prior run absent from table" "prior001" "$MD12"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
