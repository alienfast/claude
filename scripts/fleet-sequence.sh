#!/bin/bash
# fleet-sequence.sh — ship an ORDERED list of certified issues onto ONE integration branch, one background
# `claude --bg "/auto <ID>"` session at a time: each issue forks from the branch's current tip and its own
# /finish merges it back, and when the list completes a single PR from that branch onto the branch you
# launched from carries the lot. The `merge` token skips the branch and the PR — each issue then merges
# straight into the launch branch, the shape an unscoped fleet ships in.
#
# Usage: fleet-sequence.sh [pr|merge] [stale-ok] <ISSUE-ID>... [-- <claude flags...>]
#        fleet-sequence.sh solo [list] [stale-ok] [<duration>] [then-fleet [<fleet-launch tokens>...]] [-- <claude flags...>]
#        fleet-sequence.sh status [<ISSUE-ID>|solo]
#        fleet-sequence.sh stop [<ISSUE-ID>|solo]
#        fleet-sequence.sh run <slug>     (internal: the detached runner; reads tmp/fleet-sequence-<slug>.json)
#
#   <ISSUE-ID>...  The issues in the order they must ship. Each must carry `specified` and neither `human`
#                  nor `hold` (the same probe /auto's targeted mode runs), and must not already be terminal or
#                  Ready For Release — unless the marker records it shipped on this launch branch, which
#                  a resume skips unprobed. `solo` is expressly fine — this is the runner for it.
#                  A list that shares an issue with an earlier sequence (same launch branch and mode, its
#                  branch still there) RESUMES that sequence; a list sharing none is a NEW sequence.
#   pr | merge     pr (default): create `seq/<first-id>` from the launch branch, ship every issue onto it,
#                  push it after each ship, open one PR onto the launch branch at the end, then run
#                  /pr-update on it. merge: no branch, no PR — each issue merges into the launch branch.
#   stale-ok       Launch even though ~/.claude is behind origin/main in a file sessions load (TOOLING-STALE,
#                  claude-freshness.sh — checked once, at launch), with a one-line WARN; without it, exit 4.
#   -- ...         Passed to every `claude --bg` verbatim; defaults added only for flags not present
#                  (--model 'opus[1m]' --effort xhigh --permission-mode auto — skills/auto/SKILL.md's
#                  unattended-run prerequisites, same as fleet-launch.sh; no --autocompact since 2026-10-09:
#                  mods/loop-boundary compacts at iteration boundaries, and the launch refuses, exit 5, where
#                  it is not enabled unless an explicit --autocompact is passed).
#
#   solo           The DRAIN (/fleet-solo): no list — the queue is next-candidates.sh --label solo for $LINEAR_TEAM, the
#                  set /auto-prep reports as workable now, read again before every dispatch: an issue a predecessor's
#                  ship unblocked joins, and one that left the pool is never dispatched from a stale list. Always
#                  `merge` — a broad change parked on a branch only defers its collision to the catch-up merge, and
#                  one PR for a named list is the list form above. A non-ship means something else here: the issues
#                  are independent, so one that ends without shipping is recorded and the drain moves on, until
#                  FLEET_SEQUENCE_DRAIN_MAX_FAILS in a row fail — a pattern the next one would repeat. `list` prints
#                  the running order and launches nothing. <duration> ("3h", "90 minutes") is a budget: no issue
#                  starts after it, the one in flight finishes. `then-fleet` runs fleet-launch.sh with the tokens
#                  that follow once the drain ends CLEAN (drained, or out of time) — never after a stop, the fail
#                  limit, or an issue left in flight; the tokens are checked at launch (FLEET_LAUNCH_CHECK), so a
#                  bad count or a missing recommendation refuses while someone is watching. The claude flags after
#                  -- go to the drain's sessions and to that fleet. One drain per checkout, marker slug `solo`; a
#                  re-launch waits on a session the last drain left working instead of dispatching beside it. Unlike
#                  a list it also launches from a checkout parked detached with start.wt-source-branch set, merging
#                  into the branch that key names.
#
#   status         One-screen readout of a marker: mode, branch, PR, per-issue session, liveness,
#                  outcome and where it landed, the branch's position against its base, the runner's
#                  liveness. Read-only. With an ID, the sequence naming that issue; without, every
#                  running sequence — or the latest one when none is running.
#   stop           Ask the runner to stop after the issue in flight; nothing is killed, what shipped stays
#                  on the branch, and no PR is opened (re-run the list, or integration-pr.sh by hand).
#                  Killing the in-flight session is `claude agents`, never this. An ID is needed only
#                  when several sequences are running.
#
# Sequences are discrete: state is keyed by the sequence's slug — the lowercased first ID of the list that
# created it, the suffix of its seq/ branch — so no two share a marker, a log, a branch, or a /pr-update
# worktree, and several may run at once (each strictly serial within itself; an issue belongs to one live
# sequence, and two `merge` sequences never share a launch branch). A fleet may run alongside too: its
# pickers cannot take a queued issue (next-candidates.sh hides every issue a running sequence holds), and
# neither side parks the checkout the other needs. 2026-09-21: with one marker per checkout
# and a resume decided by launch branch and mode alone, `BF-2034 BF-1794` launched from the branch an earlier
# `BF-2022 …` sequence had used — its runner dead, its BF-2022 session still working — was read as a resume,
# shipped onto seq/bf-2022, and rewrote that sequence's marker and log.
#
# Why sessions and not one loop: a targeted `/auto <ID>` is one-shot and a `/loop /auto` never picks
# `solo` work, and a big issue wants a fresh context of its own. Why one branch and not a stack of PRs:
# GitHub's stacked pull requests assume a rebase-and-restack workflow, and this house merges and never
# rebases (standards/git.md) — so when the launch branch moved, every PR in the stack had to be re-merged
# level by level, each with its own CI run, and the stack still reached the launch branch one merge at a
# time (measured September 2026 on three PRs stacked on `hotfixes`). One branch takes one catch-up merge and
# one CI run, and it is the release shape an epic-scoped fleet already uses (fleet-launch.sh).
#
# Positioning: the runner never moves the main checkout. Before EVERY dispatch it sets the per-issue key
# `start.<id-lower>.wt-source-branch` to the branch that issue must ship onto (the integration branch; the
# launch branch in `merge` mode) and unsets it once the session has ended. start-wt-setup.sh resolves that
# key ahead of the checkout's own branch, and start-wt-create.sh forks from the branch's REF — so each fork
# carries every predecessor's merge, finish-merge.sh advances the branch ref-only while the checkout sits
# elsewhere, and a `/start wt` for any OTHER issue running alongside (a targeted /auto, an interactive
# /start) still forks from and merges into the checkout's own branch, as if no sequence were running.
# (Measured 2026-09-16: the earlier posture — detach HEAD at the branch and set the checkout-wide
# `start.wt-source-branch` — pointed a concurrent targeted `/auto BFP-117` at seq/bfp-112.) Every key the
# run set is unset on every exit, and the closing /pr-update runs from a throwaway worktree on the branch.
#
# Sequencing: dispatch, wait for the session's ledger tmp/auto-state-<id>.json to record the issue (the
# registry `claude agents --json --all` is the fallback for a session that ends without one: listed done,
# failed or stopped, or dropped from the listing — either one only after the session was seen live or the
# grace has passed), then
# require the target branch's tip to have moved — a `shipped` whose merge the queue deferred is waited on
# up to FLEET_SEQUENCE_MERGE_TIMEOUT. Any other outcome stops the sequence with the remaining issues
# untouched — /auto already commented and labeled the issue. Re-running the same list resumes: issues the
# marker recorded as landed are skipped (one recorded shipped whose deferred merge outlasted the wait is waited
# on again first, so the next issue never forks without it), the branch is kept, and a list whose every issue has shipped
# goes straight to the PR step — which is also how a run whose PR could not be opened is completed. A
# resume also ADOPTS a session an earlier run dispatched that is still working (or shipped with its landing
# unrecorded) — a runner can die under a harness restart its child survives — waiting on it, never
# dispatching the issue twice. A child listed `idle` with no ledger is one whose turn ended without
# finishing — an API error kills a turn that way (2026-09-21: a 500 mid-review left `fleet-sequence BF-2034`
# idle 13 hours and this runner timed out behind it) — and its recovery is hooks/auto-rewake.sh, which retries a
# one-shot /auto session every ~15 minutes for six hours; the runner logs the transition, keeps waiting, and a
# timeout names the state it saw last.
#
# Env: FLEET_SEQUENCE_POLL (seconds between reads, default 30), FLEET_SEQUENCE_GRACE (default 120),
# FLEET_SEQUENCE_ISSUE_TIMEOUT (default 43200 — 12h per issue, this being the runner for big and `solo`
# work: BF-2022 took 7h54m of healthy work on 2026-09-21, past the 6h the default used to be; on expiry the
# sequence fails and the session is left running), FLEET_SEQUENCE_MERGE_TIMEOUT (default 1800 — how long a shipped issue may take to land
# on the branch; the merge-queue drainer runs every 15 minutes), FLEET_SEQUENCE_PR_UPDATE=0 skips the
# closing /pr-update session, FLEET_SEQUENCE_PR_UPDATE_TIMEOUT (default 1800), FLEET_SEQUENCE_FOREGROUND=1
# runs the runner inline (tests). The drain's: FLEET_SEQUENCE_DRAIN_MAX_FAILS (default 2), FLEET_SEQUENCE_LIST_RETRIES
# and FLEET_SEQUENCE_LIST_WAIT (default 6 tries, 300s apart, before an unreadable listing fails the drain), and the
# test seams FLEET_SEQUENCE_LISTER / FLEET_SEQUENCE_FLEET_LAUNCHER (default next-candidates.sh / fleet-launch.sh).
#
# Read-write: tmp/fleet-sequence-<slug>.json (the marker) and tmp/fleet-sequence-<slug>.log in the main
# checkout; creates the integration branch, sets/unsets the per-issue `start.<id>.wt-source-branch` keys,
# pushes the branch, opens its PR, adds and removes a throwaway worktree at tmp/fleet-sequence-pr-update-<slug>
# for the closing /pr-update session, dispatches background claude sessions, and for a drain's then-fleet runs
# fleet-launch.sh. Never moves the main checkout's
# HEAD. Exit 1 on argument/environment errors, exit 4 on TOOLING-STALE and exit 5 on BOUNDARY-MOD-MISSING, all
# before anything is dispatched or written; the runner exits 1 when the sequence fails.

set -eo pipefail

