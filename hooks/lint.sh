#!/usr/bin/env bash
# Claude Stop hook for linting after edits are complete
# Runs biome/markdownlint on all files (fast enough to always run)

set -euo pipefail

# Read the JSON input from stdin
INPUT=$(cat)

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

  if npx biome check --write . 2>&1; then
    echo "✅ Biome check passed"
  else
    echo ""
    echo "⚠️  Biome fixed some issues. Please review the changes."
    echo ""
    exit 1
  fi

  RAN_LINTING=true
fi

# Run markdownlint if config exists
if [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]; then
  echo ""
  echo "📝 Running markdownlint --fix on all markdown files..."

  if npx markdownlint --fix '**/*.md' 2>&1; then
    echo "✅ Markdown check passed"
  else
    echo ""
    echo "⚠️  Markdownlint fixed some issues. Please review the changes."
    echo ""
    exit 1
  fi

  RAN_LINTING=true
fi

# If we didn't run any linting, exit silently (no noise)
if [[ "$RAN_LINTING" == "false" ]]; then
  exit 0
fi

exit 0
