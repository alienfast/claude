#!/bin/bash

# Claude Configuration Validator
# Validates the markdown syntax and structure of claude configurations

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

# Validate markdown syntax for configuration files
echo "📋 Validating markdown files..."
md_errors=0

# Check agents directory
if [ -d "agents" ]; then
    for file in agents/*.md; do
        if [ -f "$file" ]; then
            if [ -s "$file" ] && head -n 1 "$file" | grep -q "^#"; then
                echo "✅ $file"
            else
                echo "❌ $file - Invalid markdown format or empty"
                md_errors=$((md_errors + 1))
            fi
        fi
    done
fi

# Check commands directory  
if [ -d "commands" ]; then
    for file in commands/*.md; do
        if [ -f "$file" ]; then
            if [ -s "$file" ] && head -n 1 "$file" | grep -q "^#"; then
                echo "✅ $file"
            else
                echo "❌ $file - Invalid markdown format or empty"
                md_errors=$((md_errors + 1))
            fi
        fi
    done
fi

# Still validate JSON files in templates
for file in $(find templates -name "*.json" -type f 2>/dev/null); do
    if python -m json.tool "$file" > /dev/null 2>&1; then
        echo "✅ $file"
    else
        echo "❌ $file - Invalid JSON syntax"
        md_errors=$((md_errors + 1))
    fi
done

if [ $md_errors -eq 0 ]; then
    echo "✅ All configuration files are valid"
else
    echo "❌ Found $md_errors configuration errors"
fi

# Check directory structure
echo ""
echo "📁 Checking directory structure..."

required_dirs=("agents" "commands" "templates" "scripts" "docs")
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
echo "Agents:"
ls -1 agents/*.md 2>/dev/null | sed 's/.*\///; s/\.md$//' | sed 's/^/  - /' || echo "  (none found)"

echo ""
echo "Commands:"
ls -1 commands/*.md 2>/dev/null | sed 's/.*\///; s/\.md$//' | sed 's/^/  - /' || echo "  (none found)"

echo ""
echo "Templates:"
find templates -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/.*\///; s/\/$//' | sed 's/^/  - /' || echo "  (none found)"

# Summary
echo ""
if [ $md_errors -eq 0 ] && [ $missing_dirs -eq 0 ]; then
    echo "🎉 Configuration validation passed!"
    echo "Your ~/.claude directory is ready to use."
else
    echo "⚠️  Configuration validation found issues."
    echo "Please fix the errors above before using claude configurations."
    exit 1
fi