usage() {
  echo "usage: fleet-sequence.sh [pr|merge] [stale-ok] <ISSUE-ID>... [-- <claude flags...>] | fleet-sequence.sh solo [list] [stale-ok] [<duration>] [then-fleet [<fleet-launch tokens>...]] [-- <claude flags...>] | fleet-sequence.sh status [<ISSUE-ID>|solo] | stop [<ISSUE-ID>|solo]" >&2
  exit 1
}

for cmd in claude jq git gh; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib/fleet-markers.sh"
main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the project the sequence should work on" >&2; exit 1; }
mkdir -p "$main_checkout/tmp"
marker=""; log=""; pr_wt="" # per sequence — set by use_sequence before anything reads them
poll="${FLEET_SEQUENCE_POLL:-30}"
grace="${FLEET_SEQUENCE_GRACE:-120}"
issue_timeout="${FLEET_SEQUENCE_ISSUE_TIMEOUT:-43200}"
merge_timeout="${FLEET_SEQUENCE_MERGE_TIMEOUT:-1800}"
pr_update_timeout="${FLEET_SEQUENCE_PR_UPDATE_TIMEOUT:-1800}"
drain_max_fails="${FLEET_SEQUENCE_DRAIN_MAX_FAILS:-2}"
list_retries="${FLEET_SEQUENCE_LIST_RETRIES:-6}"
list_wait="${FLEET_SEQUENCE_LIST_WAIT:-300}"
claude_args=()

logln() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# /auto attributes main-checkout dirt by an issue-ID segment in the branch name (skills/auto Step 1); fleet-launch.sh tests the same shape.
carries_issue_id() { printf '%s' "$1" | grep -qiE '[a-z]{2,}-[0-9]+'; }

update_marker() { # <jq args...> — rewrite the marker through a jq filter
  local out
  out=$(jq "$@" "$marker") || return 1
  printf '%s\n' "$out" > "$marker"
}

# ---- one marker per sequence ----
use_sequence() { # <slug> — point marker, log and the /pr-update worktree at one sequence's own files
  marker="$main_checkout/tmp/fleet-sequence-$1.json"
  log="$main_checkout/tmp/fleet-sequence-$1.log"
  pr_wt="$main_checkout/tmp/fleet-sequence-pr-update-$1"
}
slug_of() { local b; b=$(basename "$1" .json); printf '%s' "${b#fleet-sequence-}"; } # <marker path> → its slug
all_markers() { # every sequence marker in this checkout, newest launch first
  local f
  for f in "$main_checkout"/tmp/fleet-sequence-*.json; do
    if [ -s "$f" ]; then printf '%s\t%s\n' "$(jq -r '.launch_epoch // 0' "$f" 2>/dev/null || echo 0)" "$f"; fi
  done | sort -rn | cut -f2-
}
runner_alive() { # <marker> — `running` under a live runner pid; the marker outlives the run, so `running` under a dead pid is a crash
  local k
  [ "$(jq -r '.status // ""' "$1" 2>/dev/null)" = "running" ] || return 1
  k=$(jq -r '.runner_pid // empty' "$1" 2>/dev/null)
  [[ "$k" =~ ^[0-9]+$ ]] && kill -0 "$k" 2>/dev/null
}
names_issue() { # <marker> <ISSUE-ID> — the sequence lists the issue, or recorded it on an earlier run
  jq -e --arg id "$2" '((.queue // []) + ((.issues // {}) | keys)) | index($id) != null' "$1" >/dev/null 2>&1
}
marker_naming() { # <ISSUE-ID as typed> → the newest marker naming it, or "" when none does; returns 1 on a malformed ID
  local id f
  id=$("$here/detect-issue-id.sh" --validate-only --input "$1" 2>/dev/null) || { echo "ERROR: '$1' is not an issue ID (expected e.g. BF-123)" >&2; return 1; }
  while IFS= read -r f; do
    if names_issue "$f" "$id"; then printf '%s' "$f"; return 0; fi
  done < <(all_markers)
  return 0
}
marker_for() { # <ISSUE-ID or `solo` as typed> → the marker it names, or "" when there is none; returns 1 on a malformed ID
  if [ "$(lower "$1")" = "solo" ]; then
    if [ -s "$main_checkout/tmp/fleet-sequence-solo.json" ]; then printf '%s' "$main_checkout/tmp/fleet-sequence-solo.json"; fi
    return 0
  fi
  marker_naming "$1"
}
is_drain() { [ "$(jq -r '.drain // false' "$1" 2>/dev/null)" = "true" ]; } # <marker>
seq_label() { # <marker> → how a message names it: the queue, or `solo drain` with what it has taken so far
  jq -r '((.queue // []) | join(" → ")) as $q
    | if .drain == true then "solo drain" + (if $q == "" then "" else " (" + $q + ")" end) else $q end' "$1"
}
in_flight_entries() { # <marker> → "<ID>\t<session>\t<started>" per recorded session still working, or shipped with its landing unrecorded
  local id sid since
  while IFS=$'\t' read -r id sid since; do
    [ -n "$sid" ] || continue
    if registry_alive "$sid" || [ "$(ledger_outcome "$sid" "$id" "$since")" = "shipped" ]; then printf '%s\t%s\t%s\n' "$id" "$sid" "$since"; fi
  done < <(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome != "shipped" and (.value.session // "") != "") | [.key, .value.session, (.value.started_epoch // 0)] | @tsv' "$1")
  return 0
}

# ---- the probe /auto's targeted mode runs ----
probe_issue() { # <ISSUE-ID> — prints why the issue cannot ship and returns 1; silent and 0 when it can
  local id="$1" json labels state
  json=$(linear-cli issues get "$id" -o json 2>/dev/null) || { echo "could not read $id from Linear (linear-cli issues get failed)"; return 1; }
  labels=$(printf '%s' "$json" | jq -r '.labels.nodes[].name' 2>/dev/null || true)
  state=$(printf '%s' "$json" | jq -r '.state.name // ""' 2>/dev/null || true)
  printf '%s\n' "$labels" | grep -qix specified || { echo "$id is not certified (no specified label) — run /spec $id first"; return 1; }
  if printf '%s\n' "$labels" | grep -qix human; then echo "$id is human-owned work (human label) — no unattended mode can ship it"; return 1; fi
  if printf '%s\n' "$labels" | grep -qix hold; then echo "$id is on hold (hold label) — a person parked it; remove the label to release it"; return 1; fi
  case "$state" in
    Done|Canceled|Duplicate|"Ready For Release") echo "$id is already $state — nothing to ship"; return 1 ;;
  esac
  return 0
}

# ---- the drain's pool ----
solo_listing() { # <team> → "<ID>\t<title>" per workable solo issue, in running order; the lister's exit code when it could not be read
  local out rc=0
  out=$("${FLEET_SEQUENCE_LISTER:-$here/next-candidates.sh}" --team "$1" --label solo --limit 50 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; return "$rc"; fi
  printf '%s\n' "$out" | sed -n 's/^[0-9][0-9]*\. \*\*\([A-Za-z0-9]*-[0-9][0-9]*\)\*\*[^"]*"\(.*\)"$/\1'"$(printf '\t')"'\2/p' | awk -F'\t' '!seen[$1]++'
}
drain_next() { # <team> → the first listed issue this run has not taken, or nothing when none is left; 1 when the listing stays unreadable
  local listing try=1 ids_json
  until listing=$(solo_listing "$1"); do
    [ "$try" -lt "$list_retries" ] || return 1
    logln "the solo listing could not be read (try $try of $list_retries, above) — again in ${list_wait}s" >&2
    try=$((try+1)); sleep "$list_wait"
  done
  ids_json=$(printf '%s\n' "$listing" | cut -f1 | jq -R . | jq -sc 'map(select(length > 0))')
  update_marker --argjson l "$ids_json" '(.issues // {}) as $seen | .plan = [$l[] | select(. as $x | $seen | has($x) | not)]'
  jq -r '.plan[0] // empty' "$marker"
}
print_plan() { # <listing> — the running order, each issue probed the way its dispatch will be
  local k=0 id title reason
  while IFS=$'\t' read -r id title; do
    [ -n "$id" ] || continue
    k=$((k+1))
    if reason=$(probe_issue "$id"); then printf '  %s. %s — %s\n' "$k" "$id" "$title"
    else printf '  %s. %s — %s  [will be skipped: %s]\n' "$k" "$id" "$title" "$reason"; fi
  done <<< "$1"
  return 0
}

# ---- session registry ----
registry_json() {
  local j
  j=$(claude agents --json --all 2>/dev/null || true)
  printf '%s' "$j" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$j"
}
# The row `claude stop` leaves behind keeps its state and loses its `status` and `pid` keys (fleet-status.sh
# registry_row has the measurements); it prints as `stopped` here so every caller's terminal test sees it.
registry_state() { # <short id> → prints "" (absent), "done", or the listed state; returns 2 when no registry
  local j
  j=$(registry_json) || return 2
  printf '%s' "$j" | jq -r --arg k "$1" '
    any(.[]; has("status")) as $carries_status
    | map(select((.id // (.sessionId // "" | split("-")[0])) == $k))
    | if length == 0 then ""
      elif ((.[0].state // "running") | IN("done","failed","stopped")) then (.[0].state)
      elif $carries_status and ((.[0] | has("status")) | not) and ((.[0] | has("pid")) | not) then "stopped"
      else (.[0].state // "running") end'
}
registry_alive() { # <short id> — listed and not ended
  local st
  st=$(registry_state "$1") || return 1
  case "$st" in ""|done|failed|stopped) return 1 ;; esac
  return 0
}

# ---- ledger ----
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
ledger_outcome() { # <short id> <ISSUE-ID> [since epoch] → shipped|canceled|skipped|failed|unknown
  local sid="$1" id="$2" since="${3:-0}" f list
  f="$main_checkout/tmp/auto-state-$sid.json"
  if [ ! -f "$f" ]; then
    # The ledger key is the session's short id; when it is not (an older harness keying on pid), take the
    # newest ledger that records this issue — written since this dispatch, or a previous run's ledger
    # naming the same issue would read as this session's outcome before it has done anything.
    f=$(grep -l -- "\"$id\"" "$main_checkout"/tmp/auto-state-*.json 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    [ -n "$f" ] && [ -f "$f" ] || { echo unknown; return; }
    [ "$(mtime_of "$f")" -ge "$since" ] || { echo unknown; return; }
  fi
  for list in shipped canceled skipped failed; do
    if jq -e --arg id "$id" ".$list // [] | index(\$id) != null" "$f" >/dev/null 2>&1; then echo "$list"; return; fi
  done
  echo unknown
}

# ---- dispatch ----
parse_sid() { # <claude --bg output> → the short id, or ""
  # With -n the first line is `backgrounded · <id> · <name>`, so the id is the first 8-hex token,
  # never the last field; the attach line is the fallback.
  local plain sid
  plain=$(printf '%s\n' "$1" | sed "s/$(printf '\033')\[[0-9;]*m//g")
  sid=$(printf '%s\n' "$plain" | awk '/^backgrounded/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) {print $i; exit}; exit}')
  [[ "$sid" =~ ^[0-9a-f]{8}$ ]] || sid=$(printf '%s\n' "$plain" | awk '/claude attach/ {print $3; exit}')
  [[ "$sid" =~ ^[0-9a-f]{8}$ ]] && printf '%s' "$sid"
  return 0
}

last_state="" # what the registry last listed for the session being waited on; a timeout and a missing ledger name it
note_state() { # <ISSUE-ID> <short id> <state> — the transitions a human reading the log needs to see
  case "$3" in
    idle) logln "$1: session $2 is idle — its turn ended without a ledger (an API error kills a turn this way); hooks/auto-rewake.sh retries a one-shot /auto session every ~15 min for up to six hours, so waiting" ;;
    blocked) logln "$1: session $2 is blocked — waiting on a decision only a human can give (claude attach $2)" ;;
    *) [ -z "$last_state" ] || logln "$1: session $2 is $3 again" ;;
  esac
}
timeout_reason() { # <short id> <seconds> — the state the registry last showed decides what the human does next
  case "$last_state" in
    idle) echo "session $1 still idle after ${2}s — its turn ended without a ledger and no rewake followed (hooks/auto-rewake.sh gives up after six hours of retries, and stands down on a non-transient error or a human prompt); claude attach $1 and prompt it forward" ;;
    blocked) echo "session $1 still blocked after ${2}s — waiting on a decision only a human can give; claude attach $1" ;;
    *) echo "session $1 still ${last_state:-running} after ${2}s" ;;
  esac
}

wait_session() { # <short id> <timeout seconds> <ISSUE-ID> <since epoch> → 0 when the work has ended, 1 on timeout
  local sid="$1" limit="$2" id="$3" since="$4" waited=0 seen=0 st rc step
  step=$(( poll > 0 ? poll : 1 ))
  last_state=""
  while :; do
    # The ledger is /auto Step 4's LAST act — Linear comment, label, ownership release, then the state
    # file — so an outcome recorded for this issue means the work is over whatever the registry says.
    # Measured 2026-09-10: a session sat "busy" in the registry for 7h after its ledger said shipped, and
    # a registry-only wait burned the whole 6h timeout and failed the sequence with the work already landed.
    if [ "$(ledger_outcome "$sid" "$id" "$since")" != "unknown" ]; then sleep "$poll"; return 0; fi
    rc=0; st=$(registry_state "$sid") || rc=$?
    if [ "$rc" -ne 2 ]; then
      # A session that ends without a ledger (crashed, refused, stopped from `claude agents`) still ends: registry
      # done, failed or stopped, or absent after it was seen (or after the grace when it was never seen). Any other
      # listed state — working, idle, blocked — is a session still there to wait on.
      case "$st" in
        # An ended listing is held to the same bar as an absent one: the session was seen live, or the grace has
        # passed. 2026-11-11: BF-3016's session read ended in the second it was dispatched, the drain recorded
        # `unknown` and dispatched the next solo issue, and the two ran side by side for hours.
        done|failed|stopped)
          if [ "$seen" -eq 1 ] || [ "$waited" -ge "$grace" ]; then last_state="$st"; return 0; fi
          [ "$st" = "$last_state" ] || logln "$id: the registry lists session $sid as $st before it was ever listed live — not taken as its end until ${grace}s have passed"
          last_state="$st" ;;
        "") if [ "$seen" -eq 1 ] || [ "$waited" -ge "$grace" ]; then return 0; fi ;;
        *) seen=1; [ "$st" = "$last_state" ] || note_state "$id" "$sid" "$st"; last_state="$st" ;;
      esac
    fi
    [ "$waited" -ge "$limit" ] && return 1
    sleep "$poll"; waited=$((waited + step))
  done
}

