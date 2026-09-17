#!/bin/bash
# suite-baseline-cache.test.sh — tests for suite-baseline-cache.sh.
#
# The property the cache rests on is asserted directly rather than assumed: the key of a DIRTY tree must equal
# HEAD^{tree} of the commit later made from it, because that equality is what lets one session's post-change
# run serve as the baseline of the session that forks the resulting merge. The refusal paths matter as much as
# the hits — a record whose tree moved since launch, or with no aggregate line, must write nothing.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SBC="$SCRIPT_DIR/suite-baseline-cache.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

TMP=$(mktemp -d) || { echo "cannot mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
REPO="$TMP/repo"
git init -q "$REPO" && cd "$REPO" || exit 1
REPO=$(pwd -P)   # git reports physical paths; macOS's mktemp lives under the /var → /private/var symlink
git checkout -q -b main 2>/dev/null || true
# tmp/ is ignored as in the real repos: the key covers untracked non-ignored files, so scratch written anywhere
# else between key capture and record legitimately moves the tree and makes record refuse.
printf 'node_modules/\ntmp/\n' > .gitignore
printf 'one\n' > a.txt
mkdir -p spec && printf 'spec\n' > spec/a_spec.rb
git add .gitignore a.txt spec/a_spec.rb && git commit -q -m init

echo "suite-baseline-cache.sh"

# --- key ---------------------------------------------------------------------------------------------------------

clean_key=$("$SBC" key)
eq "key of a clean tree is HEAD^{tree}" "$(git rev-parse 'HEAD^{tree}')" "$clean_key"

index_before=$(shasum "$REPO/.git/index" | cut -d' ' -f1)
printf 'two\n' > a.txt
dirty_key=$("$SBC" key)
[ "$dirty_key" != "$clean_key" ] && ok "an uncommitted edit changes the key" || no "an uncommitted edit changes the key" "different" "$dirty_key"
eq "the real index is untouched by key" "$index_before" "$(shasum "$REPO/.git/index" | cut -d' ' -f1)"
eq "the real working state is untouched by key" " M a.txt" "$(git status --porcelain)"

mkdir -p node_modules && printf 'x\n' > node_modules/ignored.js
eq "an ignored file does not change the key" "$dirty_key" "$("$SBC" key)"

printf 'new\n' > untracked.txt
untracked_key=$("$SBC" key)
[ "$untracked_key" != "$dirty_key" ] && ok "an untracked file changes the key" || no "an untracked file changes the key" "different" "$untracked_key"
rm untracked.txt

# The property everything rests on: hashing the dirty tree now must equal the tree of the commit made from it.
git add a.txt && git commit -q -m edit
eq "dirty-tree key equals HEAD^{tree} of the commit made from it" "$(git rev-parse 'HEAD^{tree}')" "$dirty_key"

rm a.txt
deleted_key=$("$SBC" key)
[ "$deleted_key" != "$dirty_key" ] && ok "a deleted tracked file changes the key" || no "a deleted tracked file changes the key" "different" "$deleted_key"
git checkout -q -- a.txt

# --- lookup / record -----------------------------------------------------------------------------------------------

out=$("$SBC" lookup rspec); rc=$?
eq "lookup misses before any record (exit 1)" "1" "$rc"
eq "lookup prints KEY then MISS on a miss" "KEY=$dirty_key
MISS" "$out"

mkdir -p tmp
"$SBC" key > tmp/rspec.key
printf 'rspec: 100 examples / 2 failures / 8 of 8 workers\n' > tmp/rspec.summary
printf './spec/a_spec.rb:12\n./spec/a_spec.rb:40\n' > tmp/rspec.failing
out=$("$SBC" record rspec --key-file tmp/rspec.key --summary-file tmp/rspec.summary --failing-file tmp/rspec.failing --note "test"); rc=$?
eq "record succeeds with a matching key (exit 0)" "0" "$rc"
case "$out" in
  "RECORDED $REPO/.git/suite-baselines/rspec/$dirty_key.json") ok "record writes under the git common dir keyed by tree" ;;
  *) no "record writes under the git common dir keyed by tree" "RECORDED .git/suite-baselines/rspec/<tree>.json" "$out" ;;
esac
eq "record stores the failing list as JSON" '["./spec/a_spec.rb:12","./spec/a_spec.rb:40"]' "$(jq -c '.failing' ".git/suite-baselines/rspec/$dirty_key.json")"

