#!/usr/bin/env bash
# Claude Stop + StopFailure hook, registered `asyncRewake: true`: wake a self-paced `/loop /auto` session that went silent.
#
# WHY: two silent deaths end a fleet session with its ledger still `active`, and neither is visible to a synchronous hook.
#   1. THE LOST WAKEUP (Stop). The turn ends compliantly — a ScheduleWakeup IS armed, so auto-heartbeat.sh passes it,
#      correctly — and then the wakeup never fires. No turn follows, so no Stop event ever fires again, and the daemon
#      retires the idle background session an hour later. Measured 2026-09-19 on a fleet of three: of 110 wakeups armed,
#      84 were superseded, 23 fired on time, and the last one in EACH session never produced a turn; 19.4 session-hours
#      sat dead behind them. Why a wakeup is lost is unestablished, which is the reason to recover rather than prevent.
#   2. THE API-ERROR KILL (StopFailure). A rate limit, overload or 5xx kills the turn mid-iteration. Stop does not fire
#      at all — StopFailure fires INSTEAD — so nothing arms a wakeup and the session is dead until a human prompts it.
#      Measured 2026-08-14 (4.85 session-hours) and 2026-08-17 (25.2 overnight).
#
# THE MECHANISM: a command hook marked `asyncRewake: true` runs in the background, and when it exits 2 the harness
# wakes the session with the hook's stderr as a system reminder. Measured 2026-09-19 on 2.1.278: a Stop hook woke a
# real `claude --bg` session sitting idle at its prompt 20s after its turn ended, and a StopFailure hook woke a session
# 4s after a 429 killed its turn (StopFailure's "output and exit codes are ignored" holds only for the synchronous
# contract). The wake arrives as a user record with origin.kind "task-notification", never "human", so it neither trips
# auto-heartbeat.sh's human-override nor counts as an operator prompt in a retro.
#
# So this hook WAITS, then looks again, and exits 2 only if nothing happened:
#   Stop         the turn now ending armed a non-stop ScheduleWakeup -> wait until its due time (record timestamp +
#                delaySeconds) plus AUTO_REWAKE_GRACE, then exit 2 iff no turn followed. The grace is 300s: the runtime
#                rounds an arm up to the next minute (a requested 1800s was scheduled "in 1837s") and observed fire
#                lateness was 2-57s.
#   StopFailure  a transient API error (rate_limit, overloaded, server_error, unknown) -> wait AUTO_REWAKE_API_DELAY
#                (900s, /auto's own API-error retry cadence), then exit 2 iff no turn followed. If the limit still
#                holds, the woken request fails the same way, StopFailure fires again, and the next instance waits
#                again — a retry loop that costs nothing per attempt and keeps the session from idling into the reaper.
#
# DELIBERATELY NOT FIRING — each is a real exit, not an oversight:
#   - Not a self-paced `/loop /auto` session, or a fixed-interval one. The discriminator is auto-heartbeat.sh's
#     decide(), sourced below: ONE definition of that session, never a second copy that can drift.
#   - A turn that ended UN-armed or on a stale arm. That is auto-heartbeat.sh's fault to catch, synchronously.
#     The turn is scoped HERE from its START, not with decide()'s `armed` verdict: that verdict windows on the last
#     stop_hook_summary, which is right for a synchronous hook (it runs before the ending turn's summary is written)
#     and wrong for this one — running in the background, it reads after that summary lands, so the window would
#     open AFTER the arm and every compliant turn would read `stale-arm`. decide() is used only for what does not
#     depend on that ordering: whether this is a self-paced /loop /auto session, and whether a human holds it.
#   - ScheduleWakeup(stop: true): the loop ended on purpose, and silence is its contract.
#   - A human prompt after the iteration anchor (decide()'s human-override): the run is under manual control.
#   - A non-transient API error (authentication, billing, invalid request, ...): a retry cannot fix it; a human must.
#   - A turn DID follow — the wakeup fired late, a task notification landed, an operator attached, or a synchronous
#     Stop hook blocked this very stop. Anything newer than this hook's start means the session is not dead.
#   - The transcript cannot be read after the wait (`stood-down … reason=transcript-unreadable`). Being unable to measure
#     is not evidence of silence, and waking a healthy session is the costlier mistake: it is told to run an iteration.
#   - The per-session caps (AUTO_REWAKE_STOP_MAX 12 consecutive rewakes, AUTO_REWAKE_API_MAX 24 = six hours of retries),
#     so a session whose scheduler is simply broken, or a multi-day quota block, cannot be revived forever.
#
# REGISTRATION (settings.json) — both fields are load-bearing, and both were measured:
#   "asyncRewake": true   without it the hook's exit code wakes nothing.
#   "timeout": 4200       command hooks default to 600s, and `timeout` DOES govern an asyncRewake hook: at timeout 3 an
#                         8s wait was killed and nothing woke; at 30 it woke. 4200 clears a 3600s wakeup plus the grace.
#                         The long wait itself was soaked the same day: a hook that waited 2100s under timeout 4200
#                         woke its session at t=2100.3s (headless, against a mock API — not yet a `--bg` session).
#
# EVERY decision for an in-scope session is one line in ~/.claude/logs/auto-rewake.log — that file is how a retro
# tells "the hook revived it" from "the hook stood down" from "the hook was never registered".
#
# Usage: as a hook, reads the event JSON on stdin. `auto-rewake.sh --decide < event.json` prints the decision as JSON
# and exits 0 without waiting, logging or touching state — what auto-rewake.test.sh drives. Run that suite after ANY
# change here. The jq programs are single-quoted bash strings: NO ' character anywhere in them, comments included.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=auto-heartbeat.sh
source "$HOOK_DIR/auto-heartbeat.sh"   # decide() only — that file guards its main body against being sourced

