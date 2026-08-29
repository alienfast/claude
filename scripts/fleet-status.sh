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
# Liveness comes from the session registry (`claude agents --json`), joined on the ledger's own
# filename key. The ledger's recorded pid CANNOT answer it: under `claude agents` every session in
# a fleet embeds the fleet-root pid (skills/auto/SKILL.md Step 4 — "only ever a coarse 'is anything
# still running' hint"), so siblings share one value and a session whose recorded ancestor exited
# reads dead while it works. Measured 2026-08-25: all three ledgers of one fleet held a pid that
# was not their session's, in both directions — two shared the live fleet root and read ALIVE for
# the fleet, one read dead while busy and was nearly reaped. The pid pair survives only as a
# last-resort hint when the registry is unavailable, and then the row says `unknown`, never `dead`.
# Only a registry-confirmed absence is flagged as a session that died without recording an outcome.
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

# Session registry, fetched once (not per row). Empty whenever `claude` is missing, exits non-zero,
# or returns something that is not a JSON array — every one of which degrades to `unknown`, never to
# a death claim.
agents_json=""
if command -v claude >/dev/null 2>&1; then
  agents_json=$(claude agents --json 2>/dev/null || true)
  printf '%s' "$agents_json" | jq -e 'type == "array"' >/dev/null 2>&1 || agents_json=""
fi
have_registry=0
[ -n "$agents_json" ] && have_registry=1

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

# Registry lookup: prints a display state when the run key is present, empty when it is absent.
# Always exits 0 so a caller's `x=$(registry_row ...)` cannot trip `set -e`. Keyed on `.id`, the
# 8-char short id that is also the ledger filename key; `.pid` is deliberately not read (absent on
# 16 of 23 rows in the live sample) and a null `.state` means present-but-unlabelled, so it renders
# as running rather than being mistaken for absence.
registry_row() {
  [ "$have_registry" -eq 1 ] || return 0
  printf '%s' "$agents_json" \
    | jq -r --arg k "$1" 'map(select(.id == $k)) | if length == 0 then "" else (.[0].state // "running") end' 2>/dev/null \
    || true
}

# True when a run key's transcript opens with /auto or /loop /auto. Mirrors fleet-metrics.py's
# is_auto_session, INCLUDING its decisive rule: the verdict comes from the FIRST human turn, so a
# session that merely mentions /auto later (this readout quotes it) is not one. Without this gate an
# interactive session that claimed an issue here is rowed in a fleet table as though the fleet ran
# it — measured 2026-08-25, where the operator's own /start wt session was mistaken for a fourth
# fleet member for a whole retro. Transcripts live under the mangled checkout path, plus one dir per
# worktree, so the glob matches what fleet-metrics.py walks. The gsub is load-bearing: a real
# opening turn is a MULTI-LINE string ("<command-message>loop</command-message>\n<command-name>…"),
# so without flattening, `head -1` takes the first LINE rather than the first MESSAGE and every
# genuine /loop /auto session reads as interactive.
proj_root="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
proj_mangled=$(printf '%s' "$main_checkout" | tr / -)
is_auto_run() {
  local key="$1" d f first
  for d in "$proj_root/$proj_mangled"*; do
    [ -d "$d" ] || continue
    for f in "$d/$key"*.jsonl; do
      [ -f "$f" ] || continue
      first=$(head -n 60 "$f" 2>/dev/null \
        | jq -rR 'fromjson? | select(.type == "user") | (.message.content? // empty)
                  | if type == "string" then . else ([.[]? | select(.type? == "text") | .text? // empty] | join(" ")) end
                  | select(. != "") | gsub("\n"; " ")' 2>/dev/null | head -1) || first=""
      [ -n "$first" ] || continue
      case "$first" in
        *"<command-name>/auto</command-name>"*) return 0 ;;
        *"<command-name>/loop</command-name>"*) case "$first" in *"/auto"*) return 0 ;; esac ;;
      esac
    done
  done
  return 1
}

# Fallback only, and only ever reported as `unknown` — see the pid note in the header. Kept because
# a live-vs-dead pid still narrows the guess for a reader with no registry.
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
    # -le, not -lt: fleet-launch stamps launch_epoch as it dispatches, so a ledger whose last write
    # lands in that same second was written by a session that had not been dispatched yet — it is
    # prior-run history. Measured 2026-08-21: a prior session's ledger tied launch_epoch exactly and
    # read as current-fleet for a whole run, inflating shipped 5→7 and session-hours 7.4→12.0, and
    # presenting a finished session as a live one idling through four status checks.
    if [[ "$mtime" =~ ^[0-9]+$ ]] && [ "$mtime" -le "$scope_epoch" ]; then
      hidden=$((hidden + 1))
      continue
    fi
  fi
  shown_files="$shown_files $f"
