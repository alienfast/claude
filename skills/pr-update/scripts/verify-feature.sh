#!/bin/bash
# Verify if a feature exists in the final state of the code
#
# Usage: ./verify-feature.sh <file-path> <search-pattern>
# Example: ./verify-feature.sh cloud/database/src/SqlDatabase.ts "mysql_native_password"

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <file-path> <search-pattern>"
  echo ""
  echo "Examples:"
  echo "  $0 cloud/database/src/sql.ts sqlDrReplica"
  echo "  $0 packages/api/README.md 'MySQL client'"
  exit 1
fi

FILE_PATH="$1"
PATTERN="$2"

# Check if file exists in HEAD
if ! git ls-files --error-unmatch "$FILE_PATH" &> /dev/null; then
  echo "❌ File not found in repository: $FILE_PATH"
  exit 1
fi

# Search for pattern in HEAD version
if git show "HEAD:$FILE_PATH" | grep -q "$PATTERN"; then
  echo "✅ PRESENT in final state"
  echo ""
  echo "Context:"
  git show "HEAD:$FILE_PATH" | grep -B2 -A2 "$PATTERN" | head -20
  exit 0
else
  echo "❌ NOT FOUND in final state"
  echo ""
  echo "This feature may have been added and then removed during development."
  echo "DO NOT include it in the PR description."
  exit 1
fi
