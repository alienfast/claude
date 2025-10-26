#!/usr/bin/env bash
# Claude Stop hook for linting after edits are complete
# Runs biome/markdownlint on all files (fast enough to always run)

set -euo pipefail

# Debug logging setup
DEBUG_LOG="/tmp/claude-lint-hook.log"

# Read the JSON input from stdin
INPUT=$(cat)

# Log hook invocation
{
  echo "=== $(date) ==="
  echo "Hook invoked"
  echo "Input: $INPUT"
  echo ""
} >> "$DEBUG_LOG" 2>&1

# Extract the cwd
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Change to the working directory
if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  cd "$CWD"
fi

# Track if we ran any linting
RAN_LINTING=false

# Run Biome if config exists
if [[ -f "biome.jsonc" ]] || [[ -f "biome.json" ]]; then
  echo ""
  echo "🎨 Running biome check --write on all files..."

  # First run with --write to fix what can be fixed
  npx biome check --write . 2>&1 || true

  # Then run again without --write to check for remaining issues
  if npx biome check . 2>&1; then
    echo "✅ Biome check passed"
  else
    echo ""
    echo "❌ Biome found issues that need manual fixing"
    echo ""
    {
      echo "--- $(date) ---"
      echo "Biome found unfixable issues - exiting with code 1"
      echo ""
    } >> "$DEBUG_LOG" 2>&1
    exit 1
  fi

  RAN_LINTING=true
fi

# Run markdownlint if config exists
if [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]; then
  echo ""
  echo "📝 Running markdownlint --fix on all markdown files..."

  # First run with --fix to fix what can be fixed
  npx markdownlint --fix '**/*.md' 2>&1 || true

  # Then run again without --fix to check for remaining issues
  if npx markdownlint '**/*.md' 2>&1; then
    echo "✅ Markdown check passed"
  else
    echo ""
    echo "❌ Markdownlint found issues that need manual fixing"
    echo ""
    {
      echo "--- $(date) ---"
      echo "Markdownlint found unfixable issues - exiting with code 1"
      echo ""
    } >> "$DEBUG_LOG" 2>&1
    exit 1
  fi

  RAN_LINTING=true
fi

# Log completion status
{
  echo "--- $(date) ---"
  echo "Linting completed:"
  echo "  Working directory: $CWD"
  echo "  Ran linting: $RAN_LINTING"

  if [[ -f "biome.jsonc" ]] || [[ -f "biome.json" ]]; then
    echo "  Biome config found: yes"
  else
    echo "  Biome config found: no"
  fi

  if [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]; then
    echo "  Markdownlint config found: yes"
  else
    echo "  Markdownlint config found: no"
  fi

  echo "  Exit code: 0"
  echo ""
} >> "$DEBUG_LOG" 2>&1

# If we didn't run any linting, exit silently (no noise)
if [[ "$RAN_LINTING" == "false" ]]; then
  exit 0
fi

exit 0
