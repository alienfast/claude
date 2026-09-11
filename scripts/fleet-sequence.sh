#!/bin/bash
# fleet-sequence.sh — ship an ORDERED list of certified issues as a stack of PRs: one background
# `claude --bg "/auto pr <ID>"` session at a time, each issue forked from the previous issue's branch
# and its PR targeting that branch, the first targeting the branch you launch from.
#
# Usage: fleet-sequence.sh <ISSUE-ID>... [-- <claude flags...>]
#        fleet-sequence.sh status
#        fleet-sequence.sh stop
#        fleet-sequence.sh run            (internal: the detached runner; reads tmp/fleet-sequence.json)
#
#   <ISSUE-ID>...  The issues in the order they must ship. Each must carry `specified` and not `human`
#                  (the same probe /auto's targeted mode runs), and must not already be terminal or
#                  Ready For Release — unless the marker records it shipped on this launch branch, which
#                  a resume skips unprobed. `solo` is expressly fine — this is the runner for it.
#   -- ...         Passed to every `claude --bg` verbatim; defaults added only for flags not present
#                  (--model 'opus[1m]' --effort xhigh --autocompact 500000 --permission-mode auto —
#                  skills/auto/SKILL.md's unattended-run prerequisites, same as fleet-launch.sh).
#
#   status         One-screen readout of the marker: per-issue session, liveness, outcome and PR, the
#                  stack in merge order, the runner's liveness. Read-only.
#   stop           Ask the runner to stop after the issue in flight; nothing is killed, and the PRs
#                  already opened stand. Killing the in-flight session is `claude agents`, never this.
#
# Why sessions and not one loop: a targeted `/auto <ID>` is one-shot and a `/loop /auto` never picks
# `solo` work, and a big issue wants a fresh context of its own. Why a stack: `/auto pr` alone forks
# every issue from the launch branch, so a dependent forks without its predecessor's code
# (skills/auto/SKILL.md's `pr` caveat); forking each issue from the previous one's branch is the fix,
# and one PR per issue is what Linear's PR linking and the auto-close keyword rule assume. The stack
# unwinds bottom-up: GitHub retargets the next PR to the launch branch when its base merges and is
# deleted. Merge commits only — a squash or rebase merge rewrites the base and every dependent needs
# a restack.
#
# Positioning between issues: `/start wt` forks from the main checkout's HEAD and records the branch it
# is on as the PR base (start-wt-setup.sh); a branch checked out in a live worktree cannot be checked
# out again, so the runner DETACHES HEAD at the previous issue's branch tip and sets
# `start.wt-source-branch` to that branch — the documented detached-HEAD path. The checkout is put
# back on the launch branch, config unset, on every exit.
#
# Sequencing: dispatch, wait for the session registry (`claude agents --json --all`) to list the
# session as done (absent after FLEET_SEQUENCE_GRACE seconds counts as done; with no registry the
# ledger alone decides), read the outcome from the session's ledger tmp/auto-state-<id>.json, and
# continue only on `shipped` with an open PR found for the issue's worktree branch. Any other outcome
# stops the sequence with the remaining issues untouched — /auto already commented and labeled the
# issue. Re-running the same list resumes: issues the marker recorded as shipped are skipped and the
# next one forks from the last shipped branch.
#
# Env: FLEET_SEQUENCE_POLL (seconds between registry reads, default 30), FLEET_SEQUENCE_GRACE (default
# 120), FLEET_SEQUENCE_ISSUE_TIMEOUT (default 21600 — 6h per issue; on expiry the sequence fails and
# the session is left running), FLEET_SEQUENCE_FOREGROUND=1 runs the runner inline (tests).
#
# Read-write: tmp/fleet-sequence.json (the marker) and tmp/fleet-sequence.log in the main checkout;
# moves the main checkout's HEAD between issues and sets/unsets `start.wt-source-branch`; dispatches
# background claude sessions. Exit 1 on argument/environment errors before anything is dispatched;
# the runner exits 1 when the sequence fails.

