#!/usr/bin/env bash
# Regression suite for analyze-pr.sh: the report runs to its end on a branch with no PR and on a branch with a long file list.
#
# WHY THIS SUITE EXISTS. Three lines ended or bent the report under `set -euo pipefail` (all measured 2026-11-12):
#   - `pr_info=$(gh pr view …)` ended the script on any branch with no PR, where gh exits 1;
#   - `echo "$list" | head -10` ended it on a documentation or infrastructure list past the pipe buffer, echo dying of SIGPIPE;
#   - `git diff --name-only | grep -q package.json` dropped the dependency notice on a name list past the buffer.
# The last two appear only on large inputs, so the arms build a branch of that size and assert it before trusting the answer.
#
# `gh` is stubbed to find no PR and no repository, which leaves the base branch on its `main` default.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/analyze-pr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}

BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/gh"

REPO="$WORK/repo"
git init -q -b main "$REPO"
G() { git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
G commit -q --allow-empty -m init
branch_of() { # branch_of <name> <extension> <count> — a branch off main adding package.json and <count> long-named files
  local i=0
  G switch -q -c "$1" main
  mkdir -p "$REPO/zz-sorts-after-package-json"
  echo '{}' > "$REPO/package.json"
  while [ "$i" -lt "$3" ]; do
    i=$((i + 1))
    echo x > "$REPO/zz-sorts-after-package-json/a-file-with-a-long-name-for-width-number-$i.$2"
  done
  G add -A
  G commit -q -m "$1"
}
run() { ( cd "$REPO" && PATH="$BIN:$PATH" "$SCRIPT" > "$WORK/out" 2>&1 ); echo $?; }
names_past_buffer() { echo $(( $(G diff main...HEAD --name-only | wc -c) > 65536 )); }

# ---- a branch with no PR: the report still runs ----
branch_of small txt 3
ck "no PR exits 0"                       "0" "$(run)"
ck_has "no PR is said"                   "No PR found for this branch" "$WORK/out"
ck_has "the base defaults to main"       "Base branch: main" "$WORK/out"
ck_has "the dependency change is noticed" "Dependency Changes Detected" "$WORK/out"
ck_has "the report reaches its end"      "Code Impact Summary" "$WORK/out"

# ---- a name list past the pipe buffer, package.json sorting first ----
branch_of wide txt 1500
ck "the wide name list is past the pipe buffer" "1" "$(names_past_buffer)"
ck "a wide branch exits 0"               "0" "$(run)"
ck_has "its dependency change is noticed" "Dependency Changes Detected" "$WORK/out"

# ---- a documentation list past the pipe buffer ----
branch_of docs md 1500
ck "the documentation list is past the pipe buffer" "1" "$(names_past_buffer)"
ck "a documentation-heavy branch exits 0" "0" "$(run)"
ck_has "ten are listed and the rest counted" "... and 1490 more" "$WORK/out"
ck_has "and the report reaches its end"  "Code Impact Summary" "$WORK/out"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
