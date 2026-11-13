#!/usr/bin/env bash
# fleet-cap.sh — how many /loop /auto sessions this machine's account pool sustains: the concurrency cap
# /auto-prep and /epic-prep recommend under and /fleet-launch prints and warns above.
#
# WHY: every session on the machine burns on the ONE account the login names, and that account's windows are
# the limit. On a plan with a 5-hour burst window the measured bracket at opus/xhigh is 3 sessions per window —
# 3 run any duration without reliably exhausting it, 4 do not (n=4 cut off 4.9h into a 12h deadline) — so on
# a machine that rotates accounts through cswap (scripts/cswap-setup.sh), where the engine moves the login at its
# threshold to an account with room and that account's window gates next, the cap is 3 × (accounts with room),
# bounded by fleet-launch.sh's count range. Until 2026-10-28 the single-account 3 was a constant in every skill
# and in the launch, so a keeper with five enrolled accounts overrode it by hand on every launch.
#
# An account with no 5h window (Claude Ultra, since 2026-10-31: `five_hour` null, the weekly alone gates it) has
# no window a count can saturate, so the per-account factor is gone: the cap is the count range, bounded by the
# pool's weekly room for the duration when --hours is given. Burn is 0.55 weekly points per session-hour
# (the 2026-10-30 fleet: 62 points over 112 session-hours on one such account; FLEET_WEEKLY_BURN overrides), the
# room is the weekly points to the engine's threshold summed over the accounts with room (fleet-headroom.sh's
# `weekly_room`), or on a single-account machine the active account's points to the gate's weekly reserve. What
# bounds the count there is the machine and the backlog's lanes, which this script does not read: the retro's
# timeout-ceiling gauge (`ceil%` in its trend) and its Slowest calls are the evidence to lower it (under one twelve-hour
# load on 2026-10-31 sibling `pnpm check` medians tripled and 15% of runs hit the 600s Bash cap).
#
# "Room" is fleet-headroom.sh's own predicate, read through its --json `cswap` verdict (an `ok` figure
# under --stale old, the binding window — the higher of 5h and 7d, so the weekly alone on an account with no
# 5h window — under the engine's threshold, an engine event within 5 minutes), the active account included
# while it is under the threshold. No rotation, an idle engine, an unreadable cswap, or no account with room
# → one account's window, and the line says why. Weekly-only is the active account's own reading (the probe
# gates `seven_day`), or with no reading cswap's active row. The weekly window sizes neither n nor duration on
# a plan with a 5h window: rotation is the lever (skills/fleet-launch/SKILL.md § The count).
#
# Output: `CAP <n>  per_account=<3|machine>  accounts_with_room=<k>/<total>  <why>`; --json for the fields, the
# line included. --hours <h> is the fleet's duration (fleet-launch.sh passes its own); --now and --stale pass
# through to fleet-headroom.sh (test seams). Exit 0 always: the cap is advice.
# Run ./fleet-cap.test.sh after ANY change.

set -uo pipefail

PER_ACCOUNT=3
RANGE_MAX=12
WEEKLY_BURN="${FLEET_WEEKLY_BURN:-0.55}"
[[ "$WEEKLY_BURN" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "$(jq -rn --argjson b "$WEEKLY_BURN" '$b > 0' 2>/dev/null)" = true ] || WEEKLY_BURN=0.55
HOURS=""
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS_JSON=0
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)        AS_JSON=1; shift ;;
    --hours)       HOURS="${2:-}"; shift 2 ;;
    --now|--stale) pass+=("$1" "${2:-}"); shift 2 ;;
    -h|--help)     sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; shift ;;
  esac
done

[[ "$HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "$(jq -rn --argjson h "$HOURS" '$h > 0' 2>/dev/null)" = true ] || HOURS=""

cswap=null; probe=""
if command -v jq >/dev/null 2>&1; then
  probe=$("$here/fleet-headroom.sh" --json ${pass[@]+"${pass[@]}"} 2>/dev/null) || true
  cswap=$(printf '%s' "$probe" | jq -c '.cswap // null' 2>/dev/null) || cswap=null
  [ -n "$cswap" ] || cswap=null
fi
gated=$(printf '%s' "$probe" | jq -r '.gated // empty' 2>/dev/null) || gated=""
seven_pct=$(printf '%s' "$probe" | jq -r '.seven_day_pct // empty' 2>/dev/null) || seven_pct=""
weekly_reserve=$(printf '%s' "$probe" | jq -r '.weekly_reserve // 3' 2>/dev/null) || weekly_reserve=3
[[ "$weekly_reserve" =~ ^[0-9]+([.][0-9]+)?$ ]] || weekly_reserve=3

# The probe reads `cswap list` only with a live engine, so an idle or unreadable cswap leaves the enrolled total unknown: `?`.
rotating=false; state=none; note=""; total=1; total_json=1; k=1; room='[]'; threshold=""
if [ "$cswap" = null ]; then
  why="single-account machine: no cswap rotation (scripts/cswap-setup.sh is the opt-in), so one account's window governs"
else
  rotating=true
  state=$(jq -r '.state // "unreadable"' <<<"$cswap")
  note=$(jq -r '.note // ""' <<<"$cswap")
  total=$(jq -r '.accounts // "?"' <<<"$cswap")
  total_json=$(jq -c '.accounts // null' <<<"$cswap")
  room=$(jq -c '.room // []' <<<"$cswap")
  case "$state" in
    engine-idle) why="cswap is enrolled but its engine is idle ($note): nothing moves the login, so one account's window governs — /cswap log" ;;
    unreadable)  why="cswap is enrolled but unreadable ($note): one account's window governs" ;;
    *)
      k=$(jq -r '.with_room // 1' <<<"$cswap")
      [[ "$k" =~ ^[0-9]+$ ]] || k=1
      threshold=$(jq -r '.threshold // "?"' <<<"$cswap")
      if [ "$k" -eq 0 ]; then
        k=1
        why="no account has room ($note): the window, not the count, is the constraint — launch after a reset, or the first picks park"
      else
        why="$k of $total enrolled accounts have room ($(jq -r 'join(", ")' <<<"$room")): the engine moves the login at threshold $threshold, so the pool is $k accounts' windows"
      fi ;;
  esac
