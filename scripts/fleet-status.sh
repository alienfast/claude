#!/bin/bash
# fleet-status.sh — one-screen readout of a running (or finished) /fleet-launch: time left,
# per-session ledgers, in-flight issues, and runway. The during-view between /auto-prep and
# /fleet-retro: those bookends exist, but mid-run the operator's only options were opening
# every session in `claude agents` or hand-joining the markers — this script does the join.
#
# Usage: fleet-status.sh [epic:<ID> | team] [--no-runway]
#   Run from the project the fleet works on (a worktree cwd is fine). Several fleets run side by side
#   in one checkout, one marker each (lib/fleet-markers.sh): with no token every running fleet gets its
#   own section (deadline, sessions, scope, shipped, runway) and the checkout-wide sections (in flight,
#   merge queue, attention) print once; a token reads one fleet alone. --no-runway skips the
#   remaining-candidates count, the one section that costs a Linear ranking call (~10-20s) per fleet.
#
# Sources (all read-only; no Linear writes, no git mutations):
#   tmp/fleet-deadline-<slug>.json     one per running fleet (an archived fleet-deadline-<slug>.<epoch>.json is
#                                      not read): fleet_sessions (the session set) + launch_epoch + count, plus
#                                      the deadline when the launch carried one, plus scope + the
#                                      prep-time members snapshot (+ branch/base) when it was
#                                      epic-scoped, plus backlog: true under a `backlog` launch —
#                                      the runway then counts with --backlog-fallback (fleet-launch.sh)
#   epic-graph.sh (scoped fleets)      the live membership, for the shipped/remaining/added burn-down
#   tmp/auto-state-*.json              per-session ledgers: shipped/canceled/failed, mode
#   .claude/worktrees/ + worktree-identity/ sidecars   in-flight issues, session ownership
#   linear-cli (optional)              issue state/title joins, failed/canceled cross-check,
#                                      stalled flags, runway
#   .claude/merge-queue/               deferred merges (via merge-queue.sh list)
#   fleet-headroom.sh                  the pick-time headroom probe, run once per fleet session on its own
#                                      mods/rate-limits history: a THROTTLE answer means sessions are parked
#
# Sessions are scoped to EACH fleet: its marker's fleet_sessions decides membership when the
# launch recorded it (every launch since 2026-08-29), and a single-run ledger (`mode: single` — a
# targeted or one-shot /auto) is never a member; without the set, ledgers whose last write predates
# the launch are prior-run history. Another fleet's ledgers, and ended fleets' ledgers awaiting their
# retro, are hidden from a fleet's table with a count (a launch expires them once /fleet-retro has
# measured their fleet — fleet-launch.sh § Expiry). Failed/canceled entries are further
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
fleet_token=""
usage() { echo "usage: fleet-status.sh [epic:<ID> | team] [--no-runway]" >&2; exit 1; }
for a in "$@"; do
  case "$a" in
    --no-runway) no_runway=1 ;;
    [Ee][Pp][Ii][Cc]:*|[Tt][Ee][Aa][Mm]) [ -z "$fleet_token" ] || usage; fleet_token="$a" ;;
    *) usage ;;
  esac
done

# The four ledger lists are bare issue ids (skills/auto/SKILL.md Step 4), but a session once appended its last ship as
# {"issue":"BF-2531","tag":"SHIPPED-MERGE","at":…} and `join(", ")` over that mix errors, which the swallowed substitution turned
# into a silently missing session row. ids(k) reads a list with an object entry as its .issue and drops what has no string id;
# LEDGER_OFFSCHEMA_JQ prints "<normalized> <dropped>" so the table can say it happened.
LEDGER_IDS_JQ='def good: type == "object" and (.issue | type) == "string" and .issue != "";
  def ids(k): ((.[k] | if type == "array" then . else [] end) | map(if type == "string" then . elif good then .issue else empty end));'
LEDGER_OFFSCHEMA_JQ='def good: type == "object" and (.issue | type) == "string" and .issue != "";
  [(.shipped, .canceled, .skipped, .failed) | arrays[] | select(type != "string")]
  | "\(map(select(good)) | length) \(map(select(good | not)) | length)"'

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
. "$SCRIPT_DIR/../lib/fleet-markers.sh"

