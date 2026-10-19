#!/usr/bin/env bash
# fleet-headroom.sh — may an /auto fleet session pick another issue right now, or would the pick
# saturate the account's 5-hour window mid-issue?
#
# WHY: the 5h limit itself is cheap to hit (minutes of reset wait) — being killed MID-ISSUE by it is
# what's expensive. A mid-turn kill fires StopFailure instead of Stop, so no wakeup is armed; before
# hooks/auto-rewake.sh that left the session dead until a human attached (2026-08-17 overnight fleet:
# 25.2 session-hours idle AFTER the reset). auto-rewake.sh now retries such a kill every 900s for up to
# six hours — a live weekly cutoff mid-turn was recovered that way on 2026-10-13, all three sessions
# resumed; the 5h case rests on the hook's design, not yet a live measurement — so the gate no longer
# prevents permanent death. What it still saves is the killed turn's rework (a kill can land mid
# non-idempotent step; 2026-08-17 also cost 2 keeper-hours draining half-done issues) and a fleet-wide
# stop until the reset. A session that only ever meets the limit BETWEEN issues loses neither: its parked
# wakeup fires after the reset. So /auto's fleet mode consults this probe at pick time and parks instead
# of picking when the window is nearly full.
#
# THE METER is the account's own. mods/rate-limits records the engine's `five_hour` reading (`percentUsed`,
# `resetsAt`) per session under ~/.claude/local/rate-limits/<session-id>.jsonl, one line per move, and the
# machine's latest reading in ~/.claude/local/rate-limits.json. `--session <id|run key>` reads the session's
# own history — the account it runs on, by construction, which is what a multi-account machine needs — and
# falls back to the snapshot (last writer on this machine). Until 2026-10-13 the probe summed output tokens
# across every transcript on the machine against a hand-calibrated token ceiling: the sum mapped to no one
# account's window, so the ceiling was set to 100M on 2026-08-30 and the gate parked nothing for six weeks.
#
# RESERVE: THROTTLE when the window's headroom (100 - percentUsed) is under --reserve points, default 20 —
# about one issue's burn (a 2026-08-14 session burned ~35 points of its window per 5h at ~2h per issue).
# Unmeasured against this meter; tune with the flag. A reading whose resetsAt has passed counts as 0% used:
# the window reset after it was taken.
#
# ROTATION: on a machine that rotates accounts through cswap (opt-in: scripts/cswap-setup.sh) the engine moves
# the login at its threshold to any enrolled account with room, so a pick dies mid-issue only when NO account
# has room. The probe asks cswap first — `cswap list --json`, the engine's own cached figures with their age,
# and its `autoswitch.threshold` — and while another account is under the threshold with a fresh `ok` figure
# it answers PICK-OK whatever the local meter says: the engine lands there when this one fills. Otherwise the
# local meter governs exactly as on a single-account machine, and the line's `cswap=` tail says why. The
# rotating machine is cswap's backup root (the test mods/rate-limits uses); a live engine is an event in
# ~/.claude/logs/cswap-auto.log within 5 minutes — an idle engine moves no one. A pick that lands while the
# active account is already at the threshold (the engine mid-move) keeps the local THROTTLE but re-probes in
# 3 minutes rather than at the reset: the next request lands on the new account. --stale <seconds> (900)
# bounds the age of a figure that counts as room — after the usage endpoint refuses a refresh, cswap serves
# the last good figure as `ok` for up to two hours.
#
# Exit: 0 = pick OK (headroom >= reserve, or no reading — FAIL OPEN: a missing mod must not halt a healthy
# fleet; the stall watcher remains the backstop, and the line says `source=none` so /fleet-status and
# /fleet-retro can see a blind gate). 2 = THROTTLE (headroom < reserve).
# Run ./fleet-headroom.test.sh after ANY change.

set -uo pipefail

SESSION=""
RESERVE=20
STALE=900
AS_JSON=0
NOW=""   # test seam: fixed epoch clock
LOCAL_DIR="${HOME:-}/.claude/local"
HISTORY_DIR="${RATE_LIMITS_DIR:-$LOCAL_DIR/rate-limits}"
SNAPSHOT="$LOCAL_DIR/rate-limits.json"
CSWAP_LOG="${HOME:-}/.claude/logs/cswap-auto.log"

while [ $# -gt 0 ]; do
  case "$1" in
    --session)  SESSION="$2"; shift 2 ;;
    --reserve)  RESERVE="$2"; shift 2 ;;
    --stale)    STALE="$2"; shift 2 ;;
    --json)     AS_JSON=1; shift ;;
    --now)      NOW="$2"; shift 2 ;;
    -h|--help)  sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 0 ;;   # fail open, never fail closed on usage
  esac
done

[ -n "$NOW" ] || NOW=$(date +%s)
[[ "$RESERVE" =~ ^[0-9]+([.][0-9]+)?$ ]] || RESERVE=20
[[ "$STALE" =~ ^[0-9]+$ ]] || STALE=900

