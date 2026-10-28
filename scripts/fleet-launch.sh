#!/bin/bash
# fleet-launch.sh — dispatch N background `/loop /auto` sessions into `claude agents`,
# staggered so each session's first pick sees the previous session's claim.
#
# Usage: fleet-launch.sh [count] [duration] [epic:<ID>] [backlog] [stale-ok] [-- <claude flags...>]
#        fleet-launch.sh stop [epic:<ID> | team]
#
#   Every fleet is keyed by a SLUG — the lowercased epic id of an epic-scoped launch, `team` for a bare one — and owns
#   its files under <main-checkout>/tmp/ (lib/fleet-markers.sh): the marker fleet-deadline-<slug>.json this script
#   writes and the recommendation fleet-recommendation-<slug>.json the prep wrote. Fleets of different slugs run side by
#   side in one checkout; a launch of a slug whose fleet is still running is a top-up of that fleet; nothing here touches
#   another fleet's marker, deadline or sessions. Until 2026-10-28 one marker and one recommendation served the whole
#   checkout, so a second epic could not launch while any fleet ran (the launch rewrote the marker the running sessions
#   read) and /epic-prep overwrote the running fleet's sizing before its retro could compare against it.
#
#   [count]     Number of /loop /auto sessions to launch (1-12). Omitted → read the slug's recommendation
#               (tmp/fleet-recommendation-team.json from /auto-prep, tmp/fleet-recommendation-<epic>.json
#               from /epic-prep <ID>; error if absent — run the prep, or pass a count). An explicit
#               count is the quota throttle: the preps recommend from lane math under the
#               concurrency cap fleet-cap.sh computes (3 per account with room: 3 on a
#               single-account machine, 3 × the accounts with room on a cswap-rotating one,
#               at most 12), which this script prints and WARNs above — counting the live sessions
#               of every other fleet in the checkout — never refuses on.
#   [epic:<ID>] Scope the fleet to one epic's graph: every session runs `/loop /auto epic:<ID> backlog`
#               (next-candidates.sh --root — the epic, its descendants, and their blockers, and
#               nothing else). The scope implies the Backlog fallback (keeper ruling 2026-10-23):
#               completing the epic is the goal, so a member deferred to Backlog is picked once
#               nothing Planned/Todo in the scope is pickable — the epic's own members, never the
#               team's Backlog. The slug's recommendation must carry this scope, and a bare launch
#               reads only the team recommendation, so no launch inherits a scope it did not type
#               (until 2026-09-29 a shared file's scope launched silently: a bare launch four days
#               after an /epic-prep inherited BF-1826 unnoticed, drained its two workable members and
#               ended while the team pool had work).
#               Validated fail-closed through epic-graph.sh before anything is dispatched or
#               written: a missing issue or one without the `epic` label refuses the launch — a
#               fleet scoped to a bad epic would latch drained against an empty pool.
#               Two running fleets whose graphs share an issue (a common blocker) compete for it the
#               way siblings do: the first picker claims it, and auto-fork-key.sh lands it on the
#               branch of the epic fleet it belongs to even when a team session picked it (keeper
#               decision 2026-10-28: first one wins; nothing is hidden or refused).
#
#               Release shape (keeper decision 2026-09-11): an epic ships as ONE PR from an
#               integration branch the fleet merges into as it goes. /epic-prep creates that
#               branch from the same source /start wt would resolve (start.wt-source-branch, else
#               the checkout's branch) and records `branch` + `base` in the recommendation; when
#               the recommendation's scope is the one launching, this script verifies the branch
#               and records both in the marker. The main checkout is NEVER moved (keeper ruling
#               2026-09-23): each session's /auto points the per-issue start.<id>.wt-source-branch
#               key at the marker's branch just before dispatching an issue (auto-fork-key.sh — the
#               same key /fleet-sequence's runner uses), start-wt-setup.sh resolves that key ahead
#               of the checkout's own branch, and start-wt-create.sh forks from the branch's ref —
#               so every fleet pick forks from and merges (ref-only) into the branch while the human
#               keeps working on whatever branch the checkout is on, and their own /start wt for
#               any issue still forks from that branch. Until 2026-09-23 this script instead
#               detached the checkout at the branch and set the checkout-wide key: that posture
#               took the checkout away from its human for the fleet's duration and steered their
#               interactive /start wt onto the epic branch too. After the fleet: open the epic's
#               PR from `branch` onto `base` with epic-pr.sh (it resolves the roster and runs
#               integration-pr.sh); /pr-update on the PR by number writes the description.
#               A token with no matching prepared
#               branch launches on the checkout's own branch with a WARN — the human typed it.
#   [backlog]   Let every session fall through to Backlog once nothing Planned/Todo is pickable
#               (keeper ruling 2026-10-01; implied by epic:<ID>): the dispatched prompt gains ` backlog`, so each pick runs
#               next-candidates.sh --backlog-fallback instead of idling on PLANNED-HOLD. Planned/Todo
#               stays strictly first at every pick. The opt-in for a day with spare usage — the
#               default stays the gate (standards/linear-workflow.md § Stage Priorities), and /auto's
#               headroom gate still parks near the 5h ceiling, so this changes the spending policy
#               only. Recorded as `backlog: true` in the marker for /fleet-status and /fleet-retro.
#               A session's mode is fixed at launch; a top-up launch with the token adds fallback
#               sessions beside holding ones. Composes with epic:<ID> and team.
#   [stale-ok]  Launch even though ~/.claude is behind origin/main in a file sessions load (TOOLING-STALE,
#               claude-freshness.sh), with a one-line WARN. Without it that state refuses the launch, exit 4: every
#               session would run the stale hooks, skills and scripts for the fleet's whole duration.
#   [duration]  Optional fleet time budget — "10h", "10 hours", "90m", "45 minutes".
#               Adds deadline_epoch to the slug's marker; each session's /auto
#               checks it before PICKING new work (never mid-issue), so at the deadline
#               every session finishes its in-flight issue and ends its loop cleanly
#               (NO-CANDIDATES: fleet deadline reached). Omitted → no deadline: the
#               loops run until the certified backlog drains.
#   -- ...      Everything after -- is passed to `claude --bg` verbatim. Defaults are
#               added only for flags not present there: --model 'opus[1m]'
#               --effort xhigh --permission-mode auto (skills/auto/SKILL.md's
#               unattended-run prerequisites; auto — never acceptEdits — because a
#               background session has nobody to answer a Bash permission prompt). No
#               --autocompact: mods/loop-boundary compacts each session at its iteration
#               boundaries, and the launch refuses (exit 5) where that mod is not enabled
#               unless an explicit --autocompact after -- supplies a cap of its own.
#
#   stop [epic:<ID> | team]
#               Wind down a running fleet: write an already-passed deadline onto its marker and exit —
#               unless the marker's deadline has already passed, which is left unchanged (a stop never
#               moves a deadline later; fleet-metrics reads it as the fleet's real end). The token names
#               the fleet; with exactly one fleet running it may be omitted, and with several the stop
#               lists them and asks. No marker → nothing to stop, exit 1 (until 2026-10-28 a stop with no
#               marker wrote one, which then gated every later solo /auto in the checkout).
#               Every session ends its loop at its next iteration boundary; in-flight
#               issues run to completion. (To also abort in-flight work, use
#               `claude agents` and kill sessions individually — this script never does.)
#
# Stagger: after each dispatch, wait for a NEW directory under <main-checkout>/.claude/worktrees/
# whose identity sidecar names the dispatched session as owner — the signal that the session
# picked an issue and stamped its claim, which is exactly the state /auto Step 2's live-owner
# probe excludes from the next session's ranking (the Linear claim itself lands tens of seconds
# later). Name-diffed against a pre-dispatch snapshot, not counted, so a concurrent /finish
# removing a worktree can't mask the new one; owner-matched so a worktree another fleet's session
# creates meanwhile is not read as this session's claim (a sidecar naming another owner is skipped;
# one not yet written counts). Capped at FLEET_STAGGER_TIMEOUT (default 180s) — on timeout the next
# session launches anyway (the session may be in preflight, resuming an existing worktree, or the
# pool may have drained).
#
# Session set: the marker is written on EVERY launch and carries fleet_sessions — the short id
# each `claude --bg` prints (`backgrounded · <id>`, which is the session's ledger key) — so a
# fleet is a set of sessions, never a time window. A window admits every /auto run that touched
# the checkout: measured 2026-08-29, a bare --since read 21, then 11, then 26 sessions against
# real fleets of 3 and 5, because a targeted `/auto <ID>` run writes a ledger of the same shape.
# A top-up launch keeps every member the slug's marker already lists (a session that died
# mid-fleet stays measurable), carries the ones the registry still runs, then appends.
#
# Expiry (keeper decision 2026-10-28): a launch never discards a fleet /fleet-retro has not
# measured. Every marker in tmp/ is checked: a fleet with a live session is left alone; an ended
# one the history names (tmp/fleet-metrics-history.jsonl has a row sharing a session with its
# fleet_sessions) is expired — marker and the ledgers only it names deleted; an ended one the
# history does not name is kept and listed. The slug's own marker, when its fleet has ended
# (deadline passed, stopped, or no live session), is archived as
# fleet-deadline-<slug>.<launch_epoch>.json instead of rewritten, so the retro can still choose it
# (fleet-metrics.py --list-fleets); its still-running sessions are carried as retiring. Ledgers no
# remaining marker names (a targeted run's, a pre-2026-10-28 fleet's) expire when their session is
# dead, as before. Until 2026-10-28 a launch deleted every dead ledger, so a fleet had to be
# retro'd before the next launch or its measurement was gone.
#
# Run it from the project the fleet should work on; sessions inherit the cwd.
# Env: FLEET_PROMPT overrides the dispatched prompt (default "/loop /auto", plus " epic:<ID>"
# when scoped and " backlog" under the token — e.g. "/loop /auto BF" to team-scope the run; an
# override that drops a launch's scope is warned about, never corrected);
# FLEET_STAGGER_TIMEOUT seconds per wait.
#
# Read-write: writes tmp/fleet-deadline-<slug>.json in the main checkout (`scope`, `members`,
# `branch`, `base` added on a scoped launch; `backlog: true` under the token), archives or expires
# ended markers and expires dead unlisted ledgers as above; never moves the main checkout's HEAD
# and never writes start.wt-source-branch; dispatches background claude sessions. Exit 1 on
# argument/environment errors, exit 4 on TOOLING-STALE (see [stale-ok]) and exit 5 on
# BOUNDARY-MOD-MISSING (the loop-boundary mod is not enabled and no explicit --autocompact was
# given) — all before any dispatch or write; never mid-fleet: a dispatch failure stops further
# launches but leaves prior sessions running.

