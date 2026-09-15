#!/bin/bash
# fleet-sequence.sh — ship an ORDERED list of certified issues onto ONE integration branch, one background
# `claude --bg "/auto <ID>"` session at a time: each issue forks from the branch's current tip and its own
# /finish merges it back, and when the list completes a single PR from that branch onto the branch you
# launched from carries the lot. The `merge` token skips the branch and the PR — each issue then merges
# straight into the launch branch, the shape an unscoped fleet ships in.
#
# Usage: fleet-sequence.sh [pr|merge] <ISSUE-ID>... [-- <claude flags...>]
#        fleet-sequence.sh status
#        fleet-sequence.sh stop
#        fleet-sequence.sh run            (internal: the detached runner; reads tmp/fleet-sequence.json)
#
#   <ISSUE-ID>...  The issues in the order they must ship. Each must carry `specified` and not `human`
#                  (the same probe /auto's targeted mode runs), and must not already be terminal or
#                  Ready For Release — unless the marker records it shipped on this launch branch, which
#                  a resume skips unprobed. `solo` is expressly fine — this is the runner for it.
#   pr | merge     pr (default): create `seq/<first-id>` from the launch branch, ship every issue onto it,
#                  push it after each ship, open one PR onto the launch branch at the end, then run
#                  /pr-update on it. merge: no branch, no PR — each issue merges into the launch branch.
#   -- ...         Passed to every `claude --bg` verbatim; defaults added only for flags not present
#                  (--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto —
#                  skills/auto/SKILL.md's unattended-run prerequisites, same as fleet-launch.sh).
#
#   status         One-screen readout of the marker: mode, branch, PR, per-issue session, liveness,
#                  outcome and where it landed, the branch's position against its base, the runner's
#                  liveness. Read-only.
#   stop           Ask the runner to stop after the issue in flight; nothing is killed, what shipped stays
#                  on the branch, and no PR is opened (re-run the list, or integration-pr.sh by hand).
#                  Killing the in-flight session is `claude agents`, never this.
#
# Why sessions and not one loop: a targeted `/auto <ID>` is one-shot and a `/loop /auto` never picks
# `solo` work, and a big issue wants a fresh context of its own. Why one branch and not a stack of PRs:
# GitHub's stacked pull requests assume a rebase-and-restack workflow, and this house merges and never
# rebases (standards/git.md) — so when the launch branch moved, every PR in the stack had to be re-merged
# level by level, each with its own CI run, and the stack still reached the launch branch one merge at a
# time (measured September 2026 on three PRs stacked on `hotfixes`). One branch takes one catch-up merge and
# one CI run, and it is the release shape an epic-scoped fleet already uses (fleet-launch.sh).
#
# Positioning: `/start wt` forks from the main checkout's HEAD (not from the branch ref) and `/finish`
# merges into the recorded source branch, so before EVERY dispatch the runner detaches HEAD at the
# integration branch's tip and sets `start.wt-source-branch` to it — the documented detached-HEAD path
# (start-wt-setup.sh), under which finish-merge.sh advances the branch ref-only. Re-detaching per issue is
# what makes each fork carry its predecessor: the ref moves at each merge, a detached HEAD does not. The
# checkout is put back on the launch branch, config unset, on every exit. In `merge` mode the checkout
# simply stays on the launch branch and each merge fast-forwards it.
#
# Sequencing: dispatch, wait for the session's ledger tmp/auto-state-<id>.json to record the issue (the
# registry `claude agents --json --all` is the fallback for a session that ends without one), then
# require the target branch's tip to have moved — a `shipped` whose merge the queue deferred is waited on
# up to FLEET_SEQUENCE_MERGE_TIMEOUT. Any other outcome stops the sequence with the remaining issues
# untouched — /auto already commented and labeled the issue. Re-running the same list resumes: issues the
# marker recorded as shipped are skipped, the branch is kept, and a list whose every issue has shipped
# goes straight to the PR step — which is also how a run whose PR could not be opened is completed.
#
# Env: FLEET_SEQUENCE_POLL (seconds between reads, default 30), FLEET_SEQUENCE_GRACE (default 120),
# FLEET_SEQUENCE_ISSUE_TIMEOUT (default 21600 — 6h per issue; on expiry the sequence fails and the session
# is left running), FLEET_SEQUENCE_MERGE_TIMEOUT (default 1800 — how long a shipped issue may take to land
# on the branch; the merge-queue drainer runs every 15 minutes), FLEET_SEQUENCE_PR_UPDATE=0 skips the
# closing /pr-update session, FLEET_SEQUENCE_PR_UPDATE_TIMEOUT (default 1800), FLEET_SEQUENCE_FOREGROUND=1
# runs the runner inline (tests).
#
# Read-write: tmp/fleet-sequence.json (the marker) and tmp/fleet-sequence.log in the main checkout; creates
# the integration branch, moves the main checkout's HEAD between issues and sets/unsets
# `start.wt-source-branch`, pushes the branch, opens its PR, dispatches background claude sessions. Exit 1
# on argument/environment errors before anything is dispatched; the runner exits 1 when the sequence fails.