wait_session_end() { # <short id> <timeout seconds> → 0 when the registry lists the session ended or drops it, 1 on timeout
  local sid="$1" limit="$2" waited=0 seen=0 st rc step
  step=$(( poll > 0 ? poll : 1 ))
  while :; do
    rc=0; st=$(registry_state "$sid") || rc=$?
    if [ "$rc" -eq 2 ]; then [ "$waited" -ge "$grace" ] && return 0
    else
      case "$st" in
        done|failed|stopped|"") if [ "$seen" -eq 1 ] || [ "$waited" -ge "$grace" ]; then return 0; fi ;;
        *) seen=1 ;;
      esac
    fi
    [ "$waited" -ge "$limit" ] && return 1
    sleep "$poll"; waited=$((waited + step))
  done
}

# ---- the main checkout's position ----
target_branch() { jq -r 'if .mode == "merge" then .base else .branch end' "$marker"; }

fork_key() { printf 'start.%s.wt-source-branch' "$(lower "$1")"; } # <ISSUE-ID> → the per-issue key start-wt-setup.sh reads first

clear_fork_keys() { # unset every per-issue key this run's queue could have set — best-effort, on every runner exit
  local id
  [ -s "$marker" ] || return 0
  for id in $(jq -r '(.queue // [])[]' "$marker" 2>/dev/null); do
    git -C "$main_checkout" config --unset "$(fork_key "$id")" >/dev/null 2>&1 || true
  done
}

set_fork_key() { # <ISSUE-ID> — point this one issue's /start wt at the branch it forks from and merges into
  local branch
  branch=$(target_branch)
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || fail_run "branch '$branch' no longer exists — nothing to ship $1 onto; re-run once it is restored"
  git config "$(fork_key "$1")" "$branch" || fail_run "could not set $(fork_key "$1") before $1"
}

remove_pr_worktree() { # the throwaway /pr-update worktree; a fixed path under tmp/, so the rm is bounded
  git -C "$main_checkout" worktree remove --force "$pr_wt" >/dev/null 2>&1 || true
  rm -rf "$pr_wt"
  git -C "$main_checkout" worktree prune >/dev/null 2>&1 || true
}

wait_for_landing() { # <ISSUE-ID> <tip before dispatch> → 0 once the target branch's tip has moved and the merge queue no
  # longer holds the issue, 1 on timeout. A moved tip alone is not this issue's landing once anything else can move it — a
  # resume runs after the human has often committed to the branch — and the drainer removes the queue marker only when it lands.
  local id="$1" before="$2" branch waited=0 step queued
  branch=$(target_branch); step=$(( poll > 0 ? poll : 1 ))
  queued="$main_checkout/.claude/merge-queue/$(lower "$id").json"
  while [ "$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" = "$before" ] || [ -f "$queued" ]; do
    [ "$waited" -ge "$merge_timeout" ] && return 1
    if [ "$waited" -eq 0 ]; then
      if [ -f "$queued" ]; then
        logln "$id: ledger says shipped and its merge is queued (.claude/merge-queue) — waiting up to ${merge_timeout}s for the drainer"
      else
        logln "$id: ledger says shipped but '$branch' has not moved — waiting up to ${merge_timeout}s for the merge to land"
      fi
    fi
    sleep "$poll"; waited=$((waited + step))
  done
  return 0
}

record_landing() { # <progress label> <ISSUE-ID> <tip before dispatch> — after wait_for_landing; reads the run loop's target and mode
  local tag="$1" id="$2" before="$3" after count
  after=$(git rev-parse --verify --quiet "refs/heads/$target")
  update_marker --arg id "$id" --arg a "$after" '.issues[$id].landed_sha = $a'
  count=$(git rev-list --count "$before..$after" 2>/dev/null || echo "?")
  logln "$tag $id landed on $target at ${after:0:12} ($count commit(s))"
  # No -q: grep would exit on the first match, git log (which flushes per commit) would die of SIGPIPE writing the
  # next subject, and pipefail would fail the pipeline — a WARN on a landing whose newest commit names the issue.
  git log --format=%s "$before..$after" 2>/dev/null | grep -i -- "$id" >/dev/null \
    || logln "WARN: none of the commits $target gained mention $id — check the session's log before trusting the ship"
  [ "$mode" = "merge" ] || push_branch "$target"
}

push_branch() { # <branch> — best-effort after each ship; the PR step pushes again and fails loudly
  git remote get-url origin >/dev/null 2>&1 || return 0
  if git push -q -u origin "$1" >/dev/null 2>&1; then logln "pushed $1 to origin"
  else logln "WARN: could not push $1 to origin — retried when the PR opens"; fi
}

open_sequence_pr() { # push, open or find the PR from the branch onto the base, then /pr-update as the last child
  local branch base out url number created behind sid ids
  branch=$(jq -r '.branch' "$marker"); base=$(jq -r '.base' "$marker")
  ids=$(jq -r '([.queue[] as $q | select(.issues[$q].outcome == "shipped") | $q]
                + [(.issues | to_entries[] | select(.value.outcome == "shipped") | .key) as $k | select((.queue | index($k)) == null) | $k]) | join(" ")' "$marker")
  # shellcheck disable=SC2086
  if ! out=$("$here/integration-pr.sh" "$branch" "$base" $ids 2>&1); then
    printf '%s\n' "$out"
    fail_run "every issue shipped onto $branch but its PR onto $base could not be opened (see above) — fix and re-run the same list: the ships are kept, only the PR step repeats"
  fi
  printf '%s\n' "$out" | grep -v '^\(PR_URL\|PR_NUMBER\|CREATED\|BEHIND\)=' || true
  url=$(printf '%s\n' "$out" | sed -n 's/^PR_URL=//p'); number=$(printf '%s\n' "$out" | sed -n 's/^PR_NUMBER=//p')
  created=$(printf '%s\n' "$out" | sed -n 's/^CREATED=//p'); behind=$(printf '%s\n' "$out" | sed -n 's/^BEHIND=//p')
  update_marker --arg u "$url" --argjson n "${number:-0}" '.pr_url = $u | .pr_number = $n'
  if [ "$created" = "1" ]; then logln "PR #$number opened: $url ($branch → $base)"; else logln "PR #$number already open: $url ($branch → $base)"; fi
  case "$behind" in ""|0|"?") ;; *) logln "NOTE: $base has $behind commit(s) the branch lacks — one catch-up merge (Update branch on the PR) before it merges" ;; esac

  [ "${FLEET_SEQUENCE_PR_UPDATE:-1}" = "1" ] || return 0
  # /pr-update reads the current branch, so it runs from a throwaway worktree on the branch — never by
  # switching the main checkout, which stays wherever the human left it. The worktree lives under tmp/
  # (gitignored, and outside .claude/worktrees so the reaper never sees it); a leftover is replaced.
  remove_pr_worktree
  git worktree add -q "$pr_wt" "$branch" >/dev/null 2>&1 \
    || { logln "WARN: could not add a worktree on $branch at $pr_wt for /pr-update — run it by hand from the branch"; return 0; }
  logln "dispatching: claude --bg ${claude_args[*]} -n 'fleet-sequence pr-update' '/pr-update'  (from $pr_wt on $branch — the title and body come from the diff)"
  if ! out=$(cd "$pr_wt" && claude --bg "${claude_args[@]}" -n "fleet-sequence pr-update" "/pr-update" 2>&1); then
    printf '%s\n' "$out"; logln "WARN: /pr-update dispatch failed — run it by hand from $branch"; remove_pr_worktree; return 0
  fi
  printf '%s\n' "$out"
  sid=$(parse_sid "$out")
  [ -n "$sid" ] || { logln "WARN: could not read the /pr-update session id — run /pr-update by hand from $branch once it ends; its worktree $pr_wt is left for it"; return 0; }
  update_marker --arg s "$sid" '.pr_update_session = $s'
  if wait_session_end "$sid" "$pr_update_timeout"; then
    remove_pr_worktree
  else
    logln "WARN: /pr-update session $sid still running after ${pr_update_timeout}s — not killed; its worktree $pr_wt is left in place (git worktree remove --force $pr_wt once it ends)"
  fi
}