out=$("$SBC" lookup rspec); rc=$?
eq "lookup hits after record (exit 0)" "0" "$rc"
eq "lookup prints the recorded summary and failing lines" "KEY=$dirty_key
HIT $REPO/.git/suite-baselines/rspec/$dirty_key.json
SUMMARY rspec: 100 examples / 2 failures / 8 of 8 workers
FAILING ./spec/a_spec.rb:12
FAILING ./spec/a_spec.rb:40" "$(echo "$out" | grep -v '^RECORDED ')"
echo "$out" | grep -q "^RECORDED .* commit=$(git rev-parse HEAD) branch=main$" && ok "lookup reports when and where it was recorded" || no "lookup reports when and where it was recorded" "RECORDED <when> commit=<sha> branch=main" "$out"

# --- refusals -------------------------------------------------------------------------------------------------------

"$SBC" key > tmp/rspec.key
printf 'three\n' > a.txt
out=$("$SBC" record rspec --key-file tmp/rspec.key --summary-file tmp/rspec.summary --failing-file tmp/rspec.failing 2>&1); rc=$?
eq "record refuses when the tree moved since the key was captured (exit 3)" "3" "$rc"
[ ! -f ".git/suite-baselines/rspec/$("$SBC" key).json" ] && ok "a refused record writes nothing" || no "a refused record writes nothing" "no entry" "entry present"
git checkout -q -- a.txt

: > tmp/empty.summary
"$SBC" key > tmp/rspec.key
"$SBC" record rspec --key-file tmp/rspec.key --summary-file tmp/empty.summary --failing-file tmp/rspec.failing >/dev/null 2>&1; rc=$?
eq "record refuses an empty summary (exit 2)" "2" "$rc"

"$SBC" record rspec --key-file tmp/rspec.key --summary-file tmp/rspec.summary >/dev/null 2>&1; rc=$?
eq "record refuses a missing --failing-file (exit 2)" "2" "$rc"

"$SBC" lookup >/dev/null 2>&1; rc=$?
eq "lookup without a suite is a usage error (exit 2)" "2" "$rc"

"$SBC" lookup 'a/b' >/dev/null 2>&1; rc=$?
eq "a suite name with a slash is refused (exit 2)" "2" "$rc"

# --- a linked worktree shares the store ------------------------------------------------------------------------------

git worktree add -q "$TMP/wt" -b sibling HEAD 2>/dev/null
out=$("$SBC" lookup rspec --repo "$TMP/wt"); rc=$?
eq "a linked worktree at the same tree hits the main checkout's record" "0" "$rc"
echo "$out" | grep -q "^HIT $REPO/.git/suite-baselines/rspec/$dirty_key.json$" && ok "the hit resolves to the shared entry" || no "the hit resolves to the shared entry" "HIT <main .git path>" "$out"

# A flake — the same tree recorded with a different result — replaces the entry and says so.
mkdir -p "$TMP/wt/tmp"
printf 'rspec: 100 examples / 0 failures / 8 of 8 workers\n' > "$TMP/wt/tmp/flaky.summary"
: > "$TMP/wt/tmp/none.failing"
"$SBC" key --repo "$TMP/wt" > "$TMP/wt/tmp/k"
err=$("$SBC" record rspec --repo "$TMP/wt" --key-file "$TMP/wt/tmp/k" --summary-file "$TMP/wt/tmp/flaky.summary" --failing-file "$TMP/wt/tmp/none.failing" 2>&1 >/dev/null)
echo "$err" | grep -q 'WARN replacing' && ok "re-recording a differing result warns" || no "re-recording a differing result warns" "WARN replacing…" "$err"
git worktree remove --force "$TMP/wt"

# --- list / prune -------------------------------------------------------------------------------------------------------

out=$("$SBC" list rspec)
echo "$out" | grep -q "^[0-9T:Z-]* ${dirty_key:0:12} rspec: 100 examples / 0 failures" && ok "list shows the entry with its short key" || no "list shows the entry" "<when> <key12> <summary>" "$out"

touch -t 202001010000 ".git/suite-baselines/rspec/$dirty_key.json"
eq "prune deletes entries older than --days" "PRUNED 1" "$("$SBC" prune rspec --days 30)"
eq "prune on an empty store reports zero" "PRUNED 0" "$("$SBC" prune rspec --days 30)"
"$SBC" prune rspec >/dev/null 2>&1; rc=$?
eq "prune without --days is a usage error (exit 2)" "2" "$rc"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
