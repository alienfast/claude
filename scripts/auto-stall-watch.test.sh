#!/usr/bin/env bash
# Regression suite for auto-stall-watch.sh.
#
# Fixtures carry the REAL transcript shapes from two fleets. From 2026-08-14: the quota-cutoff tail (an
# assistant turn whose text is the limit message, with NO stop_hook_summary after it), which is what
# makes the stall invisible to every Stop hook — a synthetic "silent session" fixture would pass against
# a check that only looked at mtime and would not pin that distinction. From 2026-08-29 (session
# 6a77c517): a turn started by a task notification that ended un-armed, with the re-injected skill
# listing in the tail and the harness's untimestamped bookkeeping records after the last real entry.
#
# Timestamps are generated relative to NOW: silence is measured from the last timestamped record, so a
# fixture carrying a fixed date would read as days silent whatever its case intends.
#
# The agent-list fixture is the LIVE `claude agents --json` schema, re-snapshotted 2026-08-17: rows carry
# pid/cwd/kind/startedAt/sessionId/name — NO `id` field — and every session reports kind:"interactive",
# fleet agents included. The original suite's fixtures hand-carried an older schema (id present, fleet
# rows kind:"background"), so the suite stayed green for three days while the real watcher matched zero
# rows — 371 ticks, no flags, through two real stalls. When this schema drifts again, re-snapshot from
# the live feed, never from memory. One legacy-schema case stays to pin the fallback joins.

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/auto-stall-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
NOW=1786800000

# Sessions are discovered under $HOME/.claude/projects, so point HOME at the sandbox.
export HOME="$TMP"
PROJ="$TMP/.claude/projects/-tmp-repo"
mkdir -p "$PROJ" "$TMP/repo/tmp"

iso_ago() { # <seconds before NOW> -> the harness's ISO-8601 form, millisecond suffix included
  local s=$(( NOW - $1 ))
  date -u -r "$s" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$s" +%Y-%m-%dT%H:%M:%S.000Z
}
touch_ago() { # <seconds before NOW> <file>
  local s=$(( NOW - $1 ))
  touch -t "$(date -r "$s" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$s" +%Y%m%d%H%M.%S)" "$2"
}

mk_agents() { # <file> <id-unused> <sessionId> — live 2026-08-17 schema: no id, kind interactive
  cat > "$1" <<EOF
[{"pid":1,"cwd":"$TMP/repo","kind":"interactive","startedAt":1,"sessionId":"$3","name":"claude-59"}]
EOF
}

mk_agents_legacy() { # <file> <id> <sessionId> — pre-2026-08-17 schema: id present, kind background
  cat > "$1" <<EOF
[{"pid":1,"id":"$2","cwd":"$TMP/repo","kind":"background","startedAt":1,"sessionId":"$3","name":"loop auto mode","status":"idle","state":"working"}]
EOF
}

mk_state() { printf '{"status":"%s","reason":"","shipped":[]}\n' "$2" > "$TMP/repo/tmp/auto-state-$1.json"; }

# Every tail builder takes the age (seconds before NOW) of its LAST timestamped record.

# The observed cutoff tail: the limit message IS the final assistant turn. Nothing follows it.
tail_quota() {
  local a="$1"; cat <<EOF
{"type":"assistant","timestamp":"$(iso_ago $((a+21)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"./start-wt-setup.sh"}}]}}
{"type":"user","timestamp":"$(iso_ago $((a+1)))","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","timestamp":"$(iso_ago "$a")","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 5:10am (America/Chicago)"}]}}
EOF
}

# A healthy mid-iteration turn end: work, then an armed fallback wakeup (stop is absent/false).
tail_armed() {
  local a="$1"; cat <<EOF
{"type":"assistant","timestamp":"$(iso_ago $((a+9)))","message":{"role":"assistant","content":[{"type":"text","text":"BF-988: verifiers running."}]}}
{"type":"assistant","timestamp":"$(iso_ago $((a+8)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":1800,"noop":false,"prompt":"/loop /auto","reason":"fallback heartbeat"}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"$(iso_ago "$a")","preventedContinuation":false}
EOF
}

