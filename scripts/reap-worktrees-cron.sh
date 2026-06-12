#!/bin/bash
# reap-worktrees-cron.sh — launchd entrypoint for the worktree reaper.
#
# A stable, side-effect-controlled wrapper around `reap-worktrees.sh reap` (all registered repos) with
# a launchd-safe PATH and a timestamped append to a rolling log. launchd strips most of the interactive
# shell environment, so set PATH explicitly: git/jq/python3/gh typically live in /usr/bin,
# /usr/local/bin, or /opt/homebrew/bin; linear-cli installs to ~/.cargo/bin.
#
# Install: run ~/.claude/update.sh (renders the plist template for $HOME and bootstraps it).
# Unload:  launchctl bootout gui/$(id -u)/com.alienfast.worktree-reap

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/worktree-reap.log"
mkdir -p "$LOG_DIR"

# Preflight only the HARD dependencies. git inspects the worktrees; jq parses Linear JSON; python3 backs
# with-repo-lock.py — without any of them every run is a silent no-op, so fail loudly instead. gh and
# linear-cli are SOFT: their absence just disables the PR / Linear evidence (the local merged check still
# reaps merged worktrees), so they are not preflighted here.
missing=""
for bin in git jq python3; do command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"; done
if [ -n "$missing" ]; then
  {
    echo "=== reap $(date -u +%Y-%m-%dT%H:%M:%SZ) ABORTED ==="
    echo "ERROR: reaper missing dependencies:$missing (PATH=$PATH)"
    echo
  } >> "$LOG" 2>&1
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"worktree reaper missing:$missing\" with title \"Worktree reaper broken\"" >/dev/null 2>&1 || true
  exit 1
fi

{
  echo "=== reap $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  "$HOME/.claude/scripts/reap-worktrees.sh" reap
  echo
} >> "$LOG" 2>&1
