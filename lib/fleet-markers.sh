#!/bin/bash
# fleet-markers.sh — the per-fleet marker and recommendation files under a checkout's tmp/. Sourced by every fleet
# script and hook that reads them; lib/fleet-markers.test.sh covers it, and fleet-launch.test.sh drives the writer.
#
# A fleet is keyed by its SLUG: the lowercased epic id of an epic-scoped fleet (`bf-2948`), `team` for a team-wide one.
# Several fleets run side by side in one checkout, each with its own files, and no reader ever guesses which fleet a
# session belongs to — the slug comes from the session's own `/auto` arguments, the hook's transcript, or the epic a
# caller names:
#   tmp/fleet-deadline-<slug>.json                 the LIVE marker fleet-launch.sh writes (skills/fleet-launch/SKILL.md
#                                                  § The deadline contract); at most one per slug, a top-up rewrites it
#   tmp/fleet-deadline-<slug>.<launch_epoch>.json  an ended run of that slug a later launch of the same slug displaced,
#                                                  kept until /fleet-retro has measured it (a fleet-metrics-history.jsonl
#                                                  row names one of its sessions); never read as the running fleet
#   tmp/fleet-recommendation-<slug>.json           what /auto-prep (`team`) or /epic-prep (the epic's slug) sized it at
# Until 2026-10-28 a checkout had ONE fleet-deadline.json and ONE fleet-recommendation.json, so a second epic could not
# launch while any fleet ran: the launch rewrote the marker the running sessions read, and the prep's recommendation
# overwrote the running fleet's sizing before its retro could compare against it.

fleet_slug() { # <scope or empty> → the slug: the scope lowercased, `team` when empty
  local s
  s=$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  if [ -n "$s" ]; then printf '%s' "$s"; else printf 'team'; fi
}

fleet_marker_path() { printf '%s/tmp/fleet-deadline-%s.json' "$1" "$2"; }        # <main checkout> <slug>
fleet_rec_path()    { printf '%s/tmp/fleet-recommendation-%s.json' "$1" "$2"; }  # <main checkout> <slug>

# <path> → its stem after the prefix, without .json: `bf-2948` for a live marker, `bf-2948.1793221071` for an archived one.
fleet_marker_stem() { local stem; stem=${1##*/fleet-deadline-}; printf '%s' "${stem%.json}"; }
fleet_marker_slug() { local stem; stem=$(fleet_marker_stem "$1"); printf '%s' "${stem%%.*}"; }   # <path> → slug
fleet_marker_archived() { case "$(fleet_marker_stem "$1")" in *.*) return 0 ;; *) return 1 ;; esac; }  # <path> → 0 when archived

# <main checkout> → every live marker, one path per line, sorted by name. Exit 0 with nothing printed when none.
fleet_live_markers() {
  local f
  for f in "$1"/tmp/fleet-deadline-*.json; do
    [ -f "$f" ] || continue
    fleet_marker_archived "$f" && continue
    printf '%s\n' "$f"
  done
  return 0
}

# <main checkout> → every marker, live and archived, one path per line, sorted by name.
fleet_all_markers() {
  local f
  for f in "$1"/tmp/fleet-deadline-*.json; do [ -f "$f" ] && printf '%s\n' "$f"; done
  return 0
}

# <path> → 0 while the marker's fleet still picks: not stopped, and its deadline (when it has one) still ahead. An
# unreadable marker reads as running — a wrong "running" only delays a caller, a wrong "ended" lets one act under a fleet.
fleet_marker_running() {
  local stopped dl
  stopped=$(jq -r '.stopped // false' "$1" 2>/dev/null) || stopped=""
  [ "$stopped" = "true" ] && return 1
  dl=$(jq -r '.deadline_epoch // empty' "$1" 2>/dev/null) || dl=""
  if [[ "$dl" =~ ^[0-9]+$ ]] && [ "$dl" -le "$(date +%s)" ]; then return 1; fi
  return 0
}

# <path> <fleet-metrics-history.jsonl> → 0 when /fleet-retro has measured this fleet: some history row's session_set
# shares a session with the marker's fleet_sessions. Ids may be recorded as prefixes on either side, so match by prefix
# in both directions. A marker naming no session has nothing to measure and reads as measured.
fleet_marker_retrod() {
  local sessions hist s h
  sessions=$(jq -r '.fleet_sessions[]? // empty' "$1" 2>/dev/null) || sessions=""
  [ -n "$sessions" ] || return 0
  [ -f "$2" ] || return 1
  hist=$(jq -r '.session_set[]? // empty' "$2" 2>/dev/null) || hist=""
  for s in $sessions; do
    for h in $hist; do
      case "$s" in "$h"*) return 0 ;; esac
      case "$h" in "$s"*) return 0 ;; esac
    done
  done
  return 1
}

# <path> → how a human names this fleet on a command line: `epic:<SCOPE>` or `team`, from the marker's scope, else its slug.
fleet_marker_token() {
  local scope slug
  scope=$(jq -r '.scope // empty' "$1" 2>/dev/null) || scope=""
  if [ -n "$scope" ]; then printf 'epic:%s' "$scope"; return; fi
  slug=$(fleet_marker_slug "$1")
  if [ "$slug" = team ]; then printf 'team'; else printf 'epic:%s' "$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')"; fi
}
