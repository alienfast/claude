#!/usr/bin/env bash
#
# verify-feature.sh - Verify that features mentioned in PR description exist in HEAD
#
# Usage:
#   ./verify-feature.sh <file-path> <search-pattern>
#
# Examples:
#   # Check if a function exists
#   ./verify-feature.sh src/utils.ts "function myFunction"
#
#   # Check for a specific configuration
#   ./verify-feature.sh config/database.ts "authentication_plugin"
#
#   # Check if a file exists at all
#   ./verify-feature.sh packages/api/README.md ""
#
# Returns:
#   0 - Feature found in HEAD
#   1 - Feature NOT found in HEAD (or file doesn't exist)
#
# This script uses `git show HEAD:path` to examine the actual final state
# of files in the current branch, not the working directory state.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Usage information
usage() {
    echo "Usage: $0 <file-path> <search-pattern>"
    echo ""
    echo "Verify that a feature exists in the final state of HEAD."
    echo ""
    echo "Arguments:"
    echo "  file-path       Path to file relative to repo root"
    echo "  search-pattern  Pattern to search for (use empty string to just check file exists)"
    echo ""
    echo "Examples:"
    echo "  $0 src/utils.ts 'function myFunction'"
    echo "  $0 config/database.ts 'authentication_plugin'"
    echo "  $0 packages/api/README.md ''"
    exit 1
}

# Check arguments
if [ $# -lt 1 ]; then
    echo -e "${RED}Error: Missing required arguments${NC}" >&2
    usage
fi

FILE_PATH="$1"
SEARCH_PATTERN="${2:-}"

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
    echo -e "${RED}Error: Not in a git repository${NC}" >&2
    exit 1
fi

# Check if file exists in HEAD
if ! git cat-file -e HEAD:"$FILE_PATH" 2>/dev/null; then
    echo -e "${RED}✗ MISSING${NC}: File '$FILE_PATH' does not exist in HEAD" >&2
    exit 1
fi

# If no search pattern, just confirm file exists
if [ -z "$SEARCH_PATTERN" ]; then
    echo -e "${GREEN}✓ PRESENT${NC}: File '$FILE_PATH' exists in HEAD"
    exit 0
fi

# Search for pattern in file
if git show HEAD:"$FILE_PATH" | grep -q "$SEARCH_PATTERN"; then
    echo -e "${GREEN}✓ PRESENT${NC}: Found '$SEARCH_PATTERN' in '$FILE_PATH' (HEAD)"
    exit 0
else
    echo -e "${RED}✗ MISSING${NC}: Pattern '$SEARCH_PATTERN' not found in '$FILE_PATH' (HEAD)" >&2
    exit 1
fi