set -eo pipefail

usage() {
  echo "usage: fleet-sequence.sh <ISSUE-ID>... [-- <claude flags...>] | fleet-sequence.sh status | stop | link" >&2
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
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %m "$1" 2>/dev/null || echo 0; }
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
    # a registry-only wait burned the whole 6h timeout and failed the sequence with the PR already open.
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

# ---- the main checkout's position ----
restore_checkout() { # back on the launch branch, config unset — best-effort, on every runner exit
  local base
  base=$(jq -r '.base // empty' "$marker" 2>/dev/null || true)
  [ -n "$base" ] || return 0
  git -C "$main_checkout" config --unset start.wt-source-branch >/dev/null 2>&1 || true
  [ "$(git -C "$main_checkout" branch --show-current 2>/dev/null)" = "$base" ] && return 0
  git -C "$main_checkout" checkout -q "$base" >/dev/null 2>&1 || logln "WARN: could not put the main checkout back on $base — do it by hand (git checkout $base)"
}

open_pr_for() { # <branch> → prints "<url>\t<base>\t<number>" or nothing
  gh pr list --head "$1" --state open --json url,baseRefName,number 2>/dev/null \
    | jq -r 'if type == "array" and length > 0 then "\(.[0].url)\t\(.[0].baseRefName)\t\(.[0].number)" else empty end' 2>/dev/null || true
}