set -eo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fleet-launch.sh [count] [duration e.g. '10h' or '10 hours'] [epic:<ID>] [backlog] [stale-ok] [-- <claude flags...>] | fleet-launch.sh stop [epic:<ID> | team]" >&2
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
# targeted run's ledger. The registry also lists ENDED background sessions, so listed is not alive:
# a done/failed/stopped state, or the row `claude stop` leaves behind — state unchanged, `status` and
# `pid` both gone (fleet-status.sh registry_row has the measurements; the test is the same here).
# Empty when `claude agents` is unavailable, and then nothing is cleared.
agents_json=$(claude agents --json 2>/dev/null || true)
printf '%s' "$agents_json" | jq -e 'type == "array"' >/dev/null 2>&1 || agents_json=""
registry_alive() { # <run key> — true when the registry lists it (by id, or the sessionId prefix) and not as ended
  [ -n "$agents_json" ] || return 1
  printf '%s' "$agents_json" | jq -e --arg k "$1" '
    any(.[]; has("status")) as $carries_status
    | map(select((.id // (.sessionId // "" | split("-")[0])) == $k))
    | map(select((((.state // "running") | IN("done","failed","stopped")) | not)
                 and (($carries_status and (has("status") | not) and (has("pid") | not)) | not)))
    | length > 0' >/dev/null 2>&1
}

main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the project the fleet should work on" >&2; exit 1; }
mkdir -p "$main_checkout/tmp"
. "$script_dir/../lib/fleet-markers.sh"
history_file="$main_checkout/tmp/fleet-metrics-history.jsonl"

if [ "${1:-}" = "stop" ]; then
  shift
  [ $# -le 1 ] || usage
  stop_slug=""
  case "${1:-}" in
    "") ;;
    [Ee][Pp][Ii][Cc]:*)
      stop_slug=$(fleet_slug "${1#*:}")
      [[ "$stop_slug" =~ ^[a-z0-9]+-[0-9]+$ ]] || { echo "ERROR: epic token '$1' does not name an issue (epic:BF-123)" >&2; exit 1; } ;;
    [Tt][Ee][Aa][Mm]) stop_slug=team ;;
    *) usage ;;
  esac
  # The token names the fleet. Without one, the single running fleet is the obvious target; a wound-down fleet is still
  # a target when it is the only marker (the message below then says nothing changed); several of either are asked about.
  n_live=0; n_running=0; running=""; live=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n_live=$((n_live + 1)); live="$live"$'\n'"$f"
    if fleet_marker_running "$f"; then n_running=$((n_running + 1)); running="$running"$'\n'"$f"; fi
  done < <(fleet_live_markers "$main_checkout")
  list_tokens() { # <newline list of markers> — one `stop <token>` line each, on stderr
    local f; while IFS= read -r f; do [ -n "$f" ] && echo "  fleet-launch.sh stop $(fleet_marker_token "$f")    ($f)" >&2; done <<<"$1"
  }
  if [ -n "$stop_slug" ]; then
    marker=$(fleet_marker_path "$main_checkout" "$stop_slug")
    if ! [ -s "$marker" ]; then
      echo "ERROR: no fleet marker for $1 ($marker) — nothing to stop." >&2
      [ "$n_live" -gt 0 ] && { echo "Fleets with a marker here:" >&2; list_tokens "$live"; }
      exit 1
    fi
  elif [ "$n_running" -eq 1 ]; then marker=${running#$'\n'}
  elif [ "$n_running" -gt 1 ]; then
    echo "ERROR: $n_running fleets are running in $main_checkout — name the one to stop:" >&2; list_tokens "$running"; exit 1
  elif [ "$n_live" -eq 1 ]; then marker=${live#$'\n'}
  elif [ "$n_live" -eq 0 ]; then
    echo "No fleet marker in $main_checkout/tmp — nothing to stop." >&2; exit 1
  else
    echo "ERROR: no fleet is running; $n_live wound-down markers remain — name one to re-stop it:" >&2; list_tokens "$live"; exit 1
  fi
  now=$(date +%s)
  # Merge onto the existing marker: count and launch_epoch must survive a stop, or
  # /fleet-status loses its session scoping during the wind-down it most needs it for.
  existing=$(jq -c '.' "$marker" 2>/dev/null || echo '{}')
  # A stop never moves a deadline later: a fleet already past its own deadline is winding down by itself, and rewriting
  # the deadline to now stretches fleet-metrics' idle tail, stall clipping and early-drain horizon by the gap.
  prior=$(printf '%s' "$existing" | jq -r '.deadline_epoch // empty')
  if [[ "$prior" =~ ^[0-9]+$ ]] && [ "$prior" -le "$now" ]; then
    echo "Fleet deadline already passed ($(printf '%s' "$existing" | jq -r '.deadline // .deadline_epoch')) — marker left unchanged."
    echo "Sessions still mid-issue finish it and end at their next pick boundary; nothing more to do."
    exit 0
  fi
  printf '%s' "$existing" | jq --argjson epoch "$now" --arg human "$(date '+%Y-%m-%d %H:%M %Z')" \
    '. + {deadline_epoch: $epoch, deadline: $human, stopped: true}' > "$marker"
  echo "Fleet wind-down marker written: $marker ($(fleet_marker_token "$marker"))"
  echo "Each session ends its loop at its next iteration boundary; in-flight issues run to completion."
  exit 0
fi

count=""
if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ $# -ge 1 ]; then
  count="$1"; shift
fi

dur_tokens=()
scope_token=""
backlog_token=0
stale_ok=0
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
    [Ee][Pp][Ii][Cc]:*)
      [ -z "$scope_token" ] || { echo "ERROR: at most one epic:<ID> token (got '$scope_token' and '$1')" >&2; exit 1; }
      scope_token=$(printf '%s' "${1#*:}" | tr '[:lower:]' '[:upper:]')
      [[ "$scope_token" =~ ^[A-Z0-9]+-[0-9]+$ ]] || { echo "ERROR: epic token '$1' does not name an issue (epic:BF-123)" >&2; exit 1; } ;;
    [Bb][Aa][Cc][Kk][Ll][Oo][Gg]) backlog_token=1 ;;
    [Ss][Tt][Aa][Ll][Ee]-[Oo][Kk]) stale_ok=1 ;;
    *) dur_tokens+=("$1") ;;
  esac
  shift
done
[ "${1:-}" = "--" ] && shift
claude_args=("$@")

slug=$(fleet_slug "$scope_token")
marker=$(fleet_marker_path "$main_checkout" "$slug")
rec=$(fleet_rec_path "$main_checkout" "$slug")
prep_cmd="/auto-prep"; [ -n "$scope_token" ] && prep_cmd="/epic-prep $scope_token"
count_from_rec=0
if [ -z "$count" ]; then
  count_from_rec=1
  if [ ! -f "$rec" ]; then
    echo "ERROR: no count given and no $rec — run $prep_cmd first, or pass a count" >&2
    exit 1
  fi
  count=$(jq -r '.sessions // empty' "$rec" 2>/dev/null)
  [[ "$count" =~ ^[0-9]+$ ]] || { echo "ERROR: $rec has no numeric .sessions field" >&2; exit 1; }
  # floor: a writer using a fractional clock (python's time.time()) makes bash arithmetic abort the rest of this block.
  rec_epoch=$(jq -r '.generated_epoch // 0 | floor' "$rec" 2>/dev/null)
  age=$(( $(date +%s) - ${rec_epoch:-0} ))
  echo "Using $prep_cmd's recommendation: $count session(s) ($rec)"
  if [ "$age" -gt 86400 ]; then
    echo "WARN: that recommendation is $((age / 3600))h old — the backlog has likely moved; consider re-running $prep_cmd or passing a count" >&2
  fi
fi
# A recommendation is read only by the slug it was written for: one carrying another scope was moved or renamed by hand.
if [ -f "$rec" ]; then
  rec_scope=$(jq -r '.scope // empty' "$rec" 2>/dev/null || true)
  if [ "$rec_scope" != "$scope_token" ]; then
    echo "ERROR: $rec carries scope '${rec_scope:-none}' but this launch is ${scope_token:+epic $scope_token}${scope_token:-team-wide} — the file was written for another fleet; re-run $prep_cmd, or remove it and pass a count" >&2
    exit 1
  fi
fi
{ [ "$count" -ge 1 ] && [ "$count" -le 12 ]; } 2>/dev/null || { echo "ERROR: count must be 1-12 (got '$count')" >&2; exit 1; }
# The concurrency cap: 3 per account with room — fleet-cap.sh owns the arithmetic and the reason (skills/fleet-launch/SKILL.md
# § The count — 3 per account with room). Advice, never a refusal: an explicit count is the user's override.
cap_line=$("$script_dir/fleet-cap.sh" 2>/dev/null) || cap_line=""
concurrency_cap=$(printf '%s' "$cap_line" | awk '/^CAP /{print $2}')
[[ "$concurrency_cap" =~ ^[0-9]+$ ]] || { concurrency_cap=3; cap_line="CAP 3  (fleet-cap.sh gave no answer — the single-account figure)"; }
echo "Concurrency cap: ${cap_line#CAP }"
[ "$count" -gt "$concurrency_cap" ] && echo "WARN: $count sessions is over the cap of $concurrency_cap — more than the account pool's 5h windows refill for at any duration (3 per account with room; n=4 on one account measured cut off 4.9h into a 12h deadline). The preps recommend under the cap; an explicit count is your override" >&2

# ---- epic scope: the typed token, with the slug's recommendation supplying the prep snapshot; validated before anything is written ----
scope="$scope_token"
scope_members='[]'
scope_branch=""
scope_base=""
checkout_branch=""
[ -n "$scope" ] && [ -f "$rec" ] && echo "Using /epic-prep's recommendation for epic $scope ($rec)"
# The scope implies the fallback (next-candidates.sh --root opens it on its own); carrying the token makes the prompt, the
# marker and every session's ledger record the mode the sessions actually run in.
[ -n "$scope" ] && backlog_token=1
if [ -n "$scope" ]; then
  graph=$("$script_dir/epic-graph.sh" "$scope" 2>"$main_checkout/tmp/fleet-launch-scope.err") || {
    cat "$main_checkout/tmp/fleet-launch-scope.err" >&2
    echo "ERROR: epic scope '$scope' did not validate — nothing was dispatched (a fleet scoped to a bad epic would latch drained against an empty pool)" >&2
    exit 1
  }
  rm -f "$main_checkout/tmp/fleet-launch-scope.err"
  # The prep-time membership is the burn-down baseline (/fleet-status reports members added since
  # prep); a token with no prep snapshots the graph as launched.
  if [ -f "$rec" ]; then
    scope_members=$(jq -c '.members // []' "$rec" 2>/dev/null || echo '[]')
    [ "$(printf '%s' "$scope_members" | jq 'length')" -gt 0 ] || scope_members=$(printf '%s' "$graph" | jq -c '[.members[].identifier]')
    scope_branch=$(jq -r '.branch // empty' "$rec" 2>/dev/null || true)
    scope_base=$(jq -r '.base // empty' "$rec" 2>/dev/null || true)
  else
    scope_members=$(printf '%s' "$graph" | jq -c '[.members[].identifier]')
  fi
  echo "Scope: epic $scope — $(printf '%s' "$graph" | jq -r '"\(.members | length) non-terminal member(s) across \(.teams | join(", "))"')"
  if [ -n "$scope_branch" ]; then
    git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$scope_branch" >/dev/null \
      || { echo "ERROR: the recommendation names integration branch '$scope_branch' but no such local branch exists — re-run /epic-prep $scope" >&2; exit 1; }
    cur_src=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
    if [ -n "$cur_src" ] && [ "$cur_src" != "$scope_branch" ]; then
      echo "ERROR: start.wt-source-branch is '$cur_src' but this launch's integration branch is '$scope_branch' — a parked-checkout posture for another branch is in effect; unset it (git config --unset start.wt-source-branch) or finish that work first" >&2
      exit 1
    elif [ -n "$cur_src" ]; then
      echo "NOTE: start.wt-source-branch=$cur_src is set (the retired parked-checkout posture) — harmless, it is read only under a detached HEAD; unset it once the checkout is on a branch" >&2
    fi
    checkout_branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
    if [ "$checkout_branch" = "$scope_branch" ]; then
      echo "WARN: the main checkout is ON the integration branch '$scope_branch' — every /finish merge will fast-forward its working tree instead of advancing the ref alone (and defer to the merge queue while it is dirty); check out ${scope_base:-another branch} to keep it out of the fleet's way" >&2
    fi
    echo "Integration branch: $scope_branch (forked from ${scope_base:-?}; the epic ships as one PR onto it — sessions steer onto it with per-issue fork keys; the main checkout is not moved)"
  else
    echo "WARN: no integration branch recorded for epic $scope — sessions fork from and merge into the checkout's own branch ($(git -C "$main_checkout" branch --show-current 2>/dev/null || echo detached)); run /epic-prep $scope to prepare one" >&2
  fi
fi

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

# Preflight: a dirty main checkout no longer stops the fleet — /auto Step 1 picks past dirt it cannot attribute, and
# finish-merge.sh fast-forwards around it — but any merge that changes one of those paths defers to the queue until they are
# committed or discarded. Name them once, here, so the operator can clear them before the fleet reaches them.
dirty=$(git -C "$main_checkout" status --porcelain 2>/dev/null || true)
if [ -n "$dirty" ]; then
  branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  if printf '%s' "$branch" | grep -qiE '[a-z]{2,}-[0-9]+'; then
    echo "WARN: main checkout is dirty on '$branch', which carries an issue ID — each session's /auto will" >&2
    echo "      try to attribute and finish that work before picking. Launching anyway." >&2
  else
    echo "WARN: main checkout is dirty on '${branch:-(detached)}' — a merge that changes any of these paths defers" >&2
    echo "      to the merge queue until they are committed or discarded; every other merge lands normally:" >&2
    printf '%s\n' "$dirty" | sed 's/^/       /' >&2
    echo "      Launching anyway." >&2
  fi
fi

# mods/loop-boundary owns compaction between iterations (the --autocompact 500000 cap it replaced from 2026-10-09 is
# history in doc/compacting-investigation.md); without it a /loop /auto session on opus[1m] never compacts. An
# explicit cap after -- is the operator's own control, so there the refusal softens to a WARN.
explicit_cap=0
for a in "${claude_args[@]}"; do case "$a" in --autocompact|--autocompact=*) explicit_cap=1 ;; esac; done
if ! "$script_dir/mod-enabled.sh" loop-boundary; then
  if [ "$explicit_cap" = 1 ]; then
    echo "WARN: launching without the loop-boundary mod — the explicit --autocompact after -- is the only compaction control these sessions have" >&2
  else
    echo "Nothing was dispatched or written. Install the mod (above), or pass an explicit --autocompact after -- to launch without it." >&2
    exit 5
  fi
