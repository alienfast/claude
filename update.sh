#!/bin/bash

# set -x
set -e

source "$HOME/.claude/lib/lint.sh"

# OS detection drives the package-manager branches below. Git Bash / MSYS2 on Windows reports
# OSTYPE=msys (uname → MINGW64_NT / MSYS_NT); macOS is darwin*. macOS installs system tools via
# Homebrew; Windows has no brew, so there we install what the cross-platform managers (cargo, pnpm,
# npm) can and verify-and-instruct (winget) for the rest. Anything else (Linux) degrades to
# verify-and-warn, matching the pre-existing non-macOS fallbacks.
case "$OSTYPE" in
  darwin*)             CLAUDE_OS=macos ;;
  msys*|cygwin*|win*)  CLAUDE_OS=windows ;;
  *)                   CLAUDE_OS=other ;;
esac

echo "Updating Claude Code..."
# Non-fatal: a failed self-update (e.g. an npm-managed install on Windows where `claude update` is a
# no-op or errors) must not abort the whole bootstrap.
claude update || echo "  ⚠️  'claude update' failed or is unsupported here; continuing."

echo "Updating plugin marketplaces..."
claude plugin marketplace update
claude plugin marketplace update claude-plugins-official

echo "Installing lsp servers..."
claude plugin install typescript-lsp

# Ensure pnpm's global bin directory ($PNPM_HOME/bin as of pnpm 11) is on PATH — `pnpm
# add -g` refuses to run when it isn't. Augment PATH unconditionally (the parent shell
# always exports PNPM_HOME, so a `-z "$PNPM_HOME"` guard would skip this every time).
if [ -z "$PNPM_HOME" ]; then
  case "$CLAUDE_OS" in
    macos)   export PNPM_HOME="$HOME/Library/pnpm" ;;
    # pnpm on Windows keeps globals under %LOCALAPPDATA%\pnpm; convert to a POSIX path for Git Bash.
    # Require BOTH a non-empty LOCALAPPDATA and cygpath: `cygpath -u ""` exits 0 with empty output, and
    # a failed `$(cygpath …)` substitution does not trip set -e — either would yield a bogus "/pnpm".
    windows)
      if [ -n "$LOCALAPPDATA" ] && command -v cygpath >/dev/null 2>&1; then
        export PNPM_HOME="$(cygpath -u "$LOCALAPPDATA")/pnpm"
      else
        export PNPM_HOME="$HOME/.local/share/pnpm"
      fi ;;
    *)       export PNPM_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pnpm" ;;
  esac
fi
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac

# Install a Homebrew formula if missing, upgrade it if present. Idempotent: present-and-current is a no-op.
# Branch on `brew list` because `brew install` never upgrades and `brew upgrade` errors on a not-installed formula.
# The asymmetry under `set -e` is deliberate: an upgrade failure is swallowed (`|| true` — the working older version
# stays, so keep going), but an install failure aborts the bootstrap — a core tool that is entirely absent is not
# something to continue past.
ensure_brew() {
  local formula
  for formula in "$@"; do
    if brew list "$formula" >/dev/null 2>&1; then
      brew upgrade "$formula" >/dev/null 2>&1 || true
    else
      brew install "$formula"
    fi
  done
}

# Core CLI tools the skills assume on PATH: gh (start/finish/pr-update/dependency-updater/reap-worktrees) and jq
# (preflight-gated with `exit 1` in several scripts). Prefer Homebrew (the linear-cli bootstrap below also needs it),
# and run this before the slow pnpm/cargo work so a missing Homebrew surfaces early, not 90 lines into the cargo build.
# macOS without Homebrew is a hard stop (brew is how the whole script installs system tools). Non-macOS degrades like
# the rest of the script: just verify gh/jq are present (they come from the distro package manager, not brew) and warn.
echo ""
echo "Ensuring core CLI tools (gh, jq)..."
if command -v brew >/dev/null 2>&1; then
  ensure_brew gh jq
elif [ "$CLAUDE_OS" = macos ]; then
  echo "  ❌ Homebrew is required but not found. Install it from https://brew.sh and re-run." >&2
  exit 1
elif [ "$CLAUDE_OS" = windows ]; then
  # winget is a Store app-execution-alias that Git Bash usually can't invoke directly, so on Windows
  # verify presence and print the exact PowerShell command to run rather than shelling out to winget.
  for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        gh) echo "  ⚠️  gh not found — in PowerShell run: winget install -e --id GitHub.cli" ;;
        jq) echo "  ⚠️  jq not found — in PowerShell run: winget install -e --id jqlang.jq" ;;
      esac
    fi
  done
else
  for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || echo "  ⚠️  $tool not found on PATH — install it via your package manager; skills that use it will fail until you do."
  done
