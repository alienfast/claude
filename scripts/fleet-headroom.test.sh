#!/usr/bin/env bash
# Regression suite for fleet-headroom.sh.
#
# Fixtures carry the REAL shapes mods/rate-limits writes — a history line `{"measured_at","windows"}` and the snapshot with its
# `session` — copied from ~/.claude/local on 2026-10-13, so the jq extraction is pinned to what the mod writes. The clock is fixed
# via --now; the reserve gate, the reset-passed case, the session-then-snapshot fallback, the run-key prefix match, and the
# fail-open path are each pinned by a case. The rotating-machine cases run against a stub `cswap` on PATH whose rows carry the
# shape `cswap list --json` printed on 2026-10-19 (claude-swap 0.27.2), with cswap's backup root and the engine's event log under
# the fixture HOME.

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
tj() { # <name> <want-exit> <jq predicate> <args...> — the --json shape
  local name="$1" want_rc="$2" pred="$3"; shift 3
  local out rc
  out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --json "$@" 2>/dev/null); rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | jq -e "$pred" >/dev/null 2>&1; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=$want_rc and $pred, got rc=$rc: $out"; FAIL=$((FAIL+1))
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
tj "json shape"        0 '.pick_ok == true and .five_hour_pct == 85 and .window_reset == true and .headroom == 100 and .resets_in == 0 and .source == "session" and .writer == "fefdc843"' --session "$SID"
line $(( NOW - 60 )) 85 $(( NOW + 7200 )) >> "$HIST/$SID.jsonl"
tj "json throttle"     2 '.pick_ok == false and .headroom == 15 and .reserve == 20 and .resets_in == 7200' --session "$SID"
tj "json fail-open"    0 '.pick_ok == true and .source == "none" and (.note | test("no mods/rate-limits reading"))' --session nope0000

# RATE_LIMITS_DIR points the history read elsewhere (fleet-metrics.py honors the same variable).
mkdir -p "$TMP/alt"; line $(( NOW - 60 )) 3 $(( NOW + 7200 )) > "$TMP/alt/$SID.jsonl"
out=$(HOME="$FHOME" RATE_LIMITS_DIR="$TMP/alt" "$SCRIPT" --now "$NOW" --session "$SID" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'five_hour=3% used'; then
  echo "  PASS  RATE_LIMITS_DIR honored"; PASS=$((PASS+1))
else
  echo "  FAIL  RATE_LIMITS_DIR honored — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

# ---- Rotating machine (cswap) ----------------------------------------------------------------------------------------------
# The stub answers the two reads the probe makes; the fixture list is whatever $CSWAP_STUB_LIST names.
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'STUB'
#!/usr/bin/env bash
[ "${CSWAP_STUB_FAIL:-0}" = 1 ] && exit 1
case "$1 $2" in
  "list --json") cat "$CSWAP_STUB_LIST" ;;
  "config get")  echo "${CSWAP_STUB_THRESHOLD:-95}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB/cswap"
export PATH="$STUB:$PATH"
export CSWAP_STUB_LIST="$TMP/cswap-list.json"
export CSWAP_STUB_THRESHOLD=95
LOG="$FHOME/.claude/logs/cswap-auto.log"; mkdir -p "$(dirname "$LOG")"

acct() { # <number> <email> <active> <usageStatus> <5h pct> <7d pct> <age seconds> <weekly resetsAt>
  printf '{"number":%s,"email":"%s","active":%s,"usageStatus":"%s","usage":{"fiveHour":{"pct":%s},"sevenDay":{"pct":%s,"resetsAt":"%s"}},"usageAgeSeconds":%s}' "$1" "$2" "$3" "$4" "$5" "$6" "$8" "$7"
}
accounts() { # <acct json>... → the stub's list
  local IFS=,
  printf '{"schemaVersion":1,"activeAccountNumber":3,"accounts":[%s]}\n' "$*" > "$CSWAP_STUB_LIST"
}
beat() { # <epoch> — the engine's last event
  printf '{"schemaVersion": 1, "event": "poll", "ts": "%s", "threshold": 95.0}\n' "$(iso "$1")" > "$LOG"
}
SOON="2026-10-20T07:00:00.359279+00:00"; LATER="2026-10-22T05:00:00.190415+00:00"