GRACE="${AUTO_REWAKE_GRACE:-300}"
API_DELAY="${AUTO_REWAKE_API_DELAY:-900}"
STOP_MAX="${AUTO_REWAKE_STOP_MAX:-12}"
API_MAX="${AUTO_REWAKE_API_MAX:-24}"
SETTLE_TRIES="${AUTO_REWAKE_SETTLE:-10}"
LOG_DIR="${AUTO_REWAKE_LOG_DIR:-$HOME/.claude/logs}"
TAIL_LINES=600

MODE=hook
[[ "${1:-}" == "--decide" ]] && MODE=decide

INPUT=$(cat)
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT" 2>/dev/null || true)
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
SESSION=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)
STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)
API_ERROR=$(jq -r '.error // "unknown"' <<<"$INPUT" 2>/dev/null || echo unknown)
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
[[ -z "$SESSION" && -n "$TRANSCRIPT_PATH" ]] && SESSION=$(basename "$TRANSCRIPT_PATH" .jsonl)
SHORT="${SESSION:0:8}"

now() { printf '%s' "${AUTO_REWAKE_NOW:-$(date +%s)}"; }

# The last ScheduleWakeup of the TURN NOW ENDING: when it was armed, for how long, and whether it ended the loop.
# The turn starts at the last record that opens one — a fired wakeup (scheduled_task_fire), or a user record carrying
# text (a /loop delivery, a task notification, a prompt, a Stop-hook nudge; a tool_result carries none). An arm from an
# earlier turn is superseded by whatever opened this one, so it is not a live wakeup (auto-heartbeat.sh, TURN ANCHOR).
# With no opening record in the tail the whole tail is the turn: a long turn must not read as un-armed.
turn_wakeup() {
  tail -n "$TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null | jq -nR -c '
    [ inputs | fromjson? | select(type == "object") | select(.isSidechain != true) ] as $L
    | def utext($c):
        if ($c | type) == "string" then $c
        elif ($c | type) == "array"
          then ([$c[] | select((type == "object") and (.type == "text")) | (.text // "")] | join(" "))
        else "" end;
    ($L | to_entries) as $E
    | ([ $E[]
         | select(((.value.type == "system") and (.value.subtype == "scheduled_task_fire"))
                  or ((.value.type == "user") and ((utext(.value.message.content // "") | length) > 0)))
         | .key ] | last // -1) as $start
    | [ $E[] | select(.key > $start) | .value
        | select(.type == "assistant")
        | (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $at
        | (.message.content // []) | select(type == "array") | .[]
        | select((type == "object") and (.type == "tool_use") and (.name == "ScheduleWakeup"))
        | { at: $at,
            delay: (if ((.input.delaySeconds // null) | type) == "number" then .input.delaySeconds else null end),
            stop: (.input.stop == true),
            reason: ((.input.reason // "") | tostring | .[0:100]) }
      ] | last // empty' 2>/dev/null
}

# How many main-loop records that START or CARRY a turn are newer than <epoch>: a fired wakeup opens with a
# scheduled_task_fire system record, everything else with a user record, and any assistant record means work ran.
# FAILS when the count cannot be measured, and never answers with a guessed 0: the caller wakes the session on a 0.
# A `|| echo 0` hung off this pipeline did exactly that under pipefail — tail failed, jq had already printed its own 0,
# and the two-line "0\n0" killed the caller's -gt test, which reads as false. The file test is explicit so that the
# contract does not rest on a shell option.
turns_since() {
  local n
  [[ -f "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]] || return 1
  n=$(tail -n "$TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null | jq -nR --argjson since "$1" '
    [ inputs | fromjson? | select(type == "object") | select(.isSidechain != true)
      | select((.type == "user") or (.type == "assistant")
               or ((.type == "system") and (.subtype == "scheduled_task_fire")))
      | (try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null)
      | select((. != null) and (. > $since)) ] | length' 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

state_file() { printf '%s/auto-rewake/%s.json' "$LOG_DIR" "$SESSION"; }
# Unlike turns_since, an unreadable count answers 0: a lost count must not cost a rewake (set_counter, below).
counter() {
  local v
  v=$(jq -r --arg k "$1" '.[$k] // 0' "$(state_file)" 2>/dev/null) || v=0
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || echo 0
}
set_counter() { # set_counter <key> <value> — atomic, and never fatal: a lost count must not cost a rewake
  local f tmp; f=$(state_file); tmp="$f.$$"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  { [[ -f "$f" ]] && cat "$f" || echo '{}'; } | jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}
log() { # log <words...> — one line per decision, in-scope sessions only
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SHORT:-unknown}" "${EVENT:-?}" "$*" >> "$LOG_DIR/auto-rewake.log" 2>/dev/null || true
}

# Prints {action: skip|wait, reason, in_scope, ...}. Pure: reads the transcript and the counters, changes nothing.
decision() {
  local D kind W stop delay at due wait n try
  [[ "$EVENT" == "Stop" || "$EVENT" == "StopFailure" ]] || { echo '{"action":"skip","reason":"not-a-stop-event","in_scope":false}'; return; }
  [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || { echo '{"action":"skip","reason":"no-transcript","in_scope":false}'; return; }
  # The same cheap bail auto-heartbeat.sh makes: nearly every stop is an ordinary session with no /loop in it.
  grep -q '<command-name>/loop</command-name>' "$TRANSCRIPT_PATH" 2>/dev/null \
    || { echo '{"action":"skip","reason":"not-auto-loop","in_scope":false}'; return; }

  D=$(decide) || D=''
  [[ -n "$D" ]] || D='{"reason_kind":"unreadable"}'
  kind=$(jq -r '.reason_kind // "unreadable"' <<<"$D" 2>/dev/null || echo unreadable)
  case "$kind" in
    not-auto-loop|unreadable) echo "{\"action\":\"skip\",\"reason\":\"$kind\",\"in_scope\":false}"; return ;;
    human-override)           echo '{"action":"skip","reason":"human-override","in_scope":true}'; return ;;
  esac

  if [[ "$EVENT" == "StopFailure" ]]; then
    case "$API_ERROR" in
      rate_limit|overloaded|server_error|unknown) ;;
      *) jq -nc --arg e "$API_ERROR" '{action:"skip", reason:"not-transient", error:$e, in_scope:true}'; return ;;
    esac
    n=$(counter api_rewakes)
    [[ "$n" -ge "$API_MAX" ]] && { jq -nc --argjson n "$n" '{action:"skip", reason:"api-cap", n:$n, in_scope:true}'; return; }
    jq -nc --arg e "$API_ERROR" --argjson w "$API_DELAY" --argjson n "$n" \
      '{action:"wait", kind:"api", wait_s:$w, error:$e, n:$n, in_scope:true}'
    return
  fi

  # Stop. Only a turn that ARMED is ours; an un-armed or stale-armed one is auto-heartbeat.sh to block.
  # FLUSH RACE (auto-heartbeat.sh documents it): the turn that just ended may not be durably written when a Stop hook
  # starts, so a single read can miss the arm. A miss here is a death left unrecovered, so re-read — in the background
  # it costs nothing — until the arm shows or the tries run out.
  W=''
  for ((try = 1; try <= SETTLE_TRIES; try++)); do
    W=$(turn_wakeup) || W=''
    [[ -n "$W" || "$try" -ge "$SETTLE_TRIES" ]] && break
    sleep 0.3
  done
  [[ -n "$W" ]] || { echo '{"action":"skip","reason":"unarmed","in_scope":true}'; return; }
  stop=$(jq -r '.stop' <<<"$W"); delay=$(jq -r '.delay // empty' <<<"$W"); at=$(jq -r '.at // empty' <<<"$W")
  [[ "$stop" == "true" ]] && { echo '{"action":"skip","reason":"loop-ended","in_scope":true}'; return; }
  [[ -n "$delay" && -n "$at" ]] || { echo '{"action":"skip","reason":"no-delay","in_scope":true}'; return; }
  n=$(counter stop_rewakes)
  [[ "$n" -ge "$STOP_MAX" ]] && { jq -nc --argjson n "$n" '{action:"skip", reason:"stop-cap", n:$n, in_scope:true}'; return; }
  due=$(( at + ${delay%.*} ))
  wait=$(( due + GRACE - $(now) )); [[ "$wait" -lt 0 ]] && wait=0
  jq -nc --argjson w "$wait" --argjson due "$due" --argjson at "$at" --argjson d "${delay%.*}" --argjson n "$n" \
    --arg r "$(jq -r '.reason' <<<"$W")" '{action:"wait", kind:"stop", wait_s:$w, due:$due, armed_at:$at, delay:$d, n:$n, armed_reason:$r, in_scope:true}'
}

DEC=$(decision)
[[ "$MODE" == "decide" ]] && { printf '%s\n' "$DEC"; exit 0; }

ACTION=$(jq -r '.action' <<<"$DEC" 2>/dev/null || echo skip)
IN_SCOPE=$(jq -r '.in_scope // false' <<<"$DEC" 2>/dev/null || echo false)

# A Stop means a turn completed and the API answered: the retry count is spent. A stop no hook caused means the loop
# is turning over on its own again, so the consecutive-rewake count is spent too.
if [[ "$IN_SCOPE" == "true" && "$EVENT" == "Stop" ]]; then
  set_counter api_rewakes 0
  [[ "$STOP_ACTIVE" == "true" ]] || set_counter stop_rewakes 0
fi

if [[ "$ACTION" != "wait" ]]; then
  [[ "$IN_SCOPE" == "true" ]] && log "skip reason=$(jq -r '.reason' <<<"$DEC")"
  exit 0
fi

KIND=$(jq -r '.kind' <<<"$DEC"); WAIT=$(jq -r '.wait_s' <<<"$DEC")
STARTED=$(date +%s)
log "wait kind=$KIND wait_s=$WAIT"
[[ "$WAIT" -gt 0 ]] && sleep "$WAIT"

# A transcript this instance can no longer read is NOT an idle session. The harness re-keys a session's project directory
# when it enters or leaves a worktree, moving the transcript out from under the path captured at launch — and the session
# does that from inside a turn, so the move is itself evidence one followed; that turn's end launched its own instance.
# Measured 2026-09-20 on a three-session fleet: all 74 stop rewakes were of sessions a turn HAD followed in.
# 2s of slack: the records of the turn that just ended are stamped before this hook started, but only just.
FOLLOWED=$(turns_since $(( STARTED + 2 ))) || { log "stood-down kind=$KIND reason=transcript-unreadable"; exit 0; }
if [[ "$FOLLOWED" -gt 0 ]]; then
  log "stood-down kind=$KIND records_since=$FOLLOWED"
  exit 0
fi

# The count is read HERE, not carried from launch: a busy session supersedes its wakeups, so instances overlap, and each
# would otherwise add one to the same stale number. The cap is re-tested for the same reason.
N=$(counter "${KIND}_rewakes")
MAX=$STOP_MAX; [[ "$KIND" == "api" ]] && MAX=$API_MAX
if [[ "$N" -ge "$MAX" ]]; then
  log "stood-down kind=$KIND reason=$KIND-cap n=$N"
  exit 0
fi

WAITED_MIN=$(( ( $(date +%s) - STARTED ) / 60 ))
if [[ "$KIND" == "api" ]]; then
  set_counter api_rewakes $(( N + 1 ))
  log "rewake kind=api error=$API_ERROR n=$(( N + 1 ))/$API_MAX waited_min=$WAITED_MIN"
  cat >&2 <<EOF
auto-rewake: the previous turn of this /loop /auto run was killed by an API error ($API_ERROR) ${WAITED_MIN} min ago, and nothing has run since (retry $(( N + 1 )) of $API_MAX). That is transient infrastructure, never an issue failure — skills/auto/SKILL.md, "Transient API failures are never failures". Resume the /auto iteration exactly where the transcript left off ("Stall recovery on re-entry": make the missing dispatch, or go straight to Step 4 if /full's terminal tag was already emitted), then carry the loop on, ending the turn with ScheduleWakeup as every iteration does. This is not a human prompt. If this request fails the same way, this hook retries on its own.
EOF
  exit 2
fi

DUE=$(jq -r '.due' <<<"$DEC"); DELAY=$(jq -r '.delay' <<<"$DEC"); ARMED_AT=$(jq -r '.armed_at' <<<"$DEC")
OVERDUE_MIN=$(( ( $(date +%s) - DUE ) / 60 ))
ARMED_ISO=$(date -u -r "$ARMED_AT" +%H:%M:%SZ 2>/dev/null || date -u -d "@$ARMED_AT" +%H:%M:%SZ 2>/dev/null || echo "epoch $ARMED_AT")
set_counter stop_rewakes $(( N + 1 ))
log "rewake kind=stop armed_at=$ARMED_ISO delay=$DELAY overdue_min=$OVERDUE_MIN n=$(( N + 1 ))/$STOP_MAX"
cat >&2 <<EOF
auto-rewake: the ScheduleWakeup this session armed at $ARMED_ISO for ${DELAY}s never fired — it is ${OVERDUE_MIN} min overdue and no turn followed (rewake $(( N + 1 )) of $STOP_MAX). The /loop /auto run is still live, and this message stands in for that wakeup. Do now exactly what it would have done: run the next iteration of the auto skill with this run's original arguments, and end the turn with ScheduleWakeup as every iteration does, passing the same /loop prompt. This is not a human prompt — do not stop the loop on account of it, and do not treat the run as under manual control.
EOF
exit 2
