#!/usr/bin/env bash
# sync-main.sh — put ~/.claude on the latest origin/main and run update.sh, discarding nothing.
#
# For a machine whose checkout drifted onto a branch (a /keeper proposal branch, a PR checked out for review) or picked up
# uncommitted edits. Run it OUTSIDE Claude Code — Git Bash on Windows, Terminal on macOS — because inside a session the
# git-permissions hook refuses the branch switch (standards/git.md § What the hook enforces), and that refusal is right:
# moving the checkout is a deliberate act, and this script does it on the user's own command, once, with everything kept.
#
#   curl -fsSL https://raw.githubusercontent.com/alienfast/claude/main/scripts/sync-main.sh | bash
#
# Nothing is discarded:
#   - uncommitted edits are committed onto the branch they were made on (a detached HEAD gets a saved/<stamp> branch first)
#   - commits on local main that origin/main lacks are kept under backup/main-<stamp> before main is reset to origin/main
#   - no push, no force, no stash, no reset, no branch deletion; an in-progress merge or rebase stops the run untouched
# Then update.sh installs the platform shims and tools, and two quick suites prove the Windows fixes are live.
#
# Flags: --no-update   sync the checkout only (what sync-main.test.sh drives)
# Env:   CLAUDE_DIR    the checkout, default ~/.claude (the suite points it at a throwaway clone)
set -uo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
NO_UPDATE=0
for a in "$@"; do
  case "$a" in
    --no-update) NO_UPDATE=1 ;;
    *) echo "usage: sync-main.sh [--no-update]" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
# A double-clicked .sh on Windows closes its window the moment the script ends; hold it open when a person is watching.
pause() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) [ -t 1 ] && [ -e /dev/tty ] && read -r -p "Press Enter to close this window" < /dev/tty ;;
  esac
  return 0
}
die() { printf 'ERROR: %s\n' "$*" >&2; pause; exit 1; }
G() { git -C "$CLAUDE_DIR" "$@"; }

stamp=$(date +%Y%m%d-%H%M%S)
[ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR does not exist"
G rev-parse --git-dir >/dev/null 2>&1 || die "$CLAUDE_DIR is not a git checkout"
gitdir=$(G rev-parse --absolute-git-dir)
for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  [ -e "$gitdir/$op" ] && die "a merge or rebase is in progress in $CLAUDE_DIR — finish or abort it first, then re-run"
done

say "== $CLAUDE_DIR"
before=$(G branch --show-current)
[ -n "$before" ] && say "on branch: $before" || say "on a detached HEAD at $(G rev-parse --short HEAD)"

say "fetching origin..."
G fetch -q origin || die "git fetch failed — check the network (and GitHub sign-in), then re-run"
G rev-parse --verify -q origin/main >/dev/null || die "origin/main does not exist after the fetch"

# 1. Uncommitted edits stay on the branch they were made on. Unsigned on purpose: a signing setup that is missing or
#    expired must not turn a save into a failure, and this is a local WIP commit that never leaves the machine.
saved="nothing to save (working tree was clean)"
if [ -n "$(G status --porcelain)" ]; then
  if [ -z "$before" ]; then
    before="saved/$stamp"
    G checkout -q -b "$before" || die "could not create $before to hold the uncommitted edits"
  fi
  G add -A || die "git add failed"
  G -c commit.gpgsign=false commit -q -m "wip: local changes saved by sync-main.sh before returning to main ($stamp)" \
    || die "could not commit the local edits on $before (is user.name / user.email configured?)"
  saved="committed the uncommitted edits on $before"
  say "$saved"
else
  say "working tree clean"
fi
# A clean detached HEAD can still carry commits nothing else points at; give them a branch before HEAD moves.
if [ -z "$before" ] && [ -n "$(G rev-list origin/main..HEAD 2>/dev/null | head -1)" ]; then
  G branch "saved/$stamp" HEAD || die "could not create saved/$stamp"
  saved="kept the detached commits under saved/$stamp"
  say "$saved"
fi

# 2. Local main is reset to origin/main below; anything only it has is kept under a backup branch first. A non-keeper
#    machine can never push such commits (main is protected) — /keeper proposes them as a PR if they have global value.
backup="none needed"
if G rev-parse --verify -q main >/dev/null && [ -n "$(G rev-list origin/main..main | head -1)" ]; then
  n=$(G rev-list --count origin/main..main)
  G branch "backup/main-$stamp" main || die "could not create backup/main-$stamp"
  backup="backup/main-$stamp holds $n commit(s) that were only on local main"
  say "$backup"
fi

# 3. The switch. -B rather than a plain checkout so an already-existing main lands exactly at origin/main whatever it held
#    (its old tip is on the backup branch when that mattered); the tree is clean by now, so nothing can be carried or lost.
G checkout -q -B main origin/main || die "could not check out main at origin/main"
[ "$(G branch --show-current)" = main ] || die "expected to be on main afterwards"
[ "$(G rev-parse HEAD)" = "$(G rev-parse origin/main)" ] || die "main did not land on origin/main"
top=$(G log --oneline -1)
say "main is now at: $top"

if [ "$NO_UPDATE" = 1 ]; then
  say "== done (--no-update): was on ${before:-a detached HEAD}; $saved; backup: $backup"
  pause; exit 0
fi

# 4. Tools and shims. update.sh is non-fatal here on purpose: its own output says what it could not do, and the checks
#    below report what actually works now.
say "== running update.sh (a few minutes; it may open a browser to sign in to GitHub or Linear)"
bash "$CLAUDE_DIR/update.sh" || say "update.sh exited $? — see its output above; the checks below show what works now"

# 5. Proof. ~/bin is where update.sh puts the Windows shims and the shell that started this script may not have it yet.
export PATH="$HOME/bin:$PATH"
mkdir -p "$CLAUDE_DIR/tmp"
fails=0
check() { # check <label> <ok:0|1> <detail>
  if [ "$2" = 0 ]; then say "ok    $1 — $3"; else say "FAIL  $1 — $3"; fails=$((fails + 1)); fi
}
if command -v jq >/dev/null 2>&1; then
  if printf '["x"]' | jq -r '.[]' | od -c | grep -q '\r'; then check "jq" 1 "still emits CRLF ($(command -v jq))"
  else check "jq" 0 "LF output from $(command -v jq)"; fi
else check "jq" 1 "not found on PATH"; fi
if command -v python3 >/dev/null 2>&1; then check "python3" 0 "$(command -v python3)"; else check "python3" 1 "not found on PATH"; fi
for suite in epic-graph fleet-forecast; do
  log="$CLAUDE_DIR/tmp/sync-main-$suite.log"
  if bash "$CLAUDE_DIR/scripts/$suite.test.sh" >| "$log" 2>&1; then check "$suite suite" 0 "$(grep -v '^[[:space:]]*$' "$log" | tail -1)"
  else check "$suite suite" 1 "exit $? — see $log"; fi
done

say ""
say "== summary"
say "was on:   ${before:-a detached HEAD}"
say "saved:    $saved"
say "backup:   $backup"
say "main:     $top"
say "checks:   $((4 - fails)) ok, $fails failed"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) say ""; say "Now quit Claude Code completely and reopen it, so its shell picks up the tools in ~/bin." ;;
esac
pause
[ "$fails" -eq 0 ]