set -eo pipefail

usage() {
  echo "usage: fleet-sequence.sh [pr|merge] <ISSUE-ID>... [-- <claude flags...>] | fleet-sequence.sh status | stop" >&2
  exit 1
}

for cmd in claude jq git gh; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

here=$(cd "$(dirname "$0")" && pwd)
main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the project the sequence should work on" >&2; exit 1; }
mkdir -p "$main_checkout/tmp"
marker="$main_checkout/tmp/fleet-sequence.json"
log="$main_checkout/tmp/fleet-sequence.log"
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

restore_checkout() { # back on the launch branch, config unset — best-effort, on every runner exit
  local base
  base=$(jq -r '.base // empty' "$marker" 2>/dev/null || true)
  [ -n "$base" ] || return 0
  git -C "$main_checkout" config --unset start.wt-source-branch >/dev/null 2>&1 || true
  [ "$(git -C "$main_checkout" branch --show-current 2>/dev/null)" = "$base" ] && return 0
  git -C "$main_checkout" checkout -q "$base" >/dev/null 2>&1 || logln "WARN: could not put the main checkout back on $base — do it by hand (git checkout $base)"
}

position_checkout() { # <ISSUE-ID> — park the checkout where the next fork and merge must happen
  local mode branch
  mode=$(jq -r '.mode' "$marker"); branch=$(target_branch)
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || fail_run "branch '$branch' no longer exists — nothing to ship $1 onto; re-run once it is restored"
  if [ "$mode" = "merge" ]; then
    git config --unset start.wt-source-branch >/dev/null 2>&1 || true
    [ "$(git branch --show-current 2>/dev/null)" = "$branch" ] || git checkout -q "$branch" || fail_run "could not check out $branch before $1"
  else
    git checkout -q --detach "$branch" || fail_run "could not detach at $branch before $1"
    git config start.wt-source-branch "$branch"
  fi
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
  # /pr-update reads the current branch, so the checkout is attached to the branch for this one session;
  # the runner owns the checkout until the run ends, and restore_checkout puts it back after.
  git config --unset start.wt-source-branch >/dev/null 2>&1 || true
  git checkout -q "$branch" || { logln "WARN: could not check out $branch for /pr-update — run it by hand from the branch"; return 0; }
  logln "dispatching: claude --bg ${claude_args[*]} -n 'fleet-sequence pr-update' '/pr-update'  (on $branch — the title and body come from the diff)"
  if ! out=$(claude --bg "${claude_args[@]}" -n "fleet-sequence pr-update" "/pr-update" 2>&1); then
    printf '%s\n' "$out"; logln "WARN: /pr-update dispatch failed — run it by hand from $branch"; return 0
  fi
  printf '%s\n' "$out"
  sid=$(parse_sid "$out")
  [ -n "$sid" ] || { logln "WARN: could not read the /pr-update session id — run /pr-update by hand from $branch once it ends"; return 0; }
  update_marker --arg s "$sid" '.pr_update_session = $s'
  wait_session_end "$sid" "$pr_update_timeout" \
    || logln "WARN: /pr-update session $sid still running after ${pr_update_timeout}s — not killed; the checkout is restored under it, so re-run /pr-update from $branch once it ends"
}

