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
# that did not. Case #17 is the same principle one level down: an iteration is several TURNS when
# delegated work is in flight, and a turn that armed correctly must never vouch for a later turn of the
# same iteration that did not — the 6a77c517 death (2026-08-29).
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
# What a wakeup armed with prompt "/auto" (rather than "/loop /auto") actually delivers — verbatim
# shape from basefund session 7ac57ff0, 2026-08-08T09:18:01Z. No /loop block, and no origin.kind.
AUTO_BARE='{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-message>auto</command-message>\n<command-name>/auto</command-name>"}}'
# The same block typed by a human: a one-shot targeted run, which correctly arms nothing.
AUTO_HUMAN='{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"<command-message>auto</command-message>\n<command-name>/auto</command-name>\n<command-args>BF-123</command-args>"}}'
# A completed turn: the summary the harness writes AFTER a turn's Stop hooks have run and allowed the
# stop. Shape from basefund session 6a77c517, 2026-08-29T04:37:44Z.
STOPSUM='{"type":"system","subtype":"stop_hook_summary","isSidechain":false,"preventedContinuation":false,"hookCount":3}'
# A BLOCKED stop: the hooks prevented continuation, so the turn did NOT end.
STOPSUM_BLOCKED='{"type":"system","subtype":"stop_hook_summary","isSidechain":false,"preventedContinuation":true,"hookCount":3}'
# The wake that starts the next turn of the same iteration when a background task finishes. Not a
# human prompt (origin.kind is task-notification) and not a /loop delivery, so it never re-anchors.
NOTIF='{"type":"user","isSidechain":false,"origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>a391ddadb2c484551</task-id>\n<status>completed</status>\n</task-notification>"}}'

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

# 13. THE 7ac57ff0 MODE (2026-08-08): a wakeup armed with prompt "/auto" instead of "/loop /auto"
# fires a BARE /auto delivery carrying no /loop block. With the anchor keyed on /loop alone it stopped
# advancing, the earlier iteration's wakeup stayed inside the frozen window, and the hook was disarmed
# for the session's remaining 14.3h — it ended un-armed and the hook allowed it. Measured: 20 of that
# session's 91 wakeups used the bare prompt, and its last /loop anchor was 05:12 UTC against a 19:28
# UTC death. This is case #9's defect wearing a different delivery shape, so it fires for the same
# reason: a previous iteration's arming must never vouch for the one now ending.
check "13 bare /auto firing re-anchors (7ac57ff0)" fire true "$LOOP" "$WORK" "$WAKE" "$AUTO_BARE" "$WORK"

# 14. ...and the bare-/auto window clears normally when that iteration DOES arm.
check "14 bare /auto anchor clears when armed" fire false "$LOOP" "$WORK" "$AUTO_BARE" "$WORK" "$WAKE"

# 15. A HUMAN-typed bare /auto is a one-shot targeted run, which never arms a wakeup by design. It
# must not become an anchor — left in the $humans window it clears the hook, so correct targeted
# behaviour is not punished with a block.
check "15 human /auto one-shot does not fire" fire false "$LOOP" "$WORK" "$WAKE" "$AUTO_HUMAN" "$WORK"

# 16. Nudge accounting must survive the new anchor: counted from the bare-/auto anchor, not the /loop.
check "16 attempts counted from bare anchor" attempts 1 "$LOOP" "$NUDGE" "$WORK" "$AUTO_BARE" "$NUDGE" "$WORK"

# 17. THE 6a77c517 MODE (2026-08-29): the iteration armed correctly, the turn ended, a task-notification
# started the next turn, and THAT turn ended un-armed. The pending arm is superseded by the wake, so
# the loop is dead — yet an iteration-scoped count saw 11 arms and vouched for it (7.3h idle of a 12h
# budget). Case #9 at turn granularity: an earlier turn must never vouch for the one now ending.
check "17 arm in a prior turn does not clear (6a77c517)" fire true "$LOOP" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK"

# 18. ...and an arm in the current turn still clears.
check "18 arm in the current turn clears" fire false "$LOOP" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK" "$WAKE"

# 19. ...as does a deliberate stop in the current turn.
check "19 stop:true in the current turn clears" fire false "$LOOP" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK" "$WAKE_STOP"

# 20. The stale arm is named, so a replay can tell this mode from a never-armed iteration.
check "20 stale arm is named" reason_kind stale-arm "$LOOP" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK"

# 21. A BLOCKED stop did not end the turn and must not advance the turn anchor — otherwise every nudge
# resets the window, the nudge count restarts at 0, and the give-up bound in main() is unreachable.
check "21 blocked stop keeps the nudge count" attempts 1 "$LOOP" "$WORK" "$STOPSUM_BLOCKED" "$NUDGE" "$WORK"
check "21b arm after a blocked stop clears" fire false "$LOOP" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK" "$STOPSUM_BLOCKED" "$NUDGE" "$WORK" "$WAKE"

# 22. A turn end BEFORE the iteration anchor is stale: the window starts at the anchor, as before.
check "22 turn end before the anchor is stale" fire false "$STOPSUM" "$LOOP" "$WORK" "$WAKE"

# 23. Nudges are counted per turn, like arms: a nudge in an earlier turn of this iteration does not
# spend the current turn's bound.
check "23 attempts scoped to the turn" attempts 0 "$LOOP" "$NUDGE" "$WORK" "$WAKE" "$STOPSUM" "$NOTIF" "$WORK"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