fi

# Weekly-only: the active account's own reading says so (the probe gates seven_day); with no reading, cswap's active row.
weekly_only=false
if [ "$gated" = seven_day ]; then
  weekly_only=true
elif [ -z "$gated" ] && [ "$cswap" != null ] && [ "$(jq -r '.active.weekly_only // false' <<<"$cswap")" = true ]; then
  weekly_only=true
fi

per_json=$PER_ACCOUNT; per_label=$PER_ACCOUNT
weekly_room=null; weekly_hours=null; hours_json=null
if [ "$weekly_only" = true ]; then
  per_json=null; per_label=machine
  cap=$RANGE_MAX
  pool_room=$(jq -r '.weekly_room // empty' <<<"$cswap" 2>/dev/null) || pool_room=""
  if [[ "$pool_room" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && [ "$state" != engine-idle ] && [ "$state" != unreadable ] && [ "$state" != none ]; then
    room_pts=$(jq -rn --argjson r "$pool_room" 'if $r < 0 then 0 else $r end')
    room_src="the pool's weekly room of ${room_pts} points to the engine's threshold across the accounts with room"
  elif [[ "$seven_pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    room_pts=$(jq -rn --argjson p "$seven_pct" --argjson r "$weekly_reserve" '(100 - $r - $p) | if . < 0 then 0 else . end')
    room_src="the active account's weekly room of ${room_pts} points to the gate's weekly reserve"
  else
    room_pts=""; room_src="weekly room unknown (no weekly reading)"
  fi
  clause="Weekly-only accounts (no five_hour window): no burst window to saturate, so the machine and the backlog's lanes bound the count, not the account"
  if [ -n "$room_pts" ]; then
    weekly_room=$room_pts
    weekly_hours=$(jq -rn --argjson r "$room_pts" --argjson b "$WEEKLY_BURN" '(($r / $b) * 10 | floor) / 10')
    clause="$clause — $room_src covers ~${weekly_hours} session-hours at $WEEKLY_BURN points per session-hour"
    if [ -n "$HOURS" ]; then
      hours_json=$HOURS
      fit=$(jq -rn --argjson r "$room_pts" --argjson b "$WEEKLY_BURN" --argjson h "$HOURS" '($r / ($b * $h)) | floor')
      [[ "$fit" =~ ^-?[0-9]+$ ]] || fit=$cap
      if [ "$fit" -lt 1 ]; then
        cap=1
        clause="$clause; ${HOURS}h at that rate fits no session for the full run — the first picks park at the weekly reset"
      elif [ "$fit" -lt "$cap" ]; then
        cap=$fit
        clause="$clause; ${HOURS}h at that rate fits $fit session$([ "$fit" -eq 1 ] || echo s), which bounds the cap"
      else
        clause="$clause; ${HOURS}h at that rate fits $fit sessions, so the count range of $RANGE_MAX bounds the cap"
      fi
    else
      clause="$clause; bounded by fleet-launch.sh's count range of $RANGE_MAX"
    fi
  else
    clause="$clause ($room_src); bounded by fleet-launch.sh's count range of $RANGE_MAX"
  fi
  why="$why. $clause"
else
  cap=$(( PER_ACCOUNT * k ))
  if [ "$cap" -gt "$RANGE_MAX" ]; then
    cap=$RANGE_MAX
    why="$why; bounded by fleet-launch.sh's count range of $RANGE_MAX"
  fi
fi

line="CAP $cap  per_account=$per_label  accounts_with_room=$k/$total  $why"
if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson cap "$cap" --argjson per "$per_json" --argjson k "$k" --argjson total "$total_json" --argjson max "$RANGE_MAX" \
        --argjson rotating "$rotating" --arg state "$state" --arg note "$note" --arg why "$why" --argjson room "$room" \
        --argjson wo "$weekly_only" --argjson wr "$weekly_room" --argjson wh "$weekly_hours" --argjson burn "$WEEKLY_BURN" \
        --argjson hours "$hours_json" --arg line "$line" \
        '{cap: $cap, per_account: $per, accounts_with_room: $k, accounts: $total, range_max: $max, rotating: $rotating,
          state: $state, note: $note, why: $why, room: $room, weekly_only: $wo, weekly_room: $wr,
          weekly_session_hours: $wh, burn_per_session_hour: $burn, hours: $hours, line: $line}'
else
  echo "$line"
fi
exit 0