# The fleets to read: the token's, else every live marker; none → one pass with no marker, the empty-state readout.
markers=()
if [ -n "$fleet_token" ]; then
  case "$fleet_token" in [Tt][Ee][Aa][Mm]) slug=team ;; *) slug=$(fleet_slug "${fleet_token#*:}") ;; esac
  m=$(fleet_marker_path "$main_checkout" "$slug")
  if ! [ -s "$m" ]; then
    echo "ERROR: no fleet marker for $fleet_token ($m). Fleets with a marker here:" >&2
    while IFS= read -r f; do [ -n "$f" ] && echo "  $(fleet_marker_token "$f")  ($f)" >&2; done < <(fleet_live_markers "$main_checkout")
    exit 1
  fi
  markers=("$m")
else
  while IFS= read -r f; do [ -n "$f" ] && markers+=("$f"); done < <(fleet_live_markers "$main_checkout")
fi

now=$(date +%s)
printf '## Fleet status — %s\n\n' "$(basename "$main_checkout")"
if [ "${#markers[@]}" -gt 1 ]; then
  fleet_list=$(for f in "${markers[@]}"; do fleet_marker_token "$f"; echo; done | paste -sd, - | sed 's/,/, /g')
  printf '_%d fleets in this checkout — one section each: %s. Read one alone with `fleet-status.sh epic:<ID> | team`._\n\n' "${#markers[@]}" "$fleet_list"
fi
teams_seen=""

render_fleet() { # <marker path, or empty when the checkout has no fleet>
local marker="$1"
[ "${#markers[@]}" -gt 1 ] && printf '### Fleet %s\n\n' "$(fleet_marker_token "$marker")"

# ---------- deadline ----------

fleet_set=""
if [ -s "$marker" ]; then
  d_epoch=$(jq -r '.deadline_epoch // empty' "$marker")
  d_human=$(jq -r '.deadline // empty' "$marker")
  d_count=$(jq -r '.count // empty' "$marker")
  fleet_set=$(jq -r '(.fleet_sessions // []) | join(" ")' "$marker" 2>/dev/null || true)
  f_n=$(printf '%s' "$fleet_set" | wc -w | tr -d ' ')
  if [ "$f_n" -gt 0 ]; then launched_note=" ($f_n session(s) in the fleet)"; else launched_note="${d_count:+ ($d_count session(s) launched)}"; fi
  if [ "$(jq -r '.stopped // false' "$marker")" = "true" ]; then
    printf '**Deadline: STOPPED** (wind-down requested) — sessions finish their in-flight issue and end at the next pick.\n\n'
  elif [ -n "$d_epoch" ] && [ "$d_epoch" -gt "$now" ]; then
    rem=$(( (d_epoch - now) / 60 ))
    printf '**Deadline:** %s — **%dh%02dm remaining**%s\n\n' "$d_human" $((rem / 60)) $((rem % 60)) "$launched_note"
  elif [ -n "$d_epoch" ]; then
    printf '**Deadline:** %s — **passed**; sessions stop at their next pick boundary.\n\n' "$d_human"
  else
    # Every launch writes the marker; only a dated one carries deadline_epoch.
    printf '**Deadline:** none — loops run until the certified backlog drains.%s\n\n' "$launched_note"
  fi
else
  printf '**Deadline:** none — loops run until the certified backlog drains.\n\n'
fi
printf '_Wind down early: `/fleet-stop%s` — ends the timer, in-flight issues finish, nothing is killed._\n\n' "$([ -s "$marker" ] && printf ' %s' "$(fleet_marker_token "$marker")")"

# ---------- headroom ----------

# A parked session writes nothing to its ledger, so without this line a park reads like a death. Each fleet session is probed on
# its own mods/rate-limits history (the account it runs on), the machine's snapshot standing in for a session with none; silent
# while every reading is under the reserve, and a warning when no reading exists at all — the gate then fails open on every pick.
if [ -s "$marker" ] && [ -x "$SCRIPT_DIR/fleet-headroom.sh" ]; then
  h_throttle=""; h_seen=0
  for k in ${fleet_set:-snapshot}; do
    if [ "$k" = snapshot ]; then h_line=$("$SCRIPT_DIR/fleet-headroom.sh" 2>/dev/null) || true
    else h_line=$("$SCRIPT_DIR/fleet-headroom.sh" --session "$k" 2>/dev/null) || true; fi
    case "$h_line" in
      THROTTLE*) h_seen=1; [ -z "$h_throttle" ] && h_throttle="$h_line" ;;
      *'source=none'*) ;;
      PICK-OK*) h_seen=1 ;;
    esac
  done
  if [ -n "$h_throttle" ]; then
    printf '**Headroom: THROTTLE** — sessions park between picks and re-probe at the window reset (every ~30 min at most), so a quiet ledger may be a park rather than a death: `%s`\n\n' "$h_throttle"
  elif [ "$h_seen" = 0 ]; then
    printf '**⚠️ Headroom gate is blind** — no mods/rate-limits reading for this fleet'"'"'s sessions or this machine (`~/.claude/local/rate-limits/`), so every pick fails open and nothing parks a session short of a mid-issue cutoff. Enable rate-limits@alienfast-claude (update.sh installs it) before the next launch.\n\n'
  fi
