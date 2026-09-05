#!/bin/bash
# wt-path.test.sh — tests for wt-path.sh.
#
# The Windows-specific assertions are the point of the file, so they run only where `cygpath` exists and are
# reported as skipped elsewhere; the platform-independent contract (canonicalization, trailing slash, failure
# on a non-directory) is asserted everywhere. A tilde-segment fixture is created for real rather than asserted
# as a string, because the bug this library exists for is invisible to string comparison — it only appears
# when the path crosses into a Windows-native binary.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/wt-path.sh"

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; }
sk()   { skip=$((skip+1)); printf '  skip %s (%s)\n' "$1" "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

TMP=$(mktemp -d) || { echo "cannot mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

echo "wt-path.sh"

# --- platform-independent contract -------------------------------------------------------------------

mkdir -p "$TMP/plain/sub"
got=$(wt_path_canon "$TMP/plain/sub") || got="<returned non-zero>"
case "$got" in
  */plain/sub) ok "canon resolves an existing directory" ;;
  *)           no "canon resolves an existing directory" "*/plain/sub" "$got" ;;
esac

# A trailing slash must not produce a second spelling of the same directory, or equality tests between a
# stamped path and a freshly derived one compare unequal for a purely cosmetic reason.
a=$(wt_path_canon "$TMP/plain/sub")
b=$(wt_path_canon "$TMP/plain/sub/")
eq "canon is trailing-slash insensitive" "$a" "$b"

# Idempotency matters because callers pass already-native git output back through the helper.
eq "native is idempotent" "$a" "$(wt_path_native "$a")"

if wt_path_canon "$TMP/does-not-exist" >/dev/null 2>&1; then
  no "canon fails on a missing directory" "non-zero exit" "exit 0"
else
  ok "canon fails on a missing directory"
fi

if wt_path_canon "" >/dev/null 2>&1; then
  no "canon fails on an empty argument" "non-zero exit" "exit 0"
else
  ok "canon fails on an empty argument"
fi

# A file is not a directory: canon must refuse it rather than silently returning its parent.
: > "$TMP/afile"
if wt_path_canon "$TMP/afile" >/dev/null 2>&1; then
  no "canon fails on a regular file" "non-zero exit" "exit 0"
else
  ok "canon fails on a regular file"
fi

# `/` is deliberately asserted per-platform rather than as a universal. Off Windows it is the filesystem root
# and must survive untouched; under MSYS the shell root genuinely IS the Git installation directory, so
# `cygpath -m /` returning `C:/Program Files/Git` is correct rather than a bug. No worktree path is ever `/`
# — this only pins that the trailing-slash trimming never truncates a root into something that names nothing.
got=$(wt_path_native "/")
if [ "${WT_PATH_HAS_CYGPATH:-0}" = 1 ]; then
  case "$got" in
    [A-Za-z]:/*) ok "native maps the MSYS root to an absolute Windows path" ;;
    *)           no "native maps the MSYS root to an absolute Windows path" "<drive>:/..." "$got" ;;
  esac
else
  eq "native preserves root /" "/" "$got"
fi

# --- Windows / MSYS specifics ------------------------------------------------------------------------

if [ "${WT_PATH_HAS_CYGPATH:-0}" != 1 ]; then
  sk "native converts MSYS form to Windows form" "no cygpath"
  sk "tilde-segment path survives a Windows-native binary" "no cygpath"
  sk "native preserves a drive root" "no cygpath"
else
  got=$(wt_path_native "/c/Users")
  case "$got" in
    [A-Za-z]:/Users) ok "native converts MSYS form to Windows form" ;;
    *)               no "native converts MSYS form to Windows form" "<drive>:/Users" "$got" ;;
  esac

  got=$(wt_path_native "C:/") ; eq "native preserves a drive root" "C:/" "$got"

  # The regression this library exists for. A directory whose name begins with `~` is built for real, a git
  # repo is initialized inside it, and the MSYS and native spellings are each handed to git.exe. The MSYS
  # spelling is expected to FAIL — that is the bug — while the helper's output must work.
  tilde_dir="$TMP/~fixture/repo"
  mkdir -p "$tilde_dir"
  native=$(wt_path_canon "$tilde_dir")
  msys=$(cd "$tilde_dir" && pwd -P)
  # Init through the NATIVE path deliberately: `git init` on the MSYS spelling is itself defeated by the bug
  # under test, so building the fixture the naive way makes this case skip exactly where it should assert.
  if git -C "$native" init -q 2>/dev/null; then
    if git -C "$native" rev-parse --show-toplevel >/dev/null 2>&1; then
      ok "tilde-segment path survives a Windows-native binary"
    else
      no "tilde-segment path survives a Windows-native binary" "git accepts $native" "git rejected it"
    fi
    # Documents the underlying platform behaviour. If this ever starts passing, MSYS fixed the tilde handling
    # and the note in wt-path.sh's docblock should be revisited — it is not a reason to fail the suite.
    if git -C "$msys" rev-parse --show-toplevel >/dev/null 2>&1; then
      printf '  note the MSYS spelling now works too (%s) — platform behaviour changed\n' "$msys"
    else
      printf '  note confirmed: the MSYS spelling still fails (%s)\n' "$msys"
    fi
  else
    sk "tilde-segment path survives a Windows-native binary" "git init failed in fixture"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
