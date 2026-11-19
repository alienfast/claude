#!/usr/bin/env bash
# Regression suite for cswap-logins.sh and its launchd wrapper cswap-logins-cron.sh.
#
# A stub `cswap` answers `list --json` from a fixture whose rows carry the keys `cswap list --json` printed on 2026-11-18
# (claude-swap 1.1.0); cswap's backup root sits under a fixture HOME and the clock is fixed through --now. The wrapper's
# notices land in a file through CSWAP_LOGINS_NOTIFY_LOG, so no case raises a real notification.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/cswap-logins.sh"
CRON="$HERE/cswap-logins-cron.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
NOW=1795000000
DAY=86400
FHOME="$TMP/home"
mkdir -p "$FHOME"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ck() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL  $1 — want [$2] got [$3]"; fi
}
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
line() { printf '%s\n' "$out" | sed -n "${1}p"; }
jqok() { printf '%s' "$out" | jq -e "$@" >/dev/null 2>&1 && echo yes || echo no; }

STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'STUB'
#!/usr/bin/env bash
[ "${CSWAP_STUB_FAIL:-0}" = 1 ] && exit 1
case "$1 $2" in
  "list --json") cat "$CSWAP_STUB_LIST" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB/cswap"
export CSWAP_BIN="$STUB/cswap"
export CSWAP_STUB_LIST="$TMP/cswap-list.json"

acct() { # <number> <email> <active> <usageStatus> <loginExpiresAt, or none>
  local login="" usage=null
  [ "$5" = none ] || login="\"loginExpiresAt\":\"$5\","
  [ "$4" = ok ] && usage='{"sevenDay":{"pct":0.0,"resetsAt":"2026-11-24T12:00:00+00:00","countdown":"5d 16h","clock":"Nov 24 06:00","expectedPct":18.5,"aheadOfPace":false,"willLastToReset":true}}'
  printf '{"number":%s,"email":"%s","organizationName":"o","organizationUuid":"u","isOrganization":true,"active":%s,"usageStatus":"%s","usage":%s,%s"usageFetchedAt":"2026-11-18T19:08:41Z","usageAgeSeconds":57.0}' \
    "$1" "$2" "$3" "$4" "$usage" "$login"
}
accounts() { local IFS=,; printf '{"schemaVersion":1,"activeAccountNumber":1,"accounts":[%s],"unclaimedCredentials":[]}\n' "$*" > "$CSWAP_STUB_LIST"; }
run() { out=$(HOME="$FHOME" "$SCRIPT" --now "$NOW" "$@" 2>"$TMP/err"); rc=$?; err=$(cat "$TMP/err"); }

echo "cswap-logins.sh"

# ---- a machine that does not rotate accounts ----
accounts "$(acct 1 a@x true relogin_required "$(iso $(( NOW - DAY )))")"
run
ck "no backup root: exit 0" 0 "$rc"
ck "no backup root: silent" "" "$out"
run --json
ck "no backup root: json says so" yes "$(jqok '.rotating == false and .accounts == 0 and .lapsed == [] and .due == [] and .error == null')"

mkdir -p "$FHOME/.claude-swap-backup"

# ---- nothing to redo ----
accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" "$(acct 2 b@x false ok "$(iso $(( NOW + 29 * DAY )))")"
run
ck "all current: exit 0" 0 "$rc"
ck "all current: silent" "" "$out"
run --json
ck "all current: json" yes "$(jqok '.rotating == true and .accounts == 2 and .within_days == 3 and .before == null and .lapsed == [] and .due == [] and .error == null')"
ck "all current: json carries the clock" "$(iso "$NOW")" "$(printf '%s' "$out" | jq -r .checked_at)"

# ---- lapsed: cswap's verdict, with or without a stamp, and a stamp already past whatever the status says ----
accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" \
         "$(acct 2 b@x false relogin_required "$(iso $(( NOW - 3 * DAY )))")" \
         "$(acct 3 c@x false relogin_required none)" \
         "$(acct 4 d@x false ok "$(iso $(( NOW - 3600 )))")" \
         "$(acct 5 e@x false relogin_required "$(iso $(( NOW + 20 * DAY )))")"
