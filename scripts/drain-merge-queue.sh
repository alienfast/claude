#!/bin/bash
# drain-merge-queue.sh — launchd entrypoint for the deferred-merge drainer.
#
# A stable, side-effect-free wrapper around `merge-queue.sh drain` (all registered
# repos) with a launchd-safe PATH and a timestamped append to a rolling log. launchd
# strips most of the interactive shell environment, so set PATH explicitly: git and
# friends typically live in /usr/bin, /usr/local/bin, or /opt/homebrew/bin.
#
# Install: run ~/.claude/update.sh (renders the plist template for $HOME and bootstraps it).
# Unload:  launchctl bootout gui/$(id -u)/com.alienfast.merge-queue-drain

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/merge-queue-drain.log"
mkdir -p "$LOG_DIR"

# Preflight the drainer's own dependencies. Under launchd's minimal environment a
# missing git/jq/python3 would make every 900s run a silent no-op (markers sit
# forever, no notification). Fail loudly instead so a dead drainer is detectable.
missing=""
for bin in git jq python3; do command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"; done
if [ -n "$missing" ]; then
  {
    echo "=== drain $(date -u +%Y-%m-%dT%H:%M:%SZ) ABORTED ==="
    echo "ERROR: drainer missing dependencies:$missing (PATH=$PATH)"
    echo
  } >> "$LOG" 2>&1
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"merge-queue drainer missing:$missing\" with title \"Merge drainer broken\"" >/dev/null 2>&1 || true
  exit 1
fi

{
  echo "=== drain $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  "$HOME/.claude/scripts/merge-queue.sh" drain
  echo
} >> "$LOG" 2>&1