# The session is at 85% (its last history line) — THROTTLE on a single-account machine, and the line carries no cswap tail.
out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --session "$SID" 2>&1); rc=$?
if [ "$rc" = 2 ] && ! printf '%s' "$out" | grep -q 'cswap='; then
  echo "  PASS  single-account machine: no cswap tail"; PASS=$((PASS+1))
else
  echo "  FAIL  single-account machine: no cswap tail — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi
tj "single-account machine: json cswap null" 2 '.cswap == null' --session "$SID"

mkdir -p "$FHOME/.claude-swap-backup"
accounts "$(acct 3 a@x true ok 85 7 20 "$SOON")" "$(acct 2 b@x false ok 0 1 200 "$LATER")"

# An idle engine moves no one: the local meter governs and the tail says why.
t "rotating, no engine log: local meter"      2 'THROTTLE five_hour=85% used  headroom=15 < reserve=20 .* cswap=engine-idle(no engine event in .*cswap-auto.log) — park' --session "$SID"
beat $(( NOW - 900 ))
t "rotating, engine event 15m old: idle"      2 'cswap=engine-idle(last engine event 15m ago)' --session "$SID"

# A live engine with a landing: the pick goes ahead whatever the local meter says.
beat $(( NOW - 30 ))
t "landing opens the gate"                    0 'PICK-OK  five_hour=85% used  headroom=15 < reserve=20 but cswap has a landing  resets=' --session "$SID"
t "landing names the target and threshold"    0 'cswap=target(b@x at 1% < threshold 95, figure 3m old — the engine.s landing when a@x fills)' --session "$SID"
t "landing keeps the local meter's fields"    0 'resets_in=7200s  source=session(fefdc843)' --session "$SID"
t "local PICK-OK keeps its own line + tail"   0 'PICK-OK  five_hour=85% used  headroom=15 >= reserve=10  .* cswap=target(b@x' --session "$SID" --reserve 10
t "fail-open carries the tail"                0 'source=none  cswap=target(b@x' --session nope0000
tj "json landing"      0 '.pick_ok == true and .headroom == 15 and .cswap.state == "target" and .cswap.threshold == 95 and .cswap.active.email == "a@x" and .cswap.target.email == "b@x" and .cswap.target.binding_pct == 1' --session "$SID"

# consume-first lands on the soonest weekly reset among the accounts with room, so that one is named.
accounts "$(acct 3 a@x true ok 85 7 20 "$LATER")" "$(acct 2 later@x false ok 0 1 200 "$LATER")" "$(acct 4 soon@x false ok 0 13 200 "$SOON")"
t "the soonest-resetting landing is named"   0 'cswap=target(soon@x at 13%' --session "$SID"

# No landing: every other account at or over the threshold, stale, or not `ok` — the local meter governs.
accounts "$(acct 3 a@x true ok 85 7 20 "$SOON")" "$(acct 2 b@x false ok 96 1 200 "$LATER")" "$(acct 4 c@x false ok 0 97 200 "$LATER")"
t "no account under the threshold"            2 'THROTTLE five_hour=85% used  headroom=15 < reserve=20 .* cswap=no-target(none of the other 2 accounts is under threshold 95 with an ok figure under 900s old) — park' --session "$SID"
accounts "$(acct 3 a@x true ok 85 7 20 "$SOON")" "$(acct 2 b@x false ok 0 0 1000 "$LATER")"
t "a stale figure is not room"                2 'cswap=no-target(' --session "$SID"
t "--stale widens what counts as fresh"       0 'cswap=target(b@x at 0% < threshold 95, figure 16m old' --session "$SID" --stale 2000
accounts "$(acct 3 a@x true ok 85 7 20 "$SOON")" "$(acct 2 b@x false unavailable 0 0 10 "$LATER")"
t "a figure cswap stopped trusting is not room" 2 'cswap=no-target(' --session "$SID"
tj "json no-target"    2 '.pick_ok == false and .cswap.state == "no-target" and .cswap.target == null and .cswap.active.binding_pct == 85' --session "$SID"