fi

# gh must be authenticated for the PR/start/finish flows (gh api user, gh pr create). Mirror the linear-cli auth step
# below: check status, and only launch the interactive `gh auth login` when there is a TTY — in a non-interactive run
# (CI, piped, ssh one-shot, a /full macro) it would hang on a prompt with no stdin, so warn and continue instead.
# Scope the status check to github.com: bare `gh auth status` exits non-zero if ANY configured host is logged out,
# which would force a needless re-login on machines that once added a now-expired enterprise host.
if gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "  ✓ gh already authenticated"
elif [ -t 0 ] && [ -t 1 ]; then
  echo ""
  echo "  gh is not authenticated — launching gh auth login..."
  if ! gh auth login; then
    echo ""
    echo "  ⚠️  gh authentication did not complete. Run it yourself before using PR/start/finish skills:"
    echo "        gh auth login"
    echo "        gh auth status   # confirm"
  fi
else
  echo ""
  echo "  ⚠️  gh is not authenticated and no TTY is available for interactive login. Authenticate before using PR/start/finish skills:"
  echo "        gh auth login"
  echo "        gh auth status   # confirm"
fi

echo ""
echo "Installing skills helper..."
pnpm add -g skills

echo "Installing npm-check-updates (ncu) — required global for the dependency-updater skill..."
pnpm add -g npm-check-updates


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
# agent-browser ships prebuilt native binaries per platform but none for win32-arm64 (Windows-on-ARM
# dev VMs). Its postinstall still downloads the win32-x64 binary, and Windows-on-ARM runs x64 exes
# under built-in emulation — so alias x64 to the per-arch name the wrapper wants and retry. The
# wrapper prints the exact path it looked for ("Expected: …"), so parse that rather than guessing
# pnpm's store layout (pnpm root -g does not point at the real linked package dir). Never abort the
# bootstrap under set -e for this optional tool — everything after it (linear-cli included) matters more.
agent-browser install || {
  ab_skip_msg="  ⚠️  agent-browser has no prebuilt binary for this platform — skipping; browser-automation skills won't work here."
  ab_expected=$(agent-browser --version 2>&1 | sed -n 's/^Expected: //p' | tr -d '\r')
  if [ "$CLAUDE_OS" = windows ] && [ -n "$ab_expected" ]; then
    ab_expected=$(cygpath -u "$ab_expected")
    ab_x64="$(dirname "$ab_expected")/agent-browser-win32-x64.exe"
    if [ -f "$ab_x64" ]; then
      echo "  No upstream binary for this arch — aliasing win32-x64 to $(basename "$ab_expected") (runs under x64 emulation)..."
      cp "$ab_x64" "$ab_expected"
      agent-browser install \
        || echo "  ⚠️  agent-browser still failing under x64 emulation — skipping; browser-automation skills won't work here."
    else
      echo "$ab_skip_msg"
    fi
  else
    echo "$ab_skip_msg"
  fi
}
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

# Remove the old joa23/Light Linear `linear-cli` Homebrew formula if present. It installs its own
# `linear-cli` binary that shadows the Finesssee cargo binary on PATH (whichever brew/cargo dir comes
# first wins), so a stale brew copy silently breaks the Linear skills. Idempotent: only act when the
# formula is actually installed / the tap actually present, so re-runs are no-ops.
# Homebrew-only cleanup — the shadowing formula only ever existed on macOS, so guard the whole block
# (a bare `brew` call on Windows would spew "command not found").
if [ "$CLAUDE_OS" = macos ] && command -v brew >/dev/null 2>&1; then
  if brew list linear-cli >/dev/null 2>&1; then
    echo "Removing old Homebrew linear-cli (joa23/Light Linear)..."
    brew uninstall linear-cli
  fi
  if brew tap | grep -q '^joa23/linear-cli$'; then
    echo "Untapping joa23/linear-cli..."
    brew untap joa23/linear-cli
  fi
fi

echo "Installing linear-cli (Finesssee — https://github.com/Finesssee/linear-cli)..."
# Rust CLI with a raw-GraphQL `api` escape hatch. We use it (not joa23/Light Linear)
# because Light Linear cannot read description-anchored comments or unassign issues,
# and has no API passthrough to work around either. This installer assumes macOS +
# Homebrew and bootstraps the whole chain (Rust → cargo-binstall → linear-cli) so a
# fresh machine ends up with a working `linear-cli` on PATH.

# `cargo install` places binaries in ~/.cargo/bin regardless of how Rust was installed
# (brew or rustup), so that must be on PATH for this run and for future shells.
export PATH="$HOME/.cargo/bin:$PATH"

