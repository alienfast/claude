#!/usr/bin/env bash
# Regression suite for auto-stall-watch.sh.
#
# Fixtures carry the REAL transcript shapes from the 2026-08-14 basefund fleet — in particular the
# quota-cutoff tail (an assistant turn whose text is the limit message, with NO stop_hook_summary after
# it), which is what makes the stall invisible to every Stop hook. A synthetic "silent session" fixture
# would pass against a check that only looked at mtime and would not pin that distinction.
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

# The observed cutoff tail: the limit message IS the final assistant turn. Nothing follows it.
tail_quota() {
  cat <<'EOF'
{"type":"assistant","timestamp":"2026-08-14T10:05:38.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"./start-wt-setup.sh"}}]}}
{"type":"user","timestamp":"2026-08-14T10:05:58.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-14T10:05:59.000Z","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 5:10am (America/Chicago)"}]}}
EOF
}

# A healthy mid-iteration turn end: work, then an armed fallback wakeup (stop is absent/false).
tail_armed() {
  cat <<'EOF'
{"type":"assistant","timestamp":"2026-08-14T09:50:56.000Z","message":{"role":"assistant","content":[{"type":"text","text":"BF-988: verifiers running."}]}}
{"type":"assistant","timestamp":"2026-08-14T09:50:57.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":1800,"noop":false,"prompt":"/loop /auto","reason":"fallback heartbeat"}}]}}
{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-08-14T09:51:05.000Z","preventedContinuation":false}
EOF
}

# A deliberate loop end. Goes quiet forever by contract — must never be flagged, however long.
tail_stopped() {
  cat <<'EOF'
{"type":"assistant","timestamp":"2026-08-14T12:19:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"NO-CANDIDATES: fleet deadline reached (2026-08-14 07:19 CDT) — 5/0/0/0 this run."}]}}
{"type":"assistant","timestamp":"2026-08-14T12:19:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"stop":true}}]}}
EOF
}

run_case() { # <name> <tail-fn> <status> <age-seconds> <expected-verdict-or-none>
  local name="$1" tailfn="$2" status="$3" age="$4" want="$5"
  local id="aaaaaaaa" sid="aaaaaaaa-0000-0000-0000-000000000000"
  rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
  $tailfn > "$PROJ/$sid.jsonl"
  touch -t "$(date -r $(( NOW - age )) +%Y%m%d%H%M.%S 2>/dev/null || echo 202608140000.00)" "$PROJ/$sid.jsonl"
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

# A session with no /auto run-state file is somebody else's session, not fleet work. The state file is
# the ONLY scope filter — kind must play no part (the live schema reports every session interactive).
echo -n "  "
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota > "$PROJ/bbbbbbbb-0000-0000-0000-000000000000.jsonl"
mk_agents "$TMP/agents.json" "bbbbbbbb" "bbbbbbbb-0000-0000-0000-000000000000"
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r '"\(.stalled | length)/\(.in_scope)"')
if [ "$got" = "0/0" ]; then echo "PASS  non-/auto session (no state file) ignored, in_scope 0"; PASS=$((PASS+1));
else echo "FAIL  non-/auto session (no state file) ignored — expected 0/0, got '$got'"; FAIL=$((FAIL+1)); fi

# THE 2026-08-17 REGRESSION: a stalled fleet session in the live schema — kind "interactive", no id
# field, state file joined via the sessionId prefix. The original watcher's kind/background filter and
# .id join each independently dropped this row; three sessions sat dead 8.4h overnight at 0 flags.
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota > "$PROJ/cccccccc-0000-0000-0000-000000000000.jsonl"
touch -t "$(date -r $(( NOW - 8940 )) +%Y%m%d%H%M.%S 2>/dev/null || echo 202608140000.00)" "$PROJ/cccccccc-0000-0000-0000-000000000000.jsonl"
mk_state "cccccccc" "active"
cat > "$TMP/agents.json" <<EOF
[{"pid":1,"cwd":"$TMP/repo","kind":"interactive","startedAt":1,"sessionId":"cccccccc-0000-0000-0000-000000000000","name":"claude-61"}]
EOF
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r 'if (.stalled | length) == 0 then "none" else "\(.stalled[0].verdict)/\(.in_scope)" end')
if [ "$got" = "stalled-quota/1" ]; then echo "  PASS  live-schema fleet stall flagged (no id, kind interactive), in_scope 1"; PASS=$((PASS+1));
else echo "  FAIL  live-schema fleet stall flagged — expected stalled-quota/1, got '$got'"; FAIL=$((FAIL+1)); fi

# Legacy schema (id present, kind background) still joins through the .id fallback.
rm -f "$PROJ"/*.jsonl "$TMP/repo/tmp"/auto-state-*.json
tail_quota > "$PROJ/dddddddd-0000-0000-0000-000000000000.jsonl"
touch -t "$(date -r $(( NOW - 8940 )) +%Y%m%d%H%M.%S 2>/dev/null || echo 202608140000.00)" "$PROJ/dddddddd-0000-0000-0000-000000000000.jsonl"
mk_state "dddddddd" "active"
mk_agents_legacy "$TMP/agents.json" "dddddddd" "dddddddd-0000-0000-0000-000000000000"
got=$("$SCRIPT" --agents-json "$TMP/agents.json" --now "$NOW" --json 2>/dev/null | jq -r 'if (.stalled | length) == 0 then "none" else .stalled[0].verdict end')
if [ "$got" = "stalled-quota" ]; then echo "  PASS  legacy-schema row still flagged (id fallback)"; PASS=$((PASS+1));
else echo "  FAIL  legacy-schema row still flagged — expected stalled-quota, got '$got'"; FAIL=$((FAIL+1)); fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