fmt_dur() { if [ "$1" -lt 60 ]; then echo "${1}s"; elif [ "$1" -lt 3600 ]; then echo "$(( $1 / 60 ))m"; else echo "$(( $1 / 3600 ))h$(( ($1 % 3600) / 60 ))m"; fi; }
iso_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch empty'; }

# cswap's verdict rides every answer on a rotating machine: a `cswap=<state>(<why>)` tail on the line, a `cswap` object in --json.
cswap_state=""; cswap_note=""; cswap_json="null"
cswap_set() { cswap_state="$1"; cswap_note="$2"; cswap_json=$(jq -cn --arg s "$1" --arg n "$2" --argjson v "${3:-null}" '{state: $s, note: $n} + ($v // {})'); }
cswap_tail() { [ -n "$cswap_state" ] && printf '  cswap=%s(%s)' "$cswap_state" "$cswap_note"; return 0; }

open() { # <why> — no usable reading: say so and let the pick proceed
  echo "WARN: $1 — failing open (pick OK)" >&2
  if [ "$AS_JSON" = 1 ]; then
    jq -n --arg why "$1" --argjson r "$RESERVE" --argjson c "$cswap_json" '{pick_ok: true, source: "none", reserve: $r, note: $why, cswap: $c}'
  else
    echo "PICK-OK  five_hour=? (no reading: $1)  source=none$(cswap_tail)"
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || open "jq not found"

rotating=false
for d in "${HOME:-}/.claude-swap-backup" "${XDG_DATA_HOME:-${HOME:-}/.local/share}/claude-swap"; do [ -d "$d" ] && rotating=true; done
if [ "$rotating" = true ]; then
  last_ts=$(tail -n 1 "$CSWAP_LOG" 2>/dev/null | jq -r '.ts // .at // empty' 2>/dev/null)
  last_epoch=""; [ -n "$last_ts" ] && last_epoch=$(iso_epoch "$last_ts")
  cswap_bin=$(command -v cswap 2>/dev/null || true)
  [ -z "$cswap_bin" ] && [ -x "${HOME:-}/.local/bin/cswap" ] && cswap_bin="$HOME/.local/bin/cswap"
  if [ -z "$last_epoch" ]; then
    cswap_set engine-idle "no engine event in $CSWAP_LOG"
  elif [ $(( NOW - last_epoch )) -gt 300 ]; then
    cswap_set engine-idle "last engine event $(fmt_dur $(( NOW - last_epoch ))) ago"
  elif [ -z "$cswap_bin" ]; then
    cswap_set unreadable "cswap not on PATH or in ~/.local/bin"
  else
    list=$("$cswap_bin" list --json 2>/dev/null) || list=""
    threshold=$("$cswap_bin" config get autoswitch.threshold 2>/dev/null | tr -d '[:space:]')
    if ! printf '%s' "$list" | jq -e '.accounts | length > 0' >/dev/null 2>&1; then
      cswap_set unreadable "cswap list --json carried no accounts"
    elif ! [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      cswap_set unreadable "autoswitch.threshold unreadable"
    else
      # The binding window is the higher of 5h and 7d, as cswap's own headroomPct computes it (scoped windows such as Fable
      # are not in it). Among the accounts with room, consume-first lands on the soonest weekly reset, so that one is named.
      verdict=$(printf '%s' "$list" | jq -c --argjson t "$threshold" --argjson stale "$STALE" '
        def binding: ([(.usage.fiveHour.pct // 0), (.usage.sevenDay.pct // 0)] | max) + 0;
        def row: {email, binding_pct: binding, status: .usageStatus, age_s: .usageAgeSeconds, weekly_resets_at: .usage.sevenDay.resetsAt};
        (.accounts | map(select(.active == true)) | .[0]) as $a
        | (.accounts | map(select(.active != true and .usageStatus == "ok" and .usageAgeSeconds != null and .usageAgeSeconds <= $stale and binding < $t))
           | sort_by(.usage.sevenDay.resetsAt // "9") | .[0]) as $g
        | {threshold: $t, accounts: (.accounts | length), active: (if $a == null then null else ($a | row) end), target: (if $g == null then null else ($g | row) end)}')
      a_email=$(jq -r '.active.email // empty' <<<"$verdict")
      a_pct=$(jq -r '.active.binding_pct // empty' <<<"$verdict")
      g_email=$(jq -r '.target.email // empty' <<<"$verdict")
      g_pct=$(jq -r '.target.binding_pct // empty' <<<"$verdict")
      g_age=$(jq -r '.target.age_s // 0 | floor' <<<"$verdict")
      n_acc=$(jq -r '.accounts' <<<"$verdict")
      if [ -z "$a_email" ]; then
        cswap_set unreadable "no active account in cswap list" "$verdict"
      elif [ -z "$g_email" ]; then
        cswap_set no-target "none of the other $(( n_acc - 1 )) accounts is under threshold $threshold with an ok figure under ${STALE}s old" "$verdict"
      elif jq -en --argjson a "$a_pct" --argjson t "$threshold" '$a >= $t' >/dev/null; then
        cswap_set switching "active $a_email at ${a_pct}% >= threshold $threshold; the engine is moving to $g_email at ${g_pct}%" "$verdict"
      else
        cswap_set target "$g_email at ${g_pct}% < threshold $threshold, figure $(fmt_dur "$g_age") old — the engine's landing when $a_email fills" "$verdict"
      fi
    fi
  fi
fi

# The session's own history first (its last line is its latest windows: a line is written whenever one moves), then the snapshot.
source="none"; writer=""; reading=""
if [ -n "$SESSION" ]; then
  f=$(ls -t "$HISTORY_DIR/$SESSION"*.jsonl 2>/dev/null | head -1)
  if [ -n "$f" ]; then
    line=$(tail -n 1 "$f" 2>/dev/null)
    if printf '%s' "$line" | jq -e '.windows' >/dev/null 2>&1; then
      reading="$line"; source="session"; writer=$(basename "$f" .jsonl); writer="${writer:0:8}"
    fi
  fi
fi
if [ -z "$reading" ] && [ -f "$SNAPSHOT" ] && jq -e '.windows' "$SNAPSHOT" >/dev/null 2>&1; then
  reading=$(cat "$SNAPSHOT"); source="snapshot"; writer=$(jq -r '.session // ""' "$SNAPSHOT"); writer="${writer:0:8}"
fi
[ -n "$reading" ] || open "no mods/rate-limits reading (${SESSION:+no history for session $SESSION, and }$SNAPSHOT is missing or unreadable)"

parsed=$(printf '%s' "$reading" | jq -c '
  ((.windows // []) | map(select(.kind == "five_hour")) | .[0]) as $w
  | {pct: $w.percentUsed, resets_at: ($w.resetsAt // null), measured_at: (.measured_at // null)}' 2>/dev/null) || parsed=""
pct=$(jq -r '.pct // empty' <<<"$parsed" 2>/dev/null)
[[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || open "the $source reading carries no five_hour window"
resets_at=$(jq -r '.resets_at // empty' <<<"$parsed")
measured_at=$(jq -r '.measured_at // empty' <<<"$parsed")
resets_epoch=""; [ -n "$resets_at" ] && resets_epoch=$(iso_epoch "$resets_at")
measured_epoch=""; [ -n "$measured_at" ] && measured_epoch=$(iso_epoch "$measured_at")

window_reset=false; resets_in=0
if [ -n "$resets_epoch" ]; then
  if [ "$resets_epoch" -le "$NOW" ]; then window_reset=true; else resets_in=$(( resets_epoch - NOW )); fi
fi
effective="$pct"; [ "$window_reset" = true ] && effective=0
headroom=$(jq -rn --argjson p "$effective" '100 - $p')
local_ok=$(jq -rn --argjson h "$headroom" --argjson r "$RESERVE" '$h >= $r')

pick_ok="$local_ok"
[ "$cswap_state" = target ] && pick_ok=true
[ "$cswap_state" = switching ] && [ "$pick_ok" = false ] && resets_in=180

age=""
if [ -n "$measured_epoch" ]; then a=$(( NOW - measured_epoch )); [ "$a" -lt 0 ] && a=0; age="$(fmt_dur "$a") ago"; fi

if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson ok "$pick_ok" --argjson pct "$pct" --argjson h "$headroom" --argjson r "$RESERVE" \
        --arg resets "$resets_at" --argjson rin "$resets_in" --argjson reset "$window_reset" \
        --arg at "$measured_at" --arg src "$source" --arg w "$writer" --argjson c "$cswap_json" \
        '{pick_ok: $ok, five_hour_pct: $pct, headroom: $h, reserve: $r, resets_at: (if $resets == "" then null else $resets end),
          resets_in: $rin, window_reset: $reset, measured_at: (if $at == "" then null else $at end), source: $src, writer: $w, cswap: $c}'
else
  used="five_hour=${pct}% used"
  [ "$window_reset" = true ] && used="five_hour=${pct}% used before the window reset at $resets_at (counted as 0)"
  rest="resets=${resets_at:-unknown}  resets_in=${resets_in}s  source=${source}(${writer:-?})  measured=${measured_at:-unknown}${age:+ ($age)}$(cswap_tail)"
  if [ "$pick_ok" = true ] && [ "$local_ok" = true ]; then
    echo "PICK-OK  $used  headroom=$headroom >= reserve=$RESERVE  $rest"
  elif [ "$pick_ok" = true ]; then
    echo "PICK-OK  $used  headroom=$headroom < reserve=$RESERVE but cswap has a landing  $rest"
  elif [ "$cswap_state" = switching ]; then
    echo "THROTTLE $used  headroom=$headroom < reserve=$RESERVE  $rest — re-probe in 3m: cswap is moving the login, the next request lands on the new account"
  else
    echo "THROTTLE $used  headroom=$headroom < reserve=$RESERVE  $rest — park with a wakeup until the reset instead of picking"
  fi
fi

[ "$pick_ok" = true ] && exit 0 || exit 2
