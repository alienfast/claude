#!/usr/bin/env bash
# auto-stall-watch.sh — surface a /loop /auto background session that has gone silent mid-iteration.
#
# WHY: a Claude API quota cutoff can kill a turn in the middle of an /auto iteration. Nothing recovers
# from that, by construction:
#   - ScheduleWakeup is turn-ending by contract (skills/auto/SKILL.md "armed at turn end, never
#     mid-turn"), so an iteration in progress has NO wakeup pending to fire once the limit resets;
#   - a turn killed by an API error fires no Stop hook at all — verified on the 2026-08-14 fleet, where
#     the limit message is the last transcript entry with no stop_hook_summary after it — so
#     hooks/auto-heartbeat.sh, the guard for every other silent-loop-death shape, cannot see it.
# Measured that run: of three sessions cut off at 10:05 UTC against a 10:10 reset, the one with a wakeup
# already pending resumed at 10:17; the two without stayed dead 2h29m each until a human typed at them.
# 4.85 session-hours and ~2 issues, on a fleet whose deadline expired while they sat idle.
#
# WHY THIS ONLY ALERTS: there is no scriptable way to hand a prompt to a live background agent.
# `claude --resume <id>` is REFUSED for one ("currently running as a background agent"), `--fork-session`
# branches a COPY — which for /auto means a second loop sharing one run-state file and one worktree, worse
# than the stall — and `claude attach` needs a TTY. `claude logs` is read-only. So the recoverable half is
# detection: turning a silent multi-hour loss into an alert the operator can act on with one `claude attach`.
# If a scriptable send ever lands, resume belongs here behind an explicit opt-in flag, never as a default.
#
# SCOPING: an agent is in scope iff its cwd carries a matching /auto run-state file — NEVER by the agent
# list's `kind` field, and never by an `id` field. Measured 2026-08-17: the live `claude agents --json`
# rows carry NO `id` at all and report `kind:"interactive"` for every session, fleet agents included. The
# original version selected `kind=="background"` and joined state files on `.id`, so it matched nothing —
# 371 ticks, zero flags, through two real stalls (25.2 session-hours lost overnight on 2026-08-17 alone).
# The state-file join derives the runKey from the sessionId's first segment (auto-state-<prefix>.json),
# with the legacy `.id` and full-uuid forms kept as fallbacks.
#
# Exit 0 = ran (whether or not anything was flagged); 1 = a hard dependency is missing.
# Run ./auto-stall-watch.test.sh after ANY change to classify().

set -uo pipefail

THRESHOLD_MIN=25
NOTIFY=0
AS_JSON=0
AGENTS_JSON=""   # test seam: read the agent list from a file instead of shelling out to `claude`
NOW=""           # test seam: fixed clock

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold-min) THRESHOLD_MIN="$2"; shift 2 ;;
    --notify)        NOTIFY=1; shift ;;
    --json)          AS_JSON=1; shift ;;
    --agents-json)   AGENTS_JSON="$2"; shift 2 ;;
    --now)           NOW="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (PATH=$PATH)" >&2; exit 1; }
[ -n "$NOW" ] || NOW=$(date +%s)

PROJECTS_DIR="$HOME/.claude/projects"

# A background session's transcript can sit under the project dir for its cwd OR, once it has entered a
# worktree, under that worktree's dir. Search by session id rather than deriving one path from cwd.
find_transcript() {
  local sid="$1"
  find "$PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl" -type f 2>/dev/null | head -1
}

