#!/bin/zsh
# wait-idle.sh — block until no fleet, /auto, or /fleet-sequence session is working in this repo and no deferred
# /finish merge is still queued; then print FLEET-IDLE.
#
#   wait-idle.sh [--once] [--poll <secs>] [--settle <polls>] [--max-minutes <n>]
#
# stdout is an event stream (one line per event, for Monitor):
#   BUSY: <signal>[; <signal>…]   printed when the busy set CHANGES (first poll included), never per poll
#   FLEET-IDLE: …                 the busy set stayed empty for --settle consecutive polls (default 2)
#   WAIT-TIMEOUT: …               --max-minutes elapsed (default 720)
#   REGISTRY-UNAVAILABLE: …       `claude agents --json` did not answer; liveness cannot be judged, so never idle
# Exit: 0 idle, 1 timeout, 2 registry unavailable, 3 busy (--once only).
#
# Busy signals — any one is enough. Liveness always comes from the session registry (`claude agents --json --all`,
# listed and not ended — a done|failed|stopped state, or the row `claude stop` leaves behind: state unchanged, the
# `status` and `pid` keys gone while some row in the registry carries `status`; measured 2026-10-04,
# ~/.claude/scripts/fleet-status.sh registry_row); a ledger's recorded pid is never consulted, because every session
# in a fleet embeds the shared fleet-root pid (~/.claude/scripts/fleet-status.sh, header).
#
# A FINISHED RUN OUTRANKS THE REGISTRY. A session whose ledger (tmp/auto-state-<id>.json) reads drained|halted ended its
# loop on purpose — that write is /auto Step 4's last act — and its registry row says nothing about it: the harness
# settles a `--bg` session only when its launch prompt's turn ends, so a loop's row keeps whatever the agent view last
# called it until hooks/auto-rewake.sh retires it. Measured 2026-10-04: all three sessions of a fleet drained at the
# deadline and sat listed `working` (two) and `blocked` (one) for hours, and this wait held the merge all morning on
# exactly that. So a finished session is dropped from every signal below and named on the line as "finished:" — the
# same ledger-first rule ~/.claude/scripts/fleet-sequence.sh waits by.
#   fleet-sequence            tmp/fleet-sequence.json status == running
#   fleet-session <id>        an id in tmp/fleet-deadline.json's fleet_sessions that is alive and not finished
#   auto-ledger <key>         a tmp/auto-state-*.json with status active whose filename key is alive — this is how
#                             an INTERACTIVE terminal running /loop /auto is seen; interactive rows count only here
#   background-session <name> a non-ended background session whose cwd is this repo or one of its worktrees AND
#                             whose id joins to an /auto ledger that is not finished, a fleet-deadline member that is
#                             not finished, or a worktree's stamped owner (autofleet_keys). One rooted here that joins
#                             to none of those is reported on the BUSY/FLEET-IDLE line as "not waiting on:" and does
#                             NOT gate — a code review or an /investigate in this repo is not a reason to hold a
#                             merge. The join is on id, never on the row's name: a registry row carries no work-type
#                             field, so name matching would drop genuine /auto sessions (a wrong "idle" merges under a
#                             live session's feet, where a wrong "busy" only delays). The residual is a session whose
#                             ledger is not yet written — a few seconds at startup, during which it is ignored; its
#                             worktree stamp and ledger both close that window once it is actually working. A
#                             worktree's stamped owner is waited on only through this join, never through the stamp's
#                             own liveness (wt_owner_alive): deleting a session in `claude agents` removes its job dir,
#                             after which that falls back to the stamped pid, which for a background session is the
#                             shared daemon's, so the owner reads alive until the daemon restarts (2026-10-17: a canceled
#                             /auto run's stamp held this wait for twenty minutes after the fleet drained, with no
#                             registry row behind it).
#   merge-queue <n>           markers under .claude/merge-queue/ — a deferred /finish merge that will still land
# This session (CLAUDE_CODE_SESSION_ID) is never counted.
#
# PRM_REGISTRY_JSON=<file> replaces the registry; PRM_MAIN_CHECKOUT=<dir> replaces the main-checkout resolution.
set -u

