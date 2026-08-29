#!/bin/bash
# fleet-launch.sh — dispatch N background `/loop /auto` sessions into `claude agents`,
# staggered so each session's first pick sees the previous session's claim.
#
# Usage: fleet-launch.sh [count] [duration] [-- <claude flags...>]
#        fleet-launch.sh stop
#
#   [count]     Number of /loop /auto sessions to launch (1-12). Omitted → read the
#               recommendation /auto-prep persisted to tmp/fleet-recommendation.json
#               (error if absent — run /auto-prep first, or pass a count). An explicit
#               count is the quota throttle: auto-prep recommends from lane math alone.
#   [duration]  Optional fleet time budget — "10h", "10 hours", "90m", "45 minutes".
#               Adds deadline_epoch to tmp/fleet-deadline.json; each session's /auto
#               checks it before PICKING new work (never mid-issue), so at the deadline
#               every session finishes its in-flight issue and ends its loop cleanly
#               (NO-CANDIDATES: fleet deadline reached). Omitted → no deadline: the
#               loops run until the certified backlog drains.
#   -- ...      Everything after -- is passed to `claude --bg` verbatim. Defaults are
#               added only for flags not present there: --model 'opus[1m]'
#               --effort xhigh --autocompact 500000 --permission-mode auto
#               (skills/auto/SKILL.md's unattended-run prerequisites; auto — never
#               acceptEdits — because a background session has nobody to answer a
#               Bash permission prompt; autocompact capped because a session that
#               never compacts re-reads its whole accumulated context on every call).
#
#   stop        Wind down a running fleet: write an already-passed deadline and exit.
#               Every session ends its loop at its next iteration boundary; in-flight
#               issues run to completion. (To also abort in-flight work, use
#               `claude agents` and kill sessions individually — this script never does.)
#
# Stagger: after each dispatch, wait for a NEW directory to appear under
# <main-checkout>/.claude/worktrees/ — the signal that the session picked an issue and
# stamped its claim, which is exactly the state /auto Step 2's live-owner probe excludes
# from the next session's ranking (the Linear claim itself lands tens of seconds later).
# Name-diffed against a pre-dispatch snapshot, not counted, so a concurrent /finish
# removing a worktree can't mask the new one. Capped at FLEET_STAGGER_TIMEOUT (default
# 180s) — on timeout the next session launches anyway (the session may be in preflight,
# resuming an existing worktree, or the pool may have drained).
#
# Session set: the marker is written on EVERY launch and carries fleet_sessions — the short id
# each `claude --bg` prints (`backgrounded · <id>`, which is the session's ledger key) — so a
# fleet is a set of sessions, never a time window. A window admits every /auto run that touched
# the checkout: measured 2026-08-29, a bare --since read 21, then 11, then 26 sessions against
# real fleets of 3 and 5, because a targeted `/auto <ID>` run writes a ledger of the same shape.
# A top-up launch carries forward the members the session registry still lists, then appends.
#
# Run it from the project the fleet should work on; sessions inherit the cwd.
# Env: FLEET_PROMPT overrides the dispatched prompt (default "/loop /auto" — e.g.
# "/loop /auto BF" to team-scope the run); FLEET_STAGGER_TIMEOUT seconds per wait.
#
# Read-write: rewrites tmp/fleet-deadline.json in the main checkout; clears DEAD prior-run
# tmp/auto-state-*.json ledgers at launch — dead = absent from `claude agents --json` or
# listed as done there; they deliberately persist from a fleet's end until the next launch
# so /fleet-retro and the operator can examine them — retro before relaunching; dispatches
# background claude sessions. Exit 1 on
# argument/environment errors (never mid-fleet: a dispatch failure stops further
# launches but leaves prior sessions running).

set -eo pipefail

usage() {
  echo "usage: fleet-launch.sh [count] [duration e.g. '10h' or '10 hours'] [-- <claude flags...>] | fleet-launch.sh stop" >&2
  exit 1
}

for cmd in claude jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

