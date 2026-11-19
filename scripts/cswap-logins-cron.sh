#!/bin/bash
# cswap-logins-cron.sh — launchd entrypoint for the hourly login check on a machine that rotates accounts.
#
# Runs cswap-logins.sh, writes its verdict to ~/.claude/local/cswap-logins.json (what the rate-limits mod pins under
# the prompt) and raises a macOS notification when a login has lapsed or is about to. The notice repeats once a day
# while the same accounts stay flagged and fires at once when the set changes; the ticks in between only refresh the
# file. A check that could not read cswap is flagged the same way, since a blind check would otherwise read as clean.
#
# launchd strips the interactive PATH, so it is set here: uv puts `cswap` in ~/.local/bin.
#
# Install: scripts/cswap-setup.sh loads the agent (com.alienfast.cswap-logins); update.sh refreshes it wherever the
# rotation is installed. Unload: launchctl bootout gui/$(id -u)/com.alienfast.cswap-logins
# Test seams (cswap-logins.test.sh): --now <epoch>, and CSWAP_LOGINS_NOTIFY_LOG, a file that receives each notice as
# `<title><TAB><body>` in place of the notification.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/cswap-logins.log"
LOCAL_DIR="$HOME/.claude/local"
STATE="$LOCAL_DIR/cswap-logins.json"
NOTIFIED="$LOCAL_DIR/cswap-logins.notified"
# An hour short of a day, so the daily repeat lands on the same hourly tick instead of slipping to the next one.
REPEAT=82800
mkdir -p "$LOG_DIR" "$LOCAL_DIR"

NOW=""
[ "${1:-}" = "--now" ] && NOW="${2:-}"
[[ "$NOW" =~ ^[0-9]+$ ]] || NOW=$(date +%s)
stamp=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)

notify() { # <title> <body>
  if [ -n "${CSWAP_LOGINS_NOTIFY_LOG:-}" ]; then
    printf '%s\t%s\n' "$1" "$2" >> "$CSWAP_LOGINS_NOTIFY_LOG"
    return 0
  fi
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"' -e 'end run' \
    "$1" "$2" >/dev/null 2>&1 || true
}

if ! command -v jq >/dev/null 2>&1; then
  echo "$stamp ERROR jq not found (PATH=$PATH)" >> "$LOG"
  notify "cswap login check broken" "jq is missing — run ~/.claude/update.sh"
  exit 1
fi

rc=0
verdict=$("$here/cswap-logins.sh" --json --now "$NOW" 2>/dev/null) || rc=$?
if ! printf '%s' "$verdict" | jq -e 'type == "object"' >/dev/null 2>&1; then
  verdict=$(jq -cn --arg at "$stamp" --arg rc "$rc" \
    '{checked_at: $at, rotating: true, accounts: null, lapsed: [], due: [], error: "cswap-logins.sh exited \($rc) with no verdict"}')
fi

printf '%s\n' "$verdict" > "$STATE.tmp.$$" && mv -f "$STATE.tmp.$$" "$STATE"

flagged=$(jq -r '((.lapsed | length) + (.due | length)) > 0 or .error != null' <<<"$verdict")
sig=$(jq -r '[(.error // ""), (.lapsed | map(.email) | sort | join(",")), (.due | map(.email) | sort | join(","))] | join("|")' <<<"$verdict")
body=$(jq -r '
  [ (if (.lapsed | length) > 0 then "Lapsed: " + (.lapsed | map(.email) | join(", ")) else empty end),
    (if (.due | length) > 0 then "Due: " + (.due | map("\(.email) in \(.expires_in)") | join(", ")) else empty end),
    (if .error != null then "Check failed: " + .error else empty end) ] | join(". ")' <<<"$verdict")

if [ "$flagged" != true ]; then
  echo "$stamp ok ($(jq -r '.accounts // 0' <<<"$verdict") accounts, rotating=$(jq -r '.rotating' <<<"$verdict"))" >> "$LOG"
  rm -f "$NOTIFIED"
  exit 0
fi

echo "$stamp FLAGGED $body" >> "$LOG"
last_at=0; last_sig=""
[ -f "$NOTIFIED" ] && { read -r last_at last_sig < "$NOTIFIED" || true; }
[[ "$last_at" =~ ^[0-9]+$ ]] || last_at=0
if [ "$sig" != "$last_sig" ] || [ $(( NOW - last_at )) -ge "$REPEAT" ]; then
  if [ "$(jq -r '(.lapsed | length) + (.due | length)' <<<"$verdict")" -gt 0 ]; then
    notify "Claude accounts need a login" "$body. Run ~/.claude/scripts/cswap-setup.sh in a terminal."
  else
    notify "cswap login check failed" "$body"
  fi
  printf '%s %s\n' "$NOW" "$sig" > "$NOTIFIED"
fi