run
ck "lapsed: exit 2" 2 "$rc"
ck "lapsed: a past stamp is named" yes "$(has "cswap login lapsed: b@x (expired $(iso $(( NOW - 3 * DAY ))))" "$out")"
ck "lapsed: no stamp names cswap's verdict" yes "$(has 'cswap login lapsed: c@x (cswap reports relogin_required)' "$out")"
ck "lapsed: an ok status past its stamp" yes "$(has "cswap login lapsed: d@x (expired $(iso $(( NOW - 3600 ))))" "$out")"
ck "lapsed: cswap's verdict ahead of the stamp is not called expired" yes "$(has 'cswap login lapsed: e@x (cswap reports relogin_required)' "$out")"
ck "lapsed: the current account is not named" no "$(has 'a@x' "$out")"
ck "lapsed: the last line names the fix" yes "$(has 'claude auth login as that account, then cswap add' "$(line 5)")"
ck "lapsed: one line per account plus the fix" 5 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
run --json
ck "lapsed: json" yes "$(jqok '(.lapsed | map(.email) | sort) == ["b@x","c@x","d@x","e@x"] and .due == [] and (.lapsed | map(select(.email == "b@x")) | .[0].expired) == true and (.lapsed | map(select(.email == "e@x")) | .[0].expired) == false')"

# ---- due: inside the window, soonest first ----
accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 2 * DAY )))")" \
         "$(acct 2 b@x false ok "$(iso $(( NOW + 4 * DAY )))")" \
         "$(acct 3 c@x false ok "$(iso $(( NOW + 36000 )))")"
run
ck "due: exit 2" 2 "$rc"
ck "due: soonest first" "cswap login lapses in 10h: c@x ($(iso $(( NOW + 36000 ))))" "$(line 1)"
ck "due: days and hours" "cswap login lapses in 2d0h: a@x ($(iso $(( NOW + 2 * DAY ))))" "$(line 2)"
ck "due: outside 3 days is not named" no "$(has 'b@x' "$out")"
run --json
ck "due: json" yes "$(jqok '.lapsed == [] and (.due | map(.email)) == ["c@x","a@x"] and .due[0].expires_in_s == 36000 and .due[0].number == 3')"
run --within 7
ck "--within widens the window" yes "$(has 'cswap login lapses in 4d0h: b@x' "$out")"
run --within 0.25
ck "--within narrows it: exit 0" 0 "$rc"
ck "--within narrows it: silent" "" "$out"
run --within bogus
ck "a bad --within falls back to 3 days" 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
run --bogus
ck "an unknown argument is ignored" 2 "$rc"

# ---- --before: a fleet's deadline replaces the window ----
run --before $(( NOW + 12 * 3600 ))
ck "--before: exit 2" 2 "$rc"
ck "--before: only what lapses by then" 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
ck "--before: names it" yes "$(has 'cswap login lapses in 10h: c@x' "$out")"
run --before $(( NOW + 12 * 3600 )) --json
ck "--before: json names the deadline, not a window" yes "$(jqok --arg b "$(iso $(( NOW + 12 * 3600 )))" '.before == $b and .within_days == null')"
run --before $(( NOW + 5 * DAY ))
ck "--before reaches past the default window" yes "$(has 'cswap login lapses in 4d0h: b@x' "$out")"
run --before $(( NOW - 60 ))
ck "--before in the past flags nothing due" 0 "$rc"

# ---- lapsed lines come before due lines ----
accounts "$(acct 1 a@x true ok "$(iso $(( NOW + DAY )))")" "$(acct 2 b@x false relogin_required "$(iso $(( NOW - DAY )))")"
run
ck "lapsed before due" "cswap login lapsed: b@x (expired $(iso $(( NOW - DAY ))))" "$(line 1)"
ck "then the due line" "cswap login lapses in 1d0h: a@x ($(iso $(( NOW + DAY ))))" "$(line 2)"

# ---- the stamp's other spellings, and rows with nothing to lapse ----
soon=$(iso $(( NOW + DAY )))
accounts "$(acct 1 a@x true ok "${soon%Z}.190415+00:00")" "$(acct 2 b@x false api_key none)" \
         "$(acct 3 c@x false unavailable "$(iso $(( NOW + 30 * DAY )))")" "$(acct 4 d@x false token_expired "$(iso $(( NOW + 30 * DAY )))")"
run
ck "fractional seconds and an offset parse" yes "$(has 'cswap login lapses in 1d0h: a@x' "$out")"
ck "an API key and cswap's other statuses are not named" 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