# =====================================================================================
cmd_status() { # [<ISSUE-ID>] — that issue's sequence; without one, every running sequence, else the latest
  local f n=0 shown=() rest=""
  if [ -n "${1:-}" ]; then
    f=$(marker_for "$1") || exit 1
    [ -n "$f" ] || { echo "No sequence here names $1 — nothing launched for it from $main_checkout."; exit 0; }
    shown=("$f")
  else
    while IFS= read -r f; do
      if runner_alive "$f"; then shown+=("$f"); fi
    done < <(all_markers)
    if [ ${#shown[@]} -eq 0 ]; then
      f=""; IFS= read -r f < <(all_markers) || true
      [ -n "$f" ] || { echo "No sequence marker under $main_checkout/tmp — nothing launched here."; exit 0; }
      shown=("$f")
    fi
  fi
  for f in "${shown[@]}"; do
    [ "$n" -eq 0 ] || printf '\n---\n\n'
    use_sequence "$(slug_of "$f")"; print_status; n=$((n+1))
  done
  while IFS= read -r f; do
    case " ${shown[*]} " in *" $f "*) ;; *) rest="$rest, $(seq_label "$f") ($(jq -r '.status' "$f"))" ;; esac
  done < <(all_markers)
  [ -z "$rest" ] || printf '\n**Other sequences here:** %s — `fleet-sequence.sh status <ISSUE-ID>` reads one (`status solo` the drain).\n' "${rest#, }"
  return 0
}

print_status() { # the readout of the sequence use_sequence selected
  local status base mode branch queue runner_pid runner live id sid st outcome landed pr_url ahead behind keys k drain=0 plan fleet_exit
  status=$(jq -r '.status' "$marker"); base=$(jq -r '.base' "$marker"); mode=$(jq -r '.mode // "pr"' "$marker")
  branch=$(jq -r '.branch // ""' "$marker"); pr_url=$(jq -r '.pr_url // ""' "$marker")
  queue=$(jq -r '.queue | join(" → ")' "$marker")
  runner_pid=$(jq -r '.runner_pid // empty' "$marker")
  runner="not detached"
  if [ -n "$runner_pid" ]; then
    if kill -0 "$runner_pid" 2>/dev/null; then runner="alive (pid $runner_pid)"; else runner="gone (pid $runner_pid)"; fi
  fi
  if is_drain "$marker"; then drain=1; printf '**Solo drain:** %s · **mode:** %s' "${queue:-nothing dispatched yet}" "$mode"
  else printf '**Sequence:** %s · **mode:** %s' "$queue" "$mode"; fi
  if [ "$mode" = "merge" ]; then printf ' · **merges into:** `%s`' "$base"; else printf ' · **branch:** `%s` → `%s`' "$branch" "$base"; fi
  printf ' · **status:** %s · **runner:** %s' "$status" "$runner"
  [ "$(jq -r '.stop_requested' "$marker")" = "true" ] && printf ' · **stop requested**'
  printf '\n'
  [ "$(jq -r '.reason // ""' "$marker")" != "" ] && printf '**Reason:** %s\n' "$(jq -r '.reason' "$marker")"
  if [ "$drain" = 1 ]; then
    plan=$(jq -r '((.plan // []) - (.queue // [])) | join(", ")' "$marker")
    if [ "$status" = "running" ] && [ -n "$plan" ]; then printf '**Up next** (as last listed; read again before each dispatch): %s\n' "$plan"; fi
    if [ "$(jq -r '.deadline // ""' "$marker")" != "" ]; then printf '**Budget:** nothing new starts after %s\n' "$(jq -r '.deadline' "$marker")"; fi
    if [ "$(jq -r '.then_fleet != null' "$marker")" = "true" ]; then
      fleet_exit=$(jq -r '.fleet.exit // empty' "$marker")
      case "$fleet_exit" in
        "") if [ "$status" = "running" ]; then k="launches when the drain ends clean"; else k="not launched"; fi ;;
        0) k="launched — /fleet-status reads it" ;;
        *) k="did NOT launch (fleet-launch.sh exit $fleet_exit — see the log)" ;;
      esac
      printf '**Then:** `fleet-launch.sh %s` — %s\n' "$(jq -r '.then_fleet | join(" ")' "$marker")" "$k"
    fi
  fi
  keys=""
  for id in $(jq -r '.queue[]' "$marker"); do
    k=$(git -C "$main_checkout" config --get "$(fork_key "$id")" 2>/dev/null || true)
    [ -z "$k" ] || keys="$keys, $(lower "$id") → $k"
  done
  keys="${keys#, }"
  [ -n "$keys" ] && printf '**Fork key:** %s (per-issue `start.<id>.wt-source-branch` — only that issue'"'"'s /start wt reads it; the main checkout is not moved)\n' "$keys"
  if [ "$mode" != "merge" ]; then
    if [ -n "$pr_url" ]; then printf '**PR:** %s\n' "$pr_url"; else printf '**PR:** not opened yet (opens when the last issue ships)\n'; fi
  fi
  [ -z "$queue" ] || printf '\n| issue | session | liveness | outcome | landed |\n|---|---|---|---|---|\n'
  for id in $(jq -r '.queue[]' "$marker"); do
    sid=$(jq -r --arg id "$id" '.issues[$id].session // ""' "$marker")
    outcome=$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")
    landed=$(jq -r --arg id "$id" '.issues[$id].landed_sha // "" | .[0:12]' "$marker")
    [ -n "$landed" ] || { [ -f "$main_checkout/.claude/merge-queue/$(lower "$id").json" ] && landed="queued"; }
    live="—"
    if [ -n "$sid" ]; then
      st=$(registry_state "$sid") || st="?"
      case "$st" in "") live="not listed" ;; "?") live="no registry" ;; *) live="$st" ;; esac
    fi
    if [ -z "$sid" ] && [ -z "$outcome" ]; then outcome="queued"; fi
    printf '| %s | %s | %s | %s | %s |\n' "$id" "${sid:-—}" "$live" "${outcome:-in flight}" "${landed:-—}"
  done
  if [ "$mode" != "merge" ] && [ -n "$branch" ] && git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    ahead=$(git -C "$main_checkout" rev-list --count "$base..$branch" 2>/dev/null || echo "?")
    behind=$(git -C "$main_checkout" rev-list --count "$branch..$base" 2>/dev/null || echo "?")
    printf '\n**Branch:** `%s` is %s commit(s) ahead of `%s`, %s behind' "$branch" "$ahead" "$base" "$behind"
    [ "$behind" = "0" ] || printf ' — one catch-up merge (Update branch on the PR) before it merges'
    printf '\n'
  fi
  [ -f "$log" ] && { printf '\n**Log** (`%s`, last 5 lines):\n\n```\n' "$log"; tail -5 "$log"; printf '```\n'; }
  return 0
}

