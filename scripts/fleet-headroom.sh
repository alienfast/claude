#!/usr/bin/env bash
# fleet-headroom.sh — may an /auto fleet session pick another issue right now, or would the pick
# saturate the account's 5-hour window mid-issue?
#
# WHY: the 5h limit itself is cheap to hit (minutes of reset wait) — being killed MID-ISSUE by it is
# what's expensive: a mid-turn kill leaves no ScheduleWakeup pending and fires no Stop hook, so the
# session stays dead until a human attaches (2026-08-17 overnight fleet: 25.2 session-hours idle AFTER
# the reset, and 2 keeper-hours draining the half-done issues in the morning). A session that only ever
# meets the limit BETWEEN issues recovers itself: its parked wakeup fires after the reset. So /auto's
# fleet mode consults this probe at pick time and parks instead of picking when the window is nearly full.
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
# Exit: 0 = pick OK (headroom >= reserve, or no reading — FAIL OPEN: a missing mod must not halt a healthy
# fleet; the stall watcher remains the backstop, and the line says `source=none` so /fleet-status and
# /fleet-retro can see a blind gate). 2 = THROTTLE (headroom < reserve).
# Run ./fleet-headroom.test.sh after ANY change.

set -uo pipefail

SESSION=""
RESERVE=20
AS_JSON=0
NOW=""   # test seam: fixed epoch clock
LOCAL_DIR="${HOME:-}/.claude/local"
HISTORY_DIR="${RATE_LIMITS_DIR:-$LOCAL_DIR/rate-limits}"
SNAPSHOT="$LOCAL_DIR/rate-limits.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --session)  SESSION="$2"; shift 2 ;;
    --reserve)  RESERVE="$2"; shift 2 ;;
    --json)     AS_JSON=1; shift ;;
    --now)      NOW="$2"; shift 2 ;;
    -h|--help)  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 0 ;;   # fail open, never fail closed on usage
  esac
done

[ -n "$NOW" ] || NOW=$(date +%s)
[[ "$RESERVE" =~ ^[0-9]+([.][0-9]+)?$ ]] || RESERVE=20

open() { # <why> — no usable reading: say so and let the pick proceed
  echo "WARN: $1 — failing open (pick OK)" >&2
  if [ "$AS_JSON" = 1 ]; then
    jq -n --arg why "$1" --argjson r "$RESERVE" '{pick_ok: true, source: "none", reserve: $r, note: $why}'
  else
    echo "PICK-OK  five_hour=? (no reading: $1)  source=none"
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || open "jq not found"

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
iso_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty'; }
resets_epoch=""; [ -n "$resets_at" ] && resets_epoch=$(iso_epoch "$resets_at")
measured_epoch=""; [ -n "$measured_at" ] && measured_epoch=$(iso_epoch "$measured_at")

window_reset=false; resets_in=0
if [ -n "$resets_epoch" ]; then
  if [ "$resets_epoch" -le "$NOW" ]; then window_reset=true; else resets_in=$(( resets_epoch - NOW )); fi
fi
effective="$pct"; [ "$window_reset" = true ] && effective=0
headroom=$(jq -rn --argjson p "$effective" '100 - $p')
pick_ok=$(jq -rn --argjson h "$headroom" --argjson r "$RESERVE" '$h >= $r')

fmt_dur() { if [ "$1" -lt 3600 ]; then echo "$(( $1 / 60 ))m"; else echo "$(( $1 / 3600 ))h$(( ($1 % 3600) / 60 ))m"; fi; }
age=""
if [ -n "$measured_epoch" ]; then a=$(( NOW - measured_epoch )); [ "$a" -lt 0 ] && a=0; age="$(fmt_dur "$a") ago"; fi

if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson ok "$pick_ok" --argjson pct "$pct" --argjson h "$headroom" --argjson r "$RESERVE" \
        --arg resets "$resets_at" --argjson rin "$resets_in" --argjson reset "$window_reset" \
        --arg at "$measured_at" --arg src "$source" --arg w "$writer" \
        '{pick_ok: $ok, five_hour_pct: $pct, headroom: $h, reserve: $r, resets_at: (if $resets == "" then null else $resets end),
          resets_in: $rin, window_reset: $reset, measured_at: (if $at == "" then null else $at end), source: $src, writer: $w}'
else
  used="five_hour=${pct}% used"
  [ "$window_reset" = true ] && used="five_hour=${pct}% used before the window reset at $resets_at (counted as 0)"
  rest="resets=${resets_at:-unknown}  resets_in=${resets_in}s  source=${source}(${writer:-?})  measured=${measured_at:-unknown}${age:+ ($age)}"
  if [ "$pick_ok" = true ]; then
    echo "PICK-OK  $used  headroom=$headroom >= reserve=$RESERVE  $rest"
  else
    echo "THROTTLE $used  headroom=$headroom < reserve=$RESERVE  $rest — park with a wakeup until the reset instead of picking"
  fi
fi

[ "$pick_ok" = true ] && exit 0 || exit 2
