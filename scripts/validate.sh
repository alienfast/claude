#!/bin/bash

# Claude Configuration Validator
# Validates the JSON syntax and structure of claude configurations

set -e

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

echo "🔍 Claude Configuration Validator"
echo "=================================="

# Check if ~/.claude exists
if [ ! -d "$CLAUDE_DIR" ]; then
    echo "❌ ~/.claude directory not found. Run the install script first."
    exit 1
fi

cd "$CLAUDE_DIR"

# Validate JSON syntax for all JSON files
echo "📋 Validating JSON syntax..."
json_errors=0

for file in $(find . -name "*.json" -type f); do
    if python -m json.tool "$file" > /dev/null 2>&1; then
        echo "✅ $file"
    else
        echo "❌ $file - Invalid JSON syntax"
        json_errors=$((json_errors + 1))
    fi
done

if [ $json_errors -eq 0 ]; then
    echo "✅ All JSON files are valid"
else
    echo "❌ Found $json_errors JSON syntax errors"
fi

# Check directory structure
echo ""
echo "📁 Checking directory structure..."

required_dirs=("subagents" "commands" "templates" "scripts" "docs")
missing_dirs=0

for dir in "${required_dirs[@]}"; do
    if [ -d "$dir" ]; then
        echo "✅ $dir/"
    else
        echo "❌ $dir/ - Missing directory"
        missing_dirs=$((missing_dirs + 1))
    fi
done

if [ $missing_dirs -eq 0 ]; then
    echo "✅ All required directories present"
else
    echo "❌ Found $missing_dirs missing directories"
fi

# List available configurations
echo ""
echo "📊 Available Configurations:"
echo ""
echo "Subagents:"
ls -1 subagents/*.json 2>/dev/null | sed 's/.*\///; s/\.json$//' | sed 's/^/  - /' || echo "  (none found)"

echo ""
echo "Commands:"
ls -1 commands/*.json 2>/dev/null | sed 's/.*\///; s/\.json$//' | sed 's/^/  - /' || echo "  (none found)"

echo ""
echo "Templates:"
find templates -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/.*\///; s/\/$//' | sed 's/^/  - /' || echo "  (none found)"

# Summary
echo ""
if [ $json_errors -eq 0 ] && [ $missing_dirs -eq 0 ]; then
    echo "🎉 Configuration validation passed!"
    echo "Your ~/.claude directory is ready to use."
else
    echo "⚠️  Configuration validation found issues."
    echo "Please fix the errors above before using claude configurations."
    exit 1
fi