fi

# ---------- epic scope + member burn-down ----------

# An epic-scoped launch (fleet-launch.sh epic:<ID>) records scope, the prep-time member snapshot,
# and the integration branch. The burn-down is a LIVE epic-graph.sh read against that snapshot —
# membership is recomputed at every pick, so members filed mid-run show up here as "added since
# prep" rather than silently widening the fleet's work: while open, and once this fleet's own
# sessions ship or cancel them (with their state). One resolved outside the fleet's ledgers — an
# interactive pickup, a session that never wrote one — counts as shipped only.
scope=""
[ -s "$marker" ] && scope=$(jq -r '.scope // empty' "$marker" 2>/dev/null || true)
if [ -n "$scope" ]; then
  s_branch=$(jq -r '.branch // empty' "$marker")
  s_base=$(jq -r '.base // empty' "$marker")
  printf '**Scope:** epic %s' "$scope"
  [ -n "$s_branch" ] && printf ' — integration branch `%s`%s' "$s_branch" "${s_base:+ (forked from \`$s_base\`; ships as one PR onto it)}"
  printf '\n\n'
  if [ "$have_linear" -eq 1 ]; then
    graph=$("$SCRIPT_DIR/epic-graph.sh" "$scope" 2>/dev/null) || graph=""
    if [ -n "$graph" ]; then
      snapshot=$(jq -c '.members // []' "$marker")
      # A member filed mid-run that the fleet already shipped or canceled is terminal now, so it is in .terminal, not
      # .members. The snapshot alone cannot place it: prep records non-terminal members only, so a member already Done
      # at prep is absent from it too. What separates the two is this fleet's own ledgers — read here, because the
      # Shipped cross-check's union is built later and from the displayed rows only.
      fleet_resolved='[]'
      ledgers=()
      for k in $fleet_set; do
        if [ -s "$main_checkout/tmp/auto-state-$k.json" ]; then ledgers+=("$main_checkout/tmp/auto-state-$k.json"); fi
      done
      if [ "${#ledgers[@]}" -gt 0 ]; then
        fleet_resolved=$(jq -s -c '[.[] | (.shipped // [])[], (.canceled // [])[]] | unique' "${ledgers[@]}" 2>/dev/null) || fleet_resolved='[]'
      fi
      printf '%s' "$graph" | jq -r --arg root "$scope" --argjson snap "$snapshot" --argjson resolved "$fleet_resolved" '
        ([.members[] | select(.identifier != $root)]) as $rem
        | ([.terminal[] | select(.identifier != $root)]) as $done
        | ([$rem[] | select(.state_type == "started") | .identifier]) as $flight
        | ([$rem[] | select(.identifier as $i | ($snap | index($i)) == null) | .identifier]) as $added_open
        | ([$done[] | select(.identifier as $i | ($snap | index($i)) == null and ($resolved | index($i)) != null)
            | "\(.identifier) [\(.state)]"]) as $added_done
        | ($added_open + $added_done) as $added
        | "**Members:** \($done | length) shipped · \($rem | length) remaining"
          + (if ($flight | length) > 0 then " (\($flight | length) in flight: \($flight | join(", ")))" else "" end)
          + (if ($snap | length) == 0 then " · no prep snapshot in the marker, so added-since-prep is unknown"
             elif ($added | length) > 0 then " · \($added | length) added since prep: \($added | join(", "))"
             else " · none added since prep" end)
          + (if ($done | length) > 0 then "\n  shipped: \($done | map("\(.identifier) [\(.state)]") | join(", "))" else "" end)'
      printf '\n'
    else
      printf '_Member burn-down unavailable — `epic-graph.sh %s` failed; the epic may have lost its label or become unreadable._\n\n' "$scope"
    fi
  else
    printf '_Member burn-down skipped — linear-cli unavailable._\n\n'
  fi