# A deliberate loop end. Goes quiet forever by contract — must never be flagged, however long.
tail_stopped() {
  local a="$1"; cat <<EOF
{"type":"assistant","timestamp":"$(iso_ago $((a+2)))","message":{"role":"assistant","content":[{"type":"text","text":"NO-CANDIDATES: fleet deadline reached (2026-08-14 07:19 CDT) — 5/0/0/0 this run."}]}}
{"type":"assistant","timestamp":"$(iso_ago "$a")","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"stop":true}}]}}
EOF
}

# THE 6a77c517 DEATH (2026-08-29): an arm ended one turn, a task notification started the next, the
# skill listing was re-injected as an attachment (its /auto entry names both terminal tags in prose),
# and the turn ended un-armed. The two trailing records are the harness's bookkeeping — untimestamped,
# rewritten after the session is dead — which is what dragged the file mtime 8h past the last entry.
tail_dead() {
  local a="$1"; cat <<EOF
{"type":"assistant","timestamp":"$(iso_ago $((a+1400)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":1500,"noop":false,"prompt":"/auto","reason":"cycle-3 verifier in flight"}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"$(iso_ago $((a+1393)))","preventedContinuation":false}
{"type":"user","timestamp":"$(iso_ago $((a+933)))","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>a391ddadb2c484551</task-id>\n<status>completed</status>\n</task-notification>"}}
{"type":"attachment","timestamp":"$(iso_ago $((a+17)))","attachment":{"type":"skill_listing","content":"- auto: Autonomous Linear-backlog iteration — ships exactly ONE issue per invocation. Run continuously via /loop /auto; the loop ends itself on NO-CANDIDATES or AUTO-HALTED. Invoking /auto IS the run-scoped commit/push grant."}}
{"type":"assistant","timestamp":"$(iso_ago $((a+1)))","message":{"role":"assistant","content":[{"type":"text","text":"BF-1616: merged into nextjs-descope-user; Ready For Release."}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"$(iso_ago "$a")","preventedContinuation":false}
{"type":"last-prompt","lastPrompt":"/loop /auto","sessionId":"6a77c517-3f3e-44c7-8215-d017fca55b5e"}
{"type":"cost-state","totalCostUSD":12.5,"sessionId":"6a77c517-3f3e-44c7-8215-d017fca55b5e"}
EOF
}

# A HEALTHY HOLD, in the real shape of fleet session 12106d2b's final turn (2026-09-19): a fired wakeup opens the
# turn, the arm is followed IN THE SAME TURN by its tool_result, an attachment, the closing assistant text,
# stop_hook_summary and turn_duration — five timestamped records, which is why "no later timestamped record" can
# never be the pending test — and the harness's untimestamped bookkeeping trails after. <delay> is the armed wakeup.
tail_hold() { # <age of the last timestamped record> <delaySeconds>
  local a="$1" d="$2"; cat <<EOF
{"type":"system","subtype":"scheduled_task_fire","timestamp":"$(iso_ago $((a+26)))","cronKind":"wakeup","prompt":"/loop /auto"}
{"type":"user","timestamp":"$(iso_ago $((a+26)))","message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(iso_ago $((a+4)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":$d,"prompt":"/loop /auto","reason":"PLANNED-HOLD with only keeper-owned entries; re-checking in 30 minutes.","noop":true}}]}}
{"type":"user","timestamp":"$(iso_ago $((a+3)))","message":{"role":"user","content":[{"type":"tool_result","content":"Next wakeup scheduled for 04:41:00 (in 1837s). Nothing more to do this turn"}]}}
{"type":"attachment","timestamp":"$(iso_ago $((a+3)))","attachment":{"type":"todo_reminder"}}
{"type":"assistant","timestamp":"$(iso_ago $((a+1)))","message":{"role":"assistant","content":[{"type":"text","text":"Still holding: nothing can ship until you act on the held Planned issues. Next check is at 04:41."}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"$(iso_ago "$a")","preventedContinuation":false}
{"type":"system","subtype":"turn_duration","timestamp":"$(iso_ago "$a")","durationMs":4500}
{"type":"last-prompt","lastPrompt":"/loop /auto","sessionId":"12106d2b-995e-492c-9a78-911492ef957d"}
{"type":"cost-state","totalCostUSD":330.06,"sessionId":"12106d2b-995e-492c-9a78-911492ef957d"}
EOF
}
tail_hold_1800() { tail_hold "$1" 1800; }
tail_hold_600()  { tail_hold "$1" 600; }

# A CONSUMED wakeup is no exemption: a 60s tick fired, opened its turn, and the limit message killed it. This is the
# script's founding shape with an arm in the tail, and it must stay reachable past the pending-wakeup branch.
tail_fired_quota() {
  local a="$1"; cat <<EOF
{"type":"assistant","timestamp":"$(iso_ago $((a+200)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60,"prompt":"/loop /auto","reason":"BF-988 shipped; picking the next certified issue right away.","noop":false}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"$(iso_ago $((a+196)))","preventedContinuation":false}
{"type":"system","subtype":"scheduled_task_fire","timestamp":"$(iso_ago $((a+120)))","cronKind":"wakeup","prompt":"/loop /auto"}
{"type":"user","timestamp":"$(iso_ago $((a+120)))","message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/auto</command-args>"}}
{"type":"assistant","timestamp":"$(iso_ago "$a")","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 5:10am (America/Chicago)"}]}}
EOF
}

