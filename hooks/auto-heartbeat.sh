#!/usr/bin/env bash
# Claude Stop hook: keep a self-paced `/loop /auto` run alive.
#
# WHY: under self-paced /loop, every iteration must end with a ScheduleWakeup or the loop dies
# SILENTLY — no NO-CANDIDATES, no AUTO-HALTED, no recorded outcome, nothing in the transcript that
# reads as a failure. skills/auto/SKILL.md long mandated an unconditional ~1800s fallback
# heartbeat in its most emphatic paragraph, and prose failed three times: BF-701 and BF-665
# are cited in that skill, and BF-695 (2026-08-01) is the third — that session shipped its issue at
# 12:45, never called ScheduleWakeup once, and idled ~7.75h of a four-session fleet run while its
# state file still read shipped: []. Nothing surfaced it until the fleet was reviewed the next day.
#
# This hook does for the loop heartbeat what full-continue.sh does for the /full handoff: it moves
# the reliability out of skill prose. When a turn ends inside a self-paced `/loop /auto` iteration
# that armed no ScheduleWakeup, block the stop and re-drive the arming.
#
# DELIBERATELY NOT FIRING — each is a real exit, not an oversight:
#   - ANY ScheduleWakeup after the iteration anchor, including {stop:true}. Arming the next tick and
#     deliberately ending the loop are both compliance; only SILENCE is the bug this catches.
#   - A human prompt (origin.kind == "human") after the anchor. The run is under manual control and
#     forcing a wakeup would fight the operator — this is the "discontinue the outer loop" case,
#     where the model is mid-decision and has not yet emitted its stop call.
#   - Fixed-interval /loop (`/loop 5m /auto`). A cron re-fires that; a wakeup is not the mechanism.
#   - Any /loop whose payload is not /auto, and any session with no /loop at all.
#
# ASYMMETRIC BY DESIGN: a false block costs one extra heartbeat, which skills/auto/SKILL.md declares
# explicitly benign ("Extra firings are benign ... absorbed by the re-entry rules and Step 0 sticky
# states"). A missed block costs the rest of the run. Where the evidence is ambiguous, block.
#
# FLUSH RACE: the ScheduleWakeup this hook looks for sits in the very last assistant turn — exactly
# the record that may not be durably written when a Stop hook fires (the PL-401/402 class that
# full-continue.sh documents at length). A single read would therefore report "no wakeup" on a
# perfectly compliant turn and block every iteration. The bounded re-read poll below is what makes
# the check trustworthy; do not remove it.
#
# EDITING THE jq PROGRAM: it is one single-quoted bash string, so it must contain NO ' character
# anywhere, including in comments. `bash -n auto-heartbeat.sh` catches a stray one instantly.
# Run ./auto-heartbeat.test.sh after ANY change to decide().

set -uo pipefail