fi

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
      scope_epoch=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo "")
    fi
  fi
fi

# ---------- sessions (auto-state ledgers) ----------

# Registry lookup: prints a display state when the run key is present, empty when it is absent.
# Always exits 0 so a caller's `x=$(registry_row ...)` cannot trip `set -e`. Keyed on `.id`, the
# 8-char short id that is also the ledger filename key, falling back to the sessionId's first
# segment (the same value) because `id` comes and goes by harness version and session kind:
# present on every `--bg` row and absent on every interactive row on 2026-08-29, absent on every
# row in the 2026-08-17 snapshot auto-stall-watch.sh was rebuilt against. Without the fallback a
# targeted `/auto <ID>` run in a terminal — a ledger, no `id` — reads `dead` with the registry
# present and raises the stranded-claim flag this join exists to prevent. `.pid` is deliberately
# not read as liveness (absent on 16 of 23 rows in one live sample) and a null `.state` means
# present-but-unlabelled, so it renders as running rather than being mistaken for absence. Two
# listed shapes are ENDED sessions and print `ended`: a `done`/`failed`/`stopped` state (a `done`
# row measured 2026-08-29 — the harness settles a `--bg` session when its launch prompt's turn ends,
# or the daemon retires it), and the row `claude stop` leaves behind — its state unchanged, with
# the `status` and `pid` keys both GONE (measured 2026-10-04 on a `working` row and a `done` one;
# every live row that day carried both). The second test is taken only when some row in the same
# registry carries `status`, so a schema that drops the key entirely reads as live, never as dead.
registry_row() {
  [ "$have_registry" -eq 1 ] || return 0
  printf '%s' "$agents_json" \
    | jq -r --arg k "$1" '
        any(.[]; has("status")) as $carries_status
        | map(select((.id // (.sessionId // "" | split("-")[0])) == $k))
        | if length == 0 then ""
          elif ((.[0].state // "running") | IN("done","failed","stopped")) then "ended"
          elif $carries_status and ((.[0] | has("status")) | not) and ((.[0] | has("pid")) | not) then "ended"
          else (.[0].state // "running") end' 2>/dev/null \
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
# The harness names the dir by replacing every non-alphanumeric character of the session cwd with a dash (C:/Users/x/.claude
# lives under c--Users-x--claude) and spells a Windows drive letter however the session's cwd did, so match either case.
proj_mangled=$(printf '%s' "$main_checkout" | sed 's/[^A-Za-z0-9]/-/g')
case "$main_checkout" in
  [A-Za-z]:*) d0=$(printf '%s' "$proj_mangled" | cut -c1)
              proj_mangled="[$(printf '%s' "$d0" | tr A-Z a-z)$(printf '%s' "$d0" | tr a-z A-Z)]${proj_mangled#?}" ;;
esac
is_auto_run() {
  local key="$1" d f first proj_root
  proj_root="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  for d in "$proj_root"/$proj_mangled*; do
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
single_hidden=0
for f in $state_files; do
  key=$(basename "$f" | sed 's/auto-state-//;s/\.json//')
  # A single-run ledger (`mode: single` — a targeted or one-shot /auto, skills/auto/SKILL.md Step 4)
  # is never a fleet member, whatever its mtime: it is what a time-window scope admitted 26 of.
  if [ "$(jq -r '.mode // "loop"' "$f" 2>/dev/null)" = "single" ]; then
    single_hidden=$((single_hidden + 1))
    continue
  fi
  # Membership when the launch recorded the set; the launch_epoch window only for older markers.
  if [ -n "$fleet_set" ]; then
    case " $fleet_set " in *" $key "*) ;; *) hidden=$((hidden + 1)); continue ;; esac
  elif [[ "$scope_epoch" =~ ^[0-9]+$ ]]; then
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "")
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
  # A sidecar can outlive its worktree (one removed by hand waits for the reaper's next sweep), so the
  # bare glob is not the live set. Only a sidecar whose worktree still exists names a session that is
  # plausibly mid-issue right now.
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
# A recorded member with no ledger yet: still in preflight, or killed before its first outcome.
for k in $fleet_set; do
  case "$ledger_keys" in *" $k "*) continue ;; esac
  case " $ledgerless_keys " in *" $k "*) continue ;; esac
  ledgerless_keys="$ledgerless_keys $k"
done

died_active=""
ledger_warns=""
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
    shipped=$(jq -r "$LEDGER_IDS_JQ"' ids("shipped") | join(", ")' "$f")
    canceled=$(jq -r "$LEDGER_IDS_JQ"' ids("canceled") | join(", ")' "$f")
    failed=$(jq -r "$LEDGER_IDS_JQ"' ids("failed") | join(", ")' "$f")
    read -r off_norm off_drop <<< "$(jq -r "$LEDGER_OFFSCHEMA_JQ" "$f")"
    if [ "$(( ${off_norm:-0} + ${off_drop:-0} ))" -gt 0 ]; then
      off_n=$(( off_norm + off_drop ))
      ledger_warns="$ledger_warns"$(printf 'WARN: session %s ledger carries %d off-schema entr%s (objects where /auto writes bare ids) — %d normalized to .issue%s' \
        "$key" "$off_n" "$([ "$off_n" -eq 1 ] && echo y || echo ies)" "$off_norm" "$([ "$off_drop" -gt 0 ] && echo ", $off_drop dropped (no string id)")")$'\n'
    fi
    blocks=$(jq -r '.reviewBlocks // 0' "$f")
    all_shipped="$all_shipped $(printf '%s' "$shipped" | tr -d ',')"
    for id in $(printf '%s' "$failed" | tr -d ','); do fc_entries="$fc_entries$id failed $key"$'\n'; done
    for id in $(printf '%s' "$canceled" | tr -d ','); do fc_entries="$fc_entries$id canceled $key"$'\n'; done
    if [ "$have_registry" -eq 1 ]; then
      rstate=$(registry_row "$key")
      case "$rstate" in
        "")    live="dead"; [ "$status" = "active" ] && died_active="$died_active $key" ;;
        ended) live="dead (ended)"; [ "$status" = "active" ] && died_active="$died_active $key" ;;
        *)     live="ALIVE ($rstate)" ;;
      esac
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
      case "$rstate" in "") live="dead" ;; ended) live="dead (ended)" ;; *) live="ALIVE ($rstate)" ;; esac
    fi
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$k" "$live" "**no ledger**" "?" "?" "?" "?"
  done
  printf '\n'
  [ -n "$ledger_warns" ] && printf '%s\n' "$ledger_warns"