fi

# Last of the refusals: it is the only one that touches the network (a fetch bounded at ~10s).
fresh_rc=0
"$script_dir/claude-freshness.sh" || fresh_rc=$?
if [ "$fresh_rc" -eq 4 ]; then
  if [ "$stale_ok" = 1 ]; then
    echo "WARN: launching on the stale ~/.claude above (stale-ok) — every session runs that tooling for the fleet's whole duration" >&2
  else
    echo "Nothing was dispatched or written. Run /update and re-launch, or re-run with 'stale-ok' to launch on this tooling." >&2
    exit 4
  fi
fi

# A /fleet-sequence may be running alongside (skills/fleet-sequence/SKILL.md § Relationship to the fleet
# skills): keeping its queued issues out of this fleet's picks is next-candidates.sh's job, and its runner
# reads each child's ledger tmp/auto-state-<session>.json TWICE across a poll after the child has ended — so
# the ledger expiry below must leave every session a live sequence names alone, or a launch between the two
# reads fails the sequence.
seq_sessions=""
for seq_marker in "$main_checkout"/tmp/fleet-sequence-*.json; do
  [ -s "$seq_marker" ] || continue
  [ "$(jq -r '.status // empty' "$seq_marker" 2>/dev/null)" = "running" ] || continue
  seq_pid=$(jq -r '.runner_pid // empty' "$seq_marker" 2>/dev/null)
  [[ "$seq_pid" =~ ^[0-9]+$ ]] && kill -0 "$seq_pid" 2>/dev/null || continue
  seq_sessions="$seq_sessions $(jq -r '[(.issues // {})[] | .session // empty, .pr_update_session // empty] | join(" ")' "$seq_marker" 2>/dev/null)"
  echo "NOTE: a /fleet-sequence is running alongside ($(jq -r '(.queue // []) | join(" → ")' "$seq_marker")) — its queued issues are hidden from this fleet's picks; fleet-sequence.sh status reads it"
