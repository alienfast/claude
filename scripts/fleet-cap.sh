#!/usr/bin/env bash
# fleet-cap.sh — how many /loop /auto sessions this machine's account pool sustains: the concurrency cap
# /auto-prep and /epic-prep recommend under and /fleet-launch prints and warns above.
#
# WHY: the 5-hour burst window is per account, and the measured bracket at opus/xhigh is 3 sessions per
# window — 3 run any duration without reliably exhausting it, 4 do not (n=4 cut off 4.9h into a 12h
# deadline). Every session on the machine burns on the ONE account the login names, so on a machine that
# rotates accounts through cswap (scripts/cswap-setup.sh) the engine moves the login at its threshold to
# an account with room, that window fills next, and the first resets 5h after its block began: the pool
# refills at (accounts with room) × one window's rate, and the cap is 3 × that count, bounded by
# fleet-launch.sh's count range. Until 2026-10-28 the single-account 3 was a constant in every skill and
# in the launch, so a keeper with five enrolled accounts overrode it by hand on every launch.
#
# "Room" is fleet-headroom.sh's own predicate, read through its --json `cswap` verdict (an `ok` figure
# under --stale old, the binding window under the engine's threshold, an engine event within 5 minutes),
# the active account included while it is under the threshold. No rotation, an idle engine, an
# unreadable cswap, or no account with room → 3, and the line says why. Weekly windows are not an input:
# rotation is the lever (skills/fleet-launch/SKILL.md § The count — 3 per account with room).
#
# Output: `CAP <n>  per_account=3  accounts_with_room=<k>/<total>  <why>`; --json for the fields.
# --now and --stale pass through to fleet-headroom.sh (test seams). Exit 0 always: the cap is advice.
# Run ./fleet-cap.test.sh after ANY change.

set -uo pipefail

PER_ACCOUNT=3
RANGE_MAX=12
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS_JSON=0
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)        AS_JSON=1; shift ;;
    --now|--stale) pass+=("$1" "${2:-}"); shift 2 ;;
    -h|--help)     sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; shift ;;
  esac
done

cswap=null
if command -v jq >/dev/null 2>&1; then
  probe=$("$here/fleet-headroom.sh" --json ${pass[@]+"${pass[@]}"} 2>/dev/null) || true
  cswap=$(printf '%s' "$probe" | jq -c '.cswap // null' 2>/dev/null) || cswap=null
  [ -n "$cswap" ] || cswap=null
fi

# The probe reads `cswap list` only with a live engine, so an idle or unreadable cswap leaves the enrolled total unknown: `?`.
rotating=false; state=none; note=""; total=1; total_json=1; k=1; room='[]'
if [ "$cswap" = null ]; then
  why="single-account machine: no cswap rotation (scripts/cswap-setup.sh is the opt-in), so one account's 5h window governs"
else
  rotating=true
  state=$(jq -r '.state // "unreadable"' <<<"$cswap")
  note=$(jq -r '.note // ""' <<<"$cswap")
  total=$(jq -r '.accounts // "?"' <<<"$cswap")
  total_json=$(jq -c '.accounts // null' <<<"$cswap")
  room=$(jq -c '.room // []' <<<"$cswap")
  case "$state" in
    engine-idle) why="cswap is enrolled but its engine is idle ($note): nothing moves the login, so one account's 5h window governs — /cswap log" ;;
    unreadable)  why="cswap is enrolled but unreadable ($note): one account's 5h window governs" ;;
    *)
      k=$(jq -r '.with_room // 1' <<<"$cswap")
      [[ "$k" =~ ^[0-9]+$ ]] || k=1
      threshold=$(jq -r '.threshold // "?"' <<<"$cswap")
      if [ "$k" -eq 0 ]; then
        k=1
        why="no account has room ($note): the window, not the count, is the constraint — launch after a reset, or the first picks park"
      else
        why="$k of $total enrolled accounts have room ($(jq -r 'join(", ")' <<<"$room")): the engine moves the login at threshold $threshold, so the pool refills at $k × one window"
      fi ;;
  esac
fi

cap=$(( PER_ACCOUNT * k ))
if [ "$cap" -gt "$RANGE_MAX" ]; then
  cap=$RANGE_MAX
  why="$why; bounded by fleet-launch.sh's count range of $RANGE_MAX"
fi

if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson cap "$cap" --argjson per "$PER_ACCOUNT" --argjson k "$k" --argjson total "$total_json" --argjson max "$RANGE_MAX" \
        --argjson rotating "$rotating" --arg state "$state" --arg note "$note" --arg why "$why" --argjson room "$room" \
        '{cap: $cap, per_account: $per, accounts_with_room: $k, accounts: $total, range_max: $max, rotating: $rotating,
          state: $state, note: $note, why: $why, room: $room}'
else
  echo "CAP $cap  per_account=$PER_ACCOUNT  accounts_with_room=$k/$total  $why"
fi
exit 0
