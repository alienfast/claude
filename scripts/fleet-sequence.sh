#!/bin/bash
# fleet-sequence.sh — ship an ORDERED list of certified issues onto ONE integration branch, one background
# `claude --bg "/auto <ID>"` session at a time: each issue forks from the branch's current tip and its own
# /finish merges it back, and when the list completes a single PR from that branch onto the branch you
# launched from carries the lot. The `merge` token skips the branch and the PR — each issue then merges
# straight into the launch branch, the shape an unscoped fleet ships in.
#
# Usage: fleet-sequence.sh [pr|merge] <ISSUE-ID>... [-- <claude flags...>]
#        fleet-sequence.sh status [<ISSUE-ID>]
#        fleet-sequence.sh stop [<ISSUE-ID>]
#        fleet-sequence.sh run <slug>     (internal: the detached runner; reads tmp/fleet-sequence-<slug>.json)
#
#   <ISSUE-ID>...  The issues in the order they must ship. Each must carry `specified` and not `human`
#                  (the same probe /auto's targeted mode runs), and must not already be terminal or
#                  Ready For Release — unless the marker records it shipped on this launch branch, which
#                  a resume skips unprobed. `solo` is expressly fine — this is the runner for it.
#                  A list that shares an issue with an earlier sequence (same launch branch and mode, its
#                  branch still there) RESUMES that sequence; a list sharing none is a NEW sequence.
#   pr | merge     pr (default): create `seq/<first-id>` from the launch branch, ship every issue onto it,
#                  push it after each ship, open one PR onto the launch branch at the end, then run
#                  /pr-update on it. merge: no branch, no PR — each issue merges into the launch branch.
#   -- ...         Passed to every `claude --bg` verbatim; defaults added only for flags not present
#                  (--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto —
#                  skills/auto/SKILL.md's unattended-run prerequisites, same as fleet-launch.sh).
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
# sequence, and two `merge` sequences never share a launch branch). 2026-09-21: with one marker per checkout
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
# registry `claude agents --json --all` is the fallback for a session that ends without one), then
# require the target branch's tip to have moved — a `shipped` whose merge the queue deferred is waited on
# up to FLEET_SEQUENCE_MERGE_TIMEOUT. Any other outcome stops the sequence with the remaining issues
# untouched — /auto already commented and labeled the issue. Re-running the same list resumes: issues the
# marker recorded as shipped are skipped, the branch is kept, and a list whose every issue has shipped
# goes straight to the PR step — which is also how a run whose PR could not be opened is completed. A
# resume also ADOPTS a session an earlier run dispatched that is still working (or shipped with its landing
# unrecorded) — a runner can die under a harness restart its child survives — waiting on it, never
# dispatching the issue twice.
#
# Env: FLEET_SEQUENCE_POLL (seconds between reads, default 30), FLEET_SEQUENCE_GRACE (default 120),
# FLEET_SEQUENCE_ISSUE_TIMEOUT (default 21600 — 6h per issue; on expiry the sequence fails and the session
# is left running), FLEET_SEQUENCE_MERGE_TIMEOUT (default 1800 — how long a shipped issue may take to land
# on the branch; the merge-queue drainer runs every 15 minutes), FLEET_SEQUENCE_PR_UPDATE=0 skips the
# closing /pr-update session, FLEET_SEQUENCE_PR_UPDATE_TIMEOUT (default 1800), FLEET_SEQUENCE_FOREGROUND=1
# runs the runner inline (tests).
#
# Read-write: tmp/fleet-sequence-<slug>.json (the marker) and tmp/fleet-sequence-<slug>.log in the main
# checkout; creates the integration branch, sets/unsets the per-issue `start.<id>.wt-source-branch` keys,
# pushes the branch, opens its PR, adds and removes a throwaway worktree at tmp/fleet-sequence-pr-update-<slug>
# for the closing /pr-update session, dispatches background claude sessions. Never moves the main checkout's
# HEAD. Exit 1 on argument/environment errors before anything is dispatched; the runner exits 1 when the
# sequence fails.

set -eo pipefail

usage() {
  echo "usage: fleet-sequence.sh [pr|merge] <ISSUE-ID>... [-- <claude flags...>] | fleet-sequence.sh status [<ISSUE-ID>] | stop [<ISSUE-ID>]" >&2
  exit 1
}

