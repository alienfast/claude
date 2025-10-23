#!/usr/bin/env bash
# Claude Stop hook for batch type checking after all edits are complete
# Runs tsc -b or tsc once per response after all TypeScript files have been edited

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

# Parse transcript to find all TypeScript files that were edited in this response
# We need to look for Write and Edit tool calls on .ts, .tsx files
TS_FILES=$(jq -r '
  select(.tool_name == "Write" or .tool_name == "Edit") |
  select(.tool_input.file_path | endswith(".ts") or endswith(".tsx")) |
  .tool_input.file_path
' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u)

# If no TypeScript files were edited, exit early
if [[ -z "$TS_FILES" ]]; then
  exit 0
fi

# Count how many files were edited
FILE_COUNT=$(echo "$TS_FILES" | wc -l | tr -d ' ')

echo ""
echo "📝 Detected $FILE_COUNT TypeScript file(s) edited in this response"

# Change to the working directory
if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  cd "$CWD"
fi

# Check if the project uses TypeScript and has a tsconfig.json
if [[ ! -f "tsconfig.json" ]]; then
  echo "⚠️  No tsconfig.json found, skipping type check"
  exit 0
fi

# Detect if the project uses project references
USES_PROJECT_REFS=false
if jq -e '.references' tsconfig.json >/dev/null 2>&1; then
  USES_PROJECT_REFS=true
fi

echo "🔍 Running type check..."

# Run the appropriate tsc command
if [[ "$USES_PROJECT_REFS" == "true" ]]; then
  echo "   Using project references: npx tsc -b"
  if npx tsc -b --pretty 2>&1; then
    echo "✅ Type check passed"
  else
    echo ""
    echo "❌ Type errors found. Please fix the errors above."
    echo ""
    exit 1
  fi
else
  echo "   Standard mode: npx tsc"
  if npx tsc --pretty 2>&1; then
    echo "✅ Type check passed"
  else
    echo ""
    echo "❌ Type errors found. Please fix the errors above."
    echo ""
    exit 1
  fi
fi

exit 0
