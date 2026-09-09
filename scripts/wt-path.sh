#!/bin/bash
# wt-path.sh — the one path-normalization boundary for the worktree scripts.
#
# Why this exists: on Git Bash / MSYS, a path segment that BEGINS WITH `~` is destroyed when the MSYS runtime
# converts an argument for a Windows-native binary. Measured 2026-09-05 on a checkout at
# `C:\Users\rdami\~projects\studio`:
#
#   git -C /c/Users/rdami/.claude          rev-parse --show-toplevel   -> C:/Users/rdami/.claude        (fine)
#   git -C /c/Users/rdami/~projects/studio rev-parse --show-toplevel   -> fatal: cannot change to '...'
#   git -C C:/Users/rdami/~projects/studio rev-parse --show-toplevel   -> C:/Users/rdami/~projects/studio
#
# So the failure is NOT "MSYS paths break" — an MSYS path with no `~` segment converts correctly. It is the
# tilde specifically, and it is silent: `cd`/`pwd` inside the shell are MSYS-native and handle it perfectly,
# so the bad value only detonates once it crosses into git.exe, node, or pnpm. `pnpm install` given the MSYS
# form failed with `ENOENT: lstat 'C:\c\Users'` — the drive letter prepended to an unconverted MSYS path.
#
# The consequence that made this worth centralizing: `start-wt-create.sh` derived WT_ABS with `cd && pwd`
# (MSYS form) and every downstream consumer inherited it, so every `git -C "$WT_ABS"` in the worktree family
# failed one layer down — silently, because the callers treated the failure as "nothing to report". A safety
# artifact that fails to exist is worse than one that fails loudly, which is why the fix belongs at the
# boundary rather than at each call site.
#
# The canonical form is what `cygpath -m` produces (`C:/Users/...`, forward slashes): Windows-native binaries
# accept it, MSYS never tilde-expands it, `cd`/`[ -d ]` in Git Bash accept it, and it is what git itself
# already returns from `rev-parse --path-format=absolute` — a convention several of these scripts had already
# reached for piecemeal. Off Windows there is no `cygpath`, so `wt_path_canon` reduces to plain `pwd -P`: unchanged for
# the callers that already used it, while the ones that used a logical `cd && pwd` now emit the physical path — a difference
# only under a symlinked component, which macOS mktemp fixtures (`/var` → `/private/var`) hit on every test run.
#
# Usage — source it, do not execute:
#   . "$(dirname "$0")/wt-path.sh"       # or "$HOME/.claude/scripts/wt-path.sh"
#   abs=$(wt_path_canon  "$some_dir")    # existing directory -> canonical native absolute path
#   p=$(  wt_path_native "$some_string") # any path string    -> native form (no existence requirement)

if [ -z "${WT_PATH_LIB_LOADED:-}" ]; then
  WT_PATH_LIB_LOADED=1

  # Probed once at source time rather than per call: `command -v` is cheap but these helpers can run inside
  # per-file loops.
  if command -v cygpath >/dev/null 2>&1; then WT_PATH_HAS_CYGPATH=1; else WT_PATH_HAS_CYGPATH=0; fi

  # Convert a path STRING to native form. Does not require the path to exist, so it is safe on a path being
  # composed (a worktree that has not been created yet) or on git output that is already native — `cygpath -m`
  # is idempotent, so passing an already-converted path back through is a no-op rather than a corruption.
  wt_path_native() {
    _wtp=$1
    [ -n "$_wtp" ] || return 1
    if [ "$WT_PATH_HAS_CYGPATH" = 1 ]; then
      _wtp=$(cygpath -m -- "$_wtp" 2>/dev/null) || return 1
      [ -n "$_wtp" ] || return 1
    fi
    # Strip a trailing slash so two spellings of one directory compare equal — but never turn `/` into the
    # empty string or `C:/` into a bare drive letter, both of which stop naming a directory at all.
    case "$_wtp" in
      /) ;;
      ?:/) ;;
      */) _wtp=${_wtp%/} ;;
    esac
    printf '%s\n' "$_wtp"
  }

  # Canonicalize an EXISTING directory: resolve symlinks physically (the `pwd -P` the callers already relied
  # on, so a symlinked component cannot make one directory compare unequal to itself), then convert to native
  # form. Returns non-zero when the argument is empty or not a directory — callers turn that into their own
  # `fail`, so a bad path stops the run instead of silently measuring the wrong tree.
  wt_path_canon() {
    _wtd=$1
    [ -n "$_wtd" ] && [ -d "$_wtd" ] || return 1
    _wtd=$(cd "$_wtd" 2>/dev/null && pwd -P) || return 1
    wt_path_native "$_wtd"
  }
fi
