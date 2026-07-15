#!/bin/bash
# wt-baseline.sh — capture and diff the MAIN checkout's dirty-state baseline for worktree (`wt`) sessions.
#
# Why this exists: /start-family skills (/start, /quality-review) arm a main-checkout contamination check in
# worktree mode — EnterWorktree's isolation registration is best-effort, not a guarantee (BF-380: parallel
# delegates wrote into the main checkout, unblocked, while reporting success) — so after every delegation the
# orchestrator diffs the main checkout's current dirty state against a session-start baseline. That machinery
# was previously inlined ~10× across skill markdown as bash the model re-emitted verbatim each session;
# transcription drift was itself a failure mode. This script is the single tested implementation. The skills
# keep only the policy (when to run, what a verdict means, STOP-and-report on contamination).
#
# Usage:
#   wt-baseline.sh capture <wt-abs-path> <issue-id-lower|no-issue>
#   wt-baseline.sh diff    <wt-abs-path> <issue-id-lower|no-issue>
#
# Files — anchored to the worktree, never cwd-relative (callers run as separate Bash tool calls with no
# shared cwd, and some run from worktree subdirectories):
#   baseline: <wt-abs>/tmp/main-dirty-baseline-<token>.txt   (capture writes; diff reads)
#   current:  <wt-abs>/tmp/main-dirty-now-<token>.txt        (diff overwrites each run)
#
# stdout contract — the FIRST line is the verdict; orchestrators branch on it:
#   capture → CAPTURED <baseline-file>       exit 0
#   diff    → CLEAN                          exit 0   (no main-checkout change since baseline)
#           → CONTAMINATED                   exit 2   (then one classified line per path:)
#               NEW <path>                     clean at baseline, dirty now
#               CHANGED-IN-PLACE <path>        dirty at baseline, content hash changed since
#               VANISHED <path>                dirty at baseline, gone now — the most dangerous direction:
#                                              a delegate may have overwritten another session's
#                                              uncommitted work with HEAD content
#   either  → FAILED: <reason>               exit 1
#
# FAIL CLOSED: exit 1 means the measurement itself could not be made — callers MUST treat it like
# contamination (STOP and surface), never like clean. Empty stdout is never success; both a broken redirect
# and a broken `comm` print only to stderr, indistinguishable from "clean" if only stdout is checked —
# always branch on the verdict line.
#
# Baseline format: one content-hash line per dirty path — `<sha256>  <path>`, or `ABSENT  <path>` for a
# path that is gone/not a regular file — never a bare path list. A bare path SET would miss the dominant
# real-world case: a stray delegate write landing on a path the main checkout already had dirty (an
# engineer's WIP file); the path is a baseline member either way, so set-membership sees nothing, while a
# content hash makes it a different line the diff still catches. LC_ALL=C sort on BOTH sides — `comm`
# requires identical collation, and BSD `comm` silently emits false "new" lines under mismatched locales
# (reproduced with `src/A-b.ts` vs `src/a-b.ts`).
#
# Concurrency limitation: capture always overwrites the baseline file for its token unconditionally (loud
# WARN on stderr when clobbering, but no lock and no session stamp) — two live sessions sharing the same
# issue token is unsupported, and the second capture silently compromises the first session's detection.

set -uo pipefail

fail() {
  echo "FAILED: $1"
  echo "FAILED: $1" >&2
  exit 1
}

[ $# -eq 3 ] || fail "usage: wt-baseline.sh capture|diff <wt-abs-path> <issue-id-lower|no-issue>"
mode=$1
wt_arg=$2
token=$3

case "$mode" in
  capture|diff) ;;
  *) fail "unknown mode '$mode' (expected capture or diff)" ;;
esac

case "$token" in
  no-issue) ;;
  *)
    if ! [[ "$token" =~ ^[a-z]+-[0-9]+$ ]]; then
      fail "token '$token' is not a lowercased issue id (^[a-z]+-[0-9]+$) or 'no-issue'"
    fi
    ;;
esac

