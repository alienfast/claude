#!/bin/bash

# Claude Configuration Repository Setup Script
# This script helps set up the claude configuration repository in ~/.claude

set -e

CLAUDE_DIR="$HOME/.claude"
REPO_URL="https://github.com/alienfast/claude.git"

echo "🤖 Claude Configuration Setup"
echo "==============================="

# Check if ~/.claude already exists
if [ -d "$CLAUDE_DIR" ]; then
    echo "⚠️  Directory ~/.claude already exists."
    echo "Would you like to:"
    echo "1) Update existing installation"
    echo "2) Backup and reinstall"
    echo "3) Cancel"
    read -p "Enter choice (1-3): " choice
    
    case $choice in
        1)
            echo "📥 Updating existing installation..."
            cd "$CLAUDE_DIR"
            git pull origin main
            ;;
        2)
            echo "📦 Creating backup..."
            mv "$CLAUDE_DIR" "${CLAUDE_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
            echo "📥 Cloning fresh copy..."
            git clone "$REPO_URL" "$CLAUDE_DIR"
            ;;
        3)
            echo "❌ Installation cancelled."
            exit 0
            ;;
        *)
            echo "❌ Invalid choice. Installation cancelled."
            exit 1
            ;;
    esac
else
    echo "📥 Cloning Claude configuration repository..."
    git clone "$REPO_URL" "$CLAUDE_DIR"
fi

echo "✅ Setup completed successfully!"
echo ""
echo "📖 Next steps:"
echo "1. Explore available subagents: ls ~/.claude/subagents/"
echo "2. Check available commands: ls ~/.claude/commands/"
echo "3. Use project templates: ls ~/.claude/templates/"
echo "4. Read the documentation: cat ~/.claude/README.md"
echo ""
echo "🚀 You can now use Claude configurations across all your projects!"