# Windows: install the prebuilt x86_64 release binary via gh and skip the cargo chain — a source
# compile needs a C toolchain cargo can't assume (ring wants clang on ARM64 hosts), and the x86_64
# build runs natively on the all-x64 production machines and under Windows' built-in x64 emulation
# on ARM64 dev VMs. Falls through to the cargo chain below only if the download fails.
linear_cli_installed=false
if [ "$CLAUDE_OS" = windows ]; then
  echo "  Downloading prebuilt linear-cli release (x86_64-pc-windows-msvc)..."
  linear_tmp=$(mktemp -d)
  if gh release download --repo Finesssee/linear-cli --pattern '*x86_64-pc-windows-msvc.zip' --dir "$linear_tmp" --clobber \
     && unzip -o -q "$linear_tmp"/*.zip -d "$linear_tmp" \
     && mkdir -p "$HOME/.cargo/bin" \
     && cp "$(find "$linear_tmp" -name linear-cli.exe | head -1)" "$HOME/.cargo/bin/linear-cli.exe"; then
    linear_cli_installed=true
  else
    echo "  ⚠️  Prebuilt download failed — falling back to a cargo source build."
  fi
  rm -rf "$linear_tmp"
fi

if [ "$linear_cli_installed" = false ]; then
  # 1. Rust toolchain (provides cargo). macOS installs it via Homebrew; on Windows/other we don't
  #    auto-run winget from Git Bash (see note above), so instruct via rustup and stop.
  if ! command -v cargo >/dev/null 2>&1; then
    if [ "$CLAUDE_OS" = macos ]; then
      echo "  Rust toolchain not found — installing via Homebrew (brew install rust)..."
      brew install rust
    else
      echo "  ❌ cargo not found. Install Rust via rustup — https://rustup.rs" >&2
      [ "$CLAUDE_OS" = windows ] && echo "       on Windows (PowerShell): winget install -e --id Rustlang.Rustup" >&2
      echo "     then re-run this script." >&2
      exit 1
    fi
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  ❌ cargo still not found after install. Install Rust manually (https://rustup.rs) and re-run." >&2
    exit 1
  fi

  # 2. cargo-binstall — pulls a prebuilt linear-cli binary (via QuickInstall) instead of
  #    a slow source compile. Homebrew-only: on non-mac, compiling binstall from source just to avoid
  #    compiling linear-cli is a net loss, so step 3's `cargo install` fallback handles those platforms.
  if ! command -v cargo-binstall >/dev/null 2>&1 && [ "$CLAUDE_OS" = macos ]; then
    echo "  Installing cargo-binstall..."
    brew install cargo-binstall 2>/dev/null || cargo install cargo-binstall
  fi

  # 3. linear-cli — binstall (fast, prebuilt) with a source-compile fallback.
  if command -v cargo-binstall >/dev/null 2>&1; then
    cargo binstall -y linear-cli || cargo install linear-cli
  else
    cargo install linear-cli
  fi
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
#    status; if not logged in and a TTY is available, run the interactive browser OAuth
#    now; otherwise warn (a non-interactive run would hang on the prompt). LINEAR_API_KEY
#    in the env also satisfies it.
if linear-cli auth status >/dev/null 2>&1; then
  echo "  ✓ linear-cli already authenticated"
elif [ -n "${LINEAR_API_KEY:-}" ]; then
  echo "  ✓ linear-cli will use LINEAR_API_KEY from the environment"
elif [ -t 0 ] && [ -t 1 ]; then
  echo ""
  echo "  linear-cli is not authenticated — launching browser OAuth..."
  if ! linear-cli auth oauth; then
    echo ""
    echo "  ⚠️  Authentication did not complete. Run it yourself before using Linear skills:"
    echo "        linear-cli auth oauth      # or: export LINEAR_API_KEY=<key>"
    echo "        linear-cli auth status     # confirm"
  fi
else
  echo ""
  echo "  ⚠️  linear-cli is not authenticated and no TTY is available for interactive OAuth. Authenticate before using Linear skills:"
  echo "        linear-cli auth oauth      # or: export LINEAR_API_KEY=<key>"
  echo "        linear-cli auth status     # confirm"
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

# Reconcile this repo's local devDependencies (markdownlint-cli2, typescript) against the committed
# lockfile before the lint step below relies on them — a fresh clone has no node_modules, and a git
# pull can bump the lockfile out from under a stale install. --frozen-lockfile keeps it deterministic.
echo ""
echo "Installing local project dependencies..."
pnpm install --frozen-lockfile

lint_and_fix "pnpm check-markdown"

echo ""
echo ""
echo "Installed skills for: ${AI_AGENT_LIST[*]}"
echo ""
echo "Done! You must restart Claude (or vscode) for the changes to take effect."