# ---- a rotating machine whose cswap cannot be read: exit 3, never a clean answer ----
CSWAP_STUB_FAIL=1 run
ck "unreadable list: exit 3" 3 "$rc"
ck "unreadable list: nothing on stdout" "" "$out"
ck "unreadable list: the reason on stderr" yes "$(has 'cswap-logins: cswap list --json carried no accounts array' "$err")"
CSWAP_STUB_FAIL=1 run --json
ck "unreadable list: json carries the reason" yes "$(jqok '.rotating == true and .accounts == null and .error == "cswap list --json carried no accounts array" and .lapsed == [] and .due == []')"
printf 'not json\n' > "$CSWAP_STUB_LIST"
run
ck "a list that is not JSON: exit 3" 3 "$rc"
NOBIN="$TMP/nobin"; mkdir -p "$NOBIN"; ln -s "$(command -v jq)" "$NOBIN/jq"
out=$(HOME="$FHOME" CSWAP_BIN="" PATH="$NOBIN:/usr/bin:/bin" "$SCRIPT" --now "$NOW" 2>"$TMP/err"); rc=$?; err=$(cat "$TMP/err")
ck "no cswap anywhere: exit 3" 3 "$rc"
ck "no cswap anywhere: says where it looked" yes "$(has 'cswap not on PATH or in ~/.local/bin' "$err")"

echo "cswap-logins-cron.sh"

NOTICES="$TMP/notices"
STATE="$FHOME/.claude/local/cswap-logins.json"
MARK="$FHOME/.claude/local/cswap-logins.notified"
tick() { HOME="$FHOME" CSWAP_LOGINS_NOTIFY_LOG="$NOTICES" "$CRON" --now "$1" >/dev/null 2>&1; echo $?; }
notices() { [ -f "$NOTICES" ] && wc -l < "$NOTICES" | tr -d ' ' || echo 0; }

accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" "$(acct 2 b@x false relogin_required "$(iso $(( NOW - DAY )))")"
ck "flagged tick exits 0" 0 "$(tick "$NOW")"
ck "flagged tick raises one notice" 1 "$(notices)"
ck "the notice names the account and the fix" yes "$(has "$(printf 'Claude accounts need a login\tLapsed: b@x. Run ~/.claude/scripts/cswap-setup.sh in a terminal.')" "$(cat "$NOTICES")")"
ck "the verdict is written for the pin" yes "$(jq -e '.rotating == true and (.lapsed | map(.email)) == ["b@x"]' "$STATE" >/dev/null 2>&1 && echo yes || echo no)"
ck "the next hour's tick stays quiet" "0 1" "$(tick $(( NOW + 3600 ))) $(notices)"
ck "but still refreshes the verdict" "$(iso $(( NOW + 3600 )))" "$(jq -r .checked_at "$STATE")"
ck "the same set repeats a day on" "0 2" "$(tick $(( NOW + 82800 ))) $(notices)"

accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" "$(acct 2 b@x false relogin_required "$(iso $(( NOW - DAY )))")" \
         "$(acct 3 c@x false ok "$(iso $(( NOW + 82800 + 7200 + 36000 )))")"
ck "a changed set is raised at once" "0 3" "$(tick $(( NOW + 82800 + 7200 ))) $(notices)"
ck "and names what is due" yes "$(has 'Lapsed: b@x. Due: c@x in 10h. Run' "$(sed -n '3p' "$NOTICES")")"

accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" "$(acct 2 b@x false ok "$(iso $(( NOW + 30 * DAY )))")"
ck "a cleared set raises nothing" "0 3" "$(tick $(( NOW + 82800 + 10800 ))) $(notices)"
ck "and forgets what it last raised" no "$([ -e "$MARK" ] && echo yes || echo no)"
ck "and the verdict reads clean" yes "$(jq -e '.lapsed == [] and .due == [] and .error == null' "$STATE" >/dev/null 2>&1 && echo yes || echo no)"

accounts "$(acct 1 a@x true ok "$(iso $(( NOW + 30 * DAY )))")" "$(acct 2 b@x false relogin_required "$(iso $(( NOW - DAY )))")"
ck "the same account lapsing again is raised at once" "0 4" "$(tick $(( NOW + 82800 + 14400 ))) $(notices)"

ck "a blind check exits 0" 0 "$(CSWAP_STUB_FAIL=1 tick $(( NOW + 82800 + 18000 )))"
ck "a blind check is raised as a failed check" yes "$(has "$(printf 'cswap login check failed\tCheck failed: cswap list --json carried no accounts array')" "$(sed -n '5p' "$NOTICES")")"
ck "a blind check is written for the pin" yes "$(jq -e '.error != null' "$STATE" >/dev/null 2>&1 && echo yes || echo no)"

rm -rf "$FHOME/.claude-swap-backup"
ck "a machine that stopped rotating raises nothing" "0 5" "$(tick $(( NOW + 82800 + 21600 ))) $(notices)"
ck "and its verdict says so" false "$(jq -r .rotating "$STATE")"
ck "every tick left a log line" 8 "$(wc -l < "$FHOME/.claude/logs/cswap-logins.log" | tr -d ' ')"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
