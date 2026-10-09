#!/bin/bash
# mod-enabled.sh — exit 0 when the named mod from this repo's marketplace is installed and enabled on this machine.
#
# The fleet launchers call it before dispatching: since 2026-10-09 they add no --autocompact cap, because
# mods/loop-boundary compacts each /loop /auto session at its iteration boundaries — so a machine where that mod is
# not loaded would run every session uncapped on opus[1m] and never compact (the 2026-08-13/14 failure). The check
# reads `claude plugin list --json`, the same registry a session start loads from.
#
# Usage: mod-enabled.sh <mod-name>            e.g. mod-enabled.sh loop-boundary
# Exit:  0 — installed and enabled (prints nothing)
#        5 — not installed, or installed but disabled; the message names the command that fixes it
#        1 — usage error, or `claude plugin list --json` could not be read
set -u
name=${1:?usage: mod-enabled.sh <mod-name>}
id="$name@alienfast-claude"
if ! listing=$(claude plugin list --json 2>/dev/null); then
  echo "ERROR: could not read 'claude plugin list --json' to check that $id is enabled" >&2
  exit 1
fi
state=$(printf '%s' "$listing" | jq -r --arg id "$id" '[.[] | select(.id == $id)] | if length == 0 then "missing" elif .[0].enabled then "enabled" else "disabled" end' 2>/dev/null) || state=""
case "$state" in
  enabled) exit 0 ;;
  disabled)
    echo "ERROR: $id is installed but disabled on this machine. Enable it with: claude plugin enable $id" >&2
    exit 5 ;;
  missing)
    echo "ERROR: $id is not installed on this machine. Run ~/.claude/update.sh, or: claude plugin marketplace add ~/.claude && claude plugin install $id" >&2
    exit 5 ;;
  *)
    echo "ERROR: could not parse 'claude plugin list --json' while checking $id" >&2
    exit 1 ;;
esac
