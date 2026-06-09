#!/bin/bash

# set -x
set -e

source "$HOME/.claude/lib/lint.sh"

echo "Updating Claude Code..."
claude update

echo "Updating plugin marketplaces..."
claude plugin marketplace update
claude plugin marketplace update claude-plugins-official

echo "Installing lsp servers..."
claude plugin install typescript-lsp

# Ensure pnpm's global bin directory ($PNPM_HOME/bin as of pnpm 11) is on PATH — `pnpm
# add -g` refuses to run when it isn't. Augment PATH unconditionally (the parent shell
# always exports PNPM_HOME, so a `-z "$PNPM_HOME"` guard would skip this every time).
if [ -z "$PNPM_HOME" ]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    export PNPM_HOME="$HOME/Library/pnpm"
  else
    export PNPM_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pnpm"
  fi
fi
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac

echo "Installing skills helper..."
pnpm add -g skills


AI_AGENT_LIST=(codex github-copilot claude-code)
AI_AGENTS=$(printf -- '-a %s ' "${AI_AGENT_LIST[@]}")
echo ""
echo "Installing skills for: ${AI_AGENT_LIST[*]}"
echo ""

echo "Updating vercel agent-browser..."
# pnpm 11 enables strictDepBuilds by default, so a global install of a package with a
# build script (agent-browser's postinstall fetches its native binary) prompts for
# approval in an interactive shell and hangs the script. --allow-build approves it
# non-interactively. It is per-invocation (not persisted to global config), so it must
# stay on this line.
pnpm add -g agent-browser --allow-build=agent-browser
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

# these are already part of this repo and will not be overwritten by the command.  Further, we have done some optimizations to prevent permission prompts etc.
# echo ""
# echo "Installing linear skills..."
# if ! (cd "$HOME" && linear skills install --all); then
#   echo ""
#   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#   echo "  ❌ Linear skills installation failed."
#   echo ""
#   echo "  Run the following to set up Linear CLI (https://github.com/joa23/linear-cli/tree/main?tab=readme-ov-file#authentication),"
#   echo "   then re-run this script:"
#   echo ""
#   echo "    # 1. Authenticate (as Personal, not a Agent, accept the default port, do not set your GitHub username)"
#   echo "    linear auth login"
#   echo ""
#   echo "    # 2. Initialize your project (select default team)"
#   echo "    linear init"
#   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#   exit 1
# fi



echo ""
echo "Installing merge-queue drainer (launchd)..."
# Render the plist template (launchd needs absolute paths and won't expand $HOME)
# and (re)load it idempotently. macOS-only — the deferred-merge queue is a local
# launchd mechanism; skip elsewhere.
if [[ "$OSTYPE" == "darwin"* ]]; then
  mq_label="com.alienfast.merge-queue-drain"
  mq_template="$HOME/.claude/launchd/$mq_label.plist"
  mq_dest="$HOME/Library/LaunchAgents/$mq_label.plist"
  if [ -f "$mq_template" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    mq_rendered=$(sed "s|__HOME__|$HOME|g" "$mq_template")
    if [ "$mq_rendered" != "$(cat "$mq_dest" 2>/dev/null)" ]; then
      printf '%s\n' "$mq_rendered" > "$mq_dest"
      launchctl bootout "gui/$(id -u)/$mq_label" 2>/dev/null || true
      if launchctl bootstrap "gui/$(id -u)" "$mq_dest" 2>/dev/null; then
        echo "  installed/updated — drains the merge queue every 15 min."
      else
        echo "  WARNING: wrote $mq_dest but launchctl bootstrap failed; load it manually:"
        echo "    launchctl bootstrap gui/\$(id -u) $mq_dest"
      fi
    elif launchctl print "gui/$(id -u)/$mq_label" >/dev/null 2>&1; then
      echo "  already current."
    else
      launchctl bootstrap "gui/$(id -u)" "$mq_dest" 2>/dev/null \
        && echo "  loaded — drains the merge queue every 15 min." \
        || echo "  WARNING: could not load; run: launchctl bootstrap gui/\$(id -u) $mq_dest"
    fi
  fi
else
  echo "  skipped (macOS/launchd-only; this is $OSTYPE)."
fi

lint_and_fix "pnpm check-markdown"

echo ""
echo ""
echo "Installed skills for: ${AI_AGENT_LIST[*]}"
echo ""
echo "Done! You must restart Claude (or vscode) for the changes to take effect."