done
# Ledger-less sessions: an /auto session that owns a worktree here but has written no auto-state file
# — one killed before /auto Step 4 records its outcome. Without this pass it is absent from the table
# entirely while its worktree still shows up under "In flight", which reads as an unowned worktree.
# The gate below is what keeps that from over-firing: on 2026-08-25 the only worktree owner missing a
# ledger was the operator's own interactive session, which belongs in neither this pass nor the table.
# The worktree identity sidecar is the source rather than
# the registry's cwd: a sidecar means the session claimed an issue here, whereas cwd would also
# match any interactive session sitting in the checkout. fleet-metrics.py has the transcript-based
# equivalent for after the fact; this one only sees a session while its worktree exists, which is
# exactly the window this readout is read in. Owners are recorded in both the 8-char and the full
# uuid form, so both normalize to the short id the ledger filenames and the registry use.
ledger_keys=" "
for f in $state_files; do
  ledger_keys="$ledger_keys$(basename "$f" | sed 's/auto-state-//;s/\.json//') "
done
ledgerless_keys=""
for sc in "$main_checkout"/.claude/worktree-identity/wt-identity-*.env; do
  [ -f "$sc" ] || continue
  # Sidecars OUTLIVE their worktree — the directory retains one per worktree ever created, so the
  # bare glob yields every session that ever worked this repo (17 of them here on first run). Only
  # a sidecar whose worktree still exists names a session that is plausibly mid-issue right now.
  wt_name=$(basename "$sc" .env); wt_name=${wt_name#wt-identity-}
  [ -d "$main_checkout/.claude/worktrees/$wt_name" ] || continue
  o=$(sed -n 's/^WT_IDENTITY_OWNER=//p' "$sc" | head -1)
  [ -n "$o" ] || continue
  # Owners are written in BOTH forms — short id (84c3c783) and full uuid (35d198f1-9722-...) were
  # both observed in one fleet — while ledger filenames and registry ids are always the short one.
  # Truncate only what actually looks like a uuid: a blind ${o%%-*} also eats the first hyphen of a
  # non-uuid owner, silently turning a session that HAS a ledger into a phantom ledger-less row.
  case "$o" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) o=${o%%-*} ;;
  esac
  [ -n "$o" ] || continue
  case "$ledger_keys" in *" $o "*) continue ;; esac
  case " $ledgerless_keys " in *" $o "*) continue ;; esac
  # Only an /auto session belongs in a fleet table. An interactive session owning a worktree here is
  # the operator's own work, not a fleet member that lost its ledger.
  is_auto_run "$o" || continue
  ledgerless_keys="$ledgerless_keys $o"
done

died_active=""
all_shipped=""
fc_entries=""
if [ -z "$shown_files" ] && [ -z "$ledgerless_keys" ]; then
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
    if [ "$have_registry" -eq 1 ]; then
      rstate=$(registry_row "$key")
      if [ -n "$rstate" ]; then
        live="ALIVE ($rstate)"
      else
        live="dead"
        [ "$status" = "active" ] && died_active="$died_active $key"
      fi
    elif session_alive "$pid" "$pid_start"; then
      live="unknown (no registry; pid live)"
    else
      live="unknown (no registry; pid dead)"
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$key" "$live" "$status" "${shipped:-—}" "${canceled:-—}" "${failed:-—}" "$blocks"
  done
  for k in $ledgerless_keys; do
    live="unknown"
    if [ "$have_registry" -eq 1 ]; then
      rstate=$(registry_row "$k")
      if [ -n "$rstate" ]; then live="ALIVE ($rstate)"; else live="dead"; fi
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$k" "$live" "**no ledger**" "?" "?" "?" "?"
  done
  printf '\n'
fi
[ -n "$ledgerless_keys" ] && printf '_%d /auto session(s) own a worktree here but have written no `auto-state` ledger. Their shipped work is NOT counted in the cross-check below, which is built from ledgers only — /fleet-retro recovers them from transcripts. Interactive sessions holding a worktree are deliberately not listed._\n\n' "$(printf '%s' "$ledgerless_keys" | wc -w | tr -d ' ')"
[ "$hidden" -gt 0 ] && printf '_%d prior-run ledger(s) hidden (written before the current launch); /fleet-retro reads them until the next launch clears the dead ones._\n\n' "$hidden"
for k in $died_active; do
  printf '⚠️  **Session %s reads `active` but its process is gone** — either it died without recording an outcome (check its last issue for a stranded In Progress claim), or it wound down cleanly and never wrote its terminal status, which strands nothing. Its transcript tells them apart: a `NO-CANDIDATES`/`AUTO-HALTED` tag or a ScheduleWakeup(stop:true) means it finished. `fleet-metrics.py` reports the second shape as `wound down but never finalized its ledger`.\n\n' "$k"
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
if [ -n "$queue" ] && ! printf '%s' "$queue" | grep -Eq "queue empty|no repos registered"; then
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
