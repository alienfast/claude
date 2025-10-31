#!/usr/bin/env bash
# Claude PostToolUse hook for immediate linting after file modifications
# Only runs on files that were just modified by the tool

set -euo pipefail

# Debug logging setup
DEBUG_LOG="/tmp/claude-lint-posttool-hook.log"

# Read the JSON input from stdin
INPUT=$(cat)

# Log hook invocation
{
  echo "=== $(date) ==="
  echo "PostToolUse Hook invoked"
  echo "Input: $INPUT"
  echo ""
} >> "$DEBUG_LOG" 2>&1

# Extract tool name and cwd
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only proceed for file modification tools
if [[ "$TOOL_NAME" != "Edit" ]] && [[ "$TOOL_NAME" != "Write" ]] && [[ "$TOOL_NAME" != "NotebookEdit" ]]; then
  {
    echo "Tool $TOOL_NAME is not a file modification tool, skipping"
    echo ""
  } >> "$DEBUG_LOG" 2>&1
  exit 0
fi

# Extract file path from tool parameters
FILE_PATH=""
if [[ "$TOOL_NAME" == "Edit" ]] || [[ "$TOOL_NAME" == "Write" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.params.file_path // empty')
elif [[ "$TOOL_NAME" == "NotebookEdit" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.params.notebook_path // empty')
fi

if [[ -z "$FILE_PATH" ]]; then
  {
    echo "No file path found in tool parameters"
    echo ""
  } >> "$DEBUG_LOG" 2>&1
  exit 0
fi

# Change to the working directory
if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  cd "$CWD"
fi

# Make file path relative if it's absolute and within cwd
if [[ "$FILE_PATH" = /* ]] && [[ -n "$CWD" ]]; then
  FILE_PATH=$(realpath --relative-to="$CWD" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
fi

{
  echo "Processing file: $FILE_PATH"
  echo "Working directory: $CWD"
} >> "$DEBUG_LOG" 2>&1

# Check if file exists
if [[ ! -f "$FILE_PATH" ]]; then
  {
    echo "File does not exist: $FILE_PATH"
    echo ""
  } >> "$DEBUG_LOG" 2>&1
  exit 0
fi

# Determine file type and run appropriate linter
FILE_EXT="${FILE_PATH##*.}"
FILE_NAME=$(basename "$FILE_PATH")

# Track if we ran linting
RAN_LINTING=false

# Run markdownlint for markdown files
if [[ "$FILE_EXT" == "md" ]] || [[ "$FILE_EXT" == "markdown" ]]; then
  if [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlintrc" ]]; then
    echo ""
    echo "📝 Linting $FILE_NAME..."

    # Run with --fix first
    if npx markdownlint --fix "$FILE_PATH" 2>&1; then
      echo "✅ Markdown lint passed: $FILE_NAME"
    else
      # Run again without fix to show remaining issues
      echo "⚠️  Markdown issues in $FILE_NAME:"
      npx markdownlint "$FILE_PATH" 2>&1 || true
    fi

    RAN_LINTING=true
  fi
fi

# Run biome for supported file types
BIOME_EXTENSIONS=("js" "jsx" "ts" "tsx" "json" "jsonc" "mjs" "cjs")
if [[ " ${BIOME_EXTENSIONS[@]} " =~ " ${FILE_EXT} " ]]; then
  if [[ -f "biome.jsonc" ]] || [[ -f "biome.json" ]]; then
    echo ""
    echo "🎨 Linting $FILE_NAME..."

    # Run with --write first
    if npx biome check --write "$FILE_PATH" 2>&1; then
      echo "✅ Biome check passed: $FILE_NAME"
    else
      # Run again without write to show remaining issues
      echo "⚠️  Biome issues in $FILE_NAME:"
      npx biome check "$FILE_PATH" 2>&1 || true
    fi

    RAN_LINTING=true
  fi
fi

# Log completion
{
  echo "--- $(date) ---"
  echo "PostToolUse linting completed:"
  echo "  File: $FILE_PATH"
  echo "  Extension: $FILE_EXT"
  echo "  Ran linting: $RAN_LINTING"
  echo ""
} >> "$DEBUG_LOG" 2>&1

# Always exit 0 to not block the tool execution
exit 0