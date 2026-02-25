#!/bin/bash

# Reusable lint-and-fix loop. Pass the lint command(s) as arguments.
# Usage: lint_and_fix "pnpm check-markdown"
#        lint_and_fix "pnpm check-biome && pnpm check-markdown"
lint_and_fix() {
  local lint_cmd="$1"
  local max_attempts=3
  local attempts=0

  echo "Linting files, if there are any errors..."
  while true; do
    LINT_OUTPUT=$(eval "$lint_cmd" 2>&1) && return 0
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
    echo "  ⚠️  Lint errors detected (attempt ${attempts}/${max_attempts}) — spawning Claude to fix..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Fix the following lint errors. Do not ask questions, just fix them:\n\n${LINT_OUTPUT}" | claude -p --allowedTools Edit,Read
  done
}