cmd_stop() { # [<ISSUE-ID>] — needed only to choose among several running sequences
  local f latest="" running=()
  if [ -n "${1:-}" ]; then
    f=$(marker_for "$1") || exit 1
    [ -n "$f" ] || { echo "No sequence here names $1 — nothing to stop."; exit 0; }
    latest="$f"
    if [ "$(jq -r '.status' "$f")" = "running" ]; then running=("$f"); fi
  else
    while IFS= read -r f; do
      [ -n "$latest" ] || latest="$f"
      if [ "$(jq -r '.status' "$f")" = "running" ]; then running+=("$f"); fi
    done < <(all_markers)
    [ -n "$latest" ] || { echo "No sequence marker under $main_checkout/tmp — nothing to stop."; exit 0; }
  fi
  if [ ${#running[@]} -eq 0 ]; then echo "Sequence is already $(jq -r '.status' "$latest") — nothing to stop."; exit 0; fi
  if [ ${#running[@]} -gt 1 ]; then
    echo "ERROR: ${#running[@]} sequences are running — name an issue of the one to stop (or \`solo\` for the drain): fleet-sequence.sh stop <ISSUE-ID>" >&2
    for f in "${running[@]}"; do echo "       $(seq_label "$f")" >&2; done
    exit 1
  fi
  use_sequence "$(slug_of "${running[0]}")"
  update_marker '.stop_requested = true'
  if is_drain "$marker"; then
    echo "Stop requested for the $(seq_label "$marker"): the runner finishes the issue in flight, then stops; what shipped stays merged and no fleet is launched."
    echo "Nothing is killed — to abort the in-flight session use \`claude agents\`. Re-run the drain to continue."
    return 0
  fi
  echo "Stop requested for $(jq -r '.queue | join(" → ")' "$marker"): the runner finishes the issue in flight, then stops; what shipped stays on the branch and no PR is opened."
  echo "Nothing is killed — to abort the in-flight session use \`claude agents\`. Re-run the same list to continue and open the PR."
}

# =====================================================================================
fail_run() { # <reason> — record the failure and exit 1
  logln "FAILED: $1"
  update_marker --arg r "$1" '.status = "failed" | .reason = $r | .current = null'
  exit 1
}
on_exit_run() {
  local rc=$?
  clear_fork_keys
  if [ -s "$marker" ] && [ "$(jq -r '.status' "$marker")" = "running" ]; then
    update_marker --arg r "runner exited unexpectedly (exit $rc) — see $log" '.status = "failed" | .reason = $r | .current = null'
  fi
}

launch_fleet() { # the hand-off a clean drain owes its launch: fleet-launch.sh with the tokens `then-fleet` carried
  local a rc=0 summary
  local args=()
  summary=$(jq -r '.reason' "$marker")
  while IFS= read -r a; do args+=("$a"); done < <(jq -r '(.then_fleet // [])[]' "$marker")
  if [ "$(jq -r '(.fleet_claude_args // []) | length' "$marker")" -gt 0 ]; then
    args+=(--)
    while IFS= read -r a; do args+=("$a"); done < <(jq -r '.fleet_claude_args[]' "$marker")
  fi
  logln "then-fleet: fleet-launch.sh ${args[*]}"
  "${FLEET_SEQUENCE_FLEET_LAUNCHER:-$here/fleet-launch.sh}" "${args[@]}" || rc=$?
  update_marker --argjson rc "$rc" --argjson now "$(date +%s)" '.fleet = {exit: $rc, epoch: $now}'
  [ "$rc" -eq 0 ] || fail_run "the drain finished but the fleet did not launch (fleet-launch.sh exit $rc — its refusal is above in $log); launch it by hand. The drain: $summary"
  logln "then-fleet: launched — /fleet-status reads it"
}

finish_drain() { # <drained|deadline|fails|stop> — the drain's closing record, then the fleet when its launch named one and it ended clean
  local why="$1" base summary reason fleet_note=""
  base=$(jq -r '.base' "$marker")
  summary=$(jq -r --arg b "$base" '
    [.queue[] as $q | select(.issues[$q].outcome == "shipped") | $q] as $ok
    | [.queue[] as $q | select(.issues[$q].outcome != "shipped") | "\($q) (\(.issues[$q].outcome // "no outcome"))"] as $no
    | "shipped into \($b): " + (if ($ok | length) > 0 then ($ok | join(", ")) else "none" end)
      + (if ($no | length) > 0 then "; not shipped: " + ($no | join(", ")) else "" end)' "$marker")
  [ "$(jq -r '.then_fleet != null' "$marker")" != "true" ] || fleet_note="; the fleet was not launched"
  case "$why" in
    stop)
      logln "STOPPED: $summary$fleet_note — re-run the drain to continue"
      update_marker --arg r "stopped — $summary$fleet_note; re-run the drain to continue" '.status = "stopped" | .reason = $r'
      exit 0 ;;
    fails)
      fail_run "$drain_max_fails issues in a row ended without shipping — a pattern the next one would repeat (a broken base, an outage), so the drain stopped$fleet_note. $summary" ;;
    deadline) reason="out of time, so nothing new was started — $summary" ;;
    *) reason="drained, no workable solo issue is left — $summary" ;;
  esac
  update_marker --arg r "$reason" '.status = "done" | .reason = $r'
  clear_fork_keys
  logln "done: $reason"
  [ -n "$fleet_note" ] || return 0
  launch_fleet
}

cmd_run() { # [<slug>] — the launch passes it to the detached runner; a foreground launch has already selected the sequence
  [ -z "${1:-}" ] || use_sequence "$1"
  [ -s "$marker" ] || { echo "ERROR: no marker at ${marker:-tmp/fleet-sequence-<slug>.json} — the runner only runs under a launch" >&2; exit 1; }
  cd "$main_checkout"
  trap on_exit_run EXIT
  local base mode target ids_csv id sid out outcome remaining now started before dirty current tag reason
  local drain=0 team="" deadline="" fails=0 ended="" fresh listed rerun="re-run the same list"
  local queue=()
  base=$(jq -r '.base' "$marker"); mode=$(jq -r '.mode' "$marker"); target=$(target_branch)
  while IFS= read -r id; do queue+=("$id"); done < <(jq -r '.queue[]' "$marker")
  while IFS= read -r out; do claude_args+=("$out"); done < <(jq -r '.claude_args[]' "$marker")
  ids_csv=$(jq -r '.queue | join(", ")' "$marker")
  if is_drain "$marker"; then
    drain=1; rerun="re-run the drain"
    team=$(jq -r '.team // ""' "$marker"); deadline=$(jq -r '.deadline_epoch // empty' "$marker")
    logln "solo drain started: the workable solo issues in $team, one at a time into $base${deadline:+ — nothing new starts after $(jq -r '.deadline' "$marker")}; runner pid $$"
  elif [ "$mode" = "merge" ]; then logln "sequence started: $ids_csv merging into $base; runner pid $$"
  else logln "sequence started: $ids_csv onto $target (forked from $base); runner pid $$"; fi

  local i=0
  while :; do
    fresh=0
    if [ "$i" -lt "${#queue[@]}" ]; then
      id="${queue[$i]}"
    elif [ "$drain" = 1 ]; then
      # A drain's queue is what it has taken so far. The next issue comes from a fresh listing, and only while the run
      # may still start one.
      if [ "$(jq -r '.stop_requested' "$marker")" = "true" ]; then ended=stop; break; fi
      if [ "$fails" -ge "$drain_max_fails" ]; then ended=fails; break; fi
      if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then ended=deadline; break; fi
      id=$(drain_next "$team") || fail_run "the solo listing could not be read in $list_retries tries (above in $log) — nothing more was dispatched; $rerun once Linear answers"
      if [ -z "$id" ]; then ended=drained; break; fi
      queue+=("$id"); fresh=1
      update_marker --arg id "$id" '.queue += [$id]'
    else
      break
    fi
    i=$((i+1))
    tag="[$i/${#queue[@]}]"
    if [ "$drain" = 1 ]; then tag="[$i]"; fi
    if [ "$fresh" = 1 ] && ! reason=$(probe_issue "$id"); then
      logln "$tag $id not dispatched — $reason"
      update_marker --arg id "$id" --arg r "$reason" --argjson now "$(date +%s)" '.issues[$id] = {outcome: "refused", reason: $r, ended_epoch: $now}'
      continue
    fi
    if [ "$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")" = "shipped" ]; then
      if [ -n "$(jq -r --arg id "$id" '.issues[$id].landed_sha // ""' "$marker")" ]; then
        logln "$tag $id already shipped (landed $(jq -r --arg id "$id" '.issues[$id].landed_sha | .[0:12]' "$marker")) — skipping"
        continue
      fi
      # Shipped but never landed: an earlier run timed out on its deferred merge. Skipping it would fork the next issue
      # from a tip without it, so wait for the landing here exactly as the run that dispatched it would have.
      before=$(jq -r --arg id "$id" '.issues[$id].tip_before // ""' "$marker")
      logln "$tag $id shipped but its landing was never recorded — waiting for it before the next issue forks"
      wait_for_landing "$id" "$before" \
        || fail_run "$id: shipped but still not landed on '$target' within ${merge_timeout}s — its merge is queued (/merge-queue) or never merged; land it, then $rerun"
      record_landing "$tag" "$id" "$before"
      continue
    fi
    if [ "$drain" = 0 ] && [ "$(jq -r '.stop_requested' "$marker")" = "true" ]; then
      remaining=$(printf '%s\n' "${queue[@]:$((i-1))}" | paste -sd, - | sed 's/,/, /g')
      logln "STOPPED: stopped before $id; not started: $remaining — re-run the same list to continue"
      update_marker --arg r "stopped before $id; not started: $remaining — re-run the same list to continue" '.status = "stopped" | .reason = $r | .current = null'
      exit 0
    fi
    dirty=$(git status --porcelain 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    if [ -n "$dirty" ]; then
      current=$(git branch --show-current 2>/dev/null || true)
      carries_issue_id "$current" \
        && fail_run "main checkout is dirty on '$current' before $id — the branch name carries an issue ID, so $id's /auto would refuse that dirt or finish it as its own work; commit or stash it, then $rerun"
      logln "$tag NOTE: main checkout is dirty before $id ($dirty) — $id's /auto picks past it; a merge that changes one of those paths defers to the queue"
    fi

    # The launch carries a non-shipped entry only for a session it found still working (or shipped with its
    # landing unrecorded), so a session recorded here is one to wait on — dispatching again would start a
    # second /auto on an issue already in flight.
    sid=$(jq -r --arg id "$id" '.issues[$id].session // ""' "$marker")
    if [ -n "$sid" ]; then
      started=$(jq -r --arg id "$id" '.issues[$id].started_epoch // 0' "$marker")
      before=$(jq -r --arg id "$id" '.issues[$id].tip_before // ""' "$marker")
      update_marker --arg id "$id" '.current = $id'
      logln "$tag $id was dispatched by an earlier run of this sequence (session $sid) — waiting on that session, not dispatching again"
    else
      set_fork_key "$id"
      before=$(git rev-parse --verify --quiet "refs/heads/$target")
      started=$(date +%s)
      update_marker --arg id "$id" --argjson now "$started" --arg b "$before" \
        '.current = $id | .issues[$id] = {started_epoch: $now, tip_before: $b}'
      logln "$tag dispatching: claude --bg ${claude_args[*]} -n 'fleet-sequence $id' '/auto $id'  (forks from $target at ${before:0:12})"
      if ! out=$(claude --bg "${claude_args[@]}" -n "fleet-sequence $id" "/auto $id" 2>&1); then
        printf '%s\n' "$out"
        fail_run "dispatch of $id failed — see the claude output above in $log"
      fi
      printf '%s\n' "$out"
      sid=$(parse_sid "$out")
      [ -n "$sid" ] || fail_run "could not read the session id from the claude --bg output for $id — cannot wait on an unknown session; find it in \`claude agents\`, let it finish, then $rerun"
      update_marker --arg id "$id" --arg s "$sid" '.issues[$id].session = $s'
      logln "$tag $id running in session $sid"
    fi
    if ! wait_session "$sid" "$issue_timeout" "$id" "$started"; then
      fail_run "$id: $(timeout_reason "$sid" "$issue_timeout") — not killed; watch it in \`claude agents\`, then $rerun"
    fi
    # The key has done its job once the session has ended — its /start wt ran at the very start.
    git config --unset "$(fork_key "$id")" >/dev/null 2>&1 || true
    outcome=$(ledger_outcome "$sid" "$id" "$started")
    now=$(date +%s)
    update_marker --arg id "$id" --arg o "$outcome" --argjson now "$now" '.issues[$id] += {outcome: $o, ended_epoch: $now}'
    logln "$tag $id → $outcome (session $sid)"
    if [ "$outcome" != "shipped" ]; then
      if [ "$drain" = 1 ]; then
        # Solo issues do not build on each other, so a session that ended without shipping costs the drain that one
        # issue. `skipped` and `canceled` are /auto declining the issue, not failing at it, and leave the count alone.
        case "$outcome" in failed|unknown) fails=$((fails+1)) ;; esac
        listed=""
        if [ "$outcome" = "unknown" ] && [ -n "$last_state" ]; then listed=" (the registry last listed session $sid as $last_state)"; fi
        logln "$tag $id did not ship$listed — claude logs $sid; /auto's Linear comment names the cause. Moving on"
        continue
      fi
      remaining=$(printf '%s\n' "${queue[@]:$i}" | paste -sd, - | sed 's/,/, /g')
      case "$outcome:$last_state" in
        unknown:failed|unknown:stopped)
          fail_run "$id ended without a ledger — the registry lists session $sid as $last_state (claude logs $sid) — not started: ${remaining:-none}. Fix or drop it, then re-run the same list" ;;
      esac
      fail_run "$id ended '$outcome' in session $sid (claude logs $sid; /auto's Linear comment names the cause) — not started: ${remaining:-none}. Fix or drop it, then re-run the same list"
    fi
    fails=0

    # Shipped means merged: the branch the checkout is parked on must have moved. A deferred merge
    # (finish-merge.sh exit 3) lands later through the queue's drainer, so the wait is bounded, not skipped.
    wait_for_landing "$id" "$before" \
      || fail_run "$id: ledger says shipped but '$target' never moved within ${merge_timeout}s — a deferred merge (/merge-queue) or a ship that did not merge; land it, then $rerun"
    record_landing "$tag" "$id" "$before"
  done
  update_marker '.current = null'
  if [ "$drain" = 1 ]; then finish_drain "$ended"; return 0; fi
  [ "$mode" = "merge" ] || open_sequence_pr
  update_marker '.status = "done"'
  clear_fork_keys
  if [ "$mode" = "merge" ]; then
    logln "done: $ids_csv merged into $base — $(jq -r '[.queue[] as $q | "\($q) \(.issues[$q].landed_sha // "?" | .[0:12])"] | join(", ")' "$marker")"
  else
    logln "done: $ids_csv on $target → $base — PR $(jq -r '.pr_url // "?"' "$marker")"
  fi
}

start_runner() { # <slug> <pidfile> — the detached runner, in a session of its own
  # The harness starts every Bash tool command in a fresh process group, and a `nohup … &` child stays in that group after
  # the tool shell exits (measured 2026-09-22: the child's pgid was the tool shell's pid, the harness sat in another group).
  # That group is the harness's handle on what it spawned: runner 11121 died in the 2026-09-21 14:18 harness restart eight
  # minutes after launch, while its child session — which the harness itself resumes — worked on for eight hours with nobody
  # waiting. A fork that calls setsid() leaves the group and drops the controlling terminal, so neither a group kill nor a
  # terminal hangup reaches the runner; nohup stays on for a SIGHUP sent by name. python3 first, perl (shipped with macOS) next.
  local slug="$1" pidfile="$2" prog
  if command -v python3 >/dev/null 2>&1; then
    prog='import os, sys
script, sub, slug, pidfile = sys.argv[1:5]
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execv(script, [script, sub, slug])
with open(pidfile, "w") as f:
    f.write(str(pid))'
    ( cd "$main_checkout" && nohup python3 -c "$prog" "$here/fleet-sequence.sh" run "$slug" "$pidfile" >> "$log" 2>&1 < /dev/null ) || true
  elif command -v perl >/dev/null 2>&1; then
    prog='use POSIX qw(setsid); my ($s, $sub, $slug, $pf) = @ARGV; my $pid = fork(); die "fork: $!" unless defined $pid;
if ($pid == 0) { setsid(); exec($s, $sub, $slug) or die "exec: $!"; }
open(my $f, ">", $pf) or die "$pf: $!"; print $f $pid; close $f;'
    ( cd "$main_checkout" && nohup perl -e "$prog" -- "$here/fleet-sequence.sh" run "$slug" "$pidfile" >> "$log" 2>&1 < /dev/null ) || true
  else
    logln "WARN: neither python3 nor perl on PATH — the runner shares this shell's process group, and a harness restart ends it" >> "$log"
    ( cd "$main_checkout" && nohup "$here/fleet-sequence.sh" run "$slug" >> "$log" 2>&1 < /dev/null & echo $! > "$pidfile" ) || true
  fi
}

# =====================================================================================
# What a list launch and a drain launch both do before anything is dispatched or written. Each reads the caller's
# $mode and the selected $marker.
refuse_second_merge_runner() { # <launch branch> <what to do instead> — two merge-mode runners on one branch would each read the other's merge as its own landing
  local f
  [ "$mode" = "merge" ] || return 0
  while IFS= read -r f; do
    [ "$f" != "$marker" ] || continue
    if runner_alive "$f" && [ "$(jq -r '.mode // "pr"' "$f")" = "merge" ] && [ "$(jq -r '.base // ""' "$f")" = "$1" ]; then
      echo "ERROR: a merge-mode sequence is already merging into '$1' ($(seq_label "$f")) — each would read the other's merges as its own landings. $2" >&2
      exit 1
    fi
  done < <(all_markers)
}

preflight_dirt() { # <the checkout's branch, "" when detached>
  # Dirt is fatal only where /auto would attribute it: a targeted child refuses dirt it ties to another issue, and finishes
  # dirt it ties to its own target as its own work. Anything else it picks past, and finish-merge.sh fast-forwards around.
  local current="$1" dirty
  dirty=$(git -C "$main_checkout" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    if carries_issue_id "$current"; then
      echo "ERROR: main checkout is dirty on '$current', whose name carries an issue ID — each child's /auto would refuse that" >&2
      echo "       dirt, or finish it as its own work when the ID is its target." >&2
      printf '%s\n' "$dirty" | sed 's/^/       /' >&2
      echo "       Commit or stash the above, then re-run. Nothing was dispatched." >&2
      exit 1
    fi
    echo "WARN: main checkout is dirty on '${current:-(detached)}' — a merge that changes any of these paths defers to the" >&2
    echo "      merge queue until they are committed or discarded, and this runner waits on it; every other merge lands normally:" >&2
    printf '%s\n' "$dirty" | sed 's/^/       /' >&2
  fi
  return 0
}

preflight_tooling() { # <stale-ok: 0|1> — reads claude_args for an explicit --autocompact
  # Once, here: every child session is dispatched later by the detached runner, whose log nobody reads at launch.
  local fresh_rc=0 explicit_cap=0 a
  "$here/claude-freshness.sh" || fresh_rc=$?
  if [ "$fresh_rc" -eq 4 ]; then
    if [ "$1" = 1 ]; then
      echo "WARN: launching on the stale ~/.claude above (stale-ok) — every issue's session runs that tooling" >&2
    else
      echo "Nothing was dispatched or written. Run /update and re-launch, or re-run with 'stale-ok' to launch on this tooling." >&2
      exit 4
    fi
  fi

  # Same guard as fleet-launch.sh: no --autocompact default, so the loop-boundary mod must be enabled unless the
  # operator passed a cap of their own after --.
  for a in "${claude_args[@]}"; do case "$a" in --autocompact|--autocompact=*) explicit_cap=1 ;; esac; done
  if ! "$here/mod-enabled.sh" loop-boundary; then
    if [ "$explicit_cap" = 1 ]; then
      echo "WARN: launching without the loop-boundary mod — the explicit --autocompact after -- is the only compaction control these sessions have" >&2
    else
      echo "Nothing was dispatched or written. Install the mod (above), or pass an explicit --autocompact after -- to launch without it." >&2
      exit 5
    fi
  fi
}

have_flag() { # <flag> <args...>
  local f="$1"; shift
  local a
  for a in "$@"; do [[ "$a" == "$f" || "$a" == "$f="* ]] && return 0; done
  return 1
}
default_claude_args() { # add to claude_args whatever skills/auto/references/launch-prereqs.md requires and the operator did not pass
  have_flag --model "${claude_args[@]}" || claude_args+=(--model 'opus[1m]')
  have_flag --effort "${claude_args[@]}" || claude_args+=(--effort xhigh)
  if ! have_flag --permission-mode "${claude_args[@]}" && ! have_flag --dangerously-skip-permissions "${claude_args[@]}"; then
    claude_args+=(--permission-mode auto)
  fi
}

start_sequence() { # <slug> <keep the log: 0|1> — detach the runner for the marker just written; returns 1 when it ran inline instead (FLEET_SEQUENCE_FOREGROUND)
  local slug="$1" pidfile pid
  if [ "${FLEET_SEQUENCE_FOREGROUND:-0}" = "1" ]; then cmd_run; return 1; fi
  # A resume appends: the log it continues is the only record of why the earlier run stopped.
  [ "$2" -eq 1 ] || : > "$log"
  pidfile="$main_checkout/tmp/fleet-sequence-$slug.pid"
  start_runner "$slug" "$pidfile"
  pid=$(cat "$pidfile" 2>/dev/null || true); rm -f "$pidfile"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "ERROR: runner did not start — see $log" >&2; update_marker '.status = "failed" | .reason = "runner did not start"'; exit 1; }
  update_marker --argjson p "$pid" '.runner_pid = $p'
  echo "Runner detached (pid $pid) — log: $log"
}