for cmd in claude jq git gh; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

here=$(cd "$(dirname "$0")" && pwd)
main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the project the sequence should work on" >&2; exit 1; }
mkdir -p "$main_checkout/tmp"
marker=""; log=""; pr_wt="" # per sequence — set by use_sequence before anything reads them
poll="${FLEET_SEQUENCE_POLL:-30}"
grace="${FLEET_SEQUENCE_GRACE:-120}"
issue_timeout="${FLEET_SEQUENCE_ISSUE_TIMEOUT:-21600}"
merge_timeout="${FLEET_SEQUENCE_MERGE_TIMEOUT:-1800}"
pr_update_timeout="${FLEET_SEQUENCE_PR_UPDATE_TIMEOUT:-1800}"
claude_args=()

logln() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# ---- session registry ----
registry_json() {
  local j
  j=$(claude agents --json --all 2>/dev/null || true)
  printf '%s' "$j" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$j"
}
registry_state() { # <short id> → prints "" (absent), "done", or the listed state; returns 2 when no registry
  local j
  j=$(registry_json) || return 2
  printf '%s' "$j" | jq -r --arg k "$1" \
    'map(select((.id // (.sessionId // "" | split("-")[0])) == $k)) | if length == 0 then "" else (.[0].state // "running") end'
}
registry_alive() { # <short id> — listed and not done
  local st
  st=$(registry_state "$1") || return 1
  [ -n "$st" ] && [ "$st" != "done" ]
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

wait_session() { # <short id> <timeout seconds> <ISSUE-ID> <since epoch> → 0 when the work has ended, 1 on timeout
  local sid="$1" limit="$2" id="$3" since="$4" waited=0 seen=0 st rc step
  step=$(( poll > 0 ? poll : 1 ))
  while :; do
    # The ledger is /auto Step 4's LAST act — Linear comment, label, ownership release, then the state
    # file — so an outcome recorded for this issue means the work is over whatever the registry says.
    # Measured 2026-09-10: a session sat "busy" in the registry for 7h after its ledger said shipped, and
    # a registry-only wait burned the whole 6h timeout and failed the sequence with the work already landed.
    if [ "$(ledger_outcome "$sid" "$id" "$since")" != "unknown" ]; then sleep "$poll"; return 0; fi
    rc=0; st=$(registry_state "$sid") || rc=$?
    if [ "$rc" -ne 2 ]; then
      # A session that ends without a ledger (crashed, refused) still ends: registry done, or absent
      # after it was seen (or after the grace when it was never seen).
      if [ "$st" = "done" ]; then return 0
      elif [ -n "$st" ]; then seen=1
      elif [ "$seen" -eq 1 ] || [ "$waited" -ge "$grace" ]; then return 0
      fi
    fi
    [ "$waited" -ge "$limit" ] && return 1
    sleep "$poll"; waited=$((waited + step))
  done
}

wait_session_end() { # <short id> <timeout seconds> → 0 when the registry lists the session done or drops it, 1 on timeout
  local sid="$1" limit="$2" waited=0 seen=0 st rc step
  step=$(( poll > 0 ? poll : 1 ))
  while :; do
    rc=0; st=$(registry_state "$sid") || rc=$?
    if [ "$rc" -eq 2 ]; then [ "$waited" -ge "$grace" ] && return 0
    elif [ "$st" = "done" ]; then return 0
    elif [ -n "$st" ]; then seen=1
    elif [ "$seen" -eq 1 ] || [ "$waited" -ge "$grace" ]; then return 0
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

wait_for_landing() { # <ISSUE-ID> <tip before dispatch> → 0 once the target branch's tip has moved, 1 on timeout
  local id="$1" before="$2" branch waited=0 step
  branch=$(target_branch); step=$(( poll > 0 ? poll : 1 ))
  while [ "$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" = "$before" ]; do
    [ "$waited" -ge "$merge_timeout" ] && return 1
    if [ "$waited" -eq 0 ]; then
      if [ -f "$main_checkout/.claude/merge-queue/$(lower "$id").json" ]; then
        logln "$id: ledger says shipped and its merge is queued (.claude/merge-queue) — waiting up to ${merge_timeout}s for the drainer"
      else
        logln "$id: ledger says shipped but '$branch' has not moved — waiting up to ${merge_timeout}s for the merge to land"
      fi
    fi
    sleep "$poll"; waited=$((waited + step))
  done
  return 0
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
    f=$(marker_naming "$1") || exit 1
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
    case " ${shown[*]} " in *" $f "*) ;; *) rest="$rest, $(jq -r '.queue | join(" → ")' "$f") ($(jq -r '.status' "$f"))" ;; esac
  done < <(all_markers)
  [ -z "$rest" ] || printf '\n**Other sequences here:** %s — `fleet-sequence.sh status <ISSUE-ID>` reads one.\n' "${rest#, }"
  return 0
}

