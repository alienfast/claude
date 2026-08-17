#!/usr/bin/env bash
# fleet-headroom.sh — may an /auto fleet session pick another issue right now, or would the pick
# saturate the account's 5-hour output window mid-issue?
#
# WHY: the 5h limit itself is cheap to hit (minutes of reset wait) — being killed MID-ISSUE by it is
# what's expensive: a mid-turn kill leaves no ScheduleWakeup pending and fires no Stop hook, so the
# session stays dead until a human attaches (2026-08-17 overnight fleet: 25.2 session-hours idle AFTER
# the reset, and 2 keeper-hours draining the half-done issues in the morning). A session that only ever
# meets the limit BETWEEN issues recovers itself: its parked wakeup fires after the reset. So /auto's
# fleet mode consults this probe at pick time and parks instead of picking when the window is nearly
# full. The account's burn IS measurable locally: every consumer of the account writes a transcript on
# this machine (verified 2026-08-16/17: non-fleet burn in the cutoff windows was zero), so a trailing-5h
# sum over ~/.claude/projects, deduped by requestId, is the account meter to within the subagent slack.
#
# CEILING: not queryable from any API — it is CALIBRATED from observed cutoffs. fleet-retro records each
# cutoff's trailing-5h output into ~/.claude/telemetry/five-hour-ceiling.json; this probe reads
# `ceiling_output_tokens` from there (default 1500000 — conservatively under the 1.57M/1.74M measured
# 2026-08-17). Ceilings are account-specific: after an account switch, expect the first overnight run to
# recalibrate (one cutoff observation), then update the file.
#
# Exit: 0 = pick OK (headroom >= reserve, or the probe errored — FAIL OPEN: a broken probe must not
# halt a healthy fleet; the stall watcher remains the backstop). 2 = THROTTLE (headroom < reserve).
# Run ./fleet-headroom.test.sh after ANY change.

set -uo pipefail

CEILING=""
RESERVE=250000
WINDOW_MIN=300
AS_JSON=0
PROJECTS_DIR="$HOME/.claude/projects"
CALIBRATION="$HOME/.claude/telemetry/five-hour-ceiling.json"
NOW=""   # test seam: fixed epoch clock

while [ $# -gt 0 ]; do
  case "$1" in
    --ceiling)      CEILING="$2"; shift 2 ;;
    --reserve)      RESERVE="$2"; shift 2 ;;
    --window-min)   WINDOW_MIN="$2"; shift 2 ;;
    --json)         AS_JSON=1; shift ;;
    --projects-dir) PROJECTS_DIR="$2"; shift 2 ;;
    --calibration)  CALIBRATION="$2"; shift 2 ;;
    --now)          NOW="$2"; shift 2 ;;
    -h|--help)      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 0 ;;   # fail open, never fail closed on usage
  esac
done

command -v jq >/dev/null 2>&1 || { echo "WARN: jq not found — failing open (pick OK)" >&2; exit 0; }
[ -n "$NOW" ] || NOW=$(date +%s)

ceiling_source="flag"
if [ -z "$CEILING" ]; then
  if [ -f "$CALIBRATION" ]; then
    CEILING=$(jq -r '.ceiling_output_tokens // empty' "$CALIBRATION" 2>/dev/null)
    ceiling_source="calibration"
  fi
fi
if ! [[ "${CEILING:-}" =~ ^[0-9]+$ ]]; then
  CEILING=1500000
  ceiling_source="default"
fi

cutoff_epoch=$(( NOW - WINDOW_MIN * 60 ))
# BSD date first (macOS), GNU second. Transcript timestamps are ISO-8601 UTC with millis; a same-shape
# prefix compares correctly as a string.
cutoff_iso=$(date -u -r "$cutoff_epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
[ -n "$cutoff_iso" ] || { echo "WARN: date conversion failed — failing open (pick OK)" >&2; exit 0; }

# Only files touched inside the window (plus slack) can hold in-window entries. -mmin is a cheap
# pre-filter; the jq timestamp select is the real boundary.
files=$(find "$PROJECTS_DIR" -name '*.jsonl' -type f -mmin "-$(( WINDOW_MIN + 10 ))" 2>/dev/null)

trailing=0
nfiles=0
if [ -n "$files" ]; then
  nfiles=$(printf '%s\n' "$files" | grep -c .)
  # Dedup by requestId across every transcript (a retried or subagent-mirrored entry counts once); an
  # entry with no requestId cannot be deduped and is summed as-is. Malformed lines are dropped by
  # `fromjson?`-style tolerance: jq -R + fromjson? never aborts the stream on one bad line.
  trailing=$(printf '%s\n' "$files" | while IFS= read -r f; do
    jq -Rr --arg cutoff "$cutoff_iso" '
      fromjson? | select(type == "object")
      | select((.timestamp // "") >= $cutoff)
      | .message.usage.output_tokens? as $out | select($out != null)
      | [(.requestId // "-"), ($out | tostring)] | @tsv' "$f" 2>/dev/null
  done | awk -F'\t' '{ if ($1 == "-" || !($1 in seen)) { sum += $2; seen[$1] = 1 } } END { print sum + 0 }')
fi
[[ "$trailing" =~ ^[0-9]+$ ]] || { echo "WARN: burn sum failed — failing open (pick OK)" >&2; exit 0; }

headroom=$(( CEILING - trailing ))
pick_ok=true
[ "$headroom" -lt "$RESERVE" ] && pick_ok=false

if [ "$AS_JSON" = "1" ]; then
  jq -n --argjson t "$trailing" --argjson c "$CEILING" --argjson r "$RESERVE" --argjson h "$headroom" \
        --argjson ok "$pick_ok" --arg src "$ceiling_source" --argjson n "$nfiles" \
        '{trailing_5h_output: $t, ceiling: $c, reserve: $r, headroom: $h, pick_ok: $ok, ceiling_source: $src, files_scanned: $n}'
else
  if [ "$pick_ok" = "true" ]; then
    echo "PICK-OK  trailing-5h=$trailing  ceiling=$CEILING($ceiling_source)  headroom=$headroom  reserve=$RESERVE"
  else
    echo "THROTTLE trailing-5h=$trailing  ceiling=$CEILING($ceiling_source)  headroom=$headroom < reserve=$RESERVE — park with a wakeup instead of picking"
  fi
fi

[ "$pick_ok" = "true" ] && exit 0 || exit 2