mtime_of() {
  # BSD stat (macOS) first, GNU second — this runs from launchd on macOS but the tests may not.
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Resolve the /auto run-state file for a background session. /auto names it after the runKey, which is
# the session-id prefix the harness also reports as the agent `id` — so the agent list joins to the
# ledger with no guessing. Older runs used the full uuid; try both.
state_file_for() {
  local cwd="$1" id="$2" sid="$3"
  for cand in "$cwd/tmp/auto-state-${sid%%-*}.json" "$cwd/tmp/auto-state-$id.json" "$cwd/tmp/auto-state-$sid.json"; do
    [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# classify <transcript> <state-file|""> <silence-seconds> <threshold-seconds>
#   -> "<verdict>\t<detail>"
# Verdicts: ok | terminal | stalled | stalled-quota
#
# ORDER MATTERS. A deliberately-ended loop goes quiet forever and that is its contract, so every terminal
# signal is checked BEFORE the silence threshold. The state file is authoritative when it carries a
# terminal status; the transcript tail is the fallback for a session that died before Step 4 could write
# one (which is exactly the shape this script exists to catch, so it must not be the only check).
classify() {
  local transcript="$1" state="$2" silence="$3" threshold="$4"
  local status="" tail_txt=""

  if [ -n "$state" ]; then
    status=$(jq -r '.status // ""' "$state" 2>/dev/null)
    case "$status" in
      drained|halted|stopped|completed)
        printf 'terminal\tstate=%s' "$status"; return 0 ;;
    esac
  fi

  # 200 lines covers the closing turn comfortably; reading the whole file is not viable at 15MB+.
  tail_txt=$(tail -200 "$transcript" 2>/dev/null)

  # An explicit loop-end. ScheduleWakeup(stop:true) and the two terminal tags each mean "no wakeup is
  # pending and that is intended" — the exact state that otherwise looks identical to a stall.
  if printf '%s' "$tail_txt" | grep -qE '"stop":[[:space:]]*true|NO-CANDIDATES|AUTO-HALTED'; then
    printf 'terminal\ttag'; return 0
  fi

  [ "$silence" -ge "$threshold" ] || { printf 'ok\t-'; return 0; }

  # A quota cutoff is the diagnosable case: name it separately so the operator knows the session is
  # waiting on nothing and will never self-resume, as against a merely slow turn.
  if printf '%s' "$tail_txt" | grep -qiE "hit your [a-z0-9 -]{0,20}limit"; then
    local resets
    resets=$(printf '%s' "$tail_txt" | grep -oiE "hit your [a-z0-9 -]{0,20}limit[^\"]{0,40}" | tail -1)
    printf 'stalled-quota\t%s' "${resets:-quota limit}"; return 0
  fi

  printf 'stalled\tno terminal tag, no wakeup evidence'
}

agents=""
if [ -n "$AGENTS_JSON" ]; then
  agents=$(cat "$AGENTS_JSON")
else
  command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found (PATH=$PATH)" >&2; exit 1; }
  agents=$(claude agents --json 2>/dev/null)
fi

rows=""
INSCOPE=0
while IFS=$'\t' read -r id sid cwd name; do
  [ -n "$sid" ] || continue
  [ -n "$id" ] || id="${sid%%-*}"
  transcript=$(find_transcript "$sid")
  [ -n "$transcript" ] || continue
  state=$(state_file_for "$cwd" "$id" "$sid") || state=""
  # No run-state file means this session is not an /auto run — out of scope. This presence test is the
  # ONLY scope filter: kind is ignored (see SCOPING in the header).
  [ -n "$state" ] || continue
  INSCOPE=$((INSCOPE + 1))

  mt=$(mtime_of "$transcript")
  [ -n "$mt" ] || continue
  silence=$(( NOW - mt ))
  result=$(classify "$transcript" "$state" "$silence" $(( THRESHOLD_MIN * 60 )))
  verdict=${result%%$'\t'*}
  detail=${result#*$'\t'}

  case "$verdict" in
    stalled|stalled-quota)
      rows="${rows}${id}"$'\t'"${verdict}"$'\t'"$(( silence / 60 ))"$'\t'"${detail}"$'\t'"${cwd}"$'\t'"${name}"$'\n' ;;
  esac
# The id fallback happens in jq, not the shell: tab is IFS whitespace, so an EMPTY leading @tsv column
# collapses and shifts every later field one left in `read` (id would silently become the sessionId).
done < <(printf '%s' "$agents" | jq -r '.[] | select(.sessionId) | [(.id // (.sessionId | split("-")[0])), .sessionId, .cwd, (.name // "-")] | @tsv' 2>/dev/null)

# The JSON shape is an OBJECT, not a bare array: `in_scope` is the blindness canary's input — it
# distinguishes "no /auto session is stalled" from "the watcher matched NOTHING", which print
# identically otherwise and did so through the 2026-08-17 schema-drift blindness (BF-1226). Consumers
# read `.stalled`; the cron wrapper reads both fields and its jq failure is an ERROR, never "0 flagged".
if [ "$AS_JSON" = "1" ]; then
  printf '%s' "$rows" | jq -Rs --argjson inscope "$INSCOPE" '{in_scope: $inscope,
    stalled: (split("\n") | map(select(length > 0) | split("\t"))
    | map({id: .[0], verdict: .[1], silent_min: (.[2] | tonumber), detail: .[3], cwd: .[4], name: .[5]}))}'
  exit 0
fi

if [ -z "$rows" ]; then
  echo "no stalled /auto sessions (threshold ${THRESHOLD_MIN}m, ${INSCOPE} in scope)"
  exit 0
fi

printf '%s' "$rows" | while IFS=$'\t' read -r id verdict mins detail cwd name; do
  echo "STALLED  $id  ${mins}m silent  [$verdict]  $detail"
  echo "         cwd: $cwd"
  echo "         resume with: claude attach ${name:-$id}"
done

if [ "$NOTIFY" = "1" ] && command -v osascript >/dev/null 2>&1; then
  count=$(printf '%s' "$rows" | grep -c . )
  ids=$(printf '%s' "$rows" | cut -f1 | tr '\n' ' ')
  osascript -e "display notification \"${count} session(s) silent: ${ids}— claude attach <id>\" with title \"/auto fleet stalled\"" >/dev/null 2>&1 || true
fi
