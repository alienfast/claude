#!/bin/bash
# pnpm.sh — converge a machine's pnpm onto the version the repos pin. Sourced by update.sh; lib/pnpm.test.sh covers it
# with stubbed installers.
#
# Inside a checkout the `packageManager` field already makes any pnpm >= 10 — and a Corepack shim — download and run the
# pinned version, so the pin holds in every repo whatever is installed. It does not hold for update.sh's own global
# commands (`pnpm add -g`, `pnpm dlx`), which run from whatever directory invoked the script — the home directory, for
# /update in a non-project session — where the machine's base pnpm runs as itself. Each old major then stops the run at
# a different line under set -e (measured 2026-09-18 against ~/.claude's lockfile and pin): 8 cannot read the lockfile
# (ERR_PNPM_LOCKFILE_BREAKING_CHANGE), 9 rejects `--allow-build` (Unknown option), and 10 keeps globals in $PNPM_HOME
# rather than $PNPM_HOME/bin, so `pnpm add -g` dies with "global bin directory … is not in PATH".
#
# The upgrade must go through the channel that installed pnpm. `pnpm self-update` refuses under Corepack
# (ERR_PNPM_CANT_SELF_UPDATE_IN_COREPACK) and, on an npm-installed pnpm, exits 0 having written a second copy under
# $PNPM_HOME that the npm one keeps shadowing on PATH — the mismatch survives with a success exit (measured).

# The version `packageManager: "pnpm@11.21.0+sha512.…"` pins, bare. sed rather than `node -p`: Git Bash converts a POSIX
# path only when it is a whole argument, not inside a JS expression.
pnpm_pin_from() {
  sed -n 's/.*"packageManager": *"pnpm@\([0-9][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

# The version that runs OUTSIDE any checkout — `cd /` has no package.json above it, so no pin masks it. Never fails:
# a `v=$(…)` assignment of a failing substitution would end the caller under set -e.
pnpm_base_version() {
  { (cd / && pnpm --version 2>/dev/null) || true; } | tr -d '\r'
}

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# Which installer owns the pnpm on PATH: corepack | brew | standalone | npm | unknown. Decided by the resolved path, not
# by content — pnpm's own bundle mentions Corepack, so a grep would misfile every npm and brew install. Git for Windows
# ships the Corepack and npm shims as small sh scripts rather than symlinks, so those two are recognized by content,
# size-gated to keep the bundle out. A version-manager shim (volta, mise, asdf, fnm) is deliberately `unknown`: the
# right command is the manager's own, and the caller prints every option rather than guessing one.
pnpm_channel() {
  local p real home size
  p=$(command -v pnpm 2>/dev/null) || { echo unknown; return 0; }
  real=$(readlink -f "$p" 2>/dev/null) || real=$p
  case "$real" in
    */Cellar/pnpm/*)       echo brew; return 0 ;;
    */corepack/*)          echo corepack; return 0 ;;
    */node_modules/pnpm/*) echo npm; return 0 ;;
  esac
  # Canonicalize both sides: a PNPM_HOME reached through a symlink (macOS /var → /private/var, a linked home) would
  # otherwise never prefix-match the resolved binary.
  if [ -n "${PNPM_HOME:-}" ]; then
    home=$(readlink -f "$PNPM_HOME" 2>/dev/null) || home=$PNPM_HOME
    case "$real" in "$home"/*) echo standalone; return 0 ;; esac
  fi
  size=$(wc -c < "$real" 2>/dev/null || echo 0)
  if [ "${size:-0}" -lt 4096 ]; then
    if grep -qi 'corepack' "$real" 2>/dev/null; then echo corepack; return 0; fi
    if grep -q 'node_modules/pnpm/' "$real" 2>/dev/null; then echo npm; return 0; fi
  fi
  echo unknown
}

# <channel> <version> — one attempt through that channel; the caller re-measures rather than trusting the exit code.
# Homebrew has no pinned install, so `brew upgrade` lands on its current formula — newer than the pin, which is fine:
# inside a checkout the pin still selects the version that runs.
pnpm_upgrade_via() {
  case "$1" in
    corepack)   corepack install -g "pnpm@$2" ;;
    brew)       brew upgrade pnpm ;;
    standalone) pnpm self-update "$2" ;;
    npm)        npm install -g "pnpm@$2" ;;
    *)          return 1 ;;
  esac
}

# <package.json carrying the pin> — upgrade when the base pnpm is older than the pin. Returns 1 only when pnpm is
# missing altogether (nothing after it in update.sh can run); a failed upgrade warns with every channel's command and
# returns 0, so the rest of the bootstrap — gh, linear-cli, the launchd agents — still runs.
converge_pnpm() {
  local pin cur channel
  pin=$(pnpm_pin_from "$1")
  cur=$(pnpm_base_version)
  echo ""
  echo "Checking pnpm against the pinned version..."
  if [ -z "$cur" ]; then
    echo "  ❌ pnpm is not on PATH. Install it (https://pnpm.io/installation) and re-run." >&2
    return 1
  fi
  if [ -z "$pin" ]; then
    echo "  ⚠️  no pnpm pin found in $1 — leaving pnpm $cur as is."
    return 0
  fi
  if ! version_lt "$cur" "$pin"; then
    echo "  ✓ pnpm $cur (pinned: $pin)"
    return 0
  fi
  channel=$(pnpm_channel)
  echo "  pnpm $cur is older than the pinned $pin — upgrading via $channel..."
  pnpm_upgrade_via "$channel" "$pin" || true
  hash -r
  cur=$(pnpm_base_version)
  if [ -n "$cur" ] && ! version_lt "$cur" "$pin"; then
    echo "  ✓ pnpm $cur (pinned: $pin)"
    return 0
  fi
  echo "  ⚠️  pnpm is still ${cur:-missing} (pinned: $pin). Upgrade it the way it was installed, then re-run:"
  echo "        corepack install -g pnpm@$pin      # Corepack shim (pnpm beside corepack in a Node install)"
  echo "        brew upgrade pnpm                    # Homebrew"
  echo "        pnpm self-update $pin               # standalone installer (get.pnpm.io)"
  echo "        npm install -g pnpm@$pin            # npm"
  return 0
}
