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

echo "== 10b. data is not code: heredoc bodies and quoted text"
assert_allowed "$(printf 'git commit -F - <<%sEOF%s\nfix: git worktree remove refuses, and --force is blocked\ngit reset --hard is mentioned here as prose\nEOF' "'" "'")" "heredoc body describing git commands"
assert_allowed "$(printf 'git commit -F - <<EOF\ngit clean -fd in the body\nEOF')" "unquoted heredoc delimiter"
assert_allowed "grep 'git reset --hard' skills/" "quoted search pattern"
assert_allowed "git commit -m 'revert the git checkout foo.ts change'" "quoted commit message"
# Executor forms are a DOCUMENTED bypass, not a regression: every rule requires the segment to start
# with `git`, and these start with `bash`/`eval`. standards/git.md § "The hook only sees the Bash tool's
# command string" states this is out of scope. The executor carve-out in the hook (which suppresses
# quote-stripping here) is defense-in-depth for if that ever widens — it does not block these today.
assert_allowed "bash -c 'git reset --hard'" "executor form — documented bypass, git not in command position"
assert_allowed "eval 'git clean -fd'" "executor form — documented bypass"

echo "== 10c. global options between git and the subcommand do not hide it"
# 2026-09-09: a runaway heredoc ran these three forms against ~/.claude and none was blocked —
# every rule anchored on `^git <subcommand>` and `-C "$REPO"` sat in between.
assert_blocked 'git -C "$REPO" reset -q --hard' "reset behind -C with a quoted path"
assert_blocked 'git -C "$REPO" clean -qfd' "clean -fd behind -C with a quoted path"
assert_blocked 'git -C "$REPO" branch -q -D feature' "branch -D behind -C with a quoted path"
assert_blocked 'git -C /abs/path reset --hard' "reset behind -C with a bare path"
assert_blocked 'git --git-dir=/x/.git --work-tree=/x reset --hard' "reset behind --git-dir= and --work-tree="
assert_blocked 'git -c core.pager=cat -C . checkout -f main' "checkout -f behind stacked -c and -C"
assert_blocked 'git --no-pager -C . push --force origin main' "push --force behind --no-pager and -C"
assert_blocked 'true; git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard' "the incident's ;-list"
assert_allowed 'git -C "$REPO" status' "status behind -C"
assert_allowed 'git -C /abs/path log --oneline -5' "log behind -C"
assert_allowed 'git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init' "test-fixture commit behind -c"
assert_allowed 'git -C "$REPO" reset -q --soft HEAD~1' "--soft reset behind -C stays allowed"
assert_allowed 'git -C "$REPO" branch --format="%(refname:short)"' "branch listing behind -C"
assert_allowed 'git -C /abs/path' "-C with no subcommand"

echo "== 11. the hook fails CLOSED on an unparseable payload"
rc_bad=$(printf 'not json at all' | "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$rc_bad" = "2" ]; then
  echo "  ok     BLOCK  non-JSON stdin (previously exited 0, allowing every git command)"
  pass=$((pass + 1))
else
  echo "  FAIL   expected BLOCK (2) on non-JSON stdin, got $rc_bad"
  fail=$((fail + 1))
fi