done

# ---- expiry and carry (header § Expiry) ----
# Every marker in tmp/ is read once: which of its sessions the registry still runs, whether /fleet-retro has measured it,
# and — for this slug's own marker — whether this launch tops its fleet up or starts a new run. With no registry nothing
# expires and nothing is carried, as before.
launch_now=$(date +%s)
launch_epoch=$launch_now
marker_live_keys() { # <marker> → the fleet_sessions the registry lists as running, space-separated
  local k out=""
  for k in $(jq -r '(.fleet_sessions // [])[]' "$1" 2>/dev/null); do registry_alive "$k" && out="$out $k"; done
  printf '%s' "$out"
}
marker_launch_epoch() { # <marker> → launch_epoch, else the file's mtime
  local le
  le=$(jq -r '.launch_epoch // empty' "$1" 2>/dev/null) || le=""
  [[ "$le" =~ ^[0-9]+$ ]] || le=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  printf '%s' "$le"
}
marker_label() { # <marker> → "<slug> (launched <date>, <n> session(s))"
  local le n
  le=$(marker_launch_epoch "$1")
  n=$(jq -r '(.fleet_sessions // []) | length' "$1" 2>/dev/null) || n=0
  printf '%s (launched %s, %s session(s))' "$(fleet_marker_slug "$1")" \
    "$(date -r "$le" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$le" '+%Y-%m-%d %H:%M')" "$n"
}
protected=" "        # ledger keys some remaining marker names — never expired by this launch
other_active=""      # live, non-retiring sessions of the other running fleets, for the cap line
other_slugs=""
expired=""
expired_keys=""      # sessions of expired markers — their dead ledgers go with the marker, not as prior-run clearing
kept_unretrod=""
old_marker_json=""   # this slug's marker as found, for the carry and retiring logic below
while IFS= read -r mf; do
  [ -n "$mf" ] && [ -f "$mf" ] || continue
  m_keys=$(jq -r '(.fleet_sessions // []) | join(" ")' "$mf" 2>/dev/null) || m_keys=""
  if [ "$mf" = "$marker" ]; then
    old_marker_json=$(jq -c '.' "$mf" 2>/dev/null || echo '{}')
    continue
  fi
  if [ -z "$agents_json" ]; then protected="$protected$m_keys "; continue; fi
  m_live=$(marker_live_keys "$mf")
  if [ -n "$m_live" ]; then
    protected="$protected$m_keys "
    if ! fleet_marker_archived "$mf"; then
      m_ret=$(jq -r '(.retiring // [])[]' "$mf" 2>/dev/null) || m_ret=""
      for k in $m_live; do printf '%s\n' "$m_ret" | grep -qxF -- "$k" || other_active="$other_active $k"; done
      other_slugs="$other_slugs $(fleet_marker_slug "$mf")"
    fi
    continue
  fi
  label=$(marker_label "$mf")
  if fleet_marker_retrod "$mf" "$history_file"; then
    rm -f "$mf"
    expired="$expired"$'\n'"  $label"
    expired_keys="$expired_keys $m_keys"
  else
    protected="$protected$m_keys "
    kept_unretrod="$kept_unretrod"$'\n'"  $label ($mf)"
  fi
