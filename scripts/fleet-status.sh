#!/bin/bash
# fleet-status.sh — one-screen readout of a running (or finished) /fleet-launch: time left,
# per-session ledgers, in-flight issues, and runway. The during-view between /auto-prep and
# /fleet-retro: those bookends exist, but mid-run the operator's only options were opening
# every session in `claude agents` or hand-joining the markers — this script does the join.
#
# Usage: fleet-status.sh [--no-runway]
#   Run from the project the fleet works on (a worktree cwd is fine). --no-runway skips the
#   remaining-candidates count, the one section that costs a Linear ranking call (~10-20s).
#
# Sources (all read-only; no Linear writes, no git mutations):
#   tmp/fleet-deadline.json            deadline + launched count + launch_epoch (fleet-launch.sh)
#   tmp/auto-state-*.json              per-session ledgers: shipped/canceled/failed, pid liveness
#   .claude/worktrees/ + worktree-identity/ sidecars   in-flight issues, session ownership
#   linear-cli (optional)              issue state/title joins, failed/canceled cross-check,
#                                      stalled flags, runway
#   .claude/merge-queue/               deferred merges (via merge-queue.sh list)
#
# Sessions are scoped to the CURRENT fleet: ledgers whose last write predates the launch are
# prior-run history (fleet-launch clears the dead ones at the next launch; until then they are
# hidden here with a count, and /fleet-retro reads them). Failed/canceled entries are further
# cross-checked against each issue's current Linear state, because a ledger entry is a claim
# about that run only — a later session or an interactive pickup can ship the issue without
# any ledger recording it, and without the join a long-resolved failure reads as live.
#
# A session is ALIVE when its recorded pid exists AND the process start time matches the
# recorded one (pid reuse otherwise reads a dead session as running). A state file that says
# "active" with a dead pid is flagged — that session died without recording an outcome.
#
# Exit codes: 0 success, 1 not a git repo / missing dependency.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

no_runway=0
case "${1:-}" in
  --no-runway) no_runway=1 ;;
  "") ;;
  *) echo "usage: fleet-status.sh [--no-runway]" >&2; exit 1 ;;
esac

for cmd in git jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done
have_linear=0
command -v linear-cli >/dev/null 2>&1 && have_linear=1

main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository — run from the fleet's project" >&2; exit 1; }

now=$(date +%s)
printf '## Fleet status — %s\n\n' "$(basename "$main_checkout")"

# ---------- deadline ----------

marker="$main_checkout/tmp/fleet-deadline.json"
if [ -s "$marker" ]; then
  d_epoch=$(jq -r '.deadline_epoch // empty' "$marker")
  d_human=$(jq -r '.deadline // empty' "$marker")
  d_count=$(jq -r '.count // empty' "$marker")
  if [ "$(jq -r '.stopped // false' "$marker")" = "true" ]; then
    printf '**Deadline: STOPPED** (wind-down requested) — sessions finish their in-flight issue and end at the next pick.\n\n'
  elif [ -n "$d_epoch" ] && [ "$d_epoch" -gt "$now" ]; then
    rem=$(( (d_epoch - now) / 60 ))
    printf '**Deadline:** %s — **%dh%02dm remaining**%s\n\n' "$d_human" $((rem / 60)) $((rem % 60)) "${d_count:+ ($d_count session(s) launched)}"
  else
    printf '**Deadline:** %s — **passed**; sessions stop at their next pick boundary.\n\n' "$d_human"
  fi
else
  printf '**Deadline:** none — loops run until the certified backlog drains.\n\n'
fi
printf '_Wind down early: `/fleet-launch stop` — ends the timer, in-flight issues finish, nothing is killed._\n\n'

# ---------- fleet scoping epoch ----------