# Canonicalize before comparing — a symlinked path component would otherwise make identical directories
# compare unequal (or a registered worktree look wrong).
[ -n "$wt_arg" ] && [ -d "$wt_arg" ] || fail "wt-abs path '$wt_arg' unset or not a directory"
WT_ABS=$(cd "$wt_arg" && pwd -P) || fail "could not canonicalize '$wt_arg'"

# `git -C ""` is a documented no-op (leaves cwd unchanged, exits 0), so an empty/wrong path would silently
# measure the WRONG tree instead of failing loudly — these guards are the only thing standing between a
# broken argument and a fabricated clean bill of health.
# Split into probe + dirname so a failed `git rev-parse` (e.g. WT_ABS is not a repository) is caught by its
# OWN exit status — `dirname` always succeeds (on empty input it prints '.'), so testing `dirname`'s exit
# instead of git's would silently fall through to measuring the invoking cwd's repo.
common_dir=$(git -C "$WT_ABS" rev-parse --path-format=absolute --git-common-dir) \
  || fail "could not derive git common dir from '$WT_ABS' (not a repository?)"
[ -n "$common_dir" ] || fail "git common dir came back empty for '$WT_ABS'"
MAIN_CHECKOUT=$(dirname "$common_dir")
[ -n "$MAIN_CHECKOUT" ] && [ -d "$MAIN_CHECKOUT" ] || fail "MAIN_CHECKOUT '$MAIN_CHECKOUT' unset or not a directory"
MAIN_CHECKOUT=$(cd "$MAIN_CHECKOUT" && pwd -P) || fail "could not canonicalize '$MAIN_CHECKOUT'"
[ "$WT_ABS" != "$MAIN_CHECKOUT" ] || fail "WT_ABS == MAIN_CHECKOUT ('$WT_ABS') — not a worktree with a separate main checkout"

if command -v shasum >/dev/null 2>&1; then HASH_CMD=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then HASH_CMD=(sha256sum)
else fail "no shasum or sha256sum on PATH"; fi

BASELINE_FILE="$WT_ABS/tmp/main-dirty-baseline-${token}.txt"
MAIN_NOW="$WT_ABS/tmp/main-dirty-now-${token}.txt"

# $1 = checkout root. Prints "<sha256>  <path>" per dirty path, or "ABSENT  <path>" for one that's gone.
# -z: NUL-delimited, no C-quoting/octal-escaping. --no-renames: keeps every record to a single "XY path"
# field (a rename record's second, unprefixed old-path field would otherwise survive the fixed 3-char strip
# unstripped) — git reports a rename as separate delete + add, which this loop hashes/ABSENTs individually.
# -- ':!.claude/worktrees' ':!.claude/merge-queue': excludes the worktrees directory (git doesn't recurse
# into it, but the untracked-directory entry would still be a map line, so a concurrent /start wt session
# creating/removing its own worktree would falsely appear as a change) and the merge-queue marker directory
# (merge-queue.sh writes markers there with a bare mkdir -p and no self-ignoring .gitignore, unlike
# .claude/worktree-identity/ which self-ignores — a deferred /finish merge or the launchd drainer touching
# a marker would otherwise falsely appear too, in either direction). A hashing failure (unreadable file)
# fails closed rather than emitting an empty-hash line, which would silently degrade the content-hash map
# back to bare path membership — exactly the case hashing exists to catch. Records are read NUL-delimited
# directly (no `tr '\0' '\n'` split) because a path containing a literal newline would otherwise be sliced
# into unrelated garbage lines; such a path fails the whole capture/diff closed instead.
main_dirty_map() {
  git -C "$1" status --porcelain -z --untracked-files=all --no-renames \
    -- ':!.claude/worktrees' ':!.claude/merge-queue' \
    | while IFS= read -r -d '' rec; do
        p="${rec:3}"
        case "$p" in
          *$'\n'*) echo "FAILED: path contains a newline (unsupported): ${p%%$'\n'*}..." >&2; exit 1 ;;
        esac
        if [ -f "$1/$p" ]; then
          h="$("${HASH_CMD[@]}" "$1/$p" | cut -d' ' -f1)"
          [ -n "$h" ] || { echo "FAILED: empty hash for $p" >&2; exit 1; }
          printf '%s  %s\n' "$h" "$p"
        else printf 'ABSENT  %s\n' "$p"; fi
      done | LC_ALL=C sort
}