done < <(fleet_all_markers "$main_checkout")

# This slug's own marker: a running fleet (not winding down, a session still live) is topped up in place and keeps every
# member it lists; an ended one starts a new run — archived under its launch epoch unless the history already names it —
# and its still-running sessions are carried as retiring below.
winding_down=0
own_new_run=0
prev_members=""
if [ -n "$old_marker_json" ]; then
  prev_members=$(printf '%s' "$old_marker_json" | jq -r '(.fleet_sessions // []) | join(" ")')
  old_deadline=$(printf '%s' "$old_marker_json" | jq -r '.deadline_epoch // empty')
  old_stopped=$(printf '%s' "$old_marker_json" | jq -r '.stopped // false')
  { [[ "$old_deadline" =~ ^[0-9]+$ ]] && [ "$old_deadline" -le "$launch_now" ]; } && winding_down=1
  [ "$old_stopped" = "true" ] && winding_down=1
  own_live=""
  [ -n "$agents_json" ] && own_live=$(marker_live_keys "$marker")
  if [ "$winding_down" = 1 ] || { [ -n "$agents_json" ] && [ -z "$own_live" ]; }; then
    own_new_run=1
    label=$(marker_label "$marker")
    if fleet_marker_retrod "$marker" "$history_file"; then
      rm -f "$marker"
      expired="$expired"$'\n'"  $label"
      expired_keys="$expired_keys $prev_members"
    else
      archive="$main_checkout/tmp/fleet-deadline-$slug.$(marker_launch_epoch "$marker").json"
      mv "$marker" "$archive"
      protected="$protected$prev_members "
      kept_unretrod="$kept_unretrod"$'\n'"  $label → $archive"
    fi
  else
    protected="$protected$prev_members "
  fi