print_status() { # the readout of the sequence use_sequence selected
  local status base mode branch queue runner_pid runner live id sid st outcome landed pr_url ahead behind keys k
  status=$(jq -r '.status' "$marker"); base=$(jq -r '.base' "$marker"); mode=$(jq -r '.mode // "pr"' "$marker")
  branch=$(jq -r '.branch // ""' "$marker"); pr_url=$(jq -r '.pr_url // ""' "$marker")
  queue=$(jq -r '.queue | join(" → ")' "$marker")
  runner_pid=$(jq -r '.runner_pid // empty' "$marker")
  runner="not detached"
  if [ -n "$runner_pid" ]; then
    if kill -0 "$runner_pid" 2>/dev/null; then runner="alive (pid $runner_pid)"; else runner="gone (pid $runner_pid)"; fi
  fi
  printf '**Sequence:** %s · **mode:** %s' "$queue" "$mode"
  if [ "$mode" = "merge" ]; then printf ' · **merges into:** `%s`' "$base"; else printf ' · **branch:** `%s` → `%s`' "$branch" "$base"; fi
  printf ' · **status:** %s · **runner:** %s' "$status" "$runner"
  [ "$(jq -r '.stop_requested' "$marker")" = "true" ] && printf ' · **stop requested**'
  printf '\n'
  [ "$(jq -r '.reason // ""' "$marker")" != "" ] && printf '**Reason:** %s\n' "$(jq -r '.reason' "$marker")"
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
  printf '\n| issue | session | liveness | outcome | landed |\n|---|---|---|---|---|\n'
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
    f=$(marker_naming "$1") || exit 1
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
    echo "ERROR: ${#running[@]} sequences are running — name an issue of the one to stop: fleet-sequence.sh stop <ISSUE-ID>" >&2
    for f in "${running[@]}"; do echo "       $(jq -r '.queue | join(" → ")' "$f")" >&2; done
    exit 1
  fi
  use_sequence "$(slug_of "${running[0]}")"
  update_marker '.stop_requested = true'
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

cmd_run() { # [<slug>] — the launch passes it to the detached runner; a foreground launch has already selected the sequence
  [ -z "${1:-}" ] || use_sequence "$1"
  [ -s "$marker" ] || { echo "ERROR: no marker at ${marker:-tmp/fleet-sequence-<slug>.json} — the runner only runs under a launch" >&2; exit 1; }
  cd "$main_checkout"
  trap on_exit_run EXIT
  local base mode target ids_csv id sid out outcome remaining now started before after count
  local queue=()
  base=$(jq -r '.base' "$marker"); mode=$(jq -r '.mode' "$marker"); target=$(target_branch)
  while IFS= read -r id; do queue+=("$id"); done < <(jq -r '.queue[]' "$marker")
  while IFS= read -r out; do claude_args+=("$out"); done < <(jq -r '.claude_args[]' "$marker")
  ids_csv=$(jq -r '.queue | join(", ")' "$marker")
  if [ "$mode" = "merge" ]; then logln "sequence started: $ids_csv merging into $base; runner pid $$"
  else logln "sequence started: $ids_csv onto $target (forked from $base); runner pid $$"; fi

  local i=0
  for id in "${queue[@]}"; do
    i=$((i+1))
    if [ "$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")" = "shipped" ]; then
      logln "[$i/${#queue[@]}] $id already shipped (landed $(jq -r --arg id "$id" '.issues[$id].landed_sha // "unrecorded" | .[0:12]' "$marker")) — skipping"
      continue
    fi
    if [ "$(jq -r '.stop_requested' "$marker")" = "true" ]; then
      remaining=$(printf '%s\n' "${queue[@]:$((i-1))}" | paste -sd, - | sed 's/,/, /g')
      logln "STOPPED: stopped before $id; not started: $remaining — re-run the same list to continue"
      update_marker --arg r "stopped before $id; not started: $remaining — re-run the same list to continue" '.status = "stopped" | .reason = $r | .current = null'
      exit 0
    fi
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      fail_run "main checkout is dirty before $id — /auto would halt on it; resolve and re-run the same list"
    fi

    # The launch carries a non-shipped entry only for a session it found still working (or shipped with its
    # landing unrecorded), so a session recorded here is one to wait on — dispatching again would start a
    # second /auto on an issue already in flight.
    sid=$(jq -r --arg id "$id" '.issues[$id].session // ""' "$marker")
    if [ -n "$sid" ]; then
      started=$(jq -r --arg id "$id" '.issues[$id].started_epoch // 0' "$marker")
      before=$(jq -r --arg id "$id" '.issues[$id].tip_before // ""' "$marker")
      update_marker --arg id "$id" '.current = $id'
      logln "[$i/${#queue[@]}] $id was dispatched by an earlier run of this sequence (session $sid) — waiting on that session, not dispatching again"
    else
      set_fork_key "$id"
      before=$(git rev-parse --verify --quiet "refs/heads/$target")
      started=$(date +%s)
      update_marker --arg id "$id" --argjson now "$started" --arg b "$before" \
        '.current = $id | .issues[$id] = {started_epoch: $now, tip_before: $b}'
      logln "[$i/${#queue[@]}] dispatching: claude --bg ${claude_args[*]} -n 'fleet-sequence $id' '/auto $id'  (forks from $target at ${before:0:12})"
      if ! out=$(claude --bg "${claude_args[@]}" -n "fleet-sequence $id" "/auto $id" 2>&1); then
        printf '%s\n' "$out"
        fail_run "dispatch of $id failed — see the claude output above in $log"
      fi
      printf '%s\n' "$out"
      sid=$(parse_sid "$out")
      [ -n "$sid" ] || fail_run "could not read the session id from the claude --bg output for $id — cannot wait on an unknown session; find it in \`claude agents\`, let it finish, then re-run the same list"
      update_marker --arg id "$id" --arg s "$sid" '.issues[$id].session = $s'
      logln "[$i/${#queue[@]}] $id running in session $sid"
    fi
    if ! wait_session "$sid" "$issue_timeout" "$id" "$started"; then
      fail_run "$id: session $sid still running after ${issue_timeout}s — not killed; watch it in \`claude agents\`, then re-run the same list"
    fi
    # The key has done its job once the session has ended — its /start wt ran at the very start.
    git config --unset "$(fork_key "$id")" >/dev/null 2>&1 || true
    outcome=$(ledger_outcome "$sid" "$id" "$started")
    now=$(date +%s)
    update_marker --arg id "$id" --arg o "$outcome" --argjson now "$now" '.issues[$id] += {outcome: $o, ended_epoch: $now}'
    logln "[$i/${#queue[@]}] $id → $outcome (session $sid)"
    if [ "$outcome" != "shipped" ]; then
      remaining=$(printf '%s\n' "${queue[@]:$i}" | paste -sd, - | sed 's/,/, /g')
      fail_run "$id ended '$outcome' in session $sid (claude logs $sid; /auto's Linear comment names the cause) — not started: ${remaining:-none}. Fix or drop it, then re-run the same list"
    fi

    # Shipped means merged: the branch the checkout is parked on must have moved. A deferred merge
    # (finish-merge.sh exit 3) lands later through the queue's drainer, so the wait is bounded, not skipped.
    wait_for_landing "$id" "$before" \
      || fail_run "$id: ledger says shipped but '$target' never moved within ${merge_timeout}s — a deferred merge (/merge-queue) or a ship that did not merge; land it, then re-run the same list"
    after=$(git rev-parse --verify --quiet "refs/heads/$target")
    update_marker --arg id "$id" --arg a "$after" '.issues[$id].landed_sha = $a'
    count=$(git rev-list --count "$before..$after" 2>/dev/null || echo "?")
    logln "[$i/${#queue[@]}] $id landed on $target at ${after:0:12} ($count commit(s))"
    git log --format=%s "$before..$after" 2>/dev/null | grep -qi -- "$id" \
      || logln "WARN: none of the commits $target gained mention $id — check the session's log before trusting the ship"
    [ "$mode" = "merge" ] || push_branch "$target"
  done
  update_marker '.current = null'
  [ "$mode" = "merge" ] || open_sequence_pr
  update_marker '.status = "done"'
  clear_fork_keys
  if [ "$mode" = "merge" ]; then
    logln "done: $ids_csv merged into $base — $(jq -r '[.queue[] as $q | "\($q) \(.issues[$q].landed_sha // "?" | .[0:12])"] | join(", ")' "$marker")"
  else
    logln "done: $ids_csv on $target → $base — PR $(jq -r '.pr_url // "?"' "$marker")"
  fi
}

# =====================================================================================
cmd_launch() {
  local raw id norm prev json labels state current live k existing_issues dirty tok mode="pr" mode_set="" branch="" resume=0 carried=""
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
        else
          ids+=("$1")
        fi
        shift ;;
    esac
  done
  [ ${#ids[@]} -ge 1 ] || usage
  command -v linear-cli >/dev/null 2>&1 || { echo "ERROR: 'linear-cli' not found on PATH — needed to certify each issue before dispatch" >&2; exit 1; }

  # Normalize and dedupe the queue; every ID is validated offline first, then probed in Linear the way
  # /auto's targeted mode probes: `specified` present, `human` absent. Refusing here, before anything is
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
      echo "ERROR: $shared already in a running sequence ($(jq -r '.queue | join(" → ")' "$f"), runner pid $(jq -r '.runner_pid' "$f")) — an issue ships in one sequence at a time; fleet-sequence.sh status / stop $(jq -r '.queue[0]' "$f") first" >&2
      exit 1
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
  # Two merge-mode runners on one launch branch would each read the other's merge as its own landing.
  if [ "$mode" = "merge" ]; then
    while IFS= read -r f; do
      [ "$f" != "$marker" ] || continue
      if runner_alive "$f" && [ "$(jq -r '.mode // "pr"' "$f")" = "merge" ] && [ "$(jq -r '.base // ""' "$f")" = "$current" ]; then
        echo "ERROR: a merge-mode sequence is already merging into '$current' ($(jq -r '.queue | join(" → ")' "$f")) — each would read the other's merges as its own landings. Let it finish, or drop 'merge' to ship this list onto a branch of its own." >&2
        exit 1
      fi
    done < <(all_markers)
  fi

  # A resume keeps what the marker recorded as shipped, and ADOPTS a session an earlier run dispatched that
  # is still working or shipped with its landing unrecorded (the runner died under it). Neither is probed:
  # a shipped issue sits at Ready For Release. An adoptable issue left off the list is refused — its session
  # would still merge onto the branch, under a runner that is not waiting for it.
  if [ "$resume" -eq 1 ]; then
    carried=$(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome == "shipped") | .key' "$marker" | paste -sd' ' -)
    while IFS=$'\t' read -r id sid since; do
      [ -n "$sid" ] || continue
      if registry_alive "$sid" || [ "$(ledger_outcome "$sid" "$id" "$since")" = "shipped" ]; then
        case " ${normalized[*]} " in
          *" $id "*) adopted="$adopted $id" ;;
          *) echo "ERROR: $id was dispatched by an earlier run of this sequence (session $sid) and is still in flight, or shipped with its landing unrecorded — list it so the runner waits for it, or stop it in \`claude agents\` first" >&2; exit 1 ;;
        esac
      fi
    done < <(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome != "shipped" and (.value.session // "") != "") | [.key, .value.session, (.value.started_epoch // 0)] | @tsv' "$marker")
  fi
  for id in "${normalized[@]}"; do
    case " $carried $adopted " in *" $id "*) continue ;; esac
    json=$(linear-cli issues get "$id" -o json 2>/dev/null) || { echo "ERROR: could not read $id from Linear (linear-cli issues get failed)" >&2; exit 1; }
    labels=$(printf '%s' "$json" | jq -r '.labels.nodes[].name' 2>/dev/null || true)
    state=$(printf '%s' "$json" | jq -r '.state.name // ""' 2>/dev/null || true)
    printf '%s\n' "$labels" | grep -qix specified || { echo "ERROR: $id is not certified (no specified label) — run /spec $id first" >&2; exit 1; }
    printf '%s\n' "$labels" | grep -qix human && { echo "ERROR: $id is human-owned work (human label) — no unattended mode can ship it" >&2; exit 1; }
    case "$state" in
      Done|Canceled|Duplicate|"Ready For Release") echo "ERROR: $id is already $state — nothing to ship" >&2; exit 1 ;;
    esac
  done

  # Never alongside a fleet: its pickers choose their own issues, and `solo` work wants none of them running.
  if [ -s "$main_checkout/tmp/fleet-deadline.json" ]; then
    live=""
    for k in $(jq -r '(.fleet_sessions // [])[]' "$main_checkout/tmp/fleet-deadline.json" 2>/dev/null); do
      registry_alive "$k" && live="$live $k"
    done
    if [ -n "$live" ]; then
      echo "ERROR: a fleet is running (sessions:$live) — sequenced work never runs mid-fleet. /fleet-stop and wait for it to drain, then re-run." >&2
      exit 1
    fi
  fi

  dirty=$(git -C "$main_checkout" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "ERROR: main checkout is dirty — every session's /auto would halt at its Step 1 preflight." >&2
    printf '%s\n' "$dirty" | sed 's/^/       /' >&2
    echo "       Commit or stash the above, then re-run. Nothing was dispatched." >&2
    exit 1
  fi
  [ -n "$current" ] || { echo "ERROR: HEAD is detached — check out the branch the sequence should ship onto, then re-run" >&2; exit 1; }

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

  have_flag() {
    local f="$1"; shift
    local a
    for a in "$@"; do [[ "$a" == "$f" || "$a" == "$f="* ]] && return 0; done
    return 1
  }
  have_flag --model "${claude_args[@]}" || claude_args+=(--model 'opus[1m]')
  have_flag --effort "${claude_args[@]}" || claude_args+=(--effort xhigh)
  have_flag --autocompact "${claude_args[@]}" || claude_args+=(--autocompact 500000)
  if ! have_flag --permission-mode "${claude_args[@]}" && ! have_flag --dangerously-skip-permissions "${claude_args[@]}"; then
    claude_args+=(--permission-mode auto)
  fi

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
  if [ "${FLEET_SEQUENCE_FOREGROUND:-0}" = "1" ]; then
    cmd_run
    return
  fi
  # A resume appends: the log it continues is the only record of why the earlier run stopped.
  [ "$resume" -eq 1 ] || : > "$log"
  local pidfile="$main_checkout/tmp/fleet-sequence-$slug.pid"
  ( cd "$main_checkout" && nohup "$here/fleet-sequence.sh" run "$slug" >> "$log" 2>&1 < /dev/null & echo $! > "$pidfile" )
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || true); rm -f "$pidfile"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "ERROR: runner did not start — see $log" >&2; update_marker '.status = "failed" | .reason = "runner did not start"'; exit 1; }
  update_marker --argjson p "$pid" '.runner_pid = $p'
  echo "Runner detached (pid $pid) — log: $log"
  if [ "$mode" = "merge" ]; then
    echo "Each issue runs in its own background session and merges into $current by ref (a fast-forward touches the main checkout's tree only while it sits on $current)."
  else
    echo "Each issue runs in its own background session, forking from and merging into $branch by ref; a per-issue start.<id>.wt-source-branch key steers it, set just before its dispatch."
  fi
  echo "The main checkout is never moved, and other worktree sessions (another sequence, a targeted /auto, /start wt) may run alongside — keep the main checkout clean, since a dirty tree halts /auto's preflight."
  echo "Watch with: fleet-sequence.sh status ${normalized[0]}  |  claude agents"
}

case "${1:-}" in
  status) [ $# -le 2 ] || usage; cmd_status "${2:-}" ;;
  stop)   [ $# -le 2 ] || usage; cmd_stop "${2:-}" ;;
  run)    [ $# -eq 2 ] || usage; cmd_run "$2" ;;
  "")     usage ;;
  *)      cmd_launch "$@" ;;
esac
