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
brew trust joa23/linear-cli
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



# Render a launchd plist template (__HOME__ → $HOME, since launchd needs absolute paths and won't expand
# $HOME) into ~/Library/LaunchAgents and (re)load it idempotently. Args: <label> <success-message tail>.
install_launchd_agent() {
  local label="$1" cadence="$2"
  local template="$HOME/.claude/launchd/$label.plist"
  local dest="$HOME/Library/LaunchAgents/$label.plist"
  [ -f "$template" ] || { echo "  skipped — template missing: $template"; return 0; }
  mkdir -p "$HOME/Library/LaunchAgents"
  local rendered
  rendered=$(sed "s|__HOME__|$HOME|g" "$template")
  if [ "$rendered" != "$(cat "$dest" 2>/dev/null)" ]; then
    printf '%s\n' "$rendered" > "$dest"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$dest" 2>/dev/null; then
      echo "  installed/updated — $cadence"
    else
      echo "  WARNING: wrote $dest but launchctl bootstrap failed; load it manually:"
      echo "    launchctl bootstrap gui/\$(id -u) $dest"
    fi
  elif launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    echo "  already current."
  else
    launchctl bootstrap "gui/$(id -u)" "$dest" 2>/dev/null \
      && echo "  loaded — $cadence" \
      || echo "  WARNING: could not load; run: launchctl bootstrap gui/\$(id -u) $dest"
  fi
}

echo ""
echo "Installing launchd agents..."
# Both are local launchd mechanisms; skip on non-macOS. The drainer lands deferred /finish merges; the
# reaper reclaims completed/abandoned /start wt worktrees (the PR-merged-later and Canceled-in-Linear
# cases finish-merge.sh's own cleanup can't reach).
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "Installing merge-queue drainer (launchd)..."
  install_launchd_agent "com.alienfast.merge-queue-drain" "drains the merge queue every 15 min."
  echo "Installing worktree reaper (launchd)..."
  install_launchd_agent "com.alienfast.worktree-reap" "reaps completed/abandoned worktrees hourly."
else
  echo "  skipped (macOS/launchd-only; this is $OSTYPE)."
fi

lint_and_fix "pnpm check-markdown"

echo ""
echo ""
echo "Installed skills for: ${AI_AGENT_LIST[*]}"
echo ""
echo "Done! You must restart Claude (or vscode) for the changes to take effect."

