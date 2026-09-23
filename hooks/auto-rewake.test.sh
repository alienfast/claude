#!/usr/bin/env bash
# Regression suite for auto-rewake.sh — the asyncRewake Stop/StopFailure hook that wakes a silent `/loop /auto` session.
#
# Two layers. DECISION cases drive `auto-rewake.sh --decide`, which prints what the hook would do and never waits, logs
# or touches state. END-TO-END cases run the hook for real with second-scale waits (AUTO_REWAKE_GRACE / _API_DELAY)
# and assert the exit code, the stderr the harness would hand the model, the counters and the log.
#
# Fixture records copy real shapes: the final turn of fleet session 12106d2b (2026-09-19 — ScheduleWakeup tool_use,
# its tool_result, the closing assistant text, stop_hook_summary, turn_duration), that session's /loop delivery, the
# scheduled_task_fire record a fired wakeup opens with, and the API-error assistant record plus StopFailure payload a
# 429 produced against a mock API the same day. Re-snapshot them from a live transcript when the harness changes.
#
# The load-bearing cases are #1/#2 (the lost wakeup, with and without the ending turn's summary on disk — #1 is the
# ordering hazard that makes auto-heartbeat.sh's `armed` verdict unusable here), #21, #27 and #30 (a turn DID follow:
# never wake a live session — #27 is the shape where the hook cannot see that it did, #30 the one where it looked before
# anything could have been written) and the registration block (a missing `timeout` or `asyncRewake` disables the hook
# without a sound).
#
# The one-shot cases (#31-#38) are the 2026-09-21 fleet-sequence death: a targeted `/auto <ID>` session — no /loop anywhere,
# its `claude --bg` delivery stamped origin.kind "human" like a typed one — killed by an API 500, with the hook standing down
# as not-auto-loop while the sequence runner timed out behind it. #39 is the 2026-09-23 sequel: the `continue` that recovered
# such a death was read as manual control for the rest of the session, and the next 429 five hours later went unrecovered.
#
# GROW THIS SUITE, NEVER PRUNE IT. Every newly observed silent-death shape becomes a numbered case, added WITH its fix.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
HOOK=./auto-rewake.sh

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOGS="$TMP/logs"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# ---- record builders (epoch first) ----
rec_loop()   { jq -nc --arg t "$(iso "$1")" --arg a "${2:-/auto}" '{type:"user",isSidechain:false,origin:{kind:"human"},timestamp:$t,message:{role:"user",content:("<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>" + $a + "</command-args>")}}'; }
rec_wake()   { jq -nc --arg t "$(iso "$1")" --argjson d "$2" --argjson side "${3:-false}" '{type:"assistant",isSidechain:$side,timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_w",name:"ScheduleWakeup",input:{delaySeconds:$d,prompt:"/loop /auto",reason:"PLANNED-HOLD with only keeper-owned entries; re-checking in 30 minutes.",noop:true}}]}}'; }
rec_wake_nodelay() { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_w",name:"ScheduleWakeup",input:{prompt:"/loop /auto",reason:"no delay given"}}]}}'; }
rec_wake_stop()    { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_s",name:"ScheduleWakeup",input:{stop:true}}]}}'; }
rec_result() { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,timestamp:$t,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_w",content:"Next wakeup scheduled for 04:41:00 (in 1837s). Nothing more to do this turn"}]}}'; }
rec_text()   { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,message:{role:"assistant",content:[{type:"text",text:"Still holding: nothing can ship until you act on the held Planned issues. Next check is at 04:41."}]}}'; }
rec_work()   { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_b",name:"Bash",input:{command:"git status"}}]}}'; }
rec_stopsum(){ jq -nc --arg t "$(iso "$1")" '{type:"system",subtype:"stop_hook_summary",isSidechain:false,timestamp:$t,preventedContinuation:false,hookCount:3}'; }
rec_turndur(){ jq -nc --arg t "$(iso "$1")" '{type:"system",subtype:"turn_duration",isSidechain:false,timestamp:$t,durationMs:4500}'; }
rec_fire()   { jq -nc --arg t "$(iso "$1")" '{type:"system",subtype:"scheduled_task_fire",isSidechain:false,timestamp:$t,cronKind:"wakeup",prompt:"/loop /auto",noOpStreak:3}'; }
rec_notif()  { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,origin:{kind:"task-notification"},timestamp:$t,message:{role:"user",content:"<task-notification>\n<task-id>a391ddadb2c484551</task-id>\n<status>completed</status>\n</task-notification>"}}'; }
rec_nudge()  { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,isMeta:true,timestamp:$t,message:{role:"user",content:[{type:"text",text:"You are ending a turn inside a self-paced /loop /auto iteration without arming the next wakeup."}]}}'; }
rec_human()  { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,origin:{kind:"human"},timestamp:$t,message:{role:"user",content:"discontinue the outer loop after completing this issue"}}'; }
rec_apierr() { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,isApiErrorMessage:true,error:"rate_limit",apiErrorStatus:429,apiErrorIsTransient:true,message:{role:"assistant",content:[{type:"text",text:"API Error: Request rejected (429) · This request would exceed your account rate limit. Please try again later."}]}}'; }
rec_plain()  { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,origin:{kind:"human"},timestamp:$t,message:{role:"user",content:"fix the failing test"}}'; }
# A `claude --bg "/auto BF-2034"` delivery as fleet-sequence session 5f071ea8 recorded it (2026-09-21): origin.kind "human", as typed.
rec_auto()   { jq -nc --arg t "$(iso "$1")" --arg a "${2-BF-2034}" '{type:"user",isSidechain:false,origin:{kind:"human"},timestamp:$t,message:{role:"user",content:("<command-message>auto</command-message>\n<command-name>/auto</command-name>\n<command-args>" + $a + "</command-args>")}}'; }
rec_cont()   { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,origin:{kind:"human"},timestamp:$t,message:{role:"user",content:"continue"}}'; }
# A subagent hand-back as session cdb8b6ad recorded it (2026-09-23): a user record, isMeta true, origin.kind "peer".
rec_peer()   { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,isMeta:true,origin:{kind:"peer",from:"a40970bebbb855ae9",handback:true},timestamp:$t,message:{role:"user",content:"Another Claude session sent a message:\n<agent-message from=\"a40970bebbb855ae9\">\n[Subagent hand-back] The merge fix is done.\n</agent-message>"}}'; }
rec_quote()  { jq -nc --arg t "$(iso "$1")" '{type:"user",isSidechain:false,timestamp:$t,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_b",content:"<command-name>/auto</command-name> quoted from a transcript this session read"}]}}'; }
rec_500()    { jq -nc --arg t "$(iso "$1")" '{type:"assistant",isSidechain:false,timestamp:$t,isApiErrorMessage:true,error:"server_error",apiErrorStatus:500,apiErrorIsTransient:true,message:{role:"assistant",content:[{type:"text",text:"API Error: 500 Internal server error. This is a server-side issue, usually temporary."}]}}'; }

tfile() { mktemp "$TMP/t.XXXXXX"; }
ev() { # ev <event> <transcript> <session-id> [extra-json]
  local extra="${4:-}"; [[ -n "$extra" ]] || extra='{}'
  jq -nc --arg e "$1" --arg t "$2" --arg s "$3" --argjson x "$extra" \
    '{session_id:$s, transcript_path:$t, cwd:"/work", prompt_id:"p1", effort:{level:"high"}, hook_event_name:$e} + $x'
}
set_state() { mkdir -p "$LOGS/auto-rewake"; printf '%s' "$2" > "$LOGS/auto-rewake/$1.json"; }
get_state() { jq -r --arg k "$2" '.[$k] // 0' "$LOGS/auto-rewake/$1.json" 2>/dev/null || echo missing; }

ck() { # ck <name> <want> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s — want [%s] got [%s]\n' "$1" "$2" "$3"; fi
}
dec() { # dec <event-json> <jq-filter> [now-epoch] → the decision field, as a string
  printf '%s' "$1" | AUTO_REWAKE_NOW="${3:-}" AUTO_REWAKE_SETTLE=1 AUTO_REWAKE_LOG_DIR="$LOGS" "$HOOK" --decide 2>/dev/null | jq -r "$2 | tostring"
}

B=$(jq -rn '"2026-09-19T09:10:22Z" | fromdateiso8601')

echo "auto-rewake.sh — decisions (Stop):"

# 1. The 2026-09-19 death, as the background hook really reads it: the ending turn's own stop_hook_summary is ALREADY
#    on disk. auto-heartbeat.sh's decide() windows on that summary and would call this turn stale-arm.
f=$(tfile); { rec_loop $((B-30000)); rec_fire $((B-22)); rec_loop $((B-22)); rec_work $((B-10)); rec_wake "$B" 1800; rec_result $((B+1)); rec_text $((B+3)); rec_stopsum $((B+4)); rec_turndur $((B+4)); } > "$f"
E=$(ev Stop "$f" s-one)
ck " 1 lost-wakeup shape, summary on disk -> wait"            wait "$(dec "$E" .action $((B+5)))"
ck " 1 ... as a Stop-kind wait"                                stop "$(dec "$E" .kind $((B+5)))"
ck " 1 ... until due + 300s grace (B+1800+300 from B+5)"       2095 "$(dec "$E" .wait_s $((B+5)))"
ck " 1 ... carrying the armed delay"                           1800 "$(dec "$E" .delay $((B+5)))"

# 2. The same turn read BEFORE its summary is written (the flush-race side of the same ordering).
f=$(tfile); { rec_loop $((B-30000)); rec_fire $((B-22)); rec_loop $((B-22)); rec_wake "$B" 1800; rec_result $((B+1)); rec_text $((B+3)); } > "$f"
ck " 2 lost-wakeup shape, summary not yet written -> wait"     wait "$(dec "$(ev Stop "$f" s-two)" .action $((B+5)))"

# 3. The loop ended on purpose: silence is its contract.
f=$(tfile); { rec_loop $((B-300)); rec_work $((B-10)); rec_wake_stop "$B"; rec_text $((B+2)); } > "$f"
ck " 3 ScheduleWakeup(stop:true) -> skip loop-ended"           loop-ended "$(dec "$(ev Stop "$f" s-three)" .reason)"

# 4-5. Not a self-paced /loop /auto session.
f=$(tfile); { rec_plain $((B-60)); rec_work $((B-10)); rec_text "$B"; } > "$f"
ck " 4 ordinary session -> skip not-auto-loop"                 not-auto-loop "$(dec "$(ev Stop "$f" s-four)" .reason)"
ck " 4 ... and out of scope (nothing is logged for it)"        false "$(dec "$(ev Stop "$f" s-four)" .in_scope)"
f=$(tfile); { rec_loop $((B-300)) "5m /auto"; rec_wake "$B" 1800; rec_text $((B+2)); } > "$f"
ck " 5 fixed-interval /loop 5m /auto -> skip not-auto-loop"    not-auto-loop "$(dec "$(ev Stop "$f" s-five)" .reason)"

# 6-8. Un-armed turns belong to auto-heartbeat.sh, which blocks them synchronously.
f=$(tfile); { rec_loop $((B-300)); rec_work $((B-10)); rec_text "$B"; } > "$f"
ck " 6 turn ended with no wakeup -> skip unarmed"              unarmed "$(dec "$(ev Stop "$f" s-six)" .reason)"
f=$(tfile); { rec_loop $((B-4000)); rec_wake $((B-2000)) 1500; rec_result $((B-1999)); rec_text $((B-1997)); rec_stopsum $((B-1996)); rec_notif $((B-100)); rec_work $((B-50)); rec_text "$B"; } > "$f"
ck " 7 stale arm: a notification superseded it, this turn armed nothing -> skip unarmed"  unarmed "$(dec "$(ev Stop "$f" s-seven)" .reason)"
f=$(tfile); { rec_loop $((B-300)); rec_wake "$B" 600 true; rec_text $((B+2)); } > "$f"
ck " 8 a subagent's wakeup is not the loop's -> skip unarmed"  unarmed "$(dec "$(ev Stop "$f" s-eight)" .reason)"

# 9. A heartbeat nudge opens the rest of the turn; the arm that answers it is live.
f=$(tfile); { rec_loop $((B-300)); rec_work $((B-40)); rec_text $((B-30)); rec_nudge $((B-20)); rec_wake "$B" 1800; rec_result $((B+1)); } > "$f"
ck " 9 armed after an auto-heartbeat nudge -> wait"            wait "$(dec "$(ev Stop "$f" s-nine)" .action $((B+5)))"

# 10. An operator holds the run (decide()'s human-override): never fight them.
f=$(tfile); { rec_loop $((B-300)); rec_human $((B-60)); rec_wake "$B" 1800; rec_text $((B+2)); } > "$f"
ck "10 human prompt after the anchor -> skip human-override"   human-override "$(dec "$(ev Stop "$f" s-ten)" .reason)"

# 11-12. Degenerate arms.
f=$(tfile); { rec_loop $((B-300)); rec_wake_nodelay "$B"; rec_text $((B+2)); } > "$f"
ck "11 wakeup with no delaySeconds -> skip no-delay"           no-delay "$(dec "$(ev Stop "$f" s-eleven)" .reason)"
f=$(tfile); { rec_loop $((B-30000)); rec_fire $((B-22)); rec_wake "$B" 1800; rec_text $((B+2)); } > "$f"
ck "12 already past due + grace -> the grace runs from now, never 0"  300 "$(dec "$(ev Stop "$f" s-twelve)" .wait_s $((B+9000)))"
ck "12 ... past due but inside the grace -> still the whole grace"    300 "$(dec "$(ev Stop "$f" s-twelve)" .wait_s $((B+1900)))"
ck "12 ... not yet due -> due + grace, unchanged"                     310 "$(dec "$(ev Stop "$f" s-twelve)" .wait_s $((B+1790)))"

# 13. A turn longer than the tail: no opening record in view, so the whole tail is the turn — never "unarmed".
f=$(tfile); { rec_loop $((B-90000)); jq -nc --arg t "$(iso $((B-500)))" 'range(650) | {type:"assistant",isSidechain:false,timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_b",name:"Bash",input:{command:"true"}}]}}'; rec_wake "$B" 1800; rec_text $((B+2)); } > "$f"
ck "13 650-record turn, opener scrolled out of the tail -> wait" wait "$(dec "$(ev Stop "$f" s-thirteen)" .action $((B+5)))"

# 14. The consecutive-rewake cap: a session whose scheduler is simply broken is not revived forever.
f=$(tfile); { rec_loop $((B-300)); rec_wake "$B" 1800; rec_text $((B+2)); } > "$f"
set_state s-fourteen '{"stop_rewakes":12}'
ck "14 12 consecutive rewakes already -> skip stop-cap"        stop-cap "$(dec "$(ev Stop "$f" s-fourteen)" .reason $((B+5)))"

echo "auto-rewake.sh — decisions (StopFailure):"
f=$(tfile); { rec_loop $((B-300)); rec_work $((B-10)); rec_apierr "$B"; } > "$f"
SF='{"error":"rate_limit","last_assistant_message":"API Error: Request rejected (429)"}'
ck "15 rate_limit inside the loop -> wait"                     wait "$(dec "$(ev StopFailure "$f" s-fifteen "$SF")" .action)"
ck "15 ... as an api-kind wait of 900s"                        "api 900" "$(dec "$(ev StopFailure "$f" s-fifteen "$SF")" '"\(.kind) \(.wait_s)"')"
for e in overloaded server_error unknown; do
  ck "16 $e is transient -> wait"                              wait "$(dec "$(ev StopFailure "$f" s-sixteen "{\"error\":\"$e\"}")" .action)"
done
for e in authentication_failed billing_error invalid_request model_not_found max_output_tokens; do
  ck "17 $e needs a human -> skip not-transient"               not-transient "$(dec "$(ev StopFailure "$f" s-seventeen "{\"error\":\"$e\"}")" .reason)"
done
g=$(tfile); { rec_plain $((B-60)); rec_apierr "$B"; } > "$g"
ck "18 API error in an ordinary session -> skip not-auto-loop" not-auto-loop "$(dec "$(ev StopFailure "$g" s-eighteen "$SF")" .reason)"
g=$(tfile); { rec_loop $((B-300)); rec_human $((B-60)); rec_apierr "$B"; } > "$g"
ck "19 API error while an operator holds the run -> skip"      human-override "$(dec "$(ev StopFailure "$g" s-nineteen "$SF")" .reason)"
set_state s-twenty '{"api_rewakes":24}'
ck "20 24 retries already (six hours) -> skip api-cap"         api-cap "$(dec "$(ev StopFailure "$f" s-twenty "$SF")" .reason)"
ck "20b a hook event that is not a stop -> skip"               not-a-stop-event "$(dec "$(ev SubagentStop "$f" s-twentyb)" .reason)"

echo "auto-rewake.sh — decisions (one-shot /auto):"
SE='{"error":"server_error","last_assistant_message":"API Error: 500 Internal server error"}'
# 31. THE FLEET-SEQUENCE DEATH (2026-09-21): `claude --bg "/auto BF-2034"`, a targeted run with no /loop anywhere, killed by a
#     500 mid-review. The delivery is the anchor; the task notification after it is not a human.
f=$(tfile); { rec_auto $((B-7200)); rec_work $((B-3000)); rec_notif $((B-100)); rec_500 "$B"; } > "$f"
ck "31 server_error in a targeted /auto run -> wait"           wait "$(dec "$(ev StopFailure "$f" s-thirtyone "$SE")" .action)"
ck "31 ... as an api-kind wait of 900s"                        "api 900" "$(dec "$(ev StopFailure "$f" s-thirtyone "$SE")" '"\(.kind) \(.wait_s)"')"
ck "31 ... on a one-shot session"                              one-shot "$(dec "$(ev StopFailure "$f" s-thirtyone "$SE")" .session)"
# 32. A bare `/auto` typed once is one-shot too.
f=$(tfile); { rec_auto $((B-300)) ""; rec_500 "$B"; } > "$f"
ck "32 bare /auto -> wait"                                     wait "$(dec "$(ev StopFailure "$f" s-thirtytwo "$SE")" .action)"
# 33. A human prompt opened the turn that died — the `continue` that recovered the real session, killed again at once — so
#     the operator holds the run.
f=$(tfile); { rec_auto $((B-7200)); rec_cont $((B-60)); rec_500 "$B"; } > "$f"
ck "33 human prompt opened the dying turn -> skip human-override" human-override "$(dec "$(ev StopFailure "$f" s-thirtythree "$SE")" .reason)"
ck "33 ... in scope, so it is logged"                          true "$(dec "$(ev StopFailure "$f" s-thirtythree "$SE")" .in_scope)"
# 39. THE STICKY OVERRIDE (2026-09-23, fleet-sequence child cdb8b6ad): the `continue` of #33 recovered a 429 at 23:41Z, the run
#     then carried on unattended for five hours on hand-backs and notifications, and a second 429 at 04:36Z found the hook
#     still standing down on that one prompt. The hold is turn-scoped: once a non-human record opens a later turn, the run is
#     unattended again — and a fresh human prompt opening the dying turn holds it again.
f=$(tfile); { rec_auto $((B-30000)); rec_cont $((B-18000)); rec_work $((B-17990)); rec_text $((B-17980)); rec_stopsum $((B-17979)); rec_peer $((B-100)); rec_work $((B-50)); rec_500 "$B"; } > "$f"
ck "39 human continue, then a hand-back opened the dying turn -> wait" wait "$(dec "$(ev StopFailure "$f" s-thirtynine "$SE")" .action)"
ck "39 ... as a one-shot api-kind wait"                        "one-shot api" "$(dec "$(ev StopFailure "$f" s-thirtynine "$SE")" '"\(.session) \(.kind)"')"
f=$(tfile); { rec_auto $((B-30000)); rec_cont $((B-18000)); rec_text $((B-17980)); rec_stopsum $((B-17979)); rec_notif $((B-100)); rec_500 "$B"; } > "$f"
ck "39 ... a task notification as the opener, likewise"        wait "$(dec "$(ev StopFailure "$f" s-thirtynineb "$SE")" .action)"
f=$(tfile); { rec_auto $((B-30000)); rec_cont $((B-18000)); rec_text $((B-17980)); rec_stopsum $((B-17979)); rec_notif $((B-200)); rec_text $((B-150)); rec_stopsum $((B-149)); rec_plain $((B-60)); rec_500 "$B"; } > "$f"
ck "39 ... a fresh human prompt opening the dying turn holds again" human-override "$(dec "$(ev StopFailure "$f" s-thirtyninec "$SE")" .reason)"
# 34. A Stop on a one-shot run is the run finishing or resting, never a lost wakeup: out of scope, no log line.
f=$(tfile); { rec_auto $((B-300)); rec_work $((B-10)); rec_text "$B"; } > "$f"
ck "34 Stop on a targeted run -> skip one-shot-stop"           one-shot-stop "$(dec "$(ev Stop "$f" s-thirtyfour)" .reason)"
ck "34 ... out of scope"                                       false "$(dec "$(ev Stop "$f" s-thirtyfour)" .in_scope)"
# 35. The same error classes and the same cap as the loop path.
f=$(tfile); { rec_auto $((B-300)); rec_500 "$B"; } > "$f"
ck "35 authentication_failed on a targeted run -> skip not-transient" not-transient "$(dec "$(ev StopFailure "$f" s-thirtyfive '{"error":"authentication_failed"}')" .reason)"
set_state s-thirtyfive '{"api_rewakes":24}'
ck "35 ... and the cap holds"                                  api-cap "$(dec "$(ev StopFailure "$f" s-thirtyfive "$SE")" .reason)"
# 36. A session that only READ a transcript with an /auto delivery in it holds the block in a tool_result, not a delivery.
f=$(tfile); { rec_plain $((B-60)); rec_quote $((B-30)); rec_500 "$B"; } > "$f"
ck "36 /auto quoted in a tool result is no delivery -> skip not-auto-loop" not-auto-loop "$(dec "$(ev StopFailure "$f" s-thirtysix "$SE")" .reason)"
f=$(tfile); { rec_loop $((B-300)); rec_work $((B-10)); rec_apierr "$B"; } > "$f"
ck "36b a loop session still takes the loop path"             loop "$(dec "$(ev StopFailure "$f" s-thirtysixb "$SF")" .session)"

echo "auto-rewake.sh — end to end (second-scale waits):"
run_hook() { # run_hook <event-json> <grace> <api-delay> → RC, stderr in $TMP/err
  printf '%s' "$1" | AUTO_REWAKE_GRACE="$2" AUTO_REWAKE_API_DELAY="$3" AUTO_REWAKE_SETTLE=1 AUTO_REWAKE_LOG_DIR="$LOGS" "$HOOK" > /dev/null 2> "$TMP/err"
  RC=$?
}

# 21a. The wakeup never fires and nothing else happens: exit 2, and the model is told what to do.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_fire $((N-20)); rec_loop $((N-20)); rec_wake $((N-1)) 1; rec_result "$N"; rec_text "$N"; rec_stopsum "$N"; } > "$f"
run_hook "$(ev Stop "$f" s-e2e-lost '{"stop_hook_active":false}')" 1 900
ck "21a silent after due + grace -> exit 2"                    2 "$RC"
ck "21a ... stderr names the lost wakeup"                      1 "$(grep -c 'auto-rewake: the ScheduleWakeup this session armed' "$TMP/err")"
ck "21a ... and counts the rewake"                             1 "$(grep -c 'rewake 1 of 12' "$TMP/err")"
ck "21a ... and says it is not a human prompt"                 1 "$(grep -c 'This is not a human prompt' "$TMP/err")"
ck "21a ... the counter moved"                                 1 "$(get_state s-e2e-lost stop_rewakes)"
ck "21a ... the log records the rewake"                        1 "$(grep -c 's-e2e-lo Stop rewake kind=stop' "$LOGS/auto-rewake.log")"

# 21b. The wakeup fires (late) while the hook waits: a turn followed, so stand down in silence.
#      The appended records carry whole-second stamps and must clear the hook's 2s slack with room to spare: appended
#      at +3 they sat on that boundary, and this case flaked whenever the hook's start crossed a second.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_fire $((N-20)); rec_loop $((N-20)); rec_wake $((N-1)) 7; rec_result "$N"; rec_text "$N"; rec_stopsum "$N"; } > "$f"
( sleep 5; M=$(date +%s); { rec_fire "$M"; rec_loop "$M"; } >> "$f" ) &
run_hook "$(ev Stop "$f" s-e2e-live)" 2 900
wait
ck "21b a turn followed during the wait -> exit 0"             0 "$RC"
ck "21b ... nothing is said to the model"                      0 "$(wc -c < "$TMP/err" | tr -d ' ')"
ck "21b ... the log says it stood down"                        1 "$(grep -c 's-e2e-li Stop stood-down' "$LOGS/auto-rewake.log")"
ck "21b ... no rewake was counted"                             0 "$(get_state s-e2e-live stop_rewakes)"

# 22. A 429 kills the turn; nothing follows; exit 2 after the retry delay, naming the error.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_work $((N-5)); rec_apierr "$N"; } > "$f"
run_hook "$(ev StopFailure "$f" s-e2e-api "$SF")" 300 1
ck "22 API-error kill, silent after the delay -> exit 2"       2 "$RC"
ck "22 ... stderr names the error and the retry"               1 "$(grep -c 'API error (rate_limit).*retry 1 of 24' "$TMP/err")"
ck "22 ... the retry counter moved"                            1 "$(get_state s-e2e-api api_rewakes)"

# 37. The 2026-09-21 shape end to end: a 500 kills a targeted run, nothing follows, and the model is told to finish the run
#     and arm nothing.
N=$(date +%s); f=$(tfile); { rec_auto $((N-3000)); rec_work $((N-5)); rec_500 "$N"; } > "$f"
run_hook "$(ev StopFailure "$f" s-e2e-oneshot "$SE")" 300 1
ck "37 targeted run killed by a 500, silent after the delay -> exit 2" 2 "$RC"
ck "37 ... stderr names the run, the error and the retry"      1 "$(grep -c 'one-shot /auto run was killed by an API error (server_error).*retry 1 of 24' "$TMP/err")"
ck "37 ... and tells the model to arm nothing"                 1 "$(grep -c 'arm no wakeup' "$TMP/err")"
ck "37 ... and says it is not a human prompt"                  1 "$(grep -c 'This is not a human prompt' "$TMP/err")"
ck "37 ... the retry counter moved"                            1 "$(get_state s-e2e-oneshot api_rewakes)"
ck "37 ... the log records the rewake as one-shot"             1 "$(grep -c 's-e2e-on StopFailure rewake kind=api session=one-shot' "$LOGS/auto-rewake.log")"
# 38. A Stop on that run spends the retry count; a targeted run that never rewoke leaves no state file and no log line.
f=$(tfile); { rec_auto $((B-300)); rec_text "$B"; } > "$f"
run_hook "$(ev Stop "$f" s-e2e-oneshot)" 1 1
ck "38 a Stop on the one-shot run resets its API retry count"  0 "$(get_state s-e2e-oneshot api_rewakes)"
run_hook "$(ev Stop "$f" s-e2e-quiet)" 1 1
ck "38 ... an ordinary targeted run leaves no state file"      missing "$(get_state s-e2e-quiet api_rewakes)"
ck "38 ... and no log line"                                    0 "$(grep -c 's-e2e-qu' "$LOGS/auto-rewake.log")"

# 23. Counters: any completed turn proves the API answers; only a stop no hook caused proves the loop turns unaided.
f=$(tfile); { rec_loop $((B-300)); rec_wake_stop "$B"; } > "$f"
run_hook "$(ev Stop "$f" s-e2e-api '{"stop_hook_active":true}')" 1 1
ck "23 a Stop resets the API retry count"                      0 "$(get_state s-e2e-api api_rewakes)"
run_hook "$(ev Stop "$f" s-e2e-lost '{"stop_hook_active":true}')" 1 1
ck "23 a hook-caused Stop keeps the consecutive-rewake count"  1 "$(get_state s-e2e-lost stop_rewakes)"
run_hook "$(ev Stop "$f" s-e2e-lost '{"stop_hook_active":false}')" 1 1
ck "23 an unprompted Stop clears it"                           0 "$(get_state s-e2e-lost stop_rewakes)"

# 24. An ordinary session costs one grep and leaves no trace.
f=$(tfile); { rec_plain $((B-60)); rec_text "$B"; } > "$f"
run_hook "$(ev Stop "$f" s-ordinary)" 1 1
ck "24 ordinary session -> exit 0"                             0 "$RC"
ck "24 ... and no log line"                                    0 "$(grep -c 's-ordina' "$LOGS/auto-rewake.log")"

# 27. THE FALSE WAKE (fleet of 2026-09-19/20): the session leaves its worktree while an instance sleeps, and the harness
#     re-keys the project directory — the transcript MOVES, the old directory stays behind empty, and the turn carries on
#     in the new file. The instance still holds the old path. It must read that as "cannot measure", never as "silent".
P="$TMP/projects"; WT="$P/-work--claude-worktrees-bfp-137"; MAIN="$P/-work"; mkdir -p "$WT" "$MAIN"
N=$(date +%s); f="$WT/s-e2e-rekey.jsonl"; { rec_loop $((N-3000)); rec_fire $((N-20)); rec_loop $((N-20)); rec_wake $((N-1)) 1; rec_result "$N"; rec_text "$N"; rec_stopsum "$N"; } > "$f"
( sleep 1; mv "$f" "$MAIN/"; M=$(date +%s); { rec_work "$M"; rec_text "$M"; } >> "$MAIN/s-e2e-rekey.jsonl" ) &
run_hook "$(ev Stop "$f" s-e2e-rekey '{"stop_hook_active":false}')" 3 900
wait
ck "27 transcript re-keyed during the wait -> exit 0"          0 "$RC"
ck "27 ... nothing is said to the model"                       0 "$(wc -c < "$TMP/err" | tr -d ' ')"
ck "27 ... the log names why it stood down"                    1 "$(grep -c 's-e2e-re Stop stood-down kind=stop reason=transcript-unreadable' "$LOGS/auto-rewake.log")"
ck "27 ... no rewake was counted"                              0 "$(get_state s-e2e-rekey stop_rewakes)"

# 28. Instances OVERLAP on a busy session (each turn end launches one, and most wakeups are superseded), so the count is
#     read when it is used: two that both launched at 0 are rewakes 1 and 2, never 1 and 1. stop_hook_active keeps the
#     launch-time reset out of the way — what is under test is the read at wake.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_fire $((N-20)); rec_loop $((N-20)); rec_wake $((N-1)) 1; rec_result "$N"; rec_text "$N"; rec_stopsum "$N"; } > "$f"
E=$(ev Stop "$f" s-e2e-overlap '{"stop_hook_active":true}')
for g in 1 4; do
  ( printf '%s' "$E" | AUTO_REWAKE_GRACE="$g" AUTO_REWAKE_SETTLE=1 AUTO_REWAKE_LOG_DIR="$LOGS" "$HOOK" > /dev/null 2> "$TMP/err.$g" ) &
done
wait
ck "28 overlapping instances: the first is rewake 1"           1 "$(grep -c 'rewake 1 of 12' "$TMP/err.1")"
ck "28 ... the second is rewake 2, not a second 1"             1 "$(grep -c 'rewake 2 of 12' "$TMP/err.4")"
ck "28 ... and the counter holds both"                         2 "$(get_state s-e2e-overlap stop_rewakes)"

# 29. The cap is re-tested at the wake: an instance that launched under it does not rewake once others have reached it.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_fire $((N-20)); rec_loop $((N-20)); rec_wake $((N-1)) 1; rec_result "$N"; rec_text "$N"; rec_stopsum "$N"; } > "$f"
( sleep 1; set_state s-e2e-capwake '{"stop_rewakes":12}' ) &
run_hook "$(ev Stop "$f" s-e2e-capwake '{"stop_hook_active":true}')" 3 900
wait
ck "29 cap reached while the instance slept -> exit 0"         0 "$RC"
ck "29 ... nothing is said to the model"                       0 "$(wc -c < "$TMP/err" | tr -d ' ')"
ck "29 ... the log names the cap"                              1 "$(grep -c 's-e2e-ca Stop stood-down kind=stop reason=stop-cap n=12' "$LOGS/auto-rewake.log")"

# 30. THE ZERO WAIT (2026-09-20): a 60s arm inside a turn that ran sixteen minutes more. A wakeup cannot fire while the
#     turn that armed it still runs, so it fired as that turn ended — 33ms after the stop summary — and the hook, launched
#     past due + grace with nothing to wait out, looked before that record could exist and rewoke the session as well.
#     The fire lands at +5s under a 7s grace: its whole-second stamp has to clear the hook's 2s slack, and 21b flaked
#     about one run in four while its record sat on that boundary.
N=$(date +%s); f=$(tfile); { rec_loop $((N-3000)); rec_fire $((N-1020)); rec_loop $((N-1020)); rec_wake $((N-1000)) 60; rec_result $((N-999)); rec_work $((N-5)); rec_text "$N"; rec_stopsum "$N"; } > "$f"
( sleep 5; M=$(date +%s); { rec_fire "$M"; rec_loop "$M"; } >> "$f" ) &
run_hook "$(ev Stop "$f" s-e2e-zero '{"stop_hook_active":false}')" 7 900
wait
ck "30 overdue wakeup fires as its turn ends -> exit 0"        0 "$RC"
ck "30 ... nothing is said to the model"                       0 "$(wc -c < "$TMP/err" | tr -d ' ')"
ck "30 ... it waited out the grace, not zero"                  1 "$(grep -c 's-e2e-ze Stop wait kind=stop wait_s=7$' "$LOGS/auto-rewake.log")"
ck "30 ... the log says it stood down"                         1 "$(grep -c 's-e2e-ze Stop stood-down kind=stop records_since=' "$LOGS/auto-rewake.log")"
ck "30 ... no rewake was counted"                              0 "$(get_state s-e2e-zero stop_rewakes)"

echo "auto-rewake.sh — registration (../settings.json):"
# Both fields are load-bearing and both fail silently. Measured 2026-09-19: without asyncRewake the exit code wakes
# nothing, and at the default command timeout (600s) a hook waiting out an 1800s wakeup is killed first.
S=../settings.json
reg() { jq -r --arg ev "$1" "[.hooks[\$ev][]? | . as \$g | \$g.hooks[]? | select((.command // \"\") | test(\"auto-rewake\\\\.sh\")) | $2] | first // \"missing\" | tostring" "$S" 2>/dev/null; }
ck "25 Stop: registered"                                       command "$(reg Stop .type)"
ck "25 Stop: asyncRewake true"                                 true "$(reg Stop .asyncRewake)"
ck "25 Stop: timeout clears a 3600s wakeup + the 300s grace"   true "$(reg Stop '((.timeout // 0) >= 3960)')"
ck "26 StopFailure: registered"                                command "$(reg StopFailure .type)"
ck "26 StopFailure: asyncRewake true"                          true "$(reg StopFailure .asyncRewake)"
ck "26 StopFailure: timeout clears the 900s retry delay"       true "$(reg StopFailure '((.timeout // 0) >= 960)')"
ck "26 StopFailure: matcher admits the transient errors"       true "$(reg StopFailure '(($g.matcher // "") | (test("rate_limit") and test("overloaded") and test("server_error")))')"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
