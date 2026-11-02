#!/usr/bin/env bash
# Regression suite for fleet-cap.sh.
#
# The cap is 3 per account with room on accounts with a 5h window, and on a weekly-only pool the count range bounded by the
# weekly room, read through fleet-headroom.sh's cswap verdict, so the fixtures are the ones that
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
t "two accounts with room: cap 6"         'CAP 6  per_account=3  accounts_with_room=2/2  2 of 2 enrolled accounts have room (a@x, b@x): the engine moves the login at threshold 95, so the pool is 2 accounts. windows'
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

# ---- weekly-only accounts (Claude Ultra: fiveHour null) ----
# No window a count can saturate: the per-account factor is gone, the cap is the count range, and with --hours the pool's
# weekly room (points to the threshold over the accounts with room) bounds it at 0.55 points per session-hour. With no local
# reading under the fixture HOME the probe fails open, so the plan shape comes from cswap's active row.
acct_ultra() { # <number> <email> <active> <usageStatus> <7d pct> <age seconds>
  printf '{"number":%s,"email":"%s","active":%s,"usageStatus":"%s","usage":{"fiveHour":null,"sevenDay":{"pct":%s,"resetsAt":"2026-10-22T05:00:00.190415+00:00"}},"usageAgeSeconds":%s}' "$@"
}
beat $(( NOW - 30 ))
accounts "$(acct_ultra 1 a@x true ok 90 30)" "$(acct_ultra 2 b@x false ok 5 60)"
t "weekly-only: the count range, not 3 per account" 'CAP 12  per_account=machine  accounts_with_room=2/2  2 of 2 enrolled accounts have room (a@x, b@x): the engine moves the login at threshold 95, so the pool is 2 accounts. windows. Weekly-only accounts (no five_hour window): no burst window to saturate, so the machine and the backlog.s lanes bound the count, not the account — the pool.s weekly room of 95 points to the engine.s threshold across the accounts with room covers ~172.7 session-hours at 0.55 points per session-hour; bounded by fleet-launch.sh.s count range of 12'
tj "weekly-only: json"                     '.cap == 12 and .per_account == null and .weekly_only == true and .weekly_room == 95 and .weekly_session_hours == 172.7 and .burn_per_session_hour == 0.55 and .hours == null and (.line | startswith("CAP 12  per_account=machine"))'
t "weekly-only, 10h: the range still bounds" 'CAP 12  per_account=machine .* 10h at that rate fits 17 sessions, so the count range of 12 bounds the cap' --hours 10
t "weekly-only, 40h: the room bounds"       'CAP 4  per_account=machine .* 40h at that rate fits 4 sessions, which bounds the cap' --hours 40
tj "weekly-only, 40h: json"                '.cap == 4 and .hours == 40 and .weekly_room == 95' --hours 40
t "weekly-only, 400h: nothing fits, cap 1"  'CAP 1  per_account=machine .* 400h at that rate fits no session for the full run — the first picks park at the weekly reset' --hours 400
t "weekly-only, 90h: one session"           'CAP 1  per_account=machine .* 90h at that rate fits 1 session, which bounds the cap' --hours 90
FLEET_WEEKLY_BURN=1.1 t "weekly-only: the burn rate is overridable" 'covers ~86.3 session-hours at 1.1 points per session-hour; 40h at that rate fits 2 sessions, which bounds the cap' --hours 40
FLEET_WEEKLY_BURN=abc t "weekly-only: a bad burn rate falls back" 'at 0.55 points per session-hour' --hours 40
t "weekly-only: a bad --hours is ignored"   'bounded by fleet-launch.sh.s count range of 12' --hours -3
# The engine mid-move: the full active account is not room, so the pool's room is the landing's alone.
accounts "$(acct_ultra 1 a@x true ok 97 30)" "$(acct_ultra 2 b@x false ok 5 60)"
t "weekly-only, switching: the landing's room" 'CAP 12  per_account=machine  accounts_with_room=1/2  1 of 2 enrolled accounts have room (b@x): .* the pool.s weekly room of 90 points'
# No account under the threshold: no room, and with a duration nothing fits.
accounts "$(acct_ultra 1 a@x true ok 97 30)" "$(acct_ultra 2 b@x false ok 96 60)"
t "weekly-only, no room: says so"           'CAP 12  per_account=machine  accounts_with_room=1/2  no account has room (none of the other 1 accounts is under threshold 95 .* the pool.s weekly room of 0 points .* covers ~0 session-hours'
t "weekly-only, no room, 10h: cap 1"        'CAP 1  per_account=machine .* fits no session for the full run' --hours 10
# A mixed pool whose active account has a 5h window keeps the per-account bracket.
accounts "$(acct 1 a@x true ok 40 20 30)" "$(acct_ultra 2 b@x false ok 5 60)"
t "mixed pool, active on a 5h plan: 3 per account" 'CAP 6  per_account=3  accounts_with_room=2/2'
# An idle engine on a weekly-only account: one account's window governs, and its own reading gives the room.
mkdir -p "$FHOME/.claude/local"
printf '{"measured_at":"%s","session":"s","windows":[{"kind":"seven_day","percentUsed":90,"resetsAt":"2026-11-03T07:00:00.000Z"}]}\n' "$(iso $(( NOW - 60 )))" > "$FHOME/.claude/local/rate-limits.json"
beat $(( NOW - 900 ))
t "weekly-only, idle engine: the active account's room" 'CAP 12  per_account=machine  accounts_with_room=1/?  cswap is enrolled but its engine is idle (last engine event 15m ago): nothing moves the login, so one account.s window governs — /cswap log. Weekly-only accounts (no five_hour window): .* the active account.s weekly room of 7 points to the gate.s weekly reserve covers ~12.7 session-hours'
# A single-account machine on a weekly-only plan: the probe's own reading says so.
rm -rf "$FHOME/.claude-swap-backup"
t "single account, weekly-only: the count range" 'CAP 12  per_account=machine  accounts_with_room=1/1  single-account machine: no cswap rotation (scripts/cswap-setup.sh is the opt-in), so one account.s window governs. Weekly-only accounts (no five_hour window): .* the active account.s weekly room of 7 points to the gate.s weekly reserve covers ~12.7 session-hours at 0.55 points per session-hour; bounded by fleet-launch.sh.s count range of 12'
t "single account, weekly-only, 10h: cap 1"  'CAP 1  per_account=machine .* 10h at that rate fits 1 session, which bounds the cap' --hours 10
tj "single account, weekly-only: json"      '.cap == 12 and .weekly_only == true and .rotating == false and .weekly_room == 7 and .weekly_session_hours == 12.7'

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