mkdir -p "$WT_ABS/tmp" || fail "could not create $WT_ABS/tmp"

if [ "$mode" = "capture" ]; then
  # Same-token concurrent sessions are unsupported (no lock, no session stamp) — capture always overwrites
  # unconditionally, so a second live session on the same issue silently compromises the first's
  # contamination detection. Loudest we can be without adding one: a stderr-only WARN naming the clobber.
  if [ -e "$BASELINE_FILE" ]; then
    old_mtime=$(stat -f '%Sm' "$BASELINE_FILE" 2>/dev/null || stat -c '%y' "$BASELINE_FILE" 2>/dev/null || echo "unknown")
    echo "WARN: overwriting existing baseline for '$token' (mtime $old_mtime) — if another live session owns this token, its contamination detection is now compromised (two live sessions on one issue is unsupported)." >&2
  fi
  if ! main_dirty_map "$MAIN_CHECKOUT" > "$BASELINE_FILE"; then
    rm -f "$BASELINE_FILE"
    fail "baseline capture errored for $MAIN_CHECKOUT"
  fi
  [ -r "$BASELINE_FILE" ] || fail "baseline file $BASELINE_FILE missing/unreadable after capture"
  echo "CAPTURED $BASELINE_FILE"
  # Two separate lines, not one space-joined: a MAIN_CHECKOUT containing a space (a spaced macOS path)
  # would otherwise merge into dirty_paths= and parse wrong.
  echo "MAIN_CHECKOUT=$MAIN_CHECKOUT" >&2
  echo "dirty_paths=$(wc -l < "$BASELINE_FILE" | tr -d ' ')" >&2
  exit 0
fi

# --- diff ---
# Missing/unreadable baseline → fail closed: the delta cannot be computed, so this session's stray writes
# cannot be distinguished from whatever was already dirty.
[ -r "$BASELINE_FILE" ] || fail "baseline $BASELINE_FILE missing/unreadable — was capture run this session?"

if ! main_dirty_map "$MAIN_CHECKOUT" > "$MAIN_NOW"; then
  rm -f "$MAIN_NOW"
  fail "could not compute current dirty state for $MAIN_CHECKOUT"
fi
[ -r "$MAIN_NOW" ] || fail "current-state file $MAIN_NOW missing/unreadable after compute"

new_lines=$(LC_ALL=C comm -13 "$BASELINE_FILE" "$MAIN_NOW") || fail "comm -13 errored"
van_lines=$(LC_ALL=C comm -23 "$BASELINE_FILE" "$MAIN_NOW") || fail "comm -23 errored"

if [ -z "$new_lines" ] && [ -z "$van_lines" ]; then
  echo "CLEAN"
  exit 0
fi

# Reconcile by bare path before classifying: each line is `<sha256-or-ABSENT>  <path>` (two-space
# separated); ${line#*  } strips the prefix either way. A path appearing on BOTH sides did not vanish —
# it changed in place (same path, different hash: e.g. an already-dirty file a delegate appended to) and
# is reported exactly once.
new_paths=""
van_paths=""
while IFS= read -r line; do
  [ -n "$line" ] && new_paths+="${line#*  }"$'\n'
done <<<"$new_lines"
while IFS= read -r line; do
  [ -n "$line" ] && van_paths+="${line#*  }"$'\n'
done <<<"$van_lines"

echo "CONTAMINATED"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -Fxq -e "$p" <<<"$van_paths"; then
    echo "CHANGED-IN-PLACE $p"
  else
    echo "NEW $p"
  fi
done <<<"$new_paths"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -Fxq -e "$p" <<<"$new_paths" || echo "VANISHED $p"
done <<<"$van_paths"
exit 2
