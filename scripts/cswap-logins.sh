#!/usr/bin/env bash
# cswap-logins.sh — which accounts enrolled in cswap need a browser login: lapsed already, or lapsing inside a window.
#
# WHY: a stored login ends on a date cswap reports ahead of time (`loginExpiresAt`), and the engine cannot land on an
# account whose login has ended. Nothing said so: on 2026-11-18 four of five enrolled logins were three to five days
# past that date, the engine's log read "no candidate has readable usage" once a minute, and the login stayed on the
# one account left. This script owns the predicate, so the hourly notice (cswap-logins-cron.sh), fleet-cap.sh's line,
# the launchers' warning (lib/fleet-markers.sh) and the rate-limits mod's pin agree on what "needs a login" means.
#
# LAPSED is `usageStatus: relogin_required`, cswap's own verdict that only a new login repairs the slot, or a
# `loginExpiresAt` already past. DUE is a `loginExpiresAt` inside the window: --within <days> from now (default 3), or
# up to --before <epoch>, a fleet's deadline. cswap's other statuses are not read here.
#
# Usage: cswap-logins.sh [--within <days>] [--before <epoch>] [--json]
# Output: one line per flagged account, lapsed first and then soonest first, and a last line naming the fix; nothing
# when no login is flagged, or on a machine that does not rotate accounts (no cswap backup root). --json prints one
# object on every path: `checked_at`, `rotating`, `accounts`, `lapsed`, `due` (each row with `expires_in`, the time left
# as the lines print it) and `error`.
# Exit: 0 nothing flagged; 2 a login lapsed or due; 3 a rotating machine whose cswap could not be read, the reason on
# stderr and in `error` — the check is blind there, which is not the same as clean.
# Test seams: --now <epoch>, and CSWAP_BIN, the binary to ask in place of the one on PATH (the wrapper prepends system
# directories to PATH, so a stub there would not win). Run ./cswap-logins.test.sh after ANY change.

set -uo pipefail

WITHIN=3
BEFORE=""
AS_JSON=0
NOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --within)  WITHIN="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --before)  BEFORE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --now)     NOW="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --json)    AS_JSON=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; shift ;;
  esac
done

[[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date +%s)
[[ "$WITHIN" =~ ^[0-9]+([.][0-9]+)?$ ]] || WITHIN=3
[[ "$BEFORE" =~ ^[0-9]+$ ]] || BEFORE=""
checked=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)

blind() { # <why>
  echo "cswap-logins: $1" >&2
  [ "$AS_JSON" = 1 ] && printf '{"checked_at":"%s","rotating":true,"accounts":null,"lapsed":[],"due":[],"error":"%s"}\n' "$checked" "$1"
  exit 3
}

rotating=false
for d in "${HOME:-}/.claude-swap-backup" "${XDG_DATA_HOME:-${HOME:-}/.local/share}/claude-swap"; do [ -d "$d" ] && rotating=true; done
if [ "$rotating" = false ]; then
  [ "$AS_JSON" = 1 ] && printf '{"checked_at":"%s","rotating":false,"accounts":0,"lapsed":[],"due":[],"error":null}\n' "$checked"
  exit 0
fi

command -v jq >/dev/null 2>&1 || blind "jq not found"
cswap_bin="${CSWAP_BIN:-}"
[ -n "$cswap_bin" ] || cswap_bin=$(command -v cswap 2>/dev/null || true)
[ -z "$cswap_bin" ] && [ -x "${HOME:-}/.local/bin/cswap" ] && cswap_bin="$HOME/.local/bin/cswap"
[ -n "$cswap_bin" ] || blind "cswap not on PATH or in ~/.local/bin"
list=$("$cswap_bin" list --json 2>/dev/null) || list=""
printf '%s' "$list" | jq -e '.accounts | type == "array"' >/dev/null 2>&1 || blind "cswap list --json carried no accounts array"

verdict=$(printf '%s' "$list" | jq -c --argjson now "$NOW" --argjson within "$WITHIN" --arg before "$BEFORE" --arg checked "$checked" '
  def epoch: if . == null then null else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) end;
  def dur: if . < 3600 then "\(. / 60 | floor)m" elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d\((. % 86400) / 3600 | floor)h" end;
  (if $before != "" then ($before | tonumber) else $now + $within * 86400 end) as $horizon
  | [.accounts[] | {number, email, status: .usageStatus, login_expires_at: (.loginExpiresAt // null)} | .at = (.login_expires_at | epoch)] as $rows
  | {checked_at: $checked, rotating: true, accounts: ($rows | length),
     within_days: (if $before != "" then null else $within end),
     before: (if $before != "" then ($before | tonumber | todate) else null end),
     lapsed: ($rows | map(select(.status == "relogin_required" or (.at != null and .at <= $now))) | sort_by(.at // 0)
              | map({number, email, status, login_expires_at, expired: (.at != null and .at <= $now)})),
     due: ($rows | map(select(.status != "relogin_required" and .at != null and .at > $now and .at <= $horizon)) | sort_by(.at)
           | map({number, email, status, login_expires_at, expires_in_s: (.at - $now), expires_in: (.at - $now | dur)})),
     error: null}' 2>/dev/null) || verdict=""
[ -n "$verdict" ] || blind "cswap list --json could not be read"

if [ "$AS_JSON" = 1 ]; then
  printf '%s\n' "$verdict"
else
  jq -r '
    (.lapsed[] | "cswap login lapsed: \(.email) (" + (if .expired then "expired \(.login_expires_at)" else "cswap reports relogin_required" end) + ")"),
    (.due[] | "cswap login lapses in \(.expires_in): \(.email) (\(.login_expires_at))"),
    (if ((.lapsed | length) + (.due | length)) > 0
     then "cswap logins: redo each in a terminal — claude auth login as that account, then cswap add (~/.claude/scripts/cswap-setup.sh walks through them)"
     else empty end)' <<<"$verdict"
fi

[ "$(jq -r '(.lapsed | length) + (.due | length)' <<<"$verdict")" -gt 0 ] && exit 2
exit 0
