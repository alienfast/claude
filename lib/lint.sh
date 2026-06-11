#!/bin/bash

# Reusable lint-and-fix loop. Pass the lint command(s) as arguments.
# Usage: lint_and_fix "pnpm check-markdown"
#        lint_and_fix "pnpm check-biome && pnpm check-markdown"

# Hard wall-clock bound (seconds) for each spawned `claude -p` fix attempt. A stalled headless
# Claude used to hang the caller until the user repeatedly ctrl-c'd it; this makes a stuck attempt
# give up on its own. Override via the environment if needed.
: "${CLAUDE_FIX_TIMEOUT:=240}"

# Run "$@" under a wall-clock timeout, killing it (exit 124/143) if it overruns. Prefers
# timeout/gtimeout when present, else a portable background-watchdog fallback so the bound holds on
# a stock macOS without coreutils. The command must take its input as ARGUMENTS, not stdin:
# backgrounded jobs in a non-interactive shell get stdin redirected from /dev/null, so a piped
# prompt would silently vanish in the fallback path.
_run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"; return $?
  fi
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
  local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null; local rc=$?
  kill -TERM "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null
  return "$rc"
}

lint_and_fix() {
  local lint_cmd="$1"
  local max_attempts=3
  local attempts=0
  local last_output=""

  echo "Linting files, if there are any errors..."
  while true; do
    LINT_OUTPUT=$(eval "$lint_cmd" 2>&1) && return 0

    # Claude's previous attempt left the errors byte-for-byte unchanged — retrying is futile (e.g. a
    # rule with no auto-fixer, like MD060). Stop now rather than burning the remaining attempts.
    if [ -n "$last_output" ] && [ "$LINT_OUTPUT" = "$last_output" ]; then
      echo ""
      echo "  ❌ Lint errors unchanged after Claude's attempt — not auto-fixable. Please fix manually."
      echo ""
      echo "$LINT_OUTPUT"
      return 1
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo ""
      echo "  ❌ Lint errors remain after ${max_attempts} attempts. Please fix manually."
      echo ""
      echo "$LINT_OUTPUT"
      return 1
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️  Lint errors detected (attempt ${attempts}/${max_attempts}) — spawning Claude to fix (≤${CLAUDE_FIX_TIMEOUT}s)..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    last_output="$LINT_OUTPUT"
    local prompt rc
    prompt=$(printf 'Fix the following lint errors. Do not ask questions, just fix them:\n\n%s\n' "$LINT_OUTPUT")
    # Prompt is passed as an argument (not stdin) so _run_bounded's background fallback keeps it.
    _run_bounded "$CLAUDE_FIX_TIMEOUT" claude -p "$prompt" --allowedTools Edit,Read && rc=0 || rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
      echo "  ⏱️  Claude fix attempt exceeded ${CLAUDE_FIX_TIMEOUT}s and was stopped — moving on."
    fi
  done
}