fi

# Ledgers (tmp/auto-state-*.json): one a kept marker names stays with its fleet; one a running sequence names is left alone.
# A live LOOP ledger joins this fleet when the slug's marker already lists it, or when no marker lists it and its own scope is
# this slug's (an interactive /loop /auto running beside the fleet) — it then pulls launch_epoch back to its mtime so a top-up
# never hides a running sibling from /fleet-status, and is carried into fleet_sessions. A live single-run ledger (`mode:
# single` — a targeted or one-shot /auto, skills/auto/SKILL.md Step 4) does neither: it is not a fleet member, and anchoring
# on one is exactly how a time-window scope came to admit 26 sessions. A dead ledger no kept marker names is cleared.
cleared=""
carried=""
for sf in "$main_checkout"/tmp/auto-state-*.json; do
  [ -f "$sf" ] || continue
  key=$(basename "$sf" | sed 's/auto-state-//;s/\.json//')
  case " $seq_sessions " in *" $key "*) continue ;; esac
  if [ -z "$agents_json" ] || registry_alive "$key"; then
    [ "$(jq -r '.mode // "loop"' "$sf" 2>/dev/null)" = "single" ] && continue
    case " $prev_members " in
      *" $key "*) ;;
      *) case "$protected" in *" $key "*) continue ;; esac
         [ "$(fleet_slug "$(jq -r '.scope // empty' "$sf" 2>/dev/null)")" = "$slug" ] || continue ;;
    esac
    mt=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo "")
    [[ "$mt" =~ ^[0-9]+$ ]] && [ "$mt" -lt "$launch_epoch" ] && launch_epoch="$mt"
    [ -n "$agents_json" ] && carried="$carried $key"
  else
    case "$protected" in *" $key "*) continue ;; esac
    rm -f "$sf"
    case " $expired_keys " in *" $key "*) ;; *) cleared="$cleared $key" ;; esac
  fi
done
[ -n "$cleared" ] && echo "Cleared prior-run ledger(s):$cleared (not running per the registry and named by no kept fleet; /fleet-retro can no longer measure those runs)"
[ -n "$expired" ] && printf "Expired retro'd fleet(s) (marker and the ledgers only it named; measured in %s):%s\n" "$history_file" "$expired"
[ -n "$kept_unretrod" ] && printf "Kept un-retro'd fleet(s) — fleet-metrics.py --list-fleets names them for /fleet-retro; each expires at the first launch after its retro:%s\n" "$kept_unretrod"
[ -z "$agents_json" ] && echo "WARN: claude agents --json unavailable — no prior-run ledger cleared, and running siblings cannot be carried into fleet_sessions" >&2

# A member of the previous launch that the registry still lists is carried even without a ledger: a session still in preflight has
# not written one yet. Only while that launch is live — a winding-down marker's members are past preflight, so one with no ledger has
# finished and been cleared. The registry can still list such a session: 2026-10-12, one killed 17h earlier was re-claimed by the
# daemon (`claimed-spare … (fleet)`), carried into the next fleet as retiring with no work to finish, and counted by every observer.
if [ -n "$agents_json" ] && [ -n "$old_marker_json" ] && [ "$winding_down" = 0 ]; then
  for k in $prev_members; do
    case " $carried " in *" $k "*) continue ;; esac
    registry_alive "$k" && carried="$carried $k"
  done
fi

# Sessions carried out of a marker that was already winding down are RETIRING: they stay in fleet_sessions (the observers still
# scope by it) and are also listed in `retiring`, which auto-deadline-gate.sh treats as a passed deadline whatever the new
# deadline_epoch says. Without it a relaunch over a wound-down fleet hands every straggler the new deadline: 2026-10-10, two leg-1
# sessions finishing their last issues were carried into a 19h marker, ran beside the three new sessions (5 against the cap of 3), and
# one kept picking Backlog under its own leg-1 token for 20 more hours. A marker whose deadline is still ahead (a genuine mid-fleet
# top-up), or that has none, retires nobody; sessions an earlier relaunch already retired stay retired.
retiring=""
if [ -n "$carried" ] && [ -n "$old_marker_json" ]; then
  old_retiring=$(printf '%s' "$old_marker_json" | jq -r '(.retiring // [])[]' 2>/dev/null || true)
  for k in $carried; do
    if [ "$winding_down" = 1 ] || printf '%s\n' "$old_retiring" | grep -qxF -- "$k"; then
      retiring="$retiring $k"
    fi
  done
fi
active_carried=""
n_active=0
for k in $carried; do
  case " $retiring " in *" $k "*) ;; *) active_carried="$active_carried $k"; n_active=$(( n_active + 1 )) ;; esac
done
n_other=0
for k in $other_active; do n_other=$(( n_other + 1 )); done
if [ -n "$retiring" ]; then
  echo "Retiring session(s):$retiring — carried from a marker that was winding down; each finishes its in-flight issue, then stops picking (recorded in the marker's retiring list)"
