#!/bin/bash
# reap-tmp-cron.sh — launchd entrypoint for the tmp reaper.
#
# A stable, side-effect-controlled wrapper around `reap-tmp.sh reap` (every registered repo plus ~/.claude)
# with a launchd-safe PATH and a timestamped append to a rolling log. launchd strips most of the interactive
# shell environment, so set PATH explicitly: git/jq/python3/lsof live in /usr/bin, /usr/sbin, /usr/local/bin,
# or /opt/homebrew/bin.
#
# Install: run ~/.claude/update.sh (renders the plist template for $HOME and bootstraps it).
# Unload:  launchctl bootout gui/$(id -u)/com.alienfast.tmp-reap

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/tmp-reap.log"
mkdir -p "$LOG_DIR"

# Preflight only the HARD dependencies. git decides whether a verdict's issue branch is merged and which
# paths are worktrees; jq reads the fleet and sequence markers; python3 backs with-repo-lock.py. Without any
# of them the state-gated lanes fail closed to KEEP, so a run would be a silent near-no-op — fail loudly
# instead. lsof is SOFT: its absence only stands the open-handle guard down (one WARN in the log).
missing=""
for bin in git jq python3; do command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"; done
if [ -n "$missing" ]; then
  {
    echo "=== reap-tmp $(date -u +%Y-%m-%dT%H:%M:%SZ) ABORTED ==="
    echo "ERROR: tmp reaper missing dependencies:$missing (PATH=$PATH)"
    echo
  } >> "$LOG" 2>&1
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"tmp reaper missing:$missing\" with title \"tmp reaper broken\"" >/dev/null 2>&1 || true
  exit 1
fi

{
  echo "=== reap-tmp $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  "$HOME/.claude/scripts/reap-tmp.sh" reap
  echo
} >> "$LOG" 2>&1
