#!/usr/bin/env bash
# Tests for hooks/git-permissions.sh
#
# Exercises the hook through its real stdin contract (a JSON tool payload) and asserts the
# exit code: 0 = allowed, 2 = blocked. Every "must stay allowed" case below is a form some
# skill or script actually drives, so a regression here breaks live automation rather than
# merely over-blocking.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-permissions.sh"
pass=0
fail=0

run_hook() {
  printf '%s' "$1" | jq -Rs '{tool_input: {command: .}}' | "$HOOK" >/dev/null 2>&1
  echo $?
}

assert_blocked() {
  local cmd="$1" desc="${2:-$1}" rc
  rc=$(run_hook "$cmd")
  if [ "$rc" = "2" ]; then
    echo "  ok     BLOCK  $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL   expected BLOCK (2), got $rc: $desc"
    fail=$((fail + 1))
  fi
}

assert_allowed() {
  local cmd="$1" desc="${2:-$1}" rc
  rc=$(run_hook "$cmd")
  if [ "$rc" = "0" ]; then
    echo "  ok     ALLOW  $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL   expected ALLOW (0), got $rc: $desc"
    fail=$((fail + 1))
  fi
}

echo "== 1. non-git commands are untouched"
assert_allowed "ls -la"
assert_allowed "rm -rf node_modules"
assert_allowed "echo 'git reset --hard'" "a git string inside a non-git command"

echo "== 2. safe read-only and staging forms stay allowed"
assert_allowed "git status"
assert_allowed "git log --oneline -5"
assert_allowed "git diff HEAD"
assert_allowed "git show HEAD:path/to/file.ts"
assert_allowed "git add ."
assert_allowed "git commit -m 'msg'"
assert_allowed "git branch"
assert_allowed "git reflog"
assert_allowed "git stash list"
assert_allowed "git stash show"
assert_allowed "git restore --staged file.ts"
assert_allowed "git push"
assert_allowed "git pull"
assert_allowed "git fetch --all"
assert_allowed "git reset --soft HEAD~1" "reset --soft keeps index and tree"

echo "== 3. forms three skills recommend must stay allowed"
assert_allowed "git checkout --detach" "/full, /auto-prep, /start all advise this"
assert_allowed "git checkout -b feature/x"
assert_allowed "git clean -n" "sanctioned preview"
assert_allowed "git clean --dry-run" "previously OVER-blocked by the -[fd] substring match"

echo "== 4. long-form force (was caught before, must stay caught)"
assert_blocked "git push --force"
assert_blocked "git push --force-with-lease"
assert_blocked "git worktree remove --force wt"

echo "== 5. force bypasses that previously ran unguarded"
assert_blocked "git push -f origin main" "short -f"
assert_blocked "git push -fu origin main" "bundled short flags"
assert_blocked "git push origin +main" "force-push by refspec, no flag at all"
assert_blocked "git branch -f main abc123" "short -f on branch"
assert_blocked "git branch --force main abc123" "allowlist used to short-circuit past the force check"
assert_blocked "git branch -D feature/x" "force-delete a branch"
assert_blocked "git branch -M newname" "force-rename over an existing branch"

echo "== 6. reset modes: only --soft survives"
assert_blocked "git reset --hard"
assert_blocked "git reset --mixed"
assert_blocked "git reset" "bare reset IS --mixed"
assert_blocked "git reset HEAD~1" "same operation, previously allowed"
assert_blocked "git reset --keep" "touches the working tree"
assert_blocked "git reset --merge"

echo "== 7. checkout: the bare file form people actually type"
assert_blocked "git checkout -- foo.ts" "the only form caught before"
assert_blocked "git checkout foo.ts" "bare path — destroys the file, previously allowed"
assert_blocked "git checkout main" "moves the SHARED working tree"
assert_blocked "git checkout main -- ."

echo "== 7b. switch mirrors checkout (else it is a one-word detour)"
assert_allowed "git switch --detach"
assert_allowed "git switch -c feature/x"
assert_blocked "git switch main" "moves the SHARED working tree"
assert_blocked "git switch -- foo.ts"

echo "== 8. restore and stash"
assert_blocked "git restore foo.ts"
assert_blocked "git restore ."
assert_blocked "git stash"
assert_blocked "git stash push -m wip"
assert_blocked "git stash pop"
assert_blocked "git stash drop"
assert_blocked "git stash clear"

echo "== 9. clean"
assert_blocked "git clean -f"
assert_blocked "git clean -fd"
assert_blocked "git clean -fdx"

echo "== 10. ^git anchoring bypasses (every rule inspected only the first word)"
assert_blocked "git status && git reset --hard" "allowlisted leader hid the destructive tail"
assert_blocked "git log; git clean -fd" "semicolon compound"
assert_blocked " git reset --hard" "one leading space defeated the ^git anchor"
assert_blocked "git diff | git apply --force" "pipe segment"
assert_blocked "$(printf 'git status\ngit reset --hard')" "second line of a multi-line command"

echo "== 11. the hook fails CLOSED on an unparseable payload"
rc_bad=$(printf 'not json at all' | "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$rc_bad" = "2" ]; then
  echo "  ok     BLOCK  non-JSON stdin (previously exited 0, allowing every git command)"
  pass=$((pass + 1))
else
  echo "  FAIL   expected BLOCK (2) on non-JSON stdin, got $rc_bad"
  fail=$((fail + 1))
fi

echo
echo "$pass passed / $fail failed"
[ "$fail" -eq 0 ]
