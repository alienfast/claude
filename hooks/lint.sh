#!/usr/bin/env bash
# Claude Stop hook for batch linting after all edits are complete
# Runs biome/markdownlint once per response after all files have been edited

set -euo pipefail

# Read the JSON input from stdin
INPUT=$(cat)

# Extract the transcript path and cwd
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# If no transcript path, exit early
if [[ -z "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# Expand tilde in transcript path
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# Check if transcript file exists
if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# Change to the working directory
if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  cd "$CWD"
fi

# Parse transcript to find all files that were edited in this response
# We need to look for Write and Edit tool calls
BIOME_FILES=$(jq -r '
  select(.tool_name == "Write" or .tool_name == "Edit") |
  select(.tool_input.file_path | endswith(".json") or endswith(".jsonc") or endswith(".gql") or endswith(".ts") or endswith(".tsx") or endswith(".js") or endswith(".mjs") or endswith(".cjs")) |
  .tool_input.file_path
' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u)

MARKDOWN_FILES=$(jq -r '
  select(.tool_name == "Write" or .tool_name == "Edit") |
  select(.tool_input.file_path | endswith(".md")) |
  .tool_input.file_path
' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u)

# Track if we ran any linting
RAN_LINTING=false

# Run Biome if we have files and biome config exists
if [[ -n "$BIOME_FILES" ]] && ([[ -f "biome.jsonc" ]] || [[ -f "biome.json" ]]); then
  # Convert absolute paths to relative paths and filter out files outside the project
  RELATIVE_BIOME_FILES=""
  while IFS= read -r file; do
    if [[ -n "$file" ]]; then
      # Compute relative path
      if [[ "$file" = /* ]]; then
        RELATIVE_PATH=$(python3 -c "import os.path; print(os.path.relpath('$file', '$(pwd)'))" 2>/dev/null || echo "$file")
      else
        RELATIVE_PATH="$file"
      fi

      # Only include if file is within project (doesn't escape with ../)
      if [[ "$RELATIVE_PATH" != ../* ]]; then
        RELATIVE_BIOME_FILES="$RELATIVE_BIOME_FILES $RELATIVE_PATH"
      fi
    fi
  done <<< "$BIOME_FILES"

  # Trim leading whitespace
  RELATIVE_BIOME_FILES=$(echo "$RELATIVE_BIOME_FILES" | xargs)

  if [[ -n "$RELATIVE_BIOME_FILES" ]]; then
    FILE_COUNT=$(echo "$RELATIVE_BIOME_FILES" | wc -w | tr -d ' ')
    echo ""
    echo "🎨 Detected $FILE_COUNT file(s) for Biome linting"
    echo "🔍 Running biome check --write..."

    if npx biome check --write $RELATIVE_BIOME_FILES 2>&1; then
      echo "✅ Biome check passed"
    else
      echo ""
      echo "⚠️  Biome fixed some issues. Please review the changes."
      echo ""
      exit 1
    fi

    RAN_LINTING=true
  fi
fi

# Run markdownlint if we have files and markdownlint config exists
if [[ -n "$MARKDOWN_FILES" ]] && ([[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]); then
  # Convert absolute paths to relative paths and filter out files outside the project
  RELATIVE_MD_FILES=""
  while IFS= read -r file; do
    if [[ -n "$file" ]]; then
      # Compute relative path
      if [[ "$file" = /* ]]; then
        RELATIVE_PATH=$(python3 -c "import os.path; print(os.path.relpath('$file', '$(pwd)'))" 2>/dev/null || echo "$file")
      else
        RELATIVE_PATH="$file"
      fi

      # Only include if file is within project (doesn't escape with ../)
      if [[ "$RELATIVE_PATH" != ../* ]]; then
        RELATIVE_MD_FILES="$RELATIVE_MD_FILES $RELATIVE_PATH"
      fi
    fi
  done <<< "$MARKDOWN_FILES"

  # Trim leading whitespace
  RELATIVE_MD_FILES=$(echo "$RELATIVE_MD_FILES" | xargs)

  if [[ -n "$RELATIVE_MD_FILES" ]]; then
    FILE_COUNT=$(echo "$RELATIVE_MD_FILES" | wc -w | tr -d ' ')
    echo ""
    echo "📝 Detected $FILE_COUNT markdown file(s) for linting"
    echo "🔍 Running markdownlint --fix..."

    if npx markdownlint --fix $RELATIVE_MD_FILES 2>&1; then
      echo "✅ Markdown check passed"
    else
      echo ""
      echo "⚠️  Markdownlint fixed some issues. Please review the changes."
      echo ""
      exit 1
    fi

    RAN_LINTING=true
  fi
fi

# If we didn't run any linting, exit silently (no noise)
if [[ "$RAN_LINTING" == "false" ]]; then
  exit 0
fi

exit 0