# The threshold is cswap's, not a constant: at 80 an account at 85% is not room; at 90 it is.
accounts "$(acct 3 a@x true ok 70 7 20 "$SOON")" "$(acct 2 b@x false ok 85 0 10 "$LATER")"
CSWAP_STUB_THRESHOLD=80 t "threshold from cswap config: 85 >= 80"  2 'cswap=no-target(none of the other 1 accounts is under threshold 80' --session "$SID"
CSWAP_STUB_THRESHOLD=90 t "threshold from cswap config: 85 < 90"   0 'cswap=target(b@x at 85% < threshold 90' --session "$SID"

# The engine mid-move: the active account is at its threshold and a landing exists — keep the THROTTLE, but re-probe in 3m.
accounts "$(acct 3 a@x true ok 96 7 20 "$SOON")" "$(acct 2 b@x false ok 0 0 10 "$LATER")"
t "switching: throttle re-probes in 3m"      2 'THROTTLE five_hour=85% used  headroom=15 < reserve=20  resets=.* resets_in=180s .* cswap=switching(active a@x at 96% >= threshold 95; the engine is moving to b@x at 0%) — re-probe in 3m: cswap is moving the login' --session "$SID"
tj "json switching"    2 '.pick_ok == false and .resets_in == 180 and .cswap.state == "switching"' --session "$SID"
t "switching with a local PICK-OK picks"     0 'PICK-OK  five_hour=85% used  headroom=15 >= reserve=10 .* resets_in=7200s .* cswap=switching(' --session "$SID" --reserve 10
# The binding window is the higher of 5h and 7d: an active account at 5h 10% but 7d 96% is at the threshold.
accounts "$(acct 3 a@x true ok 10 96 20 "$SOON")" "$(acct 2 b@x false ok 0 0 10 "$LATER")"
t "binding window is max(5h, 7d)"            2 'cswap=switching(active a@x at 96%' --session "$SID"

# Reads the probe cannot trust fall back to the local meter and say so.
CSWAP_STUB_FAIL=1 t "cswap list fails: local meter" 2 'THROTTLE five_hour=85% .* cswap=unreadable(cswap list --json carried no accounts)' --session "$SID"
CSWAP_STUB_THRESHOLD=abc t "threshold unreadable: local meter" 2 'cswap=unreadable(autoswitch.threshold unreadable)' --session "$SID"
accounts "$(acct 3 a@x false ok 10 7 20 "$SOON")" "$(acct 2 b@x false ok 0 0 10 "$LATER")"
t "no active row: local meter"               2 'cswap=unreadable(no active account in cswap list)' --session "$SID"
printf '{"event":"wrapper-error","at":"%s","message":"cswap not found"}\n' "$(iso $(( NOW - 30 )))" > "$LOG"
accounts "$(acct 3 a@x true ok 85 7 20 "$SOON")" "$(acct 2 b@x false ok 0 1 200 "$LATER")"
t "a wrapper event stamp is a heartbeat too" 0 'cswap=target(b@x' --session "$SID"
out=$(HOME="$FHOME" PATH="/usr/bin:/bin" "$SCRIPT" --now "$NOW" --session "$SID" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'cswap=unreadable(cswap not on PATH or in ~/.local/bin)'; then
  echo "  PASS  cswap binary missing: local meter"; PASS=$((PASS+1))
else
  echo "  FAIL  cswap binary missing: local meter — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