# =====================================================================================
cmd_status() {
  [ -s "$marker" ] || { echo "No sequence marker at $marker — nothing launched here."; exit 0; }
  local status base mode branch queue runner_pid runner live id sid st outcome landed pr_url ahead behind
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

cmd_stop() {
  [ -s "$marker" ] || { echo "No sequence marker at $marker — nothing to stop."; exit 0; }
  local status
  status=$(jq -r '.status' "$marker")
  if [ "$status" != "running" ]; then echo "Sequence is already $status — nothing to stop."; exit 0; fi
  update_marker '.stop_requested = true'
  echo "Stop requested: the runner finishes the issue in flight, then stops; what shipped stays on the branch and no PR is opened."
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
  restore_checkout
  if [ -s "$marker" ] && [ "$(jq -r '.status' "$marker")" = "running" ]; then
    update_marker --arg r "runner exited unexpectedly (exit $rc) — see $log" '.status = "failed" | .reason = $r | .current = null'
  fi
}

cmd_run() {
  [ -s "$marker" ] || { echo "ERROR: no marker at $marker — the runner only runs under a launch" >&2; exit 1; }
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

    position_checkout "$id"
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
    if ! wait_session "$sid" "$issue_timeout" "$id" "$started"; then
      fail_run "$id: session $sid still running after ${issue_timeout}s — not killed; watch it in \`claude agents\`, then re-run the same list"
    fi
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
  restore_checkout
  if [ "$mode" = "merge" ]; then
    logln "done: $ids_csv merged into $base — $(jq -r '[.queue[] as $q | "\($q) \(.issues[$q].landed_sha // "?" | .[0:12])"] | join(", ")' "$marker")"
  else
    logln "done: $ids_csv on $target → $base — PR $(jq -r '.pr_url // "?"' "$marker")"
  fi
}

# =====================================================================================
cmd_launch() {
  local raw id norm prev json labels state current live k existing_issues dirty tok mode="pr" mode_set="" branch="" resume=0 carried="" src_cfg
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

  # A re-run on the same base in the same mode resumes the marker's run (onto a branch: only while that
  # branch still exists). Its shipped issues sit at Ready For Release and are skipped by the runner, so they
  # are not probed — the refusals below are for issues that would be dispatched.
  current=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  if [ -s "$marker" ] && [ -n "$current" ] && [ "$(jq -r '.base // ""' "$marker")" = "$current" ] && [ "$(jq -r '.mode // "pr"' "$marker")" = "$mode" ]; then
    if [ "$mode" = "merge" ]; then resume=1
    else
      branch=$(jq -r '.branch // ""' "$marker")
      if [ -n "$branch" ] && git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then resume=1; else branch=""; fi
    fi
  fi
  [ "$resume" -eq 1 ] && carried=$(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome == "shipped") | .key' "$marker" | paste -sd' ' -)
  for id in "${normalized[@]}"; do
    case " $carried " in *" $id "*) continue ;; esac
    json=$(linear-cli issues get "$id" -o json 2>/dev/null) || { echo "ERROR: could not read $id from Linear (linear-cli issues get failed)" >&2; exit 1; }
    labels=$(printf '%s' "$json" | jq -r '.labels.nodes[].name' 2>/dev/null || true)
    state=$(printf '%s' "$json" | jq -r '.state.name // ""' 2>/dev/null || true)
    printf '%s\n' "$labels" | grep -qix specified || { echo "ERROR: $id is not certified (no specified label) — run /spec $id first" >&2; exit 1; }
    printf '%s\n' "$labels" | grep -qix human && { echo "ERROR: $id is human-owned work (human label) — no unattended mode can ship it" >&2; exit 1; }
    case "$state" in
      Done|Canceled|Duplicate|"Ready For Release") echo "ERROR: $id is already $state — nothing to ship" >&2; exit 1 ;;
    esac
  done

  # A sequence is solo work by definition: never alongside a fleet, never alongside another sequence.
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
  if [ -s "$marker" ] && [ "$(jq -r '.status' "$marker")" = "running" ]; then
    k=$(jq -r '.runner_pid // empty' "$marker")
    if [ -n "$k" ] && kill -0 "$k" 2>/dev/null; then
      echo "ERROR: a sequence is already running (runner pid $k, $(jq -r '.queue | join(" → ")' "$marker")) — fleet-sequence.sh status / stop first" >&2
      exit 1
    fi
  fi

  dirty=$(git -C "$main_checkout" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "ERROR: main checkout is dirty — the runner moves HEAD between issues, and every session's /auto would halt at its Step 1 preflight." >&2
    printf '%s\n' "$dirty" | sed 's/^/       /' >&2
    echo "       Commit or stash the above, then re-run. Nothing was dispatched." >&2
    exit 1
  fi
  [ -n "$current" ] || { echo "ERROR: HEAD is detached — check out the branch the sequence should ship onto, then re-run" >&2; exit 1; }
  src_cfg=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
  if [ -n "$src_cfg" ]; then
    echo "ERROR: start.wt-source-branch is set to '$src_cfg' — another posture (an epic fleet, an unfinished sequence) is in effect; finish it or unset it (git config --unset start.wt-source-branch), then re-run" >&2
    exit 1
  fi

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
        echo "ERROR: branch '$branch' already exists but no marker records a sequence on it from '$current' — delete it (git branch -D $branch) or re-run the list that created it" >&2
        exit 1
      fi
      git -C "$main_checkout" branch "$branch" "$current" || { echo "ERROR: could not create $branch from $current" >&2; exit 1; }
    elif ! git -C "$main_checkout" merge-base --is-ancestor "$current" "$branch" 2>/dev/null; then
      echo "WARN: '$branch' is behind '$current' — the PR will need one catch-up merge (Update branch) before it merges" >&2
    fi
  fi

  existing_issues='{}'
  if [ "$resume" -eq 1 ]; then
    existing_issues=$(jq -c '(.issues // {}) | with_entries(select(.value.outcome == "shipped"))' "$marker")
    if [ "$(printf '%s' "$existing_issues" | jq 'length')" -gt 0 ]; then
      echo "Resuming on ${branch:-$current}: already shipped, kept — $(printf '%s' "$existing_issues" | jq -r 'to_entries | map("\(.key) (landed \(.value.landed_sha // "unrecorded" | .[0:12]))") | join(", ")')"
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

  local queue_json args_json pr_url
  queue_json=$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -s .)
  args_json=$(printf '%s\n' "${claude_args[@]}" | jq -R . | jq -s 'map(select(length > 0))')
  pr_url=""; [ "$resume" -eq 1 ] && pr_url=$(jq -r '.pr_url // ""' "$marker")
  jq -n --argjson q "$queue_json" --arg base "$current" --arg mode "$mode" --arg branch "$branch" --argjson a "$args_json" \
        --argjson now "$(date +%s)" --arg log "$log" --argjson issues "$existing_issues" --arg pr "$pr_url" \
    '{queue: $q, base: $base, mode: $mode, branch: (if $branch == "" then null else $branch end), claude_args: $a,
      status: "running", reason: "", stop_requested: false, current: null, issues: $issues,
      pr_url: (if $pr == "" then null else $pr end), pr_number: null, launch_epoch: $now, log: $log, runner_pid: null}' > "$marker"

  if [ "$mode" = "merge" ]; then
    echo "Sequence: $(printf '%s' "$queue_json" | jq -r 'join(" → ")') merging into $current one issue at a time (no PR)"
  else
    echo "Sequence: $(printf '%s' "$queue_json" | jq -r 'join(" → ")') onto $branch (forked from $current); one PR onto $current when the list completes"
  fi
  if [ "${FLEET_SEQUENCE_FOREGROUND:-0}" = "1" ]; then
    cmd_run
    return
  fi
  ( cd "$main_checkout" && nohup "$here/fleet-sequence.sh" run > "$log" 2>&1 < /dev/null & echo $! > "$main_checkout/tmp/fleet-sequence.pid" )
  local pid
  pid=$(cat "$main_checkout/tmp/fleet-sequence.pid" 2>/dev/null || true); rm -f "$main_checkout/tmp/fleet-sequence.pid"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "ERROR: runner did not start — see $log" >&2; update_marker '.status = "failed" | .reason = "runner did not start"'; exit 1; }
  update_marker --argjson p "$pid" '.runner_pid = $p'
  echo "Runner detached (pid $pid) — log: $log"
  if [ "$mode" = "merge" ]; then
    echo "Each issue runs in its own background session; the main checkout stays on $current and advances with every merge — leave it alone until the run ends."
  else
    echo "Each issue runs in its own background session; the main checkout's HEAD is parked on $branch between issues — leave it alone until the run ends."
  fi
  echo "Watch with: fleet-sequence.sh status  |  claude agents"
}

case "${1:-}" in
  status) [ $# -eq 1 ] || usage; cmd_status ;;
  stop)   [ $# -eq 1 ] || usage; cmd_stop ;;
  run)    [ $# -eq 1 ] || usage; cmd_run ;;
  "")     usage ;;
  *)      cmd_launch "$@" ;;
esac
