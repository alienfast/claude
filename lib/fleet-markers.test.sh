#!/usr/bin/env bash
# Unit suite for lib/fleet-markers.sh — the slug, path and predicate helpers every fleet script and hook sources. Drives
# the real functions against a throwaway checkout: live markers are listed and archived ones (<slug>.<epoch>) are not,
# `running` reads stopped/deadline, `retrod` matches history ids by prefix in both directions and treats a marker with no
# sessions as measured, `token` renders the command-line name a human types, and `duration_secs` reads a typed budget.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/fleet-markers.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ck() { # ck <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }

. "$LIB"
M="$WORK/repo"; mkdir -p "$M/tmp"
now=$(date +%s)

echo "== slug and paths"
ck "empty scope is team"           team "$(fleet_slug "")"
ck "epic id lowercases"            bf-2948 "$(fleet_slug BF-2948)"
ck "whitespace stripped"           bf-1 "$(fleet_slug ' bf-1 ')"
ck "marker path"                   "$M/tmp/fleet-deadline-bf-2948.json" "$(fleet_marker_path "$M" bf-2948)"
ck "recommendation path"           "$M/tmp/fleet-recommendation-team.json" "$(fleet_rec_path "$M" team)"
ck "stem of a live marker"         bf-2948 "$(fleet_marker_stem "$M/tmp/fleet-deadline-bf-2948.json")"
ck "stem of an archived marker"    bf-2948.1793221071 "$(fleet_marker_stem "$M/tmp/fleet-deadline-bf-2948.1793221071.json")"
ck "slug of an archived marker"    bf-2948 "$(fleet_marker_slug "$M/tmp/fleet-deadline-bf-2948.1793221071.json")"
ck "slug of the team marker"       team "$(fleet_marker_slug "$M/tmp/fleet-deadline-team.json")"
ck "live is not archived"          1 "$(rc fleet_marker_archived "$M/tmp/fleet-deadline-team.json")"
ck "epoch suffix is archived"      0 "$(rc fleet_marker_archived "$M/tmp/fleet-deadline-team.1700000000.json")"

echo "== listing"
ck "no markers lists nothing"      "" "$(fleet_live_markers "$M")"
ck "no markers exits 0"            0 "$(rc fleet_live_markers "$M")"
printf '{"fleet_sessions":["a1"]}\n' > "$M/tmp/fleet-deadline-team.json"
printf '{"fleet_sessions":["b1"],"scope":"BF-2948"}\n' > "$M/tmp/fleet-deadline-bf-2948.json"
printf '{"fleet_sessions":["c1"]}\n' > "$M/tmp/fleet-deadline-team.1700000000.json"
printf 'not json\n' > "$M/tmp/fleet-recommendation-team.json"
ck "live markers only, sorted"     "$M/tmp/fleet-deadline-bf-2948.json
$M/tmp/fleet-deadline-team.json" "$(fleet_live_markers "$M")"
ck "all markers include archived"  3 "$(fleet_all_markers "$M" | wc -l | tr -d ' ')"

echo "== running"
ck "undated, not stopped: running" 0 "$(rc fleet_marker_running "$M/tmp/fleet-deadline-team.json")"
printf '{"deadline_epoch":%s}\n' "$((now + 3600))" > "$M/tmp/fleet-deadline-team.json"
ck "deadline ahead: running"       0 "$(rc fleet_marker_running "$M/tmp/fleet-deadline-team.json")"
printf '{"deadline_epoch":%s}\n' "$((now - 60))" > "$M/tmp/fleet-deadline-team.json"
ck "deadline passed: not running"  1 "$(rc fleet_marker_running "$M/tmp/fleet-deadline-team.json")"
printf '{"deadline_epoch":%s,"stopped":true}\n' "$((now + 3600))" > "$M/tmp/fleet-deadline-team.json"
ck "stopped: not running"          1 "$(rc fleet_marker_running "$M/tmp/fleet-deadline-team.json")"
printf 'not json\n' > "$M/tmp/fleet-deadline-team.json"
ck "unreadable reads as running"   0 "$(rc fleet_marker_running "$M/tmp/fleet-deadline-team.json")"

echo "== retro'd"
H="$M/tmp/fleet-metrics-history.jsonl"
printf '{"fleet_sessions":["a1b2c3d4","e5f6a7b8"]}\n' > "$M/tmp/fleet-deadline-team.json"
ck "no history: not retro'd"       1 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
printf '{"session_set":"zz"}\n' > "$H"
ck "no shared id: not retro'd"     1 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
printf '{"session_set":"e5f6a7b8-full-uuid"}\n' >> "$H"
ck "history id extends the key"    0 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
printf '{"session_set":"a1b2"}\n' > "$H"
ck "history id is a prefix"        0 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
# fleet-metrics.py records the set as ONE comma-joined string; `.session_set[]?` on it yielded nothing, so every fleet
# read as never retro'd and no launch ever expired a marker (2026-11-01).
printf '{"session_set":"zz,a1b2c3d4"}\n' > "$H"
ck "a comma-joined set is read per id" 0 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
printf '{"session_set":"a9999999,e0000000"}\n' > "$H"
ck "a shared leading digit is not a match" 1 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$H")"
printf '{"fleet_sessions":[]}\n' > "$M/tmp/fleet-deadline-team.json"
ck "no sessions reads as measured" 0 "$(rc fleet_marker_retrod "$M/tmp/fleet-deadline-team.json" "$WORK/none.jsonl")"

echo "== token"
ck "team marker"                   team "$(fleet_marker_token "$M/tmp/fleet-deadline-team.json")"
ck "epic marker by scope"          epic:BF-2948 "$(fleet_marker_token "$M/tmp/fleet-deadline-bf-2948.json")"
printf '{"fleet_sessions":[]}\n' > "$M/tmp/fleet-deadline-ep-7.json"
ck "epic marker by slug when scope is missing" epic:EP-7 "$(fleet_marker_token "$M/tmp/fleet-deadline-ep-7.json")"

echo "== duration"
ck "hours"                         36000 "$(fleet_duration_secs 10h)"
ck "two words, any case"           10800 "$(fleet_duration_secs '3 Hours')"
ck "minutes"                       5400 "$(fleet_duration_secs 90m)"
ck "minutes spelled out"           2700 "$(fleet_duration_secs '45 minutes')"
ck "a bare number is not a duration" 1 "$(rc fleet_duration_secs 10)"
ck "an issue id is not a duration" 1 "$(rc fleet_duration_secs BF-12)"
ck "nothing is not a duration"     1 "$(rc fleet_duration_secs '')"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
