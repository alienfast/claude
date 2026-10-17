#!/usr/bin/env bash
# cswap-auto-run.sh — launchd entrypoint that keeps `cswap auto` running (installed by cswap-setup.sh, label
# com.alienfast.cswap-auto). launchd strips the interactive PATH, so it is set here: uv puts `cswap` in ~/.local/bin,
# `claude` lives there or in Homebrew's bin, and `security` (Keychain) in /usr/bin.
#
# The engine's JSON event stream is appended to ~/.claude/logs/cswap-auto.log — one line per poll, switch, quarantine
# or error — which is what a week's trial is measured from. Rotated once at each (re)start past 20MB; the agent only
# restarts on a crash (KeepAlive SuccessfulExit=false), so a missing `cswap` exits 0 after logging why, rather than
# having launchd relaunch it every minute until someone re-runs the setup script.
#
# CSWAP_BIN is a test seam (the suite points it at a stub); unset, the binary is resolved on the PATH above.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

cswap="${CSWAP_BIN:-cswap}"
LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/cswap-auto.log"
mkdir -p "$LOG_DIR"

size=$(stat -f %z "$LOG" 2>/dev/null || stat -c %s "$LOG" 2>/dev/null || echo 0)
if [ "$size" -gt 20971520 ]; then mv -f "$LOG" "$LOG.1"; fi

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
if ! command -v "$cswap" >/dev/null 2>&1; then
  echo "{\"event\":\"wrapper-error\",\"at\":\"$(now)\",\"message\":\"cswap not found ($cswap on $PATH); re-run ~/.claude/scripts/cswap-setup.sh\"}" >> "$LOG"
  exit 0
fi

echo "{\"event\":\"wrapper-start\",\"at\":\"$(now)\",\"cswap\":\"$("$cswap" --version 2>/dev/null)\"}" >> "$LOG"
exec "$cswap" auto --json >> "$LOG" 2>&1