fi
if [ -n "$active_carried" ] || [ "$n_other" -gt 0 ]; then
  total=$(( n_active + n_other + count ))
  other_clause=""; [ "$n_other" -gt 0 ] && other_clause=" + $n_other in other fleet(s) (${other_slugs# })"
  echo "Concurrency: $n_active carried session(s)$other_clause + $count new = $total running against the cap of $concurrency_cap"
  if [ "$total" -gt "$concurrency_cap" ]; then
    remedy=""
    [ -n "$active_carried" ] && remedy="stop the carried session(s) (${active_carried# })"
    [ "$n_other" -gt 0 ] && remedy="${remedy:+$remedy, }wind down another fleet (/fleet-stop epic:<ID> | team)"
    echo "WARN: $total non-retiring sessions will run, over the cap of $concurrency_cap (more than the account pool's 5h windows refill for) — $remedy or relaunch with a smaller count" >&2
  fi
  for k in $active_carried; do
    sf="$main_checkout/tmp/auto-state-$k.json"
    [ -f "$sf" ] || continue
    ledger_backlog=$(jq -r '.backlog // false' "$sf" 2>/dev/null || echo false)
    if [ "$ledger_backlog" = "true" ] && [ "$backlog_token" != 1 ]; then
      echo "WARN: carried session $k runs with backlog: true (its own token from an earlier launch) and keeps picking Backlog under it — this launch spends on Backlog anyway; stop that session if no Backlog spend is wanted" >&2
    elif [ "$ledger_backlog" != "true" ] && [ "$backlog_token" = 1 ]; then
      echo "WARN: carried session $k has no backlog token and will hold on the Planned column while this launch's sessions take Backlog" >&2
    fi
  done
fi

# Integration-branch posture: nothing to mutate. The marker below carries `branch`, and each session's /auto
# points the per-issue start.<id>.wt-source-branch key at it before every dispatch (auto-fork-key.sh), so the
# main checkout stays where its human left it — a detach here (the posture until 2026-09-23) took the checkout
# away for the fleet's duration and steered the human's own /start wt onto the epic branch as well.
if [ -n "$scope_branch" ]; then
  echo "Sessions fork from and merge into $scope_branch by ref (per-issue fork keys; the main checkout stays on ${checkout_branch:-its current HEAD}). After the fleet: ~/.claude/scripts/epic-pr.sh opens the PR from $scope_branch onto ${scope_base:-<base>}; then /pr-update <PR#>."
fi

# The marker is written on every launch: a stale deadline from a previous run would end every new loop at its first pick.
# The session set starts from the carried siblings — plus, on a top-up, every member the running fleet already listed — and
# grows by one per dispatch below. Deadline fields only when this launch carries a duration; scope fields only when scoped.
seed="$carried"
[ "$own_new_run" = 0 ] && seed="$prev_members $carried"
carried_json=$(printf '%s\n' $seed | jq -R . | jq -s 'map(select(length > 0)) | unique')
retiring_json=$(printf '%s\n' $retiring | jq -R . | jq -s 'map(select(length > 0))')
jq -n --argjson count "$count" --argjson launch "$launch_epoch" --argjson carried "$carried_json" --argjson retiring "$retiring_json" \
  '{count: $count, launch_epoch: $launch, fleet_sessions: $carried} + (if ($retiring | length) > 0 then {retiring: $retiring} else {} end)' > "$marker"
if [ -n "$scope" ]; then
  tmpm=$(jq --arg s "$scope" --argjson m "$scope_members" --arg b "$scope_branch" --arg base "$scope_base" \
    '. + {scope: $s, members: $m} + (if $b != "" then {branch: $b, base: $base} else {} end)' "$marker")
  printf '%s\n' "$tmpm" > "$marker"
fi
if [ "$backlog_token" = 1 ]; then
  tmpm=$(jq '. + {backlog: true}' "$marker")
  printf '%s\n' "$tmpm" > "$marker"
  if [ -n "$scope" ]; then
    echo "Backlog fallback: on (epic scope) — a session picks the epic's own Backlog members once nothing Planned/Todo in the scope is pickable (Planned/Todo first at every pick; never the team's Backlog; the headroom gate still parks near the 5h ceiling)"
  else
    echo "Backlog fallback: on — a session picks Backlog only once nothing Planned/Todo is pickable (Planned/Todo first at every pick; the headroom gate still parks near the 5h ceiling)"
  fi
fi
if [ -n "$deadline_epoch" ]; then
  tmpm=$(jq --argjson epoch "$deadline_epoch" --arg human "$deadline_human" '. + {deadline_epoch: $epoch, deadline: $human}' "$marker")
  printf '%s\n' "$tmpm" > "$marker"
  echo "Fleet deadline: $deadline_human ($marker)"
fi

# The active account's windows, from the reading mods/rate-limits last wrote (every session on this machine rewrites it on each
# measurement, so it names whichever account the latest session ran on). Burst: every pick parks once the 5h window is within
# fleet-headroom.sh's reserve of full, so a launch into a nearly-full window parks every session at its first pick. Weekly: the
# 2026-10-10 fleet was launched on an account 5.75h from its weekly limit and lost 18.75 of its 36 session-hours; nothing at launch
# said so. Never silent, never blocking: a reading per window or `<Window>: no reading (<why>)`, and a WARN only when the window
# could plausibly end or stall this run — 70 is an unmeasured starting threshold for the weekly (fleet-launch SKILL.md).
iso_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty'; }
age_of() { # <epoch> — "<n>m" or "<h>h <m>m" since it
  local a=$(( $(date +%s) - $1 )); [ "$a" -lt 0 ] && a=0
  if [ "$a" -lt 3600 ]; then echo "$(( a / 60 ))m"; else echo "$(( a / 3600 ))h $(( (a % 3600) / 60 ))m"; fi
}
reading_file="$HOME/.claude/local/rate-limits.json"
if [ ! -f "$reading_file" ]; then
  if "$script_dir/mod-enabled.sh" rate-limits >/dev/null 2>&1; then
    echo "Rate limits: no reading ($reading_file is missing — rate-limits@alienfast-claude is enabled but no session has measured since it loaded; start one and relaunch, or launch without)"
  else
    echo "Rate limits: no reading ($reading_file is missing and rate-limits@alienfast-claude is not enabled on this machine — update.sh installs it, or: claude plugin install rate-limits@alienfast-claude)"
  fi
elif ! reading_json=$(jq -c '{at: (.measured_at // ""), five: ((.windows // []) | map(select(.kind == "five_hour")) | .[0]), week: ((.windows // []) | map(select(.kind == "seven_day")) | .[0])}' "$reading_file" 2>/dev/null) || [ -z "$reading_json" ]; then
  echo "Rate limits: no reading ($reading_file is not readable JSON)"