cmd_launch() {
  local raw id norm prev current existing_issues tok mode="pr" mode_set="" branch="" resume=0 carried="" stale_ok=0 reason
  local ids=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; claude_args=("$@"); break ;;
      -*) echo "ERROR: unknown option '$1' — fleet-sequence takes an optional pr|merge, issue IDs in ship order, then optionally -- <claude flags>" >&2; usage ;;
      *)
        tok=$(lower "$1")
        if [ "$tok" = "pr" ] || [ "$tok" = "merge" ]; then
          if [ -n "$mode_set" ] && [ "$mode_set" != "$tok" ]; then echo "ERROR: 'pr' and 'merge' together — pick one" >&2; exit 1; fi
          mode="$tok"; mode_set="$tok"
        elif [ "$tok" = "stale-ok" ]; then
          stale_ok=1
        else
          ids+=("$1")
        fi
        shift ;;
    esac
  done
  [ ${#ids[@]} -ge 1 ] || usage
  command -v linear-cli >/dev/null 2>&1 || { echo "ERROR: 'linear-cli' not found on PATH — needed to certify each issue before dispatch" >&2; exit 1; }

  # Normalize and dedupe the queue; every ID is validated offline first, then probed in Linear the way
  # /auto's targeted mode probes: `specified` present, `human` and `hold` absent. Refusing here, before anything is
  # dispatched, is what keeps a typo from surfacing as a failed session three hours in.
  local normalized=()
  for raw in "${ids[@]}"; do
    norm=$("$here/detect-issue-id.sh" --validate-only --input "$raw" 2>/dev/null) || { echo "ERROR: '$raw' is not an issue ID (expected e.g. BF-123)" >&2; exit 1; }
    for prev in "${normalized[@]}"; do [ "$prev" = "$norm" ] && { echo "ERROR: $norm listed twice" >&2; exit 1; }; done
    normalized+=("$norm")
  done

  # Which sequence is this list? The one it SHARES AN ISSUE with — launched from this branch in this mode, its
  # integration branch still there — and a list sharing none is a new sequence with a branch, marker and log
  # of its own. The launch branch and mode alone never identify a sequence: every sequence launched from one
  # branch shares them. An issue a live runner already holds is refused outright.
  current=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  local f shared b sid since list_json adopted="" matches=()
  list_json=$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -s .)
  while IFS= read -r f; do
    shared=$(jq -r --argjson l "$list_json" '[((.queue // []) + ((.issues // {}) | keys))[] | select(. as $x | $l | index($x) != null)] | unique | join(", ")' "$f" 2>/dev/null || true)
    [ -n "$shared" ] || continue
    if runner_alive "$f"; then
      echo "ERROR: $shared already in a running sequence ($(seq_label "$f"), runner pid $(jq -r '.runner_pid' "$f")) — an issue ships in one sequence at a time; fleet-sequence.sh status / stop $(jq -r '.queue[0]' "$f") first" >&2
      exit 1
    fi
    # A drain is resumed only by the next drain: its marker has no list to share. What a list must not do is dispatch
    # an issue the last drain's session is still working.
    if is_drain "$f"; then
      while IFS=$'\t' read -r id sid since; do
        case " ${normalized[*]} " in
          *" $id "*) echo "ERROR: $id is still in flight from the last solo drain (session $sid) — re-run the drain to wait on it (fleet-sequence.sh solo), or stop it in \`claude agents\` first" >&2; exit 1 ;;
        esac
      done < <(in_flight_entries "$f")
      continue
    fi
    [ -n "$current" ] && [ "$(jq -r '.base // ""' "$f")" = "$current" ] && [ "$(jq -r '.mode // "pr"' "$f")" = "$mode" ] || continue
    if [ "$mode" != "merge" ]; then
      b=$(jq -r '.branch // ""' "$f")
      [ -n "$b" ] && git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$b" >/dev/null || continue
    fi
    matches+=("$f")
  done < <(all_markers)
  if [ ${#matches[@]} -gt 1 ]; then
    echo "ERROR: this list shares issues with ${#matches[@]} earlier sequences from '$current' — a list resumes the ONE sequence it shares an issue with. Split it:" >&2
    for f in "${matches[@]}"; do echo "       $(jq -r '.queue | join(" → ")' "$f") ($(jq -r '.status' "$f"), onto $(jq -r '.branch // .base' "$f"))" >&2; done
    exit 1
  fi
  if [ ${#matches[@]} -eq 1 ]; then
    resume=1; use_sequence "$(slug_of "${matches[0]}")"; branch=$(jq -r '.branch // ""' "$marker")
  else
    use_sequence "$(lower "${normalized[0]}")"
    if [ -s "$marker" ] && runner_alive "$marker"; then
      echo "ERROR: a running sequence already owns the name '$(slug_of "$marker")' ($(jq -r '.queue | join(" → ")' "$marker")) — fleet-sequence.sh status / stop first, or lead this list with another issue" >&2
      exit 1
    fi
  fi
  refuse_second_merge_runner "$current" "Let it finish, or drop 'merge' to ship this list onto a branch of its own."

  # A resume keeps what the marker recorded as shipped, and ADOPTS a session an earlier run dispatched that
  # is still working or shipped with its landing unrecorded (the runner died under it). Neither is probed:
  # a shipped issue sits at Ready For Release. An adoptable issue left off the list is refused — its session
  # would still merge onto the branch, under a runner that is not waiting for it.
  if [ "$resume" -eq 1 ]; then
    carried=$(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome == "shipped") | .key' "$marker" | paste -sd' ' -)
    while IFS=$'\t' read -r id sid since; do
      case " ${normalized[*]} " in
        *" $id "*) adopted="$adopted $id" ;;
        *) echo "ERROR: $id was dispatched by an earlier run of this sequence (session $sid) and is still in flight, or shipped with its landing unrecorded — list it so the runner waits for it, or stop it in \`claude agents\` first" >&2; exit 1 ;;
      esac
    done < <(in_flight_entries "$marker")
  fi
  for id in "${normalized[@]}"; do
    case " $carried $adopted " in *" $id "*) continue ;; esac
    reason=$(probe_issue "$id") || { echo "ERROR: $reason" >&2; exit 1; }
  done

  preflight_dirt "$current"
  [ -n "$current" ] || { echo "ERROR: HEAD is detached — check out the branch the sequence should ship onto, then re-run" >&2; exit 1; }
  preflight_tooling "$stale_ok"

  if [ "$mode" = "pr" ]; then
    # The PR's base is the launch branch, so it must exist on origin — an unpushed one would spend every
    # session and then fail at the PR. Launching off the default branch is legitimate (the sequence sits on
    # top of unmerged work and reaches the default branch when that work's own PR merges), so it is a note.
    git -C "$main_checkout" remote get-url origin >/dev/null 2>&1 || { echo "ERROR: no 'origin' remote — the sequence ends in a PR, which needs GitHub; use 'merge' to ship into $current without one" >&2; exit 1; }
    if ! git -C "$main_checkout" ls-remote --exit-code --heads origin "$current" >/dev/null 2>&1; then
      echo "ERROR: '$current' does not exist on origin — the PR's base must be a remote branch. Push it (git push -u origin $current), or launch from the default branch." >&2
      exit 1
    fi
    local default_branch
    default_branch=$(git -C "$main_checkout" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    if [ -n "$default_branch" ] && [ "$default_branch" != "$current" ]; then
      echo "NOTE: launching from '$current', not '$default_branch' — the PR targets $current and reaches $default_branch only when $current's own PR merges. $current's changes are in the PR's history and not in its diff." >&2
    fi
    if [ "$resume" -eq 0 ]; then
      branch="seq/$(lower "${normalized[0]}")"
      if git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        echo "ERROR: branch '$branch' already exists but no marker records a sequence on it from '$current' that shares an issue with this list — delete it (git branch -D $branch), or name an issue of the sequence that created it to resume that one" >&2
        exit 1
      fi
      git -C "$main_checkout" branch "$branch" "$current" || { echo "ERROR: could not create $branch from $current" >&2; exit 1; }
    elif ! git -C "$main_checkout" merge-base --is-ancestor "$current" "$branch" 2>/dev/null; then
      echo "WARN: '$branch' is behind '$current' — the PR will need one catch-up merge (Update branch) before it merges" >&2
    fi
  fi

  existing_issues='{}'
  if [ "$resume" -eq 1 ]; then
    # shellcheck disable=SC2086
    existing_issues=$(jq -c --argjson a "$(printf '%s\n' $adopted | jq -R . | jq -s 'map(select(length > 0))')" \
      '(.issues // {}) | with_entries(select(.value.outcome == "shipped" or (.key as $k | $a | index($k) != null)))
       | with_entries(if .value.outcome == "shipped" then . else .value |= {session, started_epoch, tip_before} end)' "$marker")
    if [ "$(printf '%s' "$existing_issues" | jq '[.[] | select(.outcome == "shipped")] | length')" -gt 0 ]; then
      echo "Resuming on ${branch:-$current}: already shipped, kept — $(printf '%s' "$existing_issues" | jq -r 'to_entries | map(select(.value.outcome == "shipped") | "\(.key) (landed \(.value.landed_sha // "unrecorded" | .[0:12]))") | join(", ")')"
    fi
    if [ -n "$adopted" ]; then
      echo "Resuming on ${branch:-$current}: still in its earlier session, waited on and not dispatched again — $(printf '%s' "$existing_issues" | jq -r 'to_entries | map(select(.value.outcome != "shipped") | "\(.key) (session \(.value.session))") | join(", ")')"
    fi
  fi

  default_claude_args

  local queue_json args_json pr_url slug
  slug=$(slug_of "$marker")
  queue_json="$list_json"
  args_json=$(printf '%s\n' "${claude_args[@]}" | jq -R . | jq -s 'map(select(length > 0))')
  pr_url=""; [ "$resume" -eq 1 ] && pr_url=$(jq -r '.pr_url // ""' "$marker")
  jq -n --arg slug "$slug" --argjson q "$queue_json" --arg base "$current" --arg mode "$mode" --arg branch "$branch" --argjson a "$args_json" \
        --argjson now "$(date +%s)" --arg log "$log" --argjson issues "$existing_issues" --arg pr "$pr_url" \
    '{slug: $slug, queue: $q, base: $base, mode: $mode, branch: (if $branch == "" then null else $branch end), claude_args: $a,
      status: "running", reason: "", stop_requested: false, current: null, issues: $issues,
      pr_url: (if $pr == "" then null else $pr end), pr_number: null, launch_epoch: $now, log: $log, runner_pid: null}' > "$marker"

  # A per-issue key a crashed runner left behind would otherwise stand until that issue's dispatch overwrote it.
  for id in "${normalized[@]}"; do git -C "$main_checkout" config --unset "$(fork_key "$id")" >/dev/null 2>&1 || true; done
  if [ "$mode" = "merge" ]; then
    echo "Sequence: $(printf '%s' "$queue_json" | jq -r 'join(" → ")') merging into $current one issue at a time (no PR)"
  else
    echo "Sequence: $(printf '%s' "$queue_json" | jq -r 'join(" → ")') onto $branch (forked from $current); one PR onto $current when the list completes"
  fi
  start_sequence "$slug" "$resume" || return 0
  if [ "$mode" = "merge" ]; then
    echo "Each issue runs in its own background session and merges into $current by ref (a fast-forward touches the main checkout's tree only while it sits on $current)."
  else
    echo "Each issue runs in its own background session, forking from and merging into $branch by ref; a per-issue start.<id>.wt-source-branch key steers it, set just before its dispatch."
  fi
  echo "The main checkout is never moved, and other worktree sessions (another sequence, a targeted /auto, /start wt) may run alongside — commit what you edit there: a merge that changes a path left uncommitted on the branch it lands on defers to the queue, and the runner waits for it."
  echo "Watch with: fleet-sequence.sh status ${normalized[0]}  |  claude agents"
}

# =====================================================================================
warn_live_fleets() { # `solo` marks work for a quiet checkout: name a fleet still working here — the operator's call, never a refusal
  local f k
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fleet_marker_running "$f" || continue
    for k in $(jq -r '(.fleet_sessions // [])[]' "$f" 2>/dev/null); do
      registry_alive "$k" || continue
      echo "WARN: a fleet is still working in this checkout ($(fleet_marker_token "$f")) — \`solo\` marks work that should not run beside one. Launching anyway (your call); /fleet-stop winds it down." >&2
      break
    done
  done < <(fleet_live_markers "$main_checkout")
  return 0
}

cmd_drain() { # [list] [stale-ok] [<duration>] [then-fleet [<fleet-launch tokens>...]] [-- <claude flags>]
  local tok list_only=0 stale_ok=0 fleet=0 secs="" deadline_epoch="" deadline_human="" current head_branch team listing n id sid since out
  local mode=merge slug=solo prior_base="" adopted="" pending="" existing_issues='{}' queue_json='[]' plan_json fleet_json=null user_json args_json
  local dur_tokens=() fleet_args=() user_args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; user_args=("$@"); break; fi
    if [ "$fleet" = 1 ]; then fleet_args+=("$1"); shift; continue; fi
    tok=$(lower "$1")
    case "$tok" in
      list) list_only=1 ;;
      stale-ok) stale_ok=1 ;;
      merge) ;;
      then-fleet) fleet=1 ;;
      pr) echo "ERROR: a solo drain lands by merge — a broad change parked on a branch only defers its collision to the catch-up merge. For one PR, name the issues: fleet-sequence.sh pr <ISSUE-ID>... (fleet-sequence.sh solo list prints them in order)" >&2; exit 1 ;;
      -*) echo "ERROR: unknown option '$1' — a solo drain takes an optional list, stale-ok, a duration, then-fleet <fleet-launch tokens>, then optionally -- <claude flags>" >&2; usage ;;
      *) dur_tokens+=("$1") ;;
    esac
    shift
  done
  command -v linear-cli >/dev/null 2>&1 || { echo "ERROR: 'linear-cli' not found on PATH — needed to certify each issue before dispatch" >&2; exit 1; }
  team="${LINEAR_TEAM:-}"
  [ -n "$team" ] || { echo "ERROR: LINEAR_TEAM is not set — without it the listing spans every team in the workspace, and the drain would ship another project's solo issues from this checkout. Export it and re-run." >&2; exit 1; }
  if [ ${#dur_tokens[@]} -gt 0 ]; then
    secs=$(fleet_duration_secs "${dur_tokens[*]}") || { echo "ERROR: cannot read '${dur_tokens[*]}' as a duration — a solo drain takes an optional budget such as '3h', '3 hours' or '90m'. It lists the issues itself; a named list is fleet-sequence.sh <ISSUE-ID>..." >&2; exit 1; }
    deadline_epoch=$(( $(date +%s) + secs ))
    deadline_human=$(date -r "$deadline_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -d "@$deadline_epoch" '+%Y-%m-%d %H:%M %Z')
  fi
  listing=$(solo_listing "$team") || { echo "ERROR: could not list the solo issues for $team (above) — nothing was dispatched or written" >&2; exit 1; }
  n=$(printf '%s\n' "$listing" | grep -c . || true)

  if [ "$list_only" = 1 ]; then
    if [ "$n" -eq 0 ]; then echo "No workable solo issue in $team — nothing to drain."; return 0; fi
    echo "Workable solo issues in $team, in running order ($n):"
    print_plan "$listing"
    return 0
  fi

  use_sequence "$slug"
  if [ -s "$marker" ] && runner_alive "$marker"; then
    echo "ERROR: a solo drain is already running here ($(seq_label "$marker"), runner pid $(jq -r '.runner_pid' "$marker")) — fleet-sequence.sh status solo / stop solo" >&2
    exit 1
  fi
  # The drain merges by ref and never needs the checkout on the branch, so it also launches from a checkout parked
  # detached with the checkout-wide start.wt-source-branch set — the branch /start wt forks from there, and the posture
  # /auto-prep's launch checklist asks for before the fleet a `then-fleet` hands off to.
  head_branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  current="$head_branch"
  if [ -z "$current" ]; then
    current=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
    if [ -z "$current" ] || ! git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$current" >/dev/null; then
      echo "ERROR: HEAD is detached and start.wt-source-branch names no local branch — check out the branch the solo issues should merge into, or set the key (git config start.wt-source-branch <branch>), then re-run" >&2
      exit 1
    fi
  fi
  preflight_dirt "$head_branch"
  refuse_second_merge_runner "$current" "Let it finish, then re-run the drain."

  # A session the last drain left working — its runner died under it, or timed out waiting — is waited on, never
  # dispatched beside: this is the one runner whose issues must not overlap. So is a ship whose merge never landed.
  if [ -s "$marker" ]; then
    prior_base=$(jq -r '.base // ""' "$marker")
    pending=$(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome == "shipped" and ((.value.landed_sha // "") == "")) | .key' "$marker" | paste -sd' ' -)
    while IFS=$'\t' read -r id sid since; do adopted="$adopted $id"; done < <(in_flight_entries "$marker")
    adopted="${adopted# }"
    if [ -n "$pending$adopted" ] && [ "$prior_base" != "$current" ]; then
      echo "ERROR: the last drain left $(printf '%s %s' "$pending" "$adopted" | xargs) unfinished on '$prior_base' (in flight, or shipped with its merge not landed) — launch from $prior_base so this drain waits for it, or stop the session in \`claude agents\` first" >&2
      exit 1
    fi
    # shellcheck disable=SC2086
    existing_issues=$(jq -c --argjson a "$(printf '%s\n' $adopted | jq -R . | jq -s 'map(select(length > 0))')" \
      '(.issues // {}) | with_entries(select((.value.outcome == "shipped" and ((.value.landed_sha // "") == "")) or (.key as $k | $a | index($k) != null)))
       | with_entries(if .value.outcome == "shipped" then . else .value |= {session, started_epoch, tip_before} end)' "$marker")
    queue_json=$(jq -c --argjson e "$existing_issues" '[(.queue // [])[] | select(. as $q | $e | has($q))]' "$marker")
  fi
  if [ "$n" -eq 0 ] && [ "$queue_json" = "[]" ] && [ "$fleet" = 0 ]; then
    echo "No workable solo issue in $team — nothing to drain."
    return 0
  fi

  claude_args=("${user_args[@]}")
  preflight_tooling "$stale_ok"
  if [ "$fleet" = 1 ]; then
    case "$(lower "${fleet_args[0]:-}")" in
      stop) echo "ERROR: then-fleet takes fleet-launch.sh's launch tokens (count, duration, epic:<ID>, backlog, stale-ok) — 'stop' is not one" >&2; exit 1 ;;
    esac
    if ! out=$(FLEET_LAUNCH_CHECK=1 "${FLEET_SEQUENCE_FLEET_LAUNCHER:-$here/fleet-launch.sh}" "${fleet_args[@]}" 2>&1); then
      printf '%s\n' "$out" >&2
      echo "ERROR: fleet-launch.sh refused the then-fleet arguments (above) — nothing was dispatched or written" >&2
      exit 1
    fi
    printf '%s\n' "$out" | grep -v '^CHECK-OK' || true
    fleet_json=$(printf '%s\n' "${fleet_args[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
  fi
  warn_live_fleets

  user_json=$(printf '%s\n' "${user_args[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
  default_claude_args
  args_json=$(printf '%s\n' "${claude_args[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
  plan_json=$(printf '%s\n' "$listing" | cut -f1 | jq -R . | jq -sc 'map(select(length > 0))')
  jq -n --arg slug "$slug" --arg team "$team" --argjson q "$queue_json" --argjson plan "$plan_json" --arg base "$current" --argjson a "$args_json" \
        --argjson dl "${deadline_epoch:-null}" --arg dlh "$deadline_human" --argjson fleet "$fleet_json" --argjson fca "$user_json" \
        --argjson now "$(date +%s)" --arg log "$log" --argjson issues "$existing_issues" \
    '{slug: $slug, drain: true, team: $team, queue: $q, plan: $plan, base: $base, mode: "merge", branch: null, claude_args: $a,
      deadline_epoch: $dl, deadline: (if $dlh == "" then null else $dlh end), then_fleet: $fleet, fleet_claude_args: $fca, fleet: null,
      status: "running", reason: "", stop_requested: false, current: null, issues: $issues,
      pr_url: null, pr_number: null, launch_epoch: $now, log: $log, runner_pid: null}' > "$marker"

  if [ "$queue_json" != "[]" ]; then
    echo "Waiting first on what the last drain left unfinished, not dispatching it again: $(printf '%s' "$queue_json" | jq -r 'join(", ")')"
  fi
  if [ "$n" -eq 0 ]; then
    echo "Solo drain: no workable solo issue in $team right now"
  else
    echo "Solo drain: $n workable solo issue(s) in $team, one at a time into $current (no PR), in this order — the listing is read again before each dispatch:"
    print_plan "$listing"
  fi
  [ -z "$deadline_human" ] || echo "Budget: nothing new starts after $deadline_human; the issue in flight then runs to completion."
  [ "$fleet" = 0 ] || echo "Then: fleet-launch.sh ${fleet_args[*]} — only after a drain that ends clean (drained, or out of time)."
  # A re-launch that waits on the last drain's session continues that run, and its log is the only record of it.
  local keep_log=0
  [ "$queue_json" = "[]" ] || keep_log=1
  start_sequence "$slug" "$keep_log" || return 0
  echo "Each issue runs in its own background session and merges into $current by ref. One that ends without shipping is skipped; $drain_max_fails in a row stop the drain."
  echo "The main checkout is never moved — commit what you edit there: a merge that changes a path left uncommitted on $current defers to the queue, and the runner waits for it."
  echo "Watch with: fleet-sequence.sh status solo  |  claude agents"
}

case "${1:-}" in
  status) [ $# -le 2 ] || usage; cmd_status "${2:-}" ;;
  stop)   [ $# -le 2 ] || usage; cmd_stop "${2:-}" ;;
  run)    [ $# -eq 2 ] || usage; cmd_run "$2" ;;
  [Ss][Oo][Ll][Oo]) shift; cmd_drain "$@" ;;
  "")     usage ;;
  *)      cmd_launch "$@" ;;
esac
