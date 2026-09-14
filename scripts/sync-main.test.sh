#!/usr/bin/env bash
# Regression suite for sync-main.sh — the "get a drifted ~/.claude back onto origin/main without losing anything" script.
# Builds a bare origin plus a throwaway clone per case and drives the real script with --no-update against CLAUDE_DIR.
# GROW THIS SUITE, NEVER PRUNE IT: the script moves a person's checkout, and every way it could lose work belongs below.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/sync-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"

PASS=0 FAIL=0
ck() { # ck <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — no [$2] in $3"; fi
}

# fresh <name> → bare origin with two commits on main, and a clone of it at $CLONE
fresh() {
  ORIGIN="$WORK/$1-origin.git"; SEED="$WORK/$1-seed"; CLONE="$WORK/$1-clone"
  $G init -q --bare "$ORIGIN"
  $G init -q "$SEED" && (cd "$SEED" && echo one > a && $G add a && $G commit -q -m "c1" && echo two > b && $G add b && $G commit -q -m "c2" && $G push -q "$ORIGIN" main)
  $G clone -q "$ORIGIN" "$CLONE"
  (cd "$CLONE" && git config user.email t@t && git config user.name t)
}
# advance_origin <name> <msg> → one more commit on origin/main, pushed from the seed
advance_origin() { (cd "$SEED" && echo "$2" > "$2" && $G add "$2" && $G commit -q -m "$2" && $G push -q "$ORIGIN" main); }
run() { CLAUDE_DIR="$CLONE" bash "$SCRIPT" --no-update > "$WORK/out" 2>&1; echo $?; }
at_origin() { [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/main)" ] && echo yes || echo no; }
branch() { git -C "$CLONE" branch --show-current; }

echo "== 1. on a branch with uncommitted edits, origin ahead"
fresh one; advance_origin one c3
(cd "$CLONE" && git checkout -q -b proposal/x && echo edit >> a && echo new > untracked)
rc=$(run)
ck "  exit 0" 0 "$rc"
ck "  lands on main" main "$(branch)"
ck "  main is origin/main" yes "$(at_origin)"
ck "  edits committed on the branch" "wip: local changes saved by sync-main.sh" "$(git -C "$CLONE" log proposal/x -1 --format=%s | cut -c1-40)"
ck "  untracked file went into the save" 1 "$(git -C "$CLONE" show --stat proposal/x | grep -c untracked)"
ck "  tree clean afterwards" "" "$(git -C "$CLONE" status --porcelain)"
ck "  no backup branch (main had nothing)" "" "$(git -C "$CLONE" branch --list 'backup/*')"
ck_has "  reports the save" "committed the uncommitted edits on proposal/x" "$WORK/out"

echo "== 2. local main has commits origin lacks (the contributor-machine ahead-commit)"
fresh two
(cd "$CLONE" && echo mine > mine && $G add mine && $G commit -q -m "local-only")
local_tip=$(git -C "$CLONE" rev-parse main)
advance_origin two c3
rc=$(run)
ck "  exit 0" 0 "$rc"
ck "  main reset to origin/main" yes "$(at_origin)"
bk=$(git -C "$CLONE" branch --list 'backup/main-*' | tr -d ' *')
ck "  one backup branch" 1 "$(printf '%s\n' "$bk" | grep -c .)"
ck "  backup holds the old tip" "$local_tip" "$(git -C "$CLONE" rev-parse "$bk")"
ck_has "  reports the backup" "holds 1 commit(s) that were only on local main" "$WORK/out"

echo "== 3. detached HEAD carrying a commit, plus uncommitted edits"
fresh three
(cd "$CLONE" && git checkout -q --detach && echo d > d && $G add d && $G commit -q -m "detached-commit" && echo more >> a)
det_tip=$(git -C "$CLONE" rev-parse HEAD)
rc=$(run)
ck "  exit 0" 0 "$rc"
ck "  lands on main" main "$(branch)"
sv=$(git -C "$CLONE" branch --list 'saved/*' | tr -d ' *')
ck "  one saved branch" 1 "$(printf '%s\n' "$sv" | grep -c .)"
ck "  saved branch descends from the detached commit" "$det_tip" "$(git -C "$CLONE" rev-parse "$sv~1")"
ck "  its tip is the WIP save" "wip: local changes saved by sync-main.sh" "$(git -C "$CLONE" log "$sv" -1 --format=%s | cut -c1-40)"

echo "== 4. clean detached HEAD with an unreachable commit is still kept"
fresh four
(cd "$CLONE" && git checkout -q --detach && echo d > d && $G add d && $G commit -q -m "detached-commit")
det_tip=$(git -C "$CLONE" rev-parse HEAD)
rc=$(run)
ck "  exit 0" 0 "$rc"
sv=$(git -C "$CLONE" branch --list 'saved/*' | tr -d ' *')
ck "  saved branch points at it" "$det_tip" "$(git -C "$CLONE" rev-parse "$sv")"
ck_has "  reports it" "kept the detached commits under saved/" "$WORK/out"

echo "== 5. already on main, clean, merely behind"
fresh five; advance_origin five c3
rc=$(run)
ck "  exit 0" 0 "$rc"
ck "  fast-forwarded" yes "$(at_origin)"
ck "  no saved or backup branches" "" "$(git -C "$CLONE" branch --list 'saved/*' 'backup/*')"
ck_has "  says the tree was clean" "nothing to save (working tree was clean)" "$WORK/out"

echo "== 6. an in-progress merge stops the run untouched"
fresh six
(cd "$CLONE" && git checkout -q -b side && echo s > a && $G commit -q -am "side" && git checkout -q main && echo m > a && $G commit -q -am "main-side" && git merge -q side >/dev/null 2>&1 || true)
ck "  sanity: merge is in progress" yes "$([ -f "$CLONE/.git/MERGE_HEAD" ] && echo yes || echo no)"
rc=$(run)
ck "  exit 1" 1 "$rc"
ck_has "  names the reason" "a merge or rebase is in progress" "$WORK/out"
ck "  still on main mid-merge" main "$(branch)"
ck "  MERGE_HEAD untouched" yes "$([ -f "$CLONE/.git/MERGE_HEAD" ] && echo yes || echo no)"

echo "== 7. a failed fetch stops before anything moves"
fresh seven
(cd "$CLONE" && git checkout -q -b proposal/y && echo edit >> a && git remote set-url origin "$WORK/does-not-exist.git")
rc=$(run)
ck "  exit 1" 1 "$rc"
ck_has "  names the fetch" "git fetch failed" "$WORK/out"
ck "  branch unchanged" proposal/y "$(branch)"
ck "  edits still uncommitted" " M a" "$(git -C "$CLONE" status --porcelain)"

echo "== 8. argument and target validation"
fresh eight
ck "  unknown flag exits 2" 2 "$(CLAUDE_DIR="$CLONE" bash "$SCRIPT" --bogus >/dev/null 2>&1; echo $?)"
ck "  missing dir exits 1" 1 "$(CLAUDE_DIR="$WORK/nope" bash "$SCRIPT" --no-update >/dev/null 2>&1; echo $?)"
mkdir -p "$WORK/notgit"
ck "  non-repo exits 1" 1 "$(CLAUDE_DIR="$WORK/notgit" bash "$SCRIPT" --no-update >/dev/null 2>&1; echo $?)"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