else
  reading_at=$(jq -r '.at' <<<"$reading_json")
  reading_at_epoch=$(iso_epoch "$reading_at")
  if [ -n "$reading_at_epoch" ]; then reading_age=$(age_of "$reading_at_epoch"); else reading_age="an unknown time (measured_at '$reading_at' is unreadable)"; fi
  burst_pct=$(jq -r '.five.percentUsed // empty' <<<"$reading_json")
  if [ -z "$burst_pct" ]; then
    echo "Burst: no reading (the last measurement in $reading_file carried no five_hour window)"
  else
    burst_reset=$(jq -r '.five.resetsAt // "unknown"' <<<"$reading_json")
    burst_reset_epoch=$(iso_epoch "$burst_reset")
    echo "Burst (five_hour): ${burst_pct}% used, resets $burst_reset, measured $reading_age ago"
    if [ "$(jq -rn --argjson p "$burst_pct" '$p > 80' 2>/dev/null)" = "true" ]; then
      if [ -n "$burst_reset_epoch" ] && [ "$burst_reset_epoch" -le "$(date +%s)" ]; then
        echo "NOTE: the 5h window read ${burst_pct}% used, but that reading predates its reset at $burst_reset — the window is empty again."
      elif [ -n "$burst_reset_epoch" ] && [ $(( burst_reset_epoch - $(date +%s) )) -le 900 ]; then
        echo "NOTE: the 5h window is ${burst_pct}% used but resets in $(( (burst_reset_epoch - $(date +%s)) / 60 ))m, so the first picks park only until then."
      else
        echo "WARN: the 5h window is ${burst_pct}% used — over fleet-headroom.sh's reserve, so every session parks at its first pick until the reset at $burst_reset. Launch after the reset, or accept the park." >&2
      fi
    fi
  fi
  weekly_pct=$(jq -r '.week.percentUsed // empty' <<<"$reading_json")
  if [ -z "$weekly_pct" ]; then
    echo "Weekly: no reading (the last measurement in $reading_file carried no seven_day window)"
  else
    weekly_reset=$(jq -r '.week.resetsAt // "unknown"' <<<"$reading_json")
    weekly_reset_epoch=$(iso_epoch "$weekly_reset")
    echo "Weekly (seven_day): ${weekly_pct}% used, resets $weekly_reset, measured $reading_age ago"
    if [ "$(jq -rn --argjson p "$weekly_pct" '$p >= 70' 2>/dev/null)" = "true" ]; then
      if [ -n "$deadline_epoch" ] && [ -n "$weekly_reset_epoch" ] && [ "$weekly_reset_epoch" -le "$deadline_epoch" ]; then
        echo "NOTE: the weekly window is ${weekly_pct}% used but resets before this fleet's deadline, so it should not end the run."
      else
        echo "WARN: the weekly window is ${weekly_pct}% used and resets $weekly_reset — after this fleet's deadline, or the launch has none. A fleet that exhausts it stops until the reset (2026-10-10: 52% of session-hours lost). Rotate to an account with room before launching." >&2
      fi
    fi
  fi
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
# No --autocompact default since 2026-10-09: the loop-boundary mod (checked above) compacts at iteration boundaries,
# and the engine's own threshold governs inside an iteration. The retired 500k cap and its sizing history are in
# doc/compacting-investigation.md; `-- --autocompact 500000` restores it for one launch.
if ! have_flag --permission-mode "${claude_args[@]}" && ! have_flag --dangerously-skip-permissions "${claude_args[@]}"; then
  # auto, not acceptEdits: acceptEdits only auto-accepts FILE EDITS, so the first gated
  # Bash command (e.g. /start wt's worktree validation) prompts into a background session
  # where nobody answers, and the session stalls at its first pick. auto mode routes
  # those commands through the classifier instead.
  claude_args+=(--permission-mode auto)
fi

default_prompt="/loop /auto"
[ -n "$scope" ] && default_prompt="$default_prompt epic:$scope"
[ "$backlog_token" = 1 ] && default_prompt="$default_prompt backlog"
prompt="${FLEET_PROMPT:-$default_prompt}"
if [ -n "$scope" ] && [ "$prompt" != "$default_prompt" ] && ! printf '%s' "$prompt" | grep -qi "epic:$scope"; then
  echo "WARN: FLEET_PROMPT='$prompt' does not carry epic:$scope — the sessions will NOT be scoped to the epic the marker records" >&2
fi
if [ "$backlog_token" = 1 ] && [ -z "$scope" ] && [ "$prompt" != "$default_prompt" ] && ! printf '%s' "$prompt" | grep -qiw "backlog"; then
  echo "WARN: FLEET_PROMPT='$prompt' does not carry backlog — the sessions will hold on the Planned gate although the marker records the fallback" >&2
fi
timeout="${FLEET_STAGGER_TIMEOUT:-180}"
wt_dir="$main_checkout/.claude/worktrees"
wt_names() { ls -1 "$wt_dir" 2>/dev/null || true; }
wt_owner() { # <worktree name> → the identity sidecar's owner in short form; empty when no sidecar or no owner yet
  local o
  o=$(sed -n 's/^WT_IDENTITY_OWNER=//p' "$main_checkout/.claude/worktree-identity/wt-identity-$1.env" 2>/dev/null | head -1)
  printf '%s' "${o:0:8}"
}

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
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      # A sibling fleet's session may stamp a worktree meanwhile: a sidecar naming another owner is not this claim.
      owner=$(wt_owner "$cand")
      if [ -n "$owner" ] && [[ "$sid" =~ ^[0-9a-f]{8}$ ]] && [ "$owner" != "$sid" ]; then continue; fi
      new="$cand"; break
    done < <(comm -13 <(printf '%s\n' "$base" | sort) <(wt_names | sort))
  done
  if [ -n "$new" ]; then
    echo "[$i/$count] claim landed after ${n}s ($new)"
  else
    echo "[$i/$count] WARN: no new worktree after ${timeout}s — launching next anyway (session may be in preflight, resuming, or the pool may be drained)" >&2
  fi
done

echo "Launched $count session(s) — watch them with: claude agents"
echo "Fleet session set: $(jq -r '(.fleet_sessions // []) | join(" ")' "$marker") ($marker)"
[ -n "$scope" ] && echo "Fleet scope: epic $scope ($(printf '%s' "$scope_members" | jq 'length') member(s) snapshotted for the burn-down)"
[ -n "$deadline_human" ] && echo "Loops stop picking new work at $deadline_human; in-flight issues run to completion."
exit 0