run_case() { # <name> <tail-fn> <status> <age-seconds> <expected-verdict-or-none> [mtime-age-seconds]
  local name="$1" tailfn="$2" status="$3" age="$4" want="$5" mage="${6:-$4}"
  local id="aaaaaaaa" sid="aaaaaaaa-0000-0000-0000-000000000000"
  rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
  $tailfn "$age" > "$PROJ/$sid.jsonl"
  touch_ago "$mage" "$PROJ/$sid.jsonl"
  [ "$status" = "-" ] || mk_state "$id" "$status"
  [ "$status" = "-" ] && mk_state "$id" "active"
  mk_agents "$TMP/agents.json" "$id" "$sid"

  local got
  got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null \
        | jq -r 'if (.stalled | length) == 0 then "none" else .stalled[0].verdict end')
  if [ "$got" = "$want" ]; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — expected '$want', got '$got'"; FAIL=$((FAIL+1))
  fi
}

echo "auto-stall-watch.sh"

# The case this script exists for: quota cutoff mid-iteration, well past threshold.
run_case "quota cutoff, 149m silent          -> stalled-quota" tail_quota   active 8940 "stalled-quota"

# Silence alone is not a fault below threshold — /auto turns legitimately run long.
run_case "quota cutoff, 5m silent            -> none"          tail_quota   active  300 "none"

# A turn that ended with a wakeup armed still has one pending; if it is late, that is a real stall,
# but the tail carries no limit message so it must not be mislabelled as quota.
run_case "no tag, 60m silent                 -> stalled"       tail_armed   active 3600 "stalled"
run_case "no tag, 10m silent                 -> none"          tail_armed   active  600 "none"

# Deliberate wind-down: terminal by tag AND by state. Either alone must suppress the flag, because a
# session can die before Step 4 writes the state (that is how BF-796 went unrecorded on 2026-08-14).
run_case "loop ended by tag, 300m silent     -> none"          tail_stopped active 18000 "none"
run_case "state drained, quota tail, 300m    -> none"          tail_quota   drained 18000 "none"
run_case "state halted, no tag, 300m         -> none"          tail_armed   halted 18000 "none"

# THE 6a77c517 MODE (2026-08-29): a notification-started turn ended un-armed and the loop died, while
# the skill listing in the tail named both terminal tags. A raw grep over the tail read that as the
# loop ending, and the watcher cleared a dead session as `terminal` for 7.3h ("1 in scope, 0 flagged").
run_case "dead after notification, listing in tail, 60m -> stalled" tail_dead active 3600 "stalled"

# ...and its mtime sat 8h past the last real entry, dragged forward by the harness's untimestamped
# bookkeeping rewrites. Silence comes from the last TIMESTAMPED record, so a fresh mtime changes nothing.
run_case "same, mtime fresh (bookkeeping rewrite)         -> stalled" tail_dead active 3600 "stalled" 0

# The reverse: fresh entries under a stale mtime are a session at work, not a stall.
run_case "no tag, entries 10m old, mtime 2h old            -> none"    tail_armed active 600 "none" 7200