fi
[ -n "$ledgerless_keys" ] && printf '_%d fleet session(s) have written no `auto-state` ledger (recorded at launch, or owning a worktree here). Their shipped work is NOT counted in the cross-check below, which is built from ledgers only — /fleet-retro recovers them from transcripts. Interactive sessions holding a worktree are deliberately not listed._\n\n' "$(printf '%s' "$ledgerless_keys" | wc -w | tr -d ' ')"
[ "$hidden" -gt 0 ] && printf '_%d ledger(s) hidden (another fleet'"'"'s, prior-run, or not in this fleet'"'"'s recorded session set); /fleet-retro reads them until a launch expires their fleet._\n\n' "$hidden"
[ "$single_hidden" -gt 0 ] && printf '_%d single-run ledger(s) not listed (`mode: single` — a targeted or one-shot /auto, not a fleet member; /fleet-retro measures it only when named with --sessions)._\n\n' "$single_hidden"
for k in $died_active; do
  printf '⚠️  **Session %s reads `active` but its process is gone** — either it died without recording an outcome (check its last issue for a stranded In Progress claim), or it wound down cleanly and never wrote its terminal status, which strands nothing. Its transcript tells them apart: a `NO-CANDIDATES`/`AUTO-HALTED` tag or a ScheduleWakeup(stop:true) means it finished. `fleet-metrics.py` reports the second shape as `wound down but never finalized its ledger`.\n\n' "$k"
