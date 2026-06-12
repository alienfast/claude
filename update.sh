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

echo "Installing linear-cli (Finesssee — https://github.com/Finesssee/linear-cli)..."
# Rust CLI with a raw-GraphQL `api` escape hatch. We use it (not joa23/Light Linear)
# because Light Linear cannot read description-anchored comments or unassign issues,
# and has no API passthrough to work around either. This installer assumes macOS +
# Homebrew and bootstraps the whole chain (Rust → cargo-binstall → linear-cli) so a
# fresh machine ends up with a working `linear-cli` on PATH.

# `cargo install` places binaries in ~/.cargo/bin regardless of how Rust was installed
# (brew or rustup), so that must be on PATH for this run and for future shells.
export PATH="$HOME/.cargo/bin:$PATH"

# 1. Rust toolchain (provides cargo). Install via Homebrew if absent.
if ! command -v cargo >/dev/null 2>&1; then
  echo "  Rust toolchain not found — installing via Homebrew (brew install rust)..."
  brew install rust
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "  ❌ cargo still not found after 'brew install rust'. Install Rust manually (https://rustup.rs) and re-run." >&2
  exit 1
fi

# 2. cargo-binstall — pulls a prebuilt linear-cli binary (via QuickInstall) instead of
#    a slow source compile. Prefer the Homebrew formula; fall back to `cargo install`.
if ! command -v cargo-binstall >/dev/null 2>&1; then
  echo "  Installing cargo-binstall..."
  brew install cargo-binstall 2>/dev/null || cargo install cargo-binstall
fi

# 3. linear-cli — binstall (fast, prebuilt) with a source-compile fallback.
if command -v cargo-binstall >/dev/null 2>&1; then
  cargo binstall -y linear-cli || cargo install linear-cli
else
  cargo install linear-cli
fi

if ! command -v linear-cli >/dev/null 2>&1; then
  echo "  ❌ linear-cli install failed (not found on PATH after install)." >&2
  exit 1
fi
echo "  ✓ $(linear-cli --version 2>/dev/null | head -1)"

# 4. Persist ~/.cargo/bin on PATH for future shells (so skills that call linear-cli
#    directly resolve it). Idempotent — skip if the rc already references cargo.
if [ -f "$HOME/.zshrc" ] \
   && ! grep -q 'cargo/bin' "$HOME/.zshrc" 2>/dev/null \
   && ! grep -q 'cargo/env' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n# rust/cargo — put ~/.cargo/bin on PATH (linear-cli, cargo-installed binaries)\nexport PATH="$HOME/.cargo/bin:$PATH"\n' >> "$HOME/.zshrc"
  echo "  ✓ added ~/.cargo/bin to ~/.zshrc PATH"
fi

# 5. Authentication. Linear skills are part of this repo (skills/) and need no
#    separate install, but linear-cli must be authenticated to be useful. Check
#    status; if not logged in, run the interactive browser OAuth now (this script is
#    run interactively from a terminal). LINEAR_API_KEY in the env also satisfies it.
if linear-cli auth status >/dev/null 2>&1; then
  echo "  ✓ linear-cli already authenticated"
elif [ -n "${LINEAR_API_KEY:-}" ]; then
  echo "  ✓ linear-cli will use LINEAR_API_KEY from the environment"
else
  echo ""
  echo "  linear-cli is not authenticated — launching browser OAuth..."
  if ! linear-cli auth oauth; then
    echo ""
    echo "  ⚠️  Authentication did not complete. Run it yourself before using Linear skills:"
    echo "        linear-cli auth oauth      # or: export LINEAR_API_KEY=<key>"
    echo "        linear-cli auth status     # confirm"
  fi
fi



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

