#!/usr/bin/env bash
# Regression suite for verify-feature.sh: a pattern is PRESENT when the file in HEAD carries it, whatever the file's size.
#
# WHY THIS SUITE EXISTS. The search ran `git show HEAD:<path> | grep -q` under pipefail, so on a file larger than the pipe
# buffer grep exited at an early match, git died of SIGPIPE still writing the rest, and the script reported a feature that
# is present as MISSING, every time (measured 2026-11-12). A small fixture can never show that, so the large arms assert
# the file's size before trusting the answer.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/verify-feature.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}

REPO="$WORK/repo"
git init -q "$REPO"
printf 'export function small() {}\n' > "$REPO/small.ts"
{
  printf 'export function early() {}\n'
  head -c 200000 /dev/zero | tr '\0' x | fold -w 100
  printf '\nexport function late() {}\n'
} > "$REPO/large.ts"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init

rc() { ( cd "$REPO" && "$SCRIPT" "$@" >/dev/null 2>&1 ); echo $?; }

ck "a pattern in a small file is present"        "0" "$(rc small.ts 'function small')"
ck "a pattern the file lacks is missing"         "1" "$(rc small.ts 'function absent')"
ck "a file that exists needs no pattern"         "0" "$(rc small.ts '')"
ck "a file HEAD lacks is missing"                "1" "$(rc nope.ts 'function small')"

ck "the large file is past the pipe buffer"      "1" "$(( $(git -C "$REPO" cat-file -s HEAD:large.ts) > 65536 ))"
ck "a pattern at the top of a large file is present" "0" "$(rc large.ts 'function early')"
ck "a pattern at its end is present"             "0" "$(rc large.ts 'function late')"
ck "a pattern a large file lacks is missing"     "1" "$(rc large.ts 'function absent')"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
