#!/usr/bin/env bash
# Claude hook to lint files after Write/Edit operations
# Portable hook that checks for project-specific config files before running linters

# Read the JSON input from stdin
INPUT=$(cat)

# Extract the file path from the JSON (handles both Write and Edit tools)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only process if we got a file path
if [[ -n "$FILE_PATH" ]]; then
  # Get the directory of the file to search for config files
  FILE_DIR=$(dirname "$FILE_PATH")

  # Check if it's a markdown file and markdownlint config exists
  if [[ "$FILE_PATH" == *.md ]]; then
    # Look for markdownlint config in current dir or parent dirs
    if [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]; then
      echo "Running markdown linter on: $FILE_PATH"

      # Run markdownlint directly on the specific file
      if npx markdownlint --fix "$FILE_PATH" 2>&1; then
        echo "✓ Markdown check passed"
      else
        echo "⚠ Markdown linting errors found and fixed. Please review the changes."
        exit 1
      fi
    fi
  # Check if it's a file that biome should handle and biome config exists
  elif [[ "$FILE_PATH" =~ \.(json|jsonc|gql|ts|tsx|js|mjs|cjs)$ ]]; then
    # Look for biome config in current dir or parent dirs
    if [[ -f "biome.jsonc" ]] || [[ -f "biome.json" ]]; then
      echo "Running biome on: $FILE_PATH"

      # Run biome directly on the specific file
      if npx biome check --write "$FILE_PATH" 2>&1; then
        echo "✓ Biome check passed"
      else
        echo "⚠ Biome linting errors found and fixed. Please review the changes."
        exit 1
      fi
    fi
  fi
fi
