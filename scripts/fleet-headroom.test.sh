#!/usr/bin/env bash
# Regression suite for fleet-headroom.sh.
#
# Fixtures carry the REAL shapes mods/rate-limits writes — a history line `{"measured_at","windows"}` and the snapshot with its
# `session` — copied from ~/.claude/local on 2026-10-13, so the jq extraction is pinned to what the mod writes. The clock is fixed
# via --now; the reserve gate, the reset-passed case, the session-then-snapshot fallback, the run-key prefix match, and the
# fail-open path are each pinned by a case.

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-headroom.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
NOW=1787000000   # fixed epoch; readings are stamped relative to it
FHOME="$TMP/home"
HIST="$FHOME/.claude/local/rate-limits"
SNAP="$FHOME/.claude/local/rate-limits.json"
SID="fefdc843-16c7-45a2-921c-a101e09239f6"
mkdir -p "$HIST"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

line() { # <measured-epoch> <five_hour pct> <resets-epoch> — one history line
  printf '{"measured_at":"%s","windows":[{"kind":"five_hour","percentUsed":%s,"resetsAt":"%s"},{"kind":"seven_day","percentUsed":86,"resetsAt":"2026-10-13T22:00:00.000Z"}]}\n' "$(iso "$1")" "$2" "$(iso "$3")"
}
snapshot() { # <measured-epoch> <five_hour pct> <resets-epoch> <session>
  printf '{\n  "measured_at": "%s",\n  "session": "%s",\n  "windows": [\n    { "kind": "five_hour", "percentUsed": %s, "resetsAt": "%s" },\n    { "kind": "seven_day", "percentUsed": 86, "resetsAt": "2026-10-13T22:00:00.000Z" }\n  ]\n}\n' "$(iso "$1")" "$4" "$2" "$(iso "$3")" > "$SNAP"
}

t() { # <name> <want-exit> <want-substr> <args...>
  local name="$1" want_rc="$2" want_sub="$3"; shift 3
  local out rc
  out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want_sub"; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=$want_rc match='$want_sub', got rc=$rc: $(head -1 <<<"$out")"; FAIL=$((FAIL+1))
  fi
}

echo "fleet-headroom.sh"

# The session's own history: 4% then 19% (the last line is its latest), window resets in 4h14m → 81 headroom, pick OK.
{ line $(( NOW - 1200 )) 4 $(( NOW + 15240 )); line $(( NOW - 300 )) 19 $(( NOW + 15240 )); } > "$HIST/$SID.jsonl"
t "own history, under the reserve"            0 'PICK-OK  five_hour=19% used  headroom=81 >= reserve=20' --session "$SID"
t "own history names its source and age"      0 'resets_in=15240s  source=session(fefdc843)  measured=.* (5m ago)' --session "$SID"
t "run-key prefix finds the session file"     0 'source=session(fefdc843)' --session fefdc843

# Over the reserve: 85% used → 15 headroom < 20 → THROTTLE, exit 2; the reserve is tunable.
line $(( NOW - 60 )) 85 $(( NOW + 7200 )) >> "$HIST/$SID.jsonl"
t "throttle when headroom < reserve"          2 'THROTTLE five_hour=85% used  headroom=15 < reserve=20' --session "$SID"
t "throttle says to park until the reset"     2 'park with a wakeup until the reset' --session "$SID"
t "reserve flag respected"                    0 'PICK-OK  five_hour=85% used  headroom=15 >= reserve=10' --session "$SID" --reserve 10

# A reading whose resetsAt has passed: the window reset after it was taken, so it counts as 0% — pick OK, and the line says why.
line $(( NOW - 7000 )) 85 $(( NOW - 100 )) >> "$HIST/$SID.jsonl"
t "reset passed counts as empty"              0 'PICK-OK  five_hour=85% used before the window reset at .* (counted as 0)  headroom=100' --session "$SID"
t "reset passed: resets_in is 0"              0 'resets_in=0s' --session "$SID"

# Snapshot fallback: no history for the session asked for, or no --session at all.
snapshot $(( NOW - 180 )) 12.5 $(( NOW + 3600 )) "aaaa1111-0000-4000-8000-000000000000"
t "no history for the session: snapshot"      0 'PICK-OK  five_hour=12.5% used  headroom=87.5 >= reserve=20 .* source=snapshot(aaaa1111)' --session nope0000
t "no --session: snapshot"                    0 'source=snapshot(aaaa1111)'
snapshot $(( NOW - 180 )) 95 $(( NOW + 3600 )) "aaaa1111-0000-4000-8000-000000000000"
t "snapshot over the reserve throttles"       2 'THROTTLE five_hour=95% used' --session nope0000

# A malformed last history line falls through to the snapshot; a snapshot that is not JSON is no reading.
printf 'not json\n' > "$HIST/bad00000-0000-4000-8000-000000000000.jsonl"
t "malformed history line: snapshot"          2 'source=snapshot(aaaa1111)' --session bad00000
printf 'not json\n' > "$SNAP"
t "no reading anywhere: fails open"           0 'PICK-OK  five_hour=? (no reading: no mods/rate-limits reading (no history for session bad00000, and .*rate-limits.json is missing or unreadable))  source=none' --session bad00000
t "no reading warns on stderr"                0 'WARN: no mods/rate-limits reading .* failing open (pick OK)' --session bad00000
rm -f "$SNAP"
t "no snapshot file at all: fails open"       0 'source=none'

# A reading without a five_hour window is no reading either.
printf '{"measured_at":"%s","windows":[{"kind":"seven_day","percentUsed":86}]}\n' "$(iso $(( NOW - 60 )))" > "$HIST/only7day0-0000-4000-8000-000000000000.jsonl"
t "no five_hour window: fails open"           0 'no reading: the session reading carries no five_hour window' --session only7day0

# --json emits the machine shape, on a throttle and on a fail-open.
out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --session "$SID" --json 2>/dev/null)
if printf '%s' "$out" | jq -e '.pick_ok == true and .five_hour_pct == 85 and .window_reset == true and .headroom == 100 and .resets_in == 0 and .source == "session" and .writer == "fefdc843"' >/dev/null 2>&1; then
  echo "  PASS  json shape"; PASS=$((PASS+1))
else
  echo "  FAIL  json shape — got: $out"; FAIL=$((FAIL+1))
fi
line $(( NOW - 60 )) 85 $(( NOW + 7200 )) >> "$HIST/$SID.jsonl"
out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --session "$SID" --json 2>/dev/null); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | jq -e '.pick_ok == false and .headroom == 15 and .reserve == 20 and .resets_in == 7200' >/dev/null 2>&1; then
  echo "  PASS  json throttle"; PASS=$((PASS+1))
else
  echo "  FAIL  json throttle — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi
out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --session nope0000 --json 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.pick_ok == true and .source == "none" and (.note | test("no mods/rate-limits reading"))' >/dev/null 2>&1; then
  echo "  PASS  json fail-open"; PASS=$((PASS+1))
else
  echo "  FAIL  json fail-open — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

# RATE_LIMITS_DIR points the history read elsewhere (fleet-metrics.py honors the same variable).
mkdir -p "$TMP/alt"; line $(( NOW - 60 )) 3 $(( NOW + 7200 )) > "$TMP/alt/$SID.jsonl"
out=$(HOME="$FHOME" RATE_LIMITS_DIR="$TMP/alt" "$SCRIPT" --now "$NOW" --session "$SID" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'five_hour=3% used'; then
  echo "  PASS  RATE_LIMITS_DIR honored"; PASS=$((PASS+1))
else
  echo "  FAIL  RATE_LIMITS_DIR honored — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