# launch_epoch is in the marker since 2026-08; an older launch-written marker falls back to its
# own mtime (equal to launch time), while a stop-rewritten legacy marker has no usable launch
# time at all — scoping is skipped rather than guessed.
scope_epoch=""
if [ -s "$marker" ]; then
  scope_epoch=$(jq -r '.launch_epoch // empty' "$marker")
  if ! [[ "$scope_epoch" =~ ^[0-9]+$ ]]; then
    if [ "$(jq -r '.stopped // false' "$marker")" = "true" ]; then
      scope_epoch=""
    else
      scope_epoch=$(stat -f %m "$marker" 2>/dev/null || stat -c %m "$marker" 2>/dev/null || echo "")
    fi
  fi
fi

# ---------- sessions (auto-state ledgers) ----------

# Liveness: pid exists AND its start time matches the recorded one (whitespace-normalized —
# ps pads single-digit days). A mismatch means pid reuse: the session is dead.
session_alive() {
  local pid="$1" recorded="$2" actual
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  actual=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
  [ "$actual" = "$(printf '%s' "$recorded" | tr -s ' ')" ]
}

printf '### Sessions\n\n'
state_files=$(ls -t "$main_checkout"/tmp/auto-state-*.json 2>/dev/null || true)
shown_files=""
hidden=0
for f in $state_files; do
  if [[ "$scope_epoch" =~ ^[0-9]+$ ]]; then
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %m "$f" 2>/dev/null || echo "")
    if [[ "$mtime" =~ ^[0-9]+$ ]] && [ "$mtime" -lt "$scope_epoch" ]; then
      hidden=$((hidden + 1))
      continue
    fi
  fi
  shown_files="$shown_files $f"
done
died_active=""
all_shipped=""
fc_entries=""
if [ -z "$shown_files" ]; then
  if [ "$hidden" -gt 0 ]; then
    printf '_No ledger from this fleet yet — sessions write their state file at the first recorded outcome._\n\n'
  else
    printf '_No auto-state files — no /auto session has recorded anything here._\n\n'
  fi
else
  printf '| session | liveness | status | shipped | canceled | failed | review blocks |\n'
  printf '|---|---|---|---|---|---|---|\n'
  for f in $shown_files; do
    key=$(basename "$f" | sed 's/auto-state-//;s/\.json//')
    pid=$(jq -r '.pid // empty' "$f")
    pid_start=$(jq -r '.pidStart // empty' "$f")
    status=$(jq -r '.status // "?"' "$f")
    shipped=$(jq -r '(.shipped // []) | join(", ")' "$f")
    canceled=$(jq -r '(.canceled // []) | join(", ")' "$f")
    failed=$(jq -r '(.failed // []) | join(", ")' "$f")
    blocks=$(jq -r '.reviewBlocks // 0' "$f")
    all_shipped="$all_shipped $(printf '%s' "$shipped" | tr -d ',')"
    for id in $(printf '%s' "$failed" | tr -d ','); do fc_entries="$fc_entries$id failed $key"$'\n'; done
    for id in $(printf '%s' "$canceled" | tr -d ','); do fc_entries="$fc_entries$id canceled $key"$'\n'; done
    if session_alive "$pid" "$pid_start"; then
      live="ALIVE (pid $pid)"
    else
      live="dead"
      [ "$status" = "active" ] && died_active="$died_active $key"
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$key" "$live" "$status" "${shipped:-—}" "${canceled:-—}" "${failed:-—}" "$blocks"
  done
  printf '\n'
fi
[ "$hidden" -gt 0 ] && printf '_%d prior-run ledger(s) hidden (written before the current launch); /fleet-retro reads them until the next launch clears the dead ones._\n\n' "$hidden"
for k in $died_active; do
  printf '⚠️  **Session %s reads `active` but its process is gone** — it died without recording an outcome; check its last issue for a stranded In Progress claim.\n\n' "$k"
done

# ---------- in-flight (live worktrees) ----------

