#!/bin/bash

# set -x
set -e

echo "Updating Claude Code..."
claude update

echo "Updating plugin marketplaces..."
claude plugin marketplace update

# Ensure pnpm global bin directory is configured
if [ -z "$PNPM_HOME" ]; then
  echo "Configuring pnpm global bin directory..."
  pnpm setup
  if [[ "$OSTYPE" == "darwin"* ]]; then
    export PNPM_HOME="$HOME/Library/pnpm"
  else
    export PNPM_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pnpm"
  fi
  export PATH="$PNPM_HOME:$PATH"
fi

echo "Installing skills helper..."
pnpm add -g skills


AI_AGENT_LIST=(codex github-copilot claude-code)
AI_AGENTS=$(printf -- '-a %s ' "${AI_AGENT_LIST[@]}")
echo ""
echo "Installing skills for: ${AI_AGENT_LIST[*]}"
echo ""

echo "Updating vercel agent-browser..."
pnpm add -g agent-browser
agent-browser install
pnpm dlx skills add vercel-labs/agent-browser \
  -g \
  --skill agent-browser \
  --skill skill-creator \
  $AI_AGENTS \
  -y

echo "Updating vercel agent-skills..."
pnpm dlx skills add vercel-labs/agent-skills \
  -g \
  --skill vercel-composition-patterns \
  --skill vercel-react-best-practices \
  $AI_AGENTS \
  -y

echo "Installing linear CLI and skills..."
brew tap joa23/linear-cli https://github.com/joa23/linear-cli
brew install linear-cli

echo ""
echo "Installing linear skills..."
if ! (cd "$HOME" && linear skills install --all); then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ❌ Linear skills installation failed."
  echo ""
  echo "  Run the following to set up Linear CLI (https://github.com/joa23/linear-cli/tree/main?tab=readme-ov-file#authentication),"
  echo "   then re-run this script:"
  echo ""
  echo "    # 1. Authenticate (as Personal, not a Agent, accept the default port, do not set your GitHub username)"
  echo "    linear auth login"
  echo ""
  echo "    # 2. Initialize your project (select default team)"
  echo "    linear init"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi


echo "Linting files, if there are any errors..."
LINT_ATTEMPTS=0
MAX_LINT_ATTEMPTS=3
while true; do
  LINT_OUTPUT=$(pnpm check-markdown 2>&1) && break
  LINT_ATTEMPTS=$((LINT_ATTEMPTS + 1))
  if [ "$LINT_ATTEMPTS" -ge "$MAX_LINT_ATTEMPTS" ]; then
    echo ""
    echo "  ❌ Lint errors remain after ${MAX_LINT_ATTEMPTS} attempts. Please fix manually."
    echo ""
    echo "$LINT_OUTPUT"
    exit 1
  fi
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ⚠️  Lint errors detected (attempt ${LINT_ATTEMPTS}/${MAX_LINT_ATTEMPTS}) — spawning Claude to fix..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Fix the following lint errors. Do not ask questions, just fix them:\n\n${LINT_OUTPUT}" | claude -p --allowedTools Edit,Read
done

echo ""
echo ""
echo "Installed skills for: ${AI_AGENT_LIST[*]}"
echo ""
echo "Done! You must restart Claude (or vscode) for the changes to take effect."

