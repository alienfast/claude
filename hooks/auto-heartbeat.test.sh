#!/usr/bin/env bash
# Regression harness for auto-heartbeat.sh decide(). Sources the hook (its main body is guarded so
# sourcing only exposes the function) and replays synthetic transcripts, asserting the fire decision
# for each mode the anchor/clearance logic must get right.
#
# The load-bearing case is #2, the BF-695 mode: a self-paced `/loop /auto` iteration that ends its
# turn having never called ScheduleWakeup. That killed a four-session fleet run for ~7.75h on
# 2026-08-01 with no failure signal anywhere — no NO-CANDIDATES, no AUTO-HALTED, and a state file
# still reading shipped: []. Case #9 is its sibling and the reason the anchor is the LAST /loop
# delivery rather than the first: an iteration that armed correctly must never vouch for a later one
# that did not.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as full-continue.test.sh. Every newly-observed real
# loop-death shape becomes a numbered case here, added WITH its fix. A mode with no live guard is a
# mode that regresses; the three prior heartbeat failures (BF-701, BF-665, BF-695) were each "already
# covered by the skill prose" right up until they were not.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./auto-heartbeat.sh

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fixture record builders — shapes copied from real transcripts.
LOOP='{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/auto</command-args>"}}'
LOOP_INTERVAL='{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>5m /auto</command-args>"}}'
LOOP_OTHER='{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/babysit-prs</command-args>"}}'
WAKE='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"ScheduleWakeup","input":{"delaySeconds":1800,"prompt":"/loop /auto"}}]}}'
WAKE_STOP='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"ScheduleWakeup","input":{"stop":true}}]}}'
WORK='{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"git status"}}]}}'
HUMAN='{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"discontinue the outer loop after completing this issue"}}'
NUDGE='{"type":"user","isSidechain":false,"isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"You are ending a turn inside a self-paced /loop /auto iteration without arming the next ScheduleWakeup."}]}}'
# A sidechain (subagent) wakeup must not clear the parent loop.
WAKE_SIDECHAIN='{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"ScheduleWakeup","input":{"delaySeconds":600}}]}}'

check() { # name expected_field expected_value records...
  local name="$1" field="$2" want="$3"; shift 3
  local f="$TMP/$RANDOM.jsonl"; : >"$f"
  local r; for r in "$@"; do printf '%s\n' "$r" >>"$f"; done
  # tostring, NOT `// "<null>"`: jq's alternative operator treats **false** as empty just like null,
  # so a `// default` guard rewrites every correct fire:false into the default and the whole suite
  # reads as broken. Same trap the linear skill documents for `//` on null.
  local got; got=$(TRANSCRIPT_PATH="$f" decide | jq -r "if has(\"${field}\") then (.${field} | tostring) else \"<missing>\" end" 2>/dev/null)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-58s %s=%s\n' "$name" "$field" "$got"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %-58s %s: want %s got %s\n' "$name" "$field" "$want" "$got"
  fi
}

echo "auto-heartbeat.sh decide() —"

# 1. Not a loop session at all: the common case, must exit cheaply and never fire.
check "1 no /loop anywhere" fire false "$WORK"

# 2. THE BF-695 MODE: loop iteration did real work, ended turn, never armed. Must fire.
check "2 unarmed turn end (BF-695)" fire true "$LOOP" "$WORK"

# 3. Armed correctly — the compliant path.
check "3 wakeup armed" fire false "$LOOP" "$WORK" "$WAKE"

# 4. Deliberate loop end. Ending is compliance, not silence.
check "4 ScheduleWakeup(stop:true)" fire false "$LOOP" "$WORK" "$WAKE_STOP"

# 5. Human took control after the anchor — do not fight the operator.
check "5 human prompt after anchor" fire false "$LOOP" "$WORK" "$HUMAN"

# 6. Fixed-interval /loop is cron-driven; an un-armed turn end is correct there.
check "6 fixed-interval /loop 5m" fire false "$LOOP_INTERVAL" "$WORK"

# 7. A /loop carrying some other payload is not this hook's business.
check "7 /loop with non-auto payload" fire false "$LOOP_OTHER" "$WORK"

# 8. Nudge accounting drives the give-up bound in main().
check "8 attempts counts prior nudges" attempts 2 "$LOOP" "$NUDGE" "$WORK" "$NUDGE" "$WORK"

# 9. ANCHOR IS THE LAST DELIVERY: iteration 1 armed, iteration 2 did not. Must still fire.
check "9 earlier armed iteration does not vouch" fire true "$LOOP" "$WORK" "$WAKE" "$LOOP" "$WORK"

# 10. Subagent wakeups are invisible to the parent loop and must not clear it.
check "10 sidechain wakeup does not clear" fire true "$LOOP" "$WORK" "$WAKE_SIDECHAIN"

# 11. Human interjection BEFORE the current iteration is stale — a later firing re-arms the hook.
check "11 human before anchor is stale" fire true "$LOOP" "$HUMAN" "$LOOP" "$WORK"

# 12. pending drives the flush-race poll: true only while no wakeup is visible.
check "12 pending false once armed" pending false "$LOOP" "$WORK" "$WAKE"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