# ---- the GitHub stack ----
# GitHub's stacked pull requests (public preview, API version 2026-03-10): a stack is an ordered list of
# PR numbers, bottom to top, each PR's base equal to the previous PR's head — exactly the chain the
# runner builds — created once two PRs exist and extended by one each time another opens. Linking never
# fails the sequence: the ships are the expensive part, and a stack can be created by hand afterwards.
gh_stack_api() { gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' "$@"; }
shipped_pr_numbers() { # → JSON array of the shipped issues' PR numbers in queue order
  jq -c '[ .queue[] as $q | .issues[$q] | select(.outcome == "shipped")
           | (.pr_number // ((.pr_url // "") | split("/") | last | tonumber? )) | select(. != null) ]' "$marker"
}
link_stack() {
  local prs count stack_number first existing out in_stack new
  prs=$(shipped_pr_numbers); count=$(printf '%s' "$prs" | jq 'length')
  stack_number=$(jq -r '.stack_number // empty' "$marker")
  if [ -z "$stack_number" ]; then
    first=$(printf '%s' "$prs" | jq -r '.[0] // empty')
    [ -n "$first" ] || return 0
    # Adopt a stack that already holds the bottom PR — one created in the web UI, or by a previous run
    # whose marker was rewritten.
    existing=$(gh_stack_api "repos/{owner}/{repo}/stacks?pull_request=$first" 2>/dev/null | jq -r 'if type == "array" then (.[0].number // empty) else empty end' 2>/dev/null || true)
    if [ -n "$existing" ]; then
      stack_number="$existing"
      update_marker --argjson n "$stack_number" '.stack_number = $n'
      logln "GitHub stack #$stack_number already holds PR #$first — extending it"
    fi
  fi
  if [ -z "$stack_number" ]; then
    if [ "$count" -lt 2 ]; then logln "GitHub stack: created once the second PR exists"; return 0; fi
    if ! out=$(printf '{"pull_requests":%s}' "$prs" | gh_stack_api --method POST 'repos/{owner}/{repo}/stacks' --input - 2>&1); then
      logln "WARN: could not create the GitHub stack for PRs $prs — $(printf '%s' "$out" | head -1). Create it by hand: printf '{\"pull_requests\":$prs}' | gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' 'repos/{owner}/{repo}/stacks' --input -"
      return 0
    fi
    stack_number=$(printf '%s' "$out" | jq -r '.number // empty' 2>/dev/null || true)
    [ -n "$stack_number" ] || { logln "WARN: stack created but its number could not be read from the response — check the PRs' merge box"; return 0; }
    update_marker --argjson n "$stack_number" --arg u "$(printf '%s' "$out" | jq -r '.url // ""')" '.stack_number = $n | .stack_url = $u'
    logln "GitHub stack #$stack_number created: PRs $prs (bottom → top)"
    return 0
  fi
  in_stack=$(gh_stack_api "repos/{owner}/{repo}/stacks/$stack_number" 2>/dev/null | jq -c '[.pull_requests[]?.number]' 2>/dev/null || echo '[]')
  new=$(jq -nc --argjson a "$prs" --argjson b "$in_stack" '$a - $b')
  [ "$(printf '%s' "$new" | jq 'length')" -gt 0 ] || return 0
  if ! out=$(printf '{"pull_requests":%s}' "$new" | gh_stack_api --method POST "repos/{owner}/{repo}/stacks/$stack_number/add" --input - 2>&1); then
    logln "WARN: could not add PRs $new to GitHub stack #$stack_number — $(printf '%s' "$out" | head -1). Add by hand: printf '{\"pull_requests\":$new}' | gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' 'repos/{owner}/{repo}/stacks/$stack_number/add' --input -"
    return 0
  fi
  logln "GitHub stack #$stack_number extended with PRs $new"
}

# =====================================================================================
cmd_status() {
  [ -s "$marker" ] || { echo "No sequence marker at $marker — nothing launched here."; exit 0; }
  local status base queue runner_pid runner live id sid st outcome pr_url branch stack prev stack_number
  status=$(jq -r '.status' "$marker"); base=$(jq -r '.base' "$marker")
  queue=$(jq -r '.queue | join(" → ")' "$marker")
  runner_pid=$(jq -r '.runner_pid // empty' "$marker")
  runner="not detached"
  if [ -n "$runner_pid" ]; then
    if kill -0 "$runner_pid" 2>/dev/null; then runner="alive (pid $runner_pid)"; else runner="gone (pid $runner_pid)"; fi
  fi
  printf '**Sequence:** %s · **base:** `%s` · **status:** %s · **runner:** %s' "$queue" "$base" "$status" "$runner"
  [ "$(jq -r '.stop_requested' "$marker")" = "true" ] && printf ' · **stop requested**'
  printf '\n'
  [ "$(jq -r '.reason // ""' "$marker")" != "" ] && printf '**Reason:** %s\n' "$(jq -r '.reason' "$marker")"
  printf '\n| issue | session | liveness | outcome | branch | PR |\n|---|---|---|---|---|---|\n'
  for id in $(jq -r '.queue[]' "$marker"); do
    sid=$(jq -r --arg id "$id" '.issues[$id].session // ""' "$marker")
    outcome=$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")
    branch=$(jq -r --arg id "$id" '.issues[$id].branch // ""' "$marker")
    pr_url=$(jq -r --arg id "$id" '.issues[$id].pr_url // ""' "$marker")
    live="—"
    if [ -n "$sid" ]; then
      st=$(registry_state "$sid") || st="?"
      case "$st" in "") live="not listed" ;; "?") live="no registry" ;; *) live="$st" ;; esac
    fi
    if [ -z "$sid" ] && [ -z "$outcome" ]; then outcome="queued"; fi
    printf '| %s | %s | %s | %s | %s | %s |\n' "$id" "${sid:-—}" "$live" "${outcome:-in flight}" "${branch:-—}" "${pr_url:-—}"
  done
  stack=""; prev="$base"
  for id in $(jq -r '.queue[]' "$marker"); do
    [ "$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")" = "shipped" ] || continue
    branch=$(jq -r --arg id "$id" '.issues[$id].branch // "?"' "$marker")
    pr_url=$(jq -r --arg id "$id" '.issues[$id].pr_url // "?"' "$marker")
    stack="$stack