done

# ---------- shipped ledger vs git ----------

printf '### Shipped (this fleet'"'"'s sessions), cross-checked against git\n\n'
all_shipped=$(printf '%s' "$all_shipped" | tr ' ' '\n' | sed '/^$/d' | sort -u)
if [ -z "$all_shipped" ]; then
  printf '_No session has recorded a ship here._\n\n'
else
  # The branch ships land on: the marker's integration branch on an epic fleet (its sessions steer onto it with
  # per-issue fork keys), else the checkout-wide key a parked checkout falls back to, else the checkout's branch.
  src_branch=$(jq -r '.branch // empty' "$marker" 2>/dev/null || true)
  if [ -n "$src_branch" ] && ! git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$src_branch" >/dev/null 2>&1; then
    printf '_The marker records integration branch `%s`, which no longer exists locally — ships are checked against the checkout instead._\n\n' "$src_branch"
    src_branch=""
  fi
  [ -n "$src_branch" ] || src_branch=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
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
      st=$(linear-cli api query "query { issue(id: \"$id\") { state { name type } labels { nodes { name } } } }" 2>/dev/null \
        | jq -r '.data.issue | [.state.type, .state.name, ([.labels.nodes[]?.name] | join(","))] | @tsv' 2>/dev/null || true)
      s_type=$(printf '%s' "$st" | cut -f1)
      s_name=$(printf '%s' "$st" | cut -f2)
      s_labels=$(printf '%s' "$st" | cut -f3)
      if [ -z "$s_type" ] || [ "$s_type" = "null" ]; then
        printf -- '- %s — recorded %s (session %s); Linear state unavailable\n' "$id" "$kind" "$keys"
      elif [ "$kind" = "failed" ]; then
        case "$s_type" in
          completed) printf -- '- %s — failed (session %s), **since shipped**: now [%s] — resolved by a later session or an interactive pickup ✓\n' "$id" "$keys" "$s_name" ;;
          canceled)  printf -- '- %s — failed (session %s), since canceled: [%s]\n' "$id" "$keys" "$s_name" ;;
          *)
            # A `failed` ledger row's outward marking depends on how the session stopped — a stall carries `stalled` (In Progress), a human-gated
            # park carries `human` / `needs decision` (Planned, unassigned) — so the row reads the labels instead of telling the operator to look
            # for one. The worktree check is the recovery signal: a parked or stalled issue with a preserved worktree holds finished or partial work
            # nothing else surfaces (BF-2329 sat parked `human` with four reviewed files staged while this row said "look for a `stalled` label").
            wt_dir="$main_checkout/.claude/worktrees/$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
            if [ -d "$wt_dir" ]; then
              wt_note="**worktree preserved at \`$wt_dir\` — finished or partial work to recover**"
            else
              wt_note="no preserved worktree"
            fi
            case ",$s_labels," in
              *,stalled,*)          mark='`stalled`, abandoned mid-flight — resume or release' ;;
              *",needs decision,"*) mark='parked `needs decision`' ;;
              *,human,*)            mark='parked `human`' ;;
              *)                    mark="" ;;
            esac
            if [ -z "$mark" ] && [ "$s_type" = "started" ]; then
              printf -- '- %s — failed (session %s), now [%s] — a retry may be in flight\n' "$id" "$keys" "$s_name"
            else
              printf -- '- %s — ⚠️ failed (session %s), still [%s] — %s; %s\n' "$id" "$keys" "$s_name" "${mark:-unresolved, no routing label}" "$wt_note"
            fi ;;
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