# Session registry, fetched once. Whether a prior-run ledger's session still runs is answered here,
# keyed on the session's short id (= the ledger key), never by the ledger's recorded pid: under
# `claude agents` every session embeds the fleet-root pid, and in a daemon-backed fleet that is the
# daemon itself (pid 55032 on 2026-08-29, alive across every fleet since 2026-08-28) — the pid test
# read all 14 prior-run ledgers as alive, cleared none, and pulled launch_epoch back 5h19m to a
# targeted run's ledger. The registry also lists ENDED background sessions (state "done"), so listed
# is not alive. Empty when `claude agents` is unavailable, and then nothing is cleared.
agents_json=$(claude agents --json 2>/dev/null || true)
printf '%s' "$agents_json" | jq -e 'type == "array"' >/dev/null 2>&1 || agents_json=""
registry_alive() { # <run key> — true when the registry lists it (by id, or the sessionId prefix) and not as done
  [ -n "$agents_json" ] || return 1
  printf '%s' "$agents_json" | jq -e --arg k "$1" \
    'map(select(((.id // (.sessionId // "" | split("-")[0])) == $k) and ((.state // "running") != "done"))) | length > 0' \
    >/dev/null 2>&1
}

main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the project the fleet should work on" >&2; exit 1; }
mkdir -p "$main_checkout/tmp"
marker="$main_checkout/tmp/fleet-deadline.json"