- $id: \`$branch\` → \`$prev\` — $pr_url"
    prev="$branch"
  done
  if [ -n "$stack" ]; then printf '\n**Stack (bottom → top):**%s\n' "$stack"; else printf '\n**Stack:** nothing shipped yet\n'; fi
  stack_number=$(jq -r '.stack_number // empty' "$marker")
  if [ -n "$stack_number" ]; then printf '**GitHub stack:** #%s — merging the top PR merges the whole stack\n' "$stack_number"
  elif [ -n "$stack" ]; then printf '**GitHub stack:** not linked yet (created once two PRs exist)\n'; fi
  [ -f "$log" ] && { printf '\n**Log** (`%s`, last 5 lines):\n\n```\n' "$log"; tail -5 "$log"; printf '```\n'; }
  return 0
}

cmd_stop() {
  [ -s "$marker" ] || { echo "No sequence marker at $marker — nothing to stop."; exit 0; }
  local status
  status=$(jq -r '.status' "$marker")
  if [ "$status" != "running" ]; then echo "Sequence is already $status — nothing to stop."; exit 0; fi
  update_marker '.stop_requested = true'
  echo "Stop requested: the runner finishes the issue in flight, then stops; the PRs opened so far stand."
  echo "Nothing is killed — to abort the in-flight session use \`claude agents\`. Re-run the same list to continue the stack."
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
  local base ids_csv id sid out outcome prev_branch branch pr_line pr_url pr_base pr_number remaining now started wt count stack_note
  local claude_args=() queue=()
  base=$(jq -r '.base' "$marker")
  while IFS= read -r id; do queue+=("$id"); done < <(jq -r '.queue[]' "$marker")
  while IFS= read -r out; do claude_args+=("$out"); done < <(jq -r '.claude_args[]' "$marker")
  ids_csv=$(jq -r '.queue | join(", ")' "$marker")
  logln "sequence started: $ids_csv stacked on $base; runner pid $$"

  local i=0
  for id in "${queue[@]}"; do
    i=$((i+1))
    if [ "$(jq -r --arg id "$id" '.issues[$id].outcome // ""' "$marker")" = "shipped" ]; then
      logln "[$i/${#queue[@]}] $id already shipped ($(jq -r --arg id "$id" '.issues[$id].pr_url // "PR unrecorded"' "$marker")) — skipping"
      continue
    fi
    if [ "$(jq -r '.stop_requested' "$marker")" = "true" ]; then
      remaining=$(printf '%s\n' "${queue[@]:$((i-1))}" | paste -sd, - | sed 's/,/, /g')
      logln "STOPPED: stopped before $id; not started: $remaining — re-run the same list to continue the stack"
      update_marker --arg r "stopped before $id; not started: $remaining — re-run the same list to continue the stack" '.status = "stopped" | .reason = $r | .current = null'
      exit 0
    fi
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      fail_run "main checkout is dirty before $id — /auto would halt on it; resolve and re-run the same list"
    fi

    # The fork point is the nearest earlier issue that shipped; the launch branch for the first.
    prev_branch=$(jq -r --arg id "$id" --arg base "$base" '
      (.queue | index($id)) as $n
      | [ .queue[0:$n][] as $q | .issues[$q] | select(.outcome == "shipped" and (.branch // "") != "") | .branch ]
      | if length > 0 then .[-1] else $base end' "$marker")
    if [ "$prev_branch" = "$base" ]; then
      git config --unset start.wt-source-branch >/dev/null 2>&1 || true
      [ "$(git branch --show-current 2>/dev/null)" = "$base" ] || git checkout -q "$base" || fail_run "could not check out $base before $id"
    else
      git rev-parse --verify --quiet "refs/heads/$prev_branch" >/dev/null || fail_run "previous branch '$prev_branch' no longer exists — the stack below $id is broken; re-run once it is restored"
      git checkout -q --detach "$prev_branch" || fail_run "could not detach at $prev_branch before $id"
      git config start.wt-source-branch "$prev_branch"
    fi
    started=$(date +%s)
    update_marker --arg id "$id" --argjson now "$started" --arg prev "$prev_branch" \
      '.current = $id | .issues[$id] = {started_epoch: $now, forked_from: $prev}'
    logln "[$i/${#queue[@]}] dispatching: claude --bg ${claude_args[*]} -n 'fleet-sequence $id' '/auto pr $id'  (forks from $prev_branch)"
    if ! out=$(claude --bg "${claude_args[@]}" -n "fleet-sequence $id" "/auto pr $id" 2>&1); then
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

    # The issue's branch lives in its preserved worktree; its open PR is what the stack is made of.
    wt="$main_checkout/.claude/worktrees/$(lower "$id")"
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || fail_run "$id shipped but its worktree ($wt) has no branch to stack on — see claude logs $sid"
    pr_line=$(open_pr_for "$branch")
    [ -n "$pr_line" ] || fail_run "$id shipped on '$branch' but no open PR was found for it — open one from the worktree with /pr-update (base $prev_branch), then re-run the same list"
    pr_url=${pr_line%%$'\t'*}; pr_number=${pr_line##*$'\t'}; pr_base=${pr_line#*$'\t'}; pr_base=${pr_base%%$'\t'*}
    update_marker --arg id "$id" --arg b "$branch" --arg u "$pr_url" --arg pb "$pr_base" --argjson n "${pr_number:-0}" \
      '.issues[$id] += {branch: $b, pr_url: $u, pr_base: $pb, pr_number: $n}'
    logln "[$i/${#queue[@]}] $id PR #$pr_number $pr_url ($branch → $pr_base)"
    link_stack
    [ "$pr_base" = "$prev_branch" ] || logln "WARN: $id's PR targets '$pr_base', not '$prev_branch' — the stack is not what the runner set up; check the worktree's start.source-branch"
    if git merge-base --is-ancestor "$prev_branch" "$branch" 2>/dev/null; then
      count=$(git rev-list --count "$prev_branch..$branch" 2>/dev/null || echo 0)
      [ "${count:-0}" -gt 0 ] || logln "WARN: '$branch' has no commits beyond '$prev_branch' although its ledger says shipped — check the session's log before merging"
    else
      logln "WARN: '$branch' does not contain '$prev_branch' — the next issue would fork without $prev_branch's code; check the worktree before continuing"
    fi
  done
  update_marker '.current = null | .status = "done"'
  restore_checkout
  stack_note=$(jq -r 'if .stack_number then "GitHub stack #\(.stack_number) — merging the top PR merges the whole stack" else "no GitHub stack (fewer than two PRs, or linking failed — see WARNs above)" end' "$marker")
  logln "done: $ids_csv stacked on $base — $stack_note. Bottom → top: $(jq -r --arg base "$base" '
    [ .queue[] as $q | .issues[$q] | select(.outcome == "shipped") | "\($q) \(.pr_url // "?")" ] | join("  →  ")' "$marker")"
}

# =====================================================================================
cmd_launch() {
  local raw id norm prev json labels state current live k existing_issues dirty
  local ids=() claude_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; claude_args=("$@"); break ;;
      -*) echo "ERROR: unknown option '$1' — fleet-sequence takes issue IDs in ship order, then optionally -- <claude flags>" >&2; usage ;;
      *) ids+=("$1"); shift ;;
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
  # A resume's already-shipped issues sit at Ready For Release (a PR-mode ship lands there) and are skipped by
  # the runner, so they are not probed — the refusals below are for issues that would be dispatched.
  local carried=""
  current=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  if [ -s "$marker" ] && [ -n "$current" ] && [ "$(jq -r '.base // ""' "$marker")" = "$current" ]; then
    carried=$(jq -r '(.issues // {}) | to_entries[] | select(.value.outcome == "shipped") | .key' "$marker" | paste -sd' ' -)
  fi
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
  current=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)
  [ -n "$current" ] || { echo "ERROR: HEAD is detached — check out the branch the stack's first PR should target, then re-run" >&2; exit 1; }

  # The first PR's base is the launch branch, and `gh pr create --base` needs it on origin — an unpushed
  # launch branch would spend the whole first session and then fail at its PR. Launching off the default
  # branch is legitimate (the stack sits on top of unmerged work and reaches the default branch when that
  # work's own PR merges), so it is a note, not a refusal.
  if git -C "$main_checkout" remote get-url origin >/dev/null 2>&1; then
    if ! git -C "$main_checkout" ls-remote --exit-code --heads origin "$current" >/dev/null 2>&1; then
      echo "ERROR: '$current' does not exist on origin — the first PR's base must be a remote branch. Push it (git push -u origin $current), or launch from the default branch." >&2
      exit 1
    fi
    local default_branch
    default_branch=$(git -C "$main_checkout" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    if [ -n "$default_branch" ] && [ "$default_branch" != "$current" ]; then
      echo "NOTE: launching from '$current', not '$default_branch' — the first PR targets $current and the stack reaches $default_branch only when $current's own PR merges (GitHub retargets on merge). $current's changes are in every PR's history and in no PR's diff." >&2
    fi
  fi

  # Re-running a list resumes it: issues the previous marker recorded as shipped on this same base keep
  # their branch and PR and are skipped, so the next one forks from the last shipped branch.
  existing_issues='{}'
  if [ -s "$marker" ] && [ "$(jq -r '.base // ""' "$marker")" = "$current" ]; then
    existing_issues=$(jq -c --argjson q "$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -s .)" \
      '(.issues // {}) | with_entries(select(.value.outcome == "shipped" and (.key as $k | $q | index($k) != null)))' "$marker")
    if [ "$(printf '%s' "$existing_issues" | jq 'length')" -gt 0 ]; then
      echo "Resuming on $current: already shipped, kept — $(printf '%s' "$existing_issues" | jq -r 'to_entries | map("\(.key) (\(.value.pr_url // "PR unrecorded"))") | join(", ")')"
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

  local queue_json args_json
  queue_json=$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -s .)
  args_json=$(printf '%s\n' "${claude_args[@]}" | jq -R . | jq -s 'map(select(length > 0))')
  jq -n --argjson q "$queue_json" --arg base "$current" --argjson a "$args_json" --argjson now "$(date +%s)" \
        --arg log "$log" --argjson issues "$existing_issues" \
    '{queue: $q, base: $base, claude_args: $a, status: "running", reason: "", stop_requested: false,
      current: null, issues: $issues, launch_epoch: $now, log: $log, runner_pid: null}' > "$marker"

  echo "Sequence: $(printf '%s' "$queue_json" | jq -r 'join(" → ")') as a PR stack on $current (each issue forks from the previous one's branch)"
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
  echo "Each issue runs in its own background session; the main checkout's HEAD moves between issues — leave it alone until the run ends."
  echo "Watch with: fleet-sequence.sh status  |  claude agents"
}

cmd_link() { # link the marker's shipped PRs into a GitHub stack now — for a run that shipped before linking existed, or whose linking WARNed
  [ -s "$marker" ] || { echo "No sequence marker at $marker — nothing to link."; exit 0; }
  cd "$main_checkout"
  local before after
  before=$(jq -r '.stack_number // empty' "$marker")
  link_stack
  after=$(jq -r '.stack_number // empty' "$marker")
  if [ -n "$after" ]; then
    echo "GitHub stack #$after holds $(gh_stack_api "repos/{owner}/{repo}/stacks/$after" 2>/dev/null | jq -r '[.pull_requests[]?.number | "#\(.)"] | join(" → ")' 2>/dev/null || echo '?')${before:+ (was already recorded)}"
  else
    echo "No stack linked — see the WARN above, or fewer than two shipped PRs in $marker"
  fi
}

case "${1:-}" in
  status) [ $# -eq 1 ] || usage; cmd_status ;;
  stop)   [ $# -eq 1 ] || usage; cmd_stop ;;
  link)   [ $# -eq 1 ] || usage; cmd_link ;;
  run)    [ $# -eq 1 ] || usage; cmd_run ;;
  "")     usage ;;
  *)      cmd_launch "$@" ;;
esac