# ---------- team (for the runway; the attention sweep runs once per team after every fleet's section) ----------

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
# A scoped fleet names its own team — the epic's prefix — when nothing else did.
[ -z "$team" ] && [ -n "$scope" ] && team="${scope%%-*}"
[ -n "$team" ] && teams_seen="$teams_seen $team"

# ---------- runway ----------

if [ "$no_runway" -eq 0 ] && [ "$have_linear" -eq 1 ] && [ -n "$team" ]; then
  # A `backlog` launch (marker `backlog: true`) counts Backlog once nothing Planned/Todo is pickable —
  # the same flag every session's pick passes, so the runway is what the fleet will actually take.
  fb_flag=""
  if [ -s "$marker" ] && [ "$(jq -r '.backlog // false' "$marker" 2>/dev/null)" = "true" ]; then
    fb_flag="--backlog-fallback"
  fi
  # A scoped fleet's runway is the epic's: the same --root ranking every session picks from.
  if [ -n "$scope" ]; then
    ranking=$("$SCRIPT_DIR/next-candidates.sh" --root "$scope" --label specified --limit 100 $fb_flag 2>/dev/null || true)
    where="epic $scope"
  else
    ranking=$("$SCRIPT_DIR/next-candidates.sh" --team "$team" --label specified --limit 100 $fb_flag 2>/dev/null || true)
    where="$team"
  fi
  [ -n "$fb_flag" ] && where="$where (backlog fallback on)"
  n=$(printf '%s\n' "$ranking" | grep -c '^[0-9]*\. \*\*' || true)
  printf '### Runway\n\n**%s** unblocked certified candidate(s) remain in %s.\n' "$n" "$where"
  printf '%s\n' "$ranking" | grep '^_' | sed 's/^/  /' || true
  printf '\n'
elif [ "$no_runway" -eq 1 ]; then
  printf '### Runway\n\n_Skipped (--no-runway)._\n\n'
fi
}

if [ "${#markers[@]}" -eq 0 ]; then
  render_fleet ""
else
  for mk in "${markers[@]}"; do render_fleet "$mk"; done
fi

# ---------- in-flight (live worktrees) — checkout-wide ----------

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

# ---------- merge queue ----------

queue=$( (cd "$main_checkout" && "$SCRIPT_DIR/merge-queue.sh" list 2>/dev/null) || true)
if [ -n "$queue" ] && ! printf '%s' "$queue" | grep -Eq "queue empty|no repos registered"; then
  printf '### Merge queue\n\n```text\n%s\n```\n\n' "$queue"
fi

# ---------- attention (Linear flags), once per team the fleets touch ----------

if [ "$have_linear" -eq 1 ]; then
  for team in $(printf '%s\n' $teams_seen | awk 'NF' | sort -u); do
    stalled=$(linear-cli issues list --team "$team" -l stalled -o json 2>/dev/null \
      | jq -r '.[] | "- **\(.identifier)** [\(.state.name // "?")] \(.title)"' 2>/dev/null || true)
    if [ -n "$stalled" ]; then
      printf '### Needs attention — `stalled` (abandoned mid-flight)%s\n\n%s\n\n' "$([ "$(printf '%s\n' $teams_seen | awk 'NF' | sort -u | wc -l | tr -d ' ')" -gt 1 ] && printf ' — %s' "$team")" "$stalled"
    fi
  done
fi

printf -- '---\n_Live session view: `claude agents` · wind down: `/fleet-stop` · post-mortem when quiet: `/fleet-retro`_\n'