decide() {
  jq -nR -c '
    [inputs | fromjson? | select(type == "object")] as $L
    | ($L | to_entries) as $E

    # Record text, whatever shape content takes: a typed /loop command arrives as a plain string,
    # a hook block reason as an array of text blocks. Anything else contributes no text.
    | def utext($c):
        if ($c | type) == "string" then $c
        elif ($c | type) == "array"
          then ([$c[] | select((type == "object") and (.type == "text")) | (.text // "")] | join(" "))
        else "" end;

    # ITERATION ANCHOR — the last self-paced `/loop /auto` delivery. The initial invocation and
    # every wakeup firing re-deliver the identical command block, so the LAST one is the start of
    # the iteration now ending, and the question this hook asks is only ever about that window.
    ([ $E[]
         | select(.value.type == "user")
         | select(.value.isSidechain != true)
         | (utext(.value.message.content // "")) as $t
         | select($t | test("<command-name>/loop</command-name>"))
         | select($t | test("<command-args>[^<]*/auto"))
         # Self-paced only. A leading interval (5m / 30s / 2h) makes this a cron-driven loop whose
         # re-fire does not depend on a wakeup, so an un-armed turn end there is correct behaviour.
         | select(($t | test("<command-args>\\s*[0-9]+\\s*[smhSMH]")) | not)
         | .key ] | last) as $loopidx

    | if $loopidx == null then {fire: false, pending: false, reason_kind: "not-auto-loop"}
      else
        # Any deliberate ScheduleWakeup inside the window clears the hook — armed or stopped.
        ([ $E[] | select(.key > $loopidx) | .value
           | select(.type == "assistant")
           | select(.isSidechain != true)
           | (.message.content // []) | select(type == "array") | .[]
           | select((type == "object") and (.type == "tool_use") and (.name == "ScheduleWakeup"))
         ] | length) as $wakeups

        # A human interjection after the anchor hands control back to the operator.
        | ([ $E[] | select(.key > $loopidx) | .value
             | select(.type == "user")
             | select(.origin.kind == "human")
           ] | length) as $humans

        # Prior nudges from THIS hook, counted off the marker phrase carried in both block reasons.
        # Keep that phrase in sync with main() below or the bound silently stops working.
        | ([ $E[] | select(.key > $loopidx) | .value
             | select(.type == "user")
             | utext(.message.content // "")
             | select(test("self-paced /loop /auto iteration"))
           ] | length) as $attempts

        | { fire: (($wakeups == 0) and ($humans == 0)),
            pending: ($wakeups == 0),
            wakeups: $wakeups, humans: $humans, attempts: $attempts,
            reason_kind: (if $humans > 0 then "human-override"
                          elif $wakeups > 0 then "armed"
                          else "unarmed" end) }
      end
  ' "$TRANSCRIPT_PATH" 2>/dev/null
}

# main — only when executed directly. Sourcing exposes decide() to the test harness without
# reading stdin or emitting a decision.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  INPUT=$(cat)
  TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
  STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)

  [[ -z "${TRANSCRIPT_PATH:-}" ]] && exit 0
  TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
  [[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

  # Cheap bail before any jq pass: the overwhelming majority of stops are ordinary sessions with no
  # /loop at all, and this hook runs on every one of them. grep -q short-circuits on first match.
  grep -q '<command-name>/loop</command-name>' "$TRANSCRIPT_PATH" 2>/dev/null || exit 0

  # Bounded re-read poll for the flush race described in the header. Break as soon as a wakeup is
  # visible; keep re-reading only while it is still missing, so a compliant turn pays a few reads and
  # a genuinely un-armed one pays the ceiling (~POLL_MAX x 0.2s) before blocking.
  DECISION='{"fire":false}'
  POLL_MAX=8
  for ((attempt = 1; attempt <= POLL_MAX; attempt++)); do
    D=$(decide) || D=''
    [[ -z "$D" ]] && D='{"fire":false}'
    DECISION="$D"
    [[ "$(jq -r '.pending // false' <<<"$D" 2>/dev/null || echo false)" == "true" ]] || break
    [[ "$attempt" -lt "$POLL_MAX" ]] && sleep 0.2
  done

  FIRE=$(jq -r '.fire // false' <<<"$DECISION" 2>/dev/null || true)
  [[ "$FIRE" != "true" ]] && exit 0

  ATTEMPTS=$(jq -r '.attempts // 0' <<<"$DECISION")

  # Hard bound. If the model has been told twice (three times when the harness is not already
  # re-entering) and still ends the turn un-armed, something is wrong that another nudge will not
  # fix; surface it on stderr and let the stop through rather than looping forever.
  if [[ "${ATTEMPTS:-0}" -ge 3 || ( "$STOP_ACTIVE" == "true" && "${ATTEMPTS:-0}" -ge 2 ) ]]; then
    echo "[auto-heartbeat] gave up after ${ATTEMPTS} attempt(s); the /loop /auto run will die here. Re-invoke /loop /auto to resume." >&2
    exit 0
  fi

  # The marker phrase "self-paced /loop /auto iteration" MUST stay in this string — decide() counts
  # prior nudges by matching it.
  REASON="You are ending a turn inside a self-paced /loop /auto iteration without arming the next \
ScheduleWakeup. Under self-paced /loop that kills the run silently — no NO-CANDIDATES, no AUTO-HALTED, \
no recorded outcome (skills/auto/SKILL.md, Self-paced loop pacing). Do NOT stop. Do exactly one of these \
now, then continue: (1) if this iteration is still in flight or the backlog still has candidates, call \
ScheduleWakeup with prompt \"/loop /auto\" — delaySeconds 1800 for the mid-iteration fallback heartbeat, \
or 60 if you have already emitted AUTO-CONTINUE and are ticking into the next issue; or (2) if the run is \
genuinely over because you emitted NO-CANDIDATES or AUTO-HALTED, call ScheduleWakeup(stop: true) to end \
the loop explicitly. Arming an extra heartbeat is harmless and is the safe choice when unsure. Do not ask \
the user which to pick."

  jq -n -c --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi
