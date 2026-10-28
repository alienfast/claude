#!/usr/bin/env bash
# Regression suite for fleet-cap.sh.
#
# The cap is 3 per account with room, read through fleet-headroom.sh's cswap verdict, so the fixtures are the ones that
# suite uses: a stub `cswap` on PATH answering `list --json` and `config get`, cswap's backup root and the engine's event log
# under a fixture HOME, and a fixed clock through --now. No rate-limits reading exists under the fixture HOME, so the probe
# fails open on every case — the cap must not depend on the local meter.

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-cap.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
NOW=1787000000
FHOME="$TMP/home"
mkdir -p "$FHOME"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

t() { # <name> <want-substr> <args...>
  local name="$1" want_sub="$2"; shift 2
  local out rc
  out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" "$@" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q -- "$want_sub"; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=0 match='$want_sub', got rc=$rc: $out"; FAIL=$((FAIL+1))
  fi
}
tj() { # <name> <jq predicate> <args...>
  local name="$1" pred="$2"; shift 2
  local out rc
  out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" --json "$@" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e "$pred" >/dev/null 2>&1; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=0 and $pred, got rc=$rc: $out"; FAIL=$((FAIL+1))
  fi
}

echo "fleet-cap.sh"

# ---- single-account machine ----
t "single account: cap 3"                 'CAP 3  per_account=3  accounts_with_room=1/1  single-account machine: no cswap rotation'
tj "single account: json"                 '.cap == 3 and .per_account == 3 and .accounts_with_room == 1 and .rotating == false and .state == "none" and .room == []'
t "unknown argument is ignored"           'CAP 3 ' --bogus

# ---- rotating machine (cswap) ----
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
acct() { # <number> <email> <active> <usageStatus> <5h pct> <7d pct> <age seconds>
  printf '{"number":%s,"email":"%s","active":%s,"usageStatus":"%s","usage":{"fiveHour":{"pct":%s},"sevenDay":{"pct":%s,"resetsAt":"2026-10-22T05:00:00.190415+00:00"}},"usageAgeSeconds":%s}' "$@"
}
accounts() { local IFS=,; printf '{"schemaVersion":1,"activeAccountNumber":1,"accounts":[%s]}\n' "$*" > "$CSWAP_STUB_LIST"; }
beat() { printf '{"schemaVersion": 1, "event": "poll", "ts": "%s", "threshold": 95.0}\n' "$(iso "$1")" > "$LOG"; }

mkdir -p "$FHOME/.claude-swap-backup"
accounts "$(acct 1 a@x true ok 40 20 30)" "$(acct 2 b@x false ok 0 0 60)"

# An idle engine moves no one: one account's window governs.
t "rotating, no engine log: cap 3"        'CAP 3  per_account=3  accounts_with_room=1/?  cswap is enrolled but its engine is idle (no engine event in'
beat $(( NOW - 900 ))
t "rotating, engine 15m idle: cap 3"      'accounts_with_room=1/?  cswap is enrolled but its engine is idle (last engine event 15m ago)'
tj "idle engine: json names the state"    '.cap == 3 and .rotating == true and .state == "engine-idle" and .accounts == null'

# A live engine: 3 per account with room, the active one included while it is under the threshold.
beat $(( NOW - 30 ))
t "two accounts with room: cap 6"         'CAP 6  per_account=3  accounts_with_room=2/2  2 of 2 enrolled accounts have room (a@x, b@x): the engine moves the login at threshold 95, so the pool refills at 2 × one window'
tj "two accounts: json"                   '.cap == 6 and .accounts_with_room == 2 and .accounts == 2 and .state == "target" and (.room | sort) == ["a@x", "b@x"]'

# The active account over the threshold (the engine mid-move) is not room.
accounts "$(acct 1 a@x true ok 96 20 30)" "$(acct 2 b@x false ok 0 0 60)"
t "switching: the full active is not room" 'CAP 3  per_account=3  accounts_with_room=1/2  1 of 2 enrolled accounts have room (b@x)'
tj "switching: json state"                '.cap == 3 and .state == "switching" and .room == ["b@x"]'

# A stale figure is not room until --stale widens it; a figure cswap stopped trusting never is.
accounts "$(acct 1 a@x true ok 40 20 30)" "$(acct 2 b@x false ok 0 0 2000)"
t "stale figure is not room"              'CAP 3  per_account=3  accounts_with_room=1/2  1 of 2 enrolled accounts have room (a@x)'
t "--stale widens what counts"            'CAP 6  per_account=3  accounts_with_room=2/2' --stale 3000
accounts "$(acct 1 a@x true ok 40 20 30)" "$(acct 2 b@x false unavailable 0 0 60)"
t "an untrusted figure is not room"       'accounts_with_room=1/2  1 of 2 enrolled accounts have room (a@x)'

# Nothing has room: the floor stays 3 and the line says the window is the constraint.
accounts "$(acct 1 a@x true ok 97 20 30)" "$(acct 2 b@x false ok 96 0 60)"
t "no room anywhere: cap 3, the window governs" 'CAP 3  per_account=3  accounts_with_room=1/2  no account has room (none of the other 1 accounts is under threshold 95'
tj "no room: json"                        '.cap == 3 and .accounts_with_room == 1 and .state == "no-target"'

# Five accounts with room would be 15: the launch script's range bounds it at 12.
accounts "$(acct 1 a@x true ok 9 48 30)" "$(acct 2 b@x false ok 0 0 60)" "$(acct 3 c@x false ok 0 0 60)" "$(acct 4 d@x false ok 3 7 60)" "$(acct 5 e@x false ok 0 0 60)"
t "five accounts: bounded at 12"          'CAP 12  per_account=3  accounts_with_room=5/5  5 of 5 enrolled accounts have room (a@x, b@x, c@x, d@x, e@x): .* bounded by fleet-launch.sh.s count range of 12'
tj "five accounts: json range"            '.cap == 12 and .accounts_with_room == 5 and .range_max == 12'

# The threshold is cswap's: at 90 an account at 92% is not room.
accounts "$(acct 1 a@x true ok 40 20 30)" "$(acct 2 b@x false ok 92 0 60)"
CSWAP_STUB_THRESHOLD=90 t "threshold from cswap config" 'accounts_with_room=1/2  1 of 2 enrolled accounts have room (a@x): the engine moves the login at threshold 90'

# Reads the probe cannot trust: one account's window governs, and the line says why.
CSWAP_STUB_FAIL=1 t "cswap list fails: cap 3"  'CAP 3  per_account=3  accounts_with_room=1/?  cswap is enrolled but unreadable (cswap list --json carried no accounts)'
CSWAP_STUB_FAIL=1 tj "unreadable: json state" '.cap == 3 and .state == "unreadable"'
out=$(HOME="$FHOME" PATH="/usr/bin:/bin" "$SCRIPT" --now "$NOW" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'cswap is enrolled but unreadable (cswap not on PATH or in ~/.local/bin)'; then
  echo "  PASS  cswap binary missing: cap 3"; PASS=$((PASS+1))
else
  echo "  FAIL  cswap binary missing: cap 3 — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
