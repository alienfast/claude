#!/usr/bin/env bash
# Regression suite for the push polarity of finish-commit.sh and finish-detect-mode.sh: pushing is opt-in
# (--push), pr implies it, merge refuses it, and the retired --no-push spelling is an error rather than a
# silent default. Fixtures are a throwaway bare origin plus a clone in $TMP; no network.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT="$DIR/finish-commit.sh"
DETECT="$DIR/finish-detect-mode.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ck() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 — want [$2] got [$3]"; FAIL=$((FAIL+1)); fi
}
ck_has() { # <name> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 — no [$2] in [$3]"; FAIL=$((FAIL+1)); fi
}
key() { printf '%s\n' "$2" | grep "^$1="; }

G=(git -c user.email=t@t.test -c user.name=t)
ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN"
REPO="$TMP/repo"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
cd "$REPO" || exit 1
"${G[@]}" commit -q --allow-empty -m "init"
git push -q -u origin main 2>/dev/null

msg="$TMP/msg.md"
printf 'PL-1: test change\n' > "$msg"

echo "finish-commit.sh"

echo a > a.txt; git add a.txt
out=$(GIT_AUTHOR_EMAIL=t@t.test GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t.test GIT_COMMITTER_NAME=t "$COMMIT" PL-1 "$msg" 2>&1); rc=$?
ck "default commits" 0 "$rc"
ck "default leaves the commit local" 1 "$(git rev-list --count origin/main..HEAD)"
ck_has "default says it did not push" "Not pushed" "$out"
ck_has "default names the push" "git push" "$out"

out=$("$COMMIT" PL-1 "$msg" 2>&1); rc=$?
ck "ahead without --push exits 0" 0 "$rc"
ck "ahead without --push stays local" 1 "$(git rev-list --count origin/main..HEAD)"

out=$("$COMMIT" PL-1 "$msg" --push 2>&1); rc=$?
ck "--push exits 0" 0 "$rc"
ck "--push lands the commit on origin" 0 "$(git rev-list --count origin/main..HEAD)"

out=$("$COMMIT" PL-1 "$msg" 2>&1); rc=$?
ck "in sync exits 0" 0 "$rc"
ck_has "in sync is a no-op" "nothing to do" "$out"

out=$("$COMMIT" PL-1 "$msg" --no-push 2>&1); rc=$?
ck "retired --no-push is an error" 1 "$rc"
ck_has "retired --no-push names the opt-in" "--push" "$out"

git switch -q -c feature
echo b > b.txt; git add b.txt
out=$(GIT_AUTHOR_EMAIL=t@t.test GIT_AUTHOR_NAME=t GIT_COMMITTER_EMAIL=t@t.test GIT_COMMITTER_NAME=t "$COMMIT" PL-1 "$msg" 2>&1); rc=$?
ck "no-upstream default commits" 0 "$rc"
ck "no-upstream default does not publish" "" "$(git ls-remote --heads origin feature)"
ck_has "no-upstream default names set-upstream" "set-upstream" "$out"
out=$("$COMMIT" PL-1 "$msg" --push 2>&1); rc=$?
ck "no-upstream --push exits 0" 0 "$rc"
ck "no-upstream --push publishes the branch" 1 "$(git ls-remote --heads origin feature | wc -l | tr -d ' ')"

echo "finish-detect-mode.sh"

out=$("$DETECT" 2>/dev/null); rc=$?
ck "bare exits 0 outside a worktree" 0 "$rc"
ck "bare emits PUSH=0" "PUSH=0" "$(key PUSH "$out")"
ck "bare emits an empty ACTION" "ACTION=" "$(key ACTION "$out")"
out=$("$DETECT" --push 2>/dev/null); rc=$?
ck "--push exits 0" 0 "$rc"
ck "--push emits PUSH=1" "PUSH=1" "$(key PUSH "$out")"
out=$("$DETECT" pr 2>/dev/null); rc=$?
ck "pr exits 0" 0 "$rc"
ck "pr implies PUSH=1" "PUSH=1" "$(key PUSH "$out")"
"$DETECT" --no-push >/dev/null 2>&1; ck "retired --no-push is an error" 1 "$?"

git config extensions.worktreeConfig true
git worktree add -q "$TMP/wt" -b wt-branch main 2>/dev/null
git -C "$TMP/wt" config --worktree start.source-branch main
out=$(cd "$TMP/wt" && "$DETECT" 2>/dev/null); rc=$?
ck "worktree bare exits 0" 0 "$rc"
ck "worktree bare defaults to merge" "ACTION=merge" "$(key ACTION "$out")"
ck "worktree bare emits PUSH=0" "PUSH=0" "$(key PUSH "$out")"
out=$(cd "$TMP/wt" && "$DETECT" --push 2>&1); rc=$?
ck "worktree implicit merge + --push refused" 1 "$rc"
ck_has "refusal names the source-branch push" "source branch" "$out"
out=$(cd "$TMP/wt" && "$DETECT" merge --push 2>&1); rc=$?
ck "worktree explicit merge + --push refused" 1 "$rc"
out=$(cd "$TMP/wt" && "$DETECT" pr --push 2>/dev/null); rc=$?
ck "worktree pr + --push exits 0" 0 "$rc"
ck "worktree pr emits PUSH=1" "PUSH=1" "$(key PUSH "$out")"

echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