echo "== 12. a plain branch switch on a checkout with nothing to lose is allowed"
# Real repos, and the payload's cwd — the conditions are read from the checkout, not from the command string. Every
# fixture is a throwaway under $WORK; the hook only ever reads (status, rev-parse, worktree list), and 12h proves it.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"
mkrepo() { # mkrepo <dir> — main with one commit, a `feature` branch, an empty tmp/
  $G init -q "$1" && (cd "$1" && echo a > a && $G add a && $G commit -q -m c1 && $G branch feature && mkdir -p tmp)
}
run_hook_in() { # run_hook_in <cwd> <cmd> — the payload shape Claude Code sends, cwd included
  jq -n --arg d "$1" --arg c "$2" '{cwd: $d, tool_input: {command: $c}}' | "$HOOK" >/dev/null 2>&1
  echo $?
}
assert_allowed_in() { # <cwd> <cmd> [desc]
  local rc; rc=$(run_hook_in "$1" "$2")
  if [ "$rc" = "0" ]; then echo "  ok     ALLOW  ${3:-$2}"; pass=$((pass + 1)); else echo "  FAIL   expected ALLOW (0), got $rc: ${3:-$2}"; fail=$((fail + 1)); fi
}
assert_blocked_in() { # <cwd> <cmd> [desc]
  local rc; rc=$(run_hook_in "$1" "$2")
  if [ "$rc" = "2" ]; then echo "  ok     BLOCK  ${3:-$2}"; pass=$((pass + 1)); else echo "  FAIL   expected BLOCK (2), got $rc: ${3:-$2}"; fail=$((fail + 1)); fi
}
R="$WORK/r1"; mkrepo "$R"
assert_allowed_in "$R" "git checkout feature" "existing branch, clean tree, cwd from the payload"
assert_allowed_in "$R" "git switch feature"
assert_allowed_in "$R" "git checkout -q main" "a benign flag"
assert_allowed_in "$R" "git switch --no-guess feature"
assert_allowed_in "$R" "git status && git checkout feature" "compound with an allowlisted leader"
assert_allowed_in "$WORK" "git -C $R checkout feature" "literal -C from an unrelated cwd"
assert_allowed_in "$WORK" "git -C $R switch feature"
assert_allowed_in "$R/tmp" "git -C .. checkout feature" "relative -C against the payload cwd"
echo "== 12a. the operand must be an existing branch"
assert_blocked_in "$R" "git checkout nosuch" "unknown branch"
assert_blocked_in "$R" "git checkout a" "a tracked path, not a branch"
assert_blocked_in "$R" "git checkout $(git -C "$R" rev-parse HEAD)" "a sha (detaches)"
assert_blocked_in "$R" "git checkout -" "the previous-branch shorthand — read as a flag and allowed before this suite caught it"
assert_blocked_in "$R" "git switch -"
assert_blocked_in "$R" "git checkout feature -- a" "branch plus a path"
assert_blocked_in "$R" "git checkout feature main" "two operands"
assert_blocked_in "$R" "git checkout --ignore-other-worktrees feature" "overrides git's own worktree guard"
assert_blocked_in "$R" "git checkout -f feature" "force rule still fires first"
assert_blocked_in "$R" "git checkout -m feature" "-m carries changes: outside the plain-switch flag set"
echo "== 12b. the directory git runs in must be knowable"
assert_blocked "git checkout feature" "no cwd in the payload (the pre-conditional shape) stays blocked"
assert_blocked_in "$R" "cd $WORK && git checkout feature" "a cd in the command"
assert_blocked_in "$R" 'git -C "$REPO" checkout feature' "quoted -C is the Q placeholder"
assert_blocked_in "$R" 'git -C $REPO checkout feature' "a \$VAR -C"
assert_blocked_in "$R" "git --git-dir=$R/.git --work-tree=$R checkout feature" "--git-dir/--work-tree"
assert_blocked_in "$WORK" "git checkout feature" "cwd is not a checkout"
echo "== 12c. the tracked tree must be clean; untracked files do not count"
echo dirty >> "$R/a"
assert_blocked_in "$R" "git checkout feature" "a modified tracked file"
assert_blocked_in "$R" "git switch feature"
git -C "$R" checkout -q -- a
touch "$R/untracked"
assert_allowed_in "$R" "git checkout feature" "an untracked file survives a switch"
echo "== 12d. no fleet may be running out of the checkout"
now=$(date +%s)
printf '{"deadline_epoch": %s}\n' "$((now + 3600))" > "$R/tmp/fleet-deadline.json"
assert_blocked_in "$R" "git checkout feature" "fleet deadline in the future"
assert_blocked_in "$R" "git stash" "the same marker gates stash"
printf '{"deadline_epoch": %s, "stopped": true}\n' "$((now + 3600))" > "$R/tmp/fleet-deadline.json"
assert_allowed_in "$R" "git checkout feature" "fleet stopped by /fleet-stop"
printf '{"deadline_epoch": %s}\n' "$((now - 10))" > "$R/tmp/fleet-deadline.json"
assert_allowed_in "$R" "git checkout feature" "deadline already passed"
printf '{"fleet_sessions": ["ab000001"]}\n' > "$R/tmp/fleet-deadline.json"
assert_blocked_in "$R" "git checkout feature" "a fleet launched with no time budget is live until stopped"
printf 'not json' > "$R/tmp/fleet-deadline.json"
assert_blocked_in "$R" "git checkout feature" "an unreadable marker fails closed"
rm -f "$R/tmp/fleet-deadline.json"
printf '{"status": "running", "queue": ["TT-1"]}\n' > "$R/tmp/fleet-sequence-tt-1.json"
assert_allowed_in "$R" "git checkout feature" "a running /fleet-sequence never parks the checkout, so it gates nothing"
rm -f "$R/tmp/fleet-sequence-tt-1.json"
git -C "$R" branch -q epic/tt-1
printf '{"deadline_epoch": %s, "scope": "TT-1", "branch": "epic/tt-1"}\n' "$((now + 3600))" > "$R/tmp/fleet-deadline.json"
assert_allowed_in "$R" "git checkout feature" "an epic fleet steers its picks with per-issue fork keys and never parks the checkout"
printf '{"fleet_sessions": ["ab000001"], "scope": "TT-1", "branch": "epic/tt-1"}\n' > "$R/tmp/fleet-deadline.json"
assert_allowed_in "$R" "git checkout feature" "the same without a time budget"
git -C "$R" branch -q -d epic/tt-1
assert_blocked_in "$R" "git checkout feature" "a recorded branch that no longer exists puts the picks back on the checkout's branch"
rm -f "$R/tmp/fleet-deadline.json"
echo "== 12e. from a linked worktree, the markers are read from the MAIN checkout"
WT="$WORK/r1-wt"; git -C "$R" worktree add -q "$WT" feature
assert_allowed_in "$WT" "git checkout main" "hook allows; git itself refuses a branch checked out elsewhere"
printf '{"deadline_epoch": %s}\n' "$((now + 3600))" > "$R/tmp/fleet-deadline.json"
assert_blocked_in "$WT" "git checkout main" "main checkout's fleet marker seen from the worktree"
rm -f "$R/tmp/fleet-deadline.json"
echo "== 12f. origin/<branch> counts (git creates the tracking branch — a creation, not a move)"
C="$WORK/r1-clone"; $G clone -q "$R" "$C"
assert_allowed_in "$C" "git checkout feature" "only origin/feature exists locally"
assert_blocked_in "$C" "git checkout nosuch"
echo "== 12g. -B and -C reset an existing branch and move the tree: denied, unlike -b and -c"
assert_blocked_in "$R" "git checkout -B main origin/main" "the form the flag-only allowance let through"
assert_blocked_in "$R" "git switch -C feature main"
assert_blocked "git checkout -B main origin/main" "with no cwd either"
assert_allowed_in "$R" "git checkout -b topic/x" "-b still creates"
assert_allowed_in "$R" "git switch -c topic/y"
echo "== 12h. the hook only reads: nothing moved"
if [ "$(git -C "$R" branch --show-current)" = main ] && [ "$(git -C "$R" status --porcelain --untracked-files=no)" = "" ]; then
  echo "  ok     r1 still on main with a clean tracked tree"; pass=$((pass + 1))