printf '### In flight\n\n'
wt_count=0
while IFS= read -r wt; do
  case "$wt" in "$main_checkout"/.claude/worktrees/*) ;; *) continue ;; esac
  [ -d "$wt" ] || continue
  wt_count=$((wt_count + 1))
  issue=$(basename "$wt" | tr '[:lower:]' '[:upper:]')
  branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "?")
  owner=""
  sidecar="$main_checkout/.claude/worktree-identity/wt-identity-$(basename "$wt").env"
  [ -f "$sidecar" ] && owner=$(sed -n 's/^WT_IDENTITY_OWNER=//p' "$sidecar" | head -1)
  linear_bit=""
  if [ "$have_linear" -eq 1 ]; then
    linear_bit=$(linear-cli issues get "$issue" -o json -q 2>/dev/null \
      | jq -r '" — [\(.state.name // "?")] \(.title // "")"' 2>/dev/null || true)
  fi
  printf -- '- **%s**%s\n  branch `%s`%s\n' "$issue" "$linear_bit" "$branch" "${owner:+ · session $owner}"
done < <(git -C "$main_checkout" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
[ "$wt_count" -eq 0 ] && printf '_No live worktrees — nothing is mid-issue right now._\n'
printf '\n'

# ---------- shipped ledger vs git ----------

printf '### Shipped (this fleet'"'"'s sessions), cross-checked against git\n\n'
all_shipped=$(printf '%s' "$all_shipped" | tr ' ' '\n' | sed '/^$/d' | sort -u)
if [ -z "$all_shipped" ]; then
  printf '_No session has recorded a ship here._\n\n'
else
  # The integration branch: the same key start-wt-setup falls back to, else the checkout's branch.
  src_branch=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
  [ -n "$src_branch" ] || src_branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null)
  [ -n "$src_branch" ] || src_branch=HEAD
  recent_subjects=$(git -C "$main_checkout" log -300 --format='%s' "$src_branch" 2>/dev/null || true)
  for id in $all_shipped; do
    if printf '%s\n' "$recent_subjects" | grep -q "^$id:"; then
      printf -- '- %s — merged on `%s` ✓\n' "$id" "$src_branch"
    elif (cd "$main_checkout" && "$SCRIPT_DIR/merge-queue.sh" list 2>/dev/null) | grep -q "^$id "; then
      printf -- '- %s — **deferred**: sitting in the merge queue\n' "$id"
    else
      printf -- '- %s — ⚠️ recorded shipped but no commit found on `%s` and not queued — investigate\n' "$id" "$src_branch"
    fi
  done
  printf '\n'
fi

# ---------- failed/canceled ledger vs Linear ----------

# The counterpart of the shipped-vs-git join above: each failed/canceled entry checked against
# the issue's CURRENT state, so an entry resolved outside the ledgers reads as history, not as
# a live problem. Only the ⚠️ rows need action.
if [ -n "$fc_entries" ]; then
  printf '### Failed / canceled (recorded), cross-checked against Linear\n\n'
  if [ "$have_linear" -eq 0 ]; then
    printf '_linear-cli unavailable — entries not cross-checked._\n\n'
  else
    rollup=$(printf '%s' "$fc_entries" | sed '/^ *$/d' | sort -u \
      | awk '{k=$1" "$2; s[k]=s[k] ? s[k] "," $3 : $3} END {for (e in s) print e, s[e]}' | sort)
    while read -r id kind keys; do
      [ -n "$id" ] || continue
      st=$(linear-cli api query "query { issue(id: \"$id\") { state { name type } } }" 2>/dev/null \
        | jq -r '.data.issue.state | [.type, .name] | @tsv' 2>/dev/null || true)
      s_type=$(printf '%s' "$st" | cut -f1)
      s_name=$(printf '%s' "$st" | cut -f2)
      if [ -z "$s_type" ] || [ "$s_type" = "null" ]; then
        printf -- '- %s — recorded %s (session %s); Linear state unavailable\n' "$id" "$kind" "$keys"
      elif [ "$kind" = "failed" ]; then
        case "$s_type" in
          completed) printf -- '- %s — failed (session %s), **since shipped**: now [%s] — resolved by a later session or an interactive pickup ✓\n' "$id" "$keys" "$s_name" ;;
          canceled)  printf -- '- %s — failed (session %s), since canceled: [%s]\n' "$id" "$keys" "$s_name" ;;
          started)   printf -- '- %s — failed (session %s), now [%s] — a retry may be in flight\n' "$id" "$keys" "$s_name" ;;
          *)         printf -- '- %s — ⚠️ failed (session %s), still [%s] — unresolved; look for a `stalled` label and a preserved worktree\n' "$id" "$keys" "$s_name" ;;
        esac
      else
        case "$s_type" in
          canceled)  printf -- '- %s — canceled (session %s) — Linear agrees: [%s] ✓\n' "$id" "$keys" "$s_name" ;;
          completed) printf -- '- %s — ⚠️ recorded canceled (session %s) but Linear shows [%s] — reconcile\n' "$id" "$keys" "$s_name" ;;
          *)         printf -- '- %s — ⚠️ recorded canceled (session %s) but Linear shows [%s] — reopened since?\n' "$id" "$keys" "$s_name" ;;
        esac
      fi
    done <<< "$rollup"
    printf '\n'
  fi
fi

# ---------- merge queue ----------

queue=$( (cd "$main_checkout" && "$SCRIPT_DIR/merge-queue.sh" list 2>/dev/null) || true)
if [ -n "$queue" ] && ! printf '%s' "$queue" | grep -q "queue empty"; then
  printf '### Merge queue\n\n```text\n%s\n```\n\n' "$queue"
fi

# ---------- attention (Linear flags) ----------

team=""
if [ -n "${LINEAR_TEAM:-}" ]; then
  team="${LINEAR_TEAM%%,*}"
else
  # Infer from the issue prefixes in play (ledgers + live worktree dirnames); ambiguity leaves it unset.
  wt_issues=$(git -C "$main_checkout" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' \
    | grep "^$main_checkout/.claude/worktrees/" | xargs -n1 basename 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)
  fc_ids=$(printf '%s' "$fc_entries" | awk 'NF{print $1}' | sort -u)
  team=$(printf '%s\n%s\n%s\n' "$all_shipped" "$wt_issues" "$fc_ids" | sed -n 's/^\([A-Z][A-Z0-9]*\)-[0-9]*$/\1/p' | sort -u)
  [ "$(printf '%s\n' "$team" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ] || team=""
fi
if [ "$have_linear" -eq 1 ] && [ -n "$team" ]; then
  stalled=$(linear-cli issues list --team "$team" -l stalled -o json 2>/dev/null \
    | jq -r '.[] | "- **\(.identifier)** [\(.state.name // "?")] \(.title)"' 2>/dev/null || true)
  if [ -n "$stalled" ]; then
    printf '### Needs attention — `stalled` (abandoned mid-flight)\n\n%s\n\n' "$stalled"
  fi
fi

# ---------- runway ----------

if [ "$no_runway" -eq 0 ] && [ "$have_linear" -eq 1 ] && [ -n "$team" ]; then
  ranking=$("$SCRIPT_DIR/next-candidates.sh" --team "$team" --label specified --limit 100 2>/dev/null || true)
  n=$(printf '%s\n' "$ranking" | grep -c '^[0-9]*\. \*\*' || true)
  printf '### Runway\n\n**%s** unblocked certified candidate(s) remain in %s.\n' "$n" "$team"
  printf '%s\n' "$ranking" | grep '^_' | sed 's/^/  /' || true
  printf '\n'
elif [ "$no_runway" -eq 1 ]; then
  printf '### Runway\n\n_Skipped (--no-runway)._\n\n'
fi

printf -- '---\n_Live session view: `claude agents` · wind down: `/fleet-launch stop` · post-mortem when quiet: `/fleet-retro`_\n'