# THE PENDING WAKEUP (2026-09-19). A flat 25-minute rule flagged 8 of 9 healthy 1800s holds on one fleet, each
# raising its own alert, on the night three sessions really died behind a wakeup that never fired. A session with a
# wakeup pending is stalled only once that wakeup is 300s overdue; one without is judged by the flat rule as before.
detail() { "$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r '.stalled[0].detail // "none"'; }
ck_detail() { # <name> <want>  — reads the files the preceding run_case left in place
  local got; got=$(detail)
  if [ "$got" = "$2" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 — expected '$2', got '$got'"; FAIL=$((FAIL+1)); fi
}
run_case "healthy 1800s hold at minute 27 (flat rule flagged it)   -> none"    tail_hold_1800 active 1620 "none"
run_case "the same hold at minute 36: the wakeup is 6m overdue     -> stalled" tail_hold_1800 active 2160 "stalled"
ck_detail "  ... and the detail names the overdue wakeup" "wakeup overdue 6m (armed 1800s)"
run_case "a lost 600s wakeup at minute 16 (flat rule missed it)    -> stalled" tail_hold_600  active  960 "stalled"
ck_detail "  ... flagged 9 minutes sooner than 25m of silence would" "wakeup overdue 6m (armed 600s)"
run_case "a 600s hold at minute 14, inside the grace               -> none"    tail_hold_600  active  840 "none"
run_case "a CONSUMED wakeup never exempts: fired, then quota-killed, 30m -> stalled-quota" tail_fired_quota active 1800 "stalled-quota"
run_case "  ... and under the flat threshold it is still a turn at work  -> none" tail_fired_quota active 600 "none"
run_case "no tag, 60m silent: the armed fixture now reads as overdue     -> stalled" tail_armed active 3600 "stalled"
ck_detail "  ... by 30m" "wakeup overdue 30m (armed 1800s)"
run_case "dead after notification: no wakeup PENDING, flat rule decides  -> stalled" tail_dead active 3600 "stalled"
ck_detail "  ... and says so" "no terminal tag, no wakeup pending"

# A session with no /auto run-state file is somebody else's session, not fleet work. The state file is
# the ONLY scope filter — kind must play no part (the live schema reports every session interactive).
echo -n "  "
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota 8940 > "$PROJ/bbbbbbbb-0000-0000-0000-000000000000.jsonl"
mk_agents "$TMP/agents.json" "bbbbbbbb" "bbbbbbbb-0000-0000-0000-000000000000"
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r '"\(.stalled | length)/\(.in_scope)"')
if [ "$got" = "0/0" ]; then echo "PASS  non-/auto session (no state file) ignored, in_scope 0"; PASS=$((PASS+1));
else echo "FAIL  non-/auto session (no state file) ignored — expected 0/0, got '$got'"; FAIL=$((FAIL+1)); fi

# THE 2026-08-17 REGRESSION: a stalled fleet session in the live schema — kind "interactive", no id
# field, state file joined via the sessionId prefix. The original watcher's kind/background filter and
# .id join each independently dropped this row; three sessions sat dead 8.4h overnight at 0 flags.
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota 8940 > "$PROJ/cccccccc-0000-0000-0000-000000000000.jsonl"
touch_ago 8940 "$PROJ/cccccccc-0000-0000-0000-000000000000.jsonl"
mk_state "cccccccc" "active"
cat > "$TMP/agents.json" <<EOF
[{"pid":1,"cwd":"$TMP/repo","kind":"interactive","startedAt":1,"sessionId":"cccccccc-0000-0000-0000-000000000000","name":"claude-61"}]
EOF
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r 'if (.stalled | length) == 0 then "none" else "\(.stalled[0].verdict)/\(.in_scope)" end')
if [ "$got" = "stalled-quota/1" ]; then echo "  PASS  live-schema fleet stall flagged (no id, kind interactive), in_scope 1"; PASS=$((PASS+1));
else echo "  FAIL  live-schema fleet stall flagged — expected stalled-quota/1, got '$got'"; FAIL=$((FAIL+1)); fi

# Legacy schema (id present, kind background) still joins through the .id fallback.
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota 8940 > "$PROJ/dddddddd-0000-0000-0000-000000000000.jsonl"
touch_ago 8940 "$PROJ/dddddddd-0000-0000-0000-000000000000.jsonl"
mk_state "dddddddd" "active"
mk_agents_legacy "$TMP/agents.json" "dddddddd" "dddddddd-0000-0000-0000-000000000000"
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r 'if (.stalled | length) == 0 then "none" else .stalled[0].verdict end')
if [ "$got" = "stalled-quota" ]; then echo "  PASS  legacy-schema row still flagged (id fallback)"; PASS=$((PASS+1));
else echo "  FAIL  legacy-schema row still flagged — expected stalled-quota, got '$got'"; FAIL=$((FAIL+1)); fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