ONCE=0; POLL=60; SETTLE=2; MAXMIN=720
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --poll) shift; POLL=$1 ;;
    --settle) shift; SETTLE=$1 ;;
    --max-minutes) shift; MAXMIN=$1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "wait-idle.sh: unexpected argument: $1" >&2; exit 3 ;;
  esac
  shift
done

if [ -n "${PRM_MAIN_CHECKOUT:-}" ]; then
  MAIN=$PRM_MAIN_CHECKOUT
else
  MAIN=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1 && sub(/^worktree /,"") {print; exit}')
fi
[ -n "$MAIN" ] || { echo "wait-idle.sh: not inside a git repository" >&2; exit 3; }
SELF=${CLAUDE_CODE_SESSION_ID:-}

registry_json() {
  local j
  if [ -n "${PRM_REGISTRY_JSON:-}" ]; then j=$(cat "$PRM_REGISTRY_JSON" 2>/dev/null || true)
  else j=$(claude agents --json --all 2>/dev/null || true); fi
  print -r -- "$j" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  print -r -- "$j"
}
# <registry> <short id> → 0 when listed and not ended (header). The stopped-row test is taken only when some row in
# the same registry carries `status`, so a schema that drops the key entirely reads as live — a wrong "busy" only delays.
alive_key() {
  print -r -- "$1" | jq -e --arg k "$2" '
    any(.[]; has("status")) as $carries_status
    | map(select((.id // (.sessionId // "" | split("-")[0])) == $k))
    | length > 0
      and (((.[0].state // "running") | IN("done","failed","stopped")) | not)
      and (($carries_status and ((.[0] | has("status")) | not) and ((.[0] | has("pid")) | not)) | not)' >/dev/null 2>&1
}
# <short id> → 0 when this repo's ledger for the session records a finished run (header: a finished run outranks the registry)
ledger_finished() {
  local f="$MAIN/tmp/auto-state-$1.json" st
  [ -f "$f" ] || return 1
  st=$(jq -r '.status // empty' "$f" 2>/dev/null)
  case "$st" in drained|halted) return 0 ;; esac
  return 1
}
finished_keys() { # every ledger key whose run is finished, one per line
  local f key
  for f in "$MAIN"/tmp/auto-state-*.json(N); do
    key=${${f:t}#auto-state-}; key=${key%.json}
    ledger_finished "$key" && echo "$key"
  done
  return 0
}

# Session ids positively identified as fleet/auto work in this repo, one per line: an /auto ledger's filename key (its
# existence is what marks the session as /auto — an active-vs-finished test stays in busy_signals, and a finished one is
# left out here so its row joins to nothing), a fleet-deadline member, or a worktree's stamped owner. Identification is
# by id JOIN, never by matching the row's name: names are free text and a genuine /auto session routinely carries none
# of the words — measured, "bf-1914 preflight validation" contains neither "auto" nor "fleet", so a name filter would
# read it as foreign and merge under its feet.
autofleet_keys() {
  local f key wt
  for f in "$MAIN"/tmp/auto-state-*.json(N); do
    key=${${f:t}#auto-state-}; key=${key%.json}
    ledger_finished "$key" || echo "$key"
  done
  if [ -f "$MAIN/tmp/fleet-deadline.json" ]; then
    for key in $(jq -r '.fleet_sessions[]? // empty' "$MAIN/tmp/fleet-deadline.json" 2>/dev/null); do
      ledger_finished "$key" || echo "$key"
    done
  fi
  for wt in "$MAIN"/.claude/worktrees/*(N/); do
    git -C "$wt" config --worktree --get-all start.owner-session 2>/dev/null
  done
  return 0
}

# Prints the busy signals for one poll, one per line. Returns 2 when the registry cannot answer.
# Lines prefixed "#ignored " are NOT busy signals — they name in-repo background sessions this gate deliberately
# does not wait on; "#finished " lines name sessions whose ledger says their run is over. Both are for the caller to report.
busy_signals() {
  local reg f key n known fin
  reg=$(registry_json) || return 2
  known=$(autofleet_keys)
  fin=$(finished_keys)

  [ -f "$MAIN/tmp/fleet-sequence.json" ] \
    && [ "$(jq -r '.status // empty' "$MAIN/tmp/fleet-sequence.json" 2>/dev/null)" = "running" ] \
    && echo "fleet-sequence ($(jq -r '.current // "?"' "$MAIN/tmp/fleet-sequence.json"))"

  if [ -f "$MAIN/tmp/fleet-deadline.json" ]; then
    for key in $(jq -r '.fleet_sessions[]? // empty' "$MAIN/tmp/fleet-deadline.json" 2>/dev/null); do
      ledger_finished "$key" && continue
      alive_key "$reg" "$key" && echo "fleet-session $key"
    done
  fi

  for f in "$MAIN"/tmp/auto-state-*.json(N); do
    [ "$(jq -r '.status // empty' "$f" 2>/dev/null)" = "active" ] || continue
    key=${${f:t}#auto-state-}; key=${key%.json}
    alive_key "$reg" "$key" && echo "auto-ledger $key"
  done

  print -r -- "$reg" | jq -r --arg main "$MAIN" --arg self "$SELF" --arg known "$known" --arg fin "$fin" '
    ($known | split("\n") | map(select(length > 0))) as $ids
    | ($fin | split("\n") | map(select(length > 0))) as $finished
    | any(.[]; has("status")) as $carries_status
    | .[] | select(.kind == "background")
        | select((.sessionId // "") != $self)
        | select((.state // "running") | IN("done","failed","stopped") | not)
        | select(($carries_status and (has("status") | not) and (has("pid") | not)) | not)
        | select(((.cwd // "") == $main) or ((.cwd // "") | startswith($main + "/")))
        | . as $row
        | (($row.id // (($row.sessionId // "") | split("-")[0]))) as $k
        | (if ($finished | index($k)) then "#finished " elif ($ids | index($k)) then "" else "#ignored " end)
          + "background-session \($row.name // $row.id // $row.sessionId) (\($row.state // "running"), \($row.cwd))"' 2>/dev/null

  n=$(print -l -- "$MAIN"/.claude/merge-queue/*.json(N) | grep -c .)
  [ "$n" -gt 0 ] && echo "merge-queue $n"
  return 0
}

prev=""; quiet=0; polls=0
while true; do
  all=$(busy_signals); rc=$?
  if [ $rc -eq 2 ]; then
    echo "REGISTRY-UNAVAILABLE: claude agents --json did not answer — cannot judge session liveness; not idle"
    exit 2
  fi
  # Ignored and finished rows are reported, never gated on — so a merge is not held by a code review, a /investigate,
  # or any other background session that happens to be rooted here, nor by a session whose loop has ended and whose
  # registry row has not caught up. No `set -e`, so a no-match grep's exit 1 is harmless.
  cur=$(print -r -- "$all" | grep -v '^#')
  ignored=$(print -r -- "$all" | sed -n 's/^#ignored background-session //p' | paste -sd ';' - | sed 's/;/; /g')
  [ -n "$ignored" ] && ignored=" (not waiting on: $ignored)"
  finished=$(print -r -- "$all" | sed -n 's/^#finished background-session //p' | paste -sd ';' - | sed 's/;/; /g')
  [ -n "$finished" ] && ignored="$ignored (finished, ledger terminal: $finished)"
  if [ -n "$cur" ]; then
    quiet=0
    [ "$cur" != "$prev" ] && echo "BUSY: $(print -r -- "$cur" | paste -sd ';' - | sed 's/;/; /g')$ignored"
    prev=$cur
    [ $ONCE -eq 1 ] && exit 3
  else
    quiet=$((quiet+1)); prev=""
    if [ $ONCE -eq 1 ] || [ $quiet -ge $SETTLE ]; then
      echo "FLEET-IDLE: no fleet, /auto, or fleet-sequence session is working in $MAIN and the merge queue is empty$ignored"
      exit 0
    fi
  fi
  polls=$((polls+1))
  [ $((polls*POLL)) -ge $((MAXMIN*60)) ] && { echo "WAIT-TIMEOUT: still busy after ${MAXMIN}m — last: $(print -r -- "$cur" | paste -sd ';' -)"; exit 1; }
  sleep "$POLL"
done