if [ "${1:-}" = "stop" ]; then
  [ $# -eq 1 ] || usage
  now=$(date +%s)
  # Merge onto the existing marker: count and launch_epoch must survive a stop, or
  # /fleet-status loses its session scoping during the wind-down it most needs it for.
  existing=$(jq -c '.' "$marker" 2>/dev/null || echo '{}')
  printf '%s' "$existing" | jq --argjson epoch "$now" --arg human "$(date '+%Y-%m-%d %H:%M %Z')" \
    '. + {deadline_epoch: $epoch, deadline: $human, stopped: true}' > "$marker"
  echo "Fleet wind-down marker written: $marker"
  echo "Each session ends its loop at its next iteration boundary; in-flight issues run to completion."
  exit 0
fi

count=""
if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ $# -ge 1 ]; then
  count="$1"; shift
fi

dur_tokens=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do dur_tokens+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
claude_args=("$@")

if [ -z "$count" ]; then
  rec="$main_checkout/tmp/fleet-recommendation.json"
  if [ ! -f "$rec" ]; then
    echo "ERROR: no count given and no $rec — run /auto-prep first, or pass a count" >&2
    exit 1
  fi
  count=$(jq -r '.sessions // empty' "$rec" 2>/dev/null)
  [[ "$count" =~ ^[0-9]+$ ]] || { echo "ERROR: $rec has no numeric .sessions field" >&2; exit 1; }
  rec_epoch=$(jq -r '.generated_epoch // 0' "$rec" 2>/dev/null)
  age=$(( $(date +%s) - ${rec_epoch:-0} ))
  echo "Using /auto-prep's recommendation: $count session(s) ($rec)"
  if [ "$age" -gt 86400 ]; then
    echo "WARN: that recommendation is $((age / 3600))h old — the backlog has likely moved; consider re-running /auto-prep or passing a count" >&2
  fi
fi
{ [ "$count" -ge 1 ] && [ "$count" -le 12 ]; } 2>/dev/null || { echo "ERROR: count must be 1-12 (got '$count')" >&2; exit 1; }
[ "$count" -gt 3 ] && echo "WARN: >3 sessions reliably exhausts a 5h burst window at any duration (n=4 measured cut off 4.9h into a 12h deadline; auto-prep caps its recommendation at 3) — an explicit count is your override" >&2

deadline_epoch=""
deadline_human=""
if [ ${#dur_tokens[@]} -gt 0 ]; then
  dur=$(printf '%s' "${dur_tokens[*]}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  if [[ "$dur" =~ ^([0-9]+)(h|hr|hrs|hour|hours)$ ]]; then
    secs=$(( BASH_REMATCH[1] * 3600 ))
  elif [[ "$dur" =~ ^([0-9]+)(m|min|mins|minute|minutes)$ ]]; then
    secs=$(( BASH_REMATCH[1] * 60 ))
  else
    echo "ERROR: cannot parse duration '${dur_tokens[*]}' — use e.g. '10h', '10 hours', '90m', '45 minutes'" >&2
    exit 1
  fi
  deadline_epoch=$(( $(date +%s) + secs ))
  deadline_human=$(date -r "$deadline_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$deadline_epoch" '+%Y-%m-%d %H:%M %Z')
fi

# Preflight: /auto Step 1 halts on a dirty main checkout it cannot attribute to an in-progress
# issue, and every session re-discovers that independently — so one uncommitted file kills the
# whole fleet, N times over, in under two minutes each. Observed 2026-08-04: a 6-line
# .claude/rules/bash.md edit on a branch with no issue ID halted all three sessions of a launch
# (19:44/19:47/19:50), and only a human committing it at 19:56 saved the run. Check once, here,
# before anything is dispatched or the deadline marker is touched.
dirty=$(git -C "$main_checkout" status --porcelain 2>/dev/null || true)
if [ -n "$dirty" ]; then
  branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  if printf '%s' "$branch" | grep -qiE '[a-z]{2,}-[0-9]+'; then
    echo "WARN: main checkout is dirty on '$branch', which carries an issue ID — each session's /auto will" >&2
    echo "      try to attribute and finish that work before picking. Launching anyway." >&2
  else
    echo "ERROR: main checkout is dirty and the branch carries no issue ID — every session would halt at" >&2
    echo "       /auto's Step 1 preflight (AUTO-HALTED: dirty working tree ... not attributable)." >&2
    echo "       branch: ${branch:-(detached)}" >&2
    printf '%s\n' "$dirty" | sed 's/^/       /' >&2
    echo "       Commit or stash the above, then re-run. Nothing was dispatched." >&2
    exit 1
  fi
fi

# Prior-run ledgers (tmp/auto-state-*.json) deliberately persist after a fleet ends so the
# operator and /fleet-retro can examine them; a NEW launch is where they expire. Clear the
# dead ones now so /fleet-status shows only this fleet's sessions. A ledger whose session the
# registry still lists as running is kept; with no registry every ledger is kept. A kept LOOP
# ledger pulls launch_epoch back to its mtime so a top-up launch never hides a running
# sibling's ledger from /fleet-status, and its session is carried into fleet_sessions. A kept
# single-run ledger (`mode: single` — a targeted or one-shot /auto, skills/auto/SKILL.md
# Step 4) does neither: it is not a fleet member, and anchoring on one is exactly how a
# time-window scope came to admit 26 sessions.
launch_epoch=$(date +%s)
cleared=""
carried=""
for sf in "$main_checkout"/tmp/auto-state-*.json; do
  [ -f "$sf" ] || continue
  key=$(basename "$sf" | sed 's/auto-state-//;s/\.json//')
  if [ -z "$agents_json" ] || registry_alive "$key"; then
    [ "$(jq -r '.mode // "loop"' "$sf" 2>/dev/null)" = "single" ] && continue
    mt=$(stat -f %m "$sf" 2>/dev/null || stat -c %m "$sf" 2>/dev/null || echo "")
    [[ "$mt" =~ ^[0-9]+$ ]] && [ "$mt" -lt "$launch_epoch" ] && launch_epoch="$mt"
    [ -n "$agents_json" ] && carried="$carried $key"
  else
    rm -f "$sf"
    cleared="$cleared $key"
  fi
done
[ -n "$cleared" ] && echo "Cleared prior-run ledger(s):$cleared (not running per the registry; /fleet-retro can no longer measure those runs)"
[ -z "$agents_json" ] && echo "WARN: claude agents --json unavailable — no prior-run ledger cleared, and running siblings cannot be carried into fleet_sessions" >&2

# A member of the previous launch that the registry still lists is carried even without a ledger:
# a session still in preflight has not written one yet.
if [ -n "$agents_json" ] && [ -s "$marker" ]; then
  for k in $(jq -r '(.fleet_sessions // [])[]' "$marker" 2>/dev/null); do
    case " $carried " in *" $k "*) continue ;; esac
    registry_alive "$k" && carried="$carried $k"
  done
fi

# The marker is rewritten on every launch: a stale deadline from a previous fleet would end every
# new loop at its first pick, and the session set starts from the carried siblings and grows by
# one per dispatch below. Deadline fields only when this launch carries a duration.
carried_json=$(printf '%s\n' $carried | jq -R . | jq -s 'map(select(length > 0))')
jq -n --argjson count "$count" --argjson launch "$launch_epoch" --argjson carried "$carried_json" \
  '{count: $count, launch_epoch: $launch, fleet_sessions: $carried}' > "$marker"
if [ -n "$deadline_epoch" ]; then
  tmpm=$(jq --argjson epoch "$deadline_epoch" --arg human "$deadline_human" '. + {deadline_epoch: $epoch, deadline: $human}' "$marker")
  printf '%s\n' "$tmpm" > "$marker"
  echo "Fleet deadline: $deadline_human ($marker)"
fi

have_flag() {
  local f="$1"; shift
  local a
  for a in "$@"; do
    [[ "$a" == "$f" || "$a" == "$f="* ]] && return 0
  done
  return 1
}
have_flag --model "${claude_args[@]}" || claude_args+=(--model 'opus[1m]')
have_flag --effort "${claude_args[@]}" || claude_args+=(--effort xhigh)
# 500k, not the model default: on opus[1m] auto-compact's default threshold sits near the 1M
# window, so a /loop /auto session accumulating across iterations never compacts — measured
# 2026-08-13/14, 91% of fleet billable volume was context re-read at >200k tokens, and cache
# reads scale linearly with context size. /auto's real state lives in tmp/ + Linear, not context.
# Sizing (under-sized twice; measure before touching): compaction triggers at ~90% of the window,
# and the trigger must clear the DEEP-issue post-compact floor (~152-177k: re-injected overhead
# plus a summary carrying the issue) + the live working set a review/fix loop re-reads after
# every compact (>=110k) + one worst-case single ingestion (~130k). 150000 thrash-aborted the
# 2026-08-14 fleet at launch; 300000 survived launch but fell into a compaction orbit mid-review
# the same night (9 compacts in 36 min — the band matched the working set, so every compact
# forced re-reads that refilled it). Details: doc/compacting-investigation.md verdict log.
have_flag --autocompact "${claude_args[@]}" || claude_args+=(--autocompact 500000)
if ! have_flag --permission-mode "${claude_args[@]}" && ! have_flag --dangerously-skip-permissions "${claude_args[@]}"; then
  # auto, not acceptEdits: acceptEdits only auto-accepts FILE EDITS, so the first gated
  # Bash command (e.g. /start wt's worktree validation) prompts into a background session
  # where nobody answers, and the session stalls at its first pick. auto mode routes
  # those commands through the classifier instead.
  claude_args+=(--permission-mode auto)
fi

prompt="${FLEET_PROMPT:-/loop /auto}"
timeout="${FLEET_STAGGER_TIMEOUT:-180}"
wt_dir="$main_checkout/.claude/worktrees"
wt_names() { ls -1 "$wt_dir" 2>/dev/null || true; }

for (( i=1; i<=count; i++ )); do
  base=$(wt_names)
  echo "[$i/$count] dispatching: claude --bg ${claude_args[*]} '$prompt'"
  if ! out=$(claude --bg "${claude_args[@]}" "$prompt" 2>&1); then
    printf '%s\n' "$out"
    echo "ERROR: dispatch $i failed — stopping ($((i-1)) session(s) already launched and left running)" >&2
    exit 1
  fi
  printf '%s\n' "$out"
  # `claude --bg` prints `backgrounded · <id>` (the id ANSI-coloured) followed by attach/logs/stop
  # hints. That id is the sessionId's first segment — the <runKey> of tmp/auto-state-<runKey>.json.
  # Recorded per dispatch, not at the end, so a dispatch that fails mid-launch still leaves the set
  # of everything launched before it.
  plain=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g")
  sid=$(printf '%s\n' "$plain" | awk '/^backgrounded/ {print $NF; exit}')
  [[ "$sid" =~ ^[0-9a-f]{8}$ ]] || sid=$(printf '%s\n' "$plain" | awk '/claude attach/ {print $3; exit}')
  if [[ "$sid" =~ ^[0-9a-f]{8}$ ]]; then
    tmpm=$(jq --arg s "$sid" '.fleet_sessions = ((.fleet_sessions // []) + [$s] | unique)' "$marker")
    printf '%s\n' "$tmpm" > "$marker"
    echo "[$i/$count] session $sid recorded in fleet_sessions"
  else
    echo "[$i/$count] WARN: could not read the session id from the claude --bg output above — add it to fleet_sessions in $marker by hand from \`claude agents\`" >&2
  fi
  [ "$i" -eq "$count" ] && break
  new=""
  n=0
  until [ -n "$new" ] || [ "$n" -ge "$timeout" ]; do
    sleep 5; n=$((n+5))
    new=$(comm -13 <(printf '%s\n' "$base" | sort) <(wt_names | sort) | head -1)
  done
  if [ -n "$new" ]; then
    echo "[$i/$count] claim landed after ${n}s ($new)"
  else
    echo "[$i/$count] WARN: no new worktree after ${timeout}s — launching next anyway (session may be in preflight, resuming, or the pool may be drained)" >&2
  fi
done

echo "Launched $count session(s) — watch them with: claude agents"
echo "Fleet session set: $(jq -r '(.fleet_sessions // []) | join(" ")' "$marker") ($marker)"
[ -n "$deadline_human" ] && echo "Loops stop picking new work at $deadline_human; in-flight issues run to completion."
exit 0