else
  echo "  FAIL   the hook changed the fixture: $(git -C "$R" branch --show-current) / $(git -C "$R" status --porcelain)"; fail=$((fail + 1))
fi

echo "== 13. stash on a single-checkout repo with no fleet is allowed; a linked worktree or a fleet blocks it"
S="$WORK/s1"; mkrepo "$S"; echo x >> "$S/a"
assert_allowed_in "$S" "git stash" "bare"
assert_allowed_in "$S" "git stash push -m wip"
assert_allowed_in "$S" "git stash push -u -m 'quoted message'"
assert_allowed_in "$S" "git stash pop"
assert_allowed_in "$S" "git stash apply"
assert_allowed_in "$S" "git stash list"
assert_blocked_in "$S" "git stash drop" "always: deletes an entry"
assert_blocked_in "$S" "git stash clear" "always: deletes every entry"
assert_blocked_in "$S" "git stash branch topic" "always: moves the tree"
assert_blocked "git stash push -m wip" "no cwd in the payload stays blocked"
assert_blocked_in "$R" "git stash" "r1 has a linked worktree sharing the stack"
assert_allowed_in "$R" "git stash list" "read-only stays allowed there too"
assert_blocked_in "$WORK" "git stash" "cwd is not a checkout"

echo
echo "$pass passed / $fail failed"
[ "$fail" -eq 0 ]
