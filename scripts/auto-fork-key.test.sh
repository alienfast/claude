#!/usr/bin/env bash
# Regression suite for auto-fork-key.sh — the per-issue fork key an epic-scoped /auto sets before each dispatch.
# Drives the real script against a real repo: the property under test is that the key lands (or does not) in the
# MAIN checkout's config exactly when the fleet marker says this epic has an integration branch, that nothing else
# is ever written, and that the checkout's HEAD is never touched.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/auto-fork-key.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
PASS=0 FAIL=0
ck() { # ck <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — no [$2] in: $(cat "$3")"; fi
}

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" checkout -q -b monday
git -C "$REPO" branch -q epic/ep-1 monday
mkdir -p "$REPO/tmp"
run() { # run [cwd] -- <args> → exit code; stdout+stderr in $WORK/out
  local dir="$REPO"
  if [ "$1" != "--" ]; then dir="$1"; shift; fi
  shift
  ( cd "$dir" && "$SCRIPT" "$@" ) > "$WORK/out" 2>&1; echo $?
}
key() { git -C "$REPO" config --get "start.$1.wt-source-branch" 2>/dev/null || true; }
head_of() { git -C "$REPO" branch --show-current; }

echo "== 1. usage and id validation"
ck "  no args exits 1"            1 "$(run --)"
ck "  set with one id exits 1"    1 "$(run -- set EP-5)"
ck "  unset with two ids exits 1" 1 "$(run -- unset EP-5 EP-1)"
ck "  unknown action exits 1"     1 "$(run -- point EP-5 EP-1)"
ck "  malformed issue id exits 1" 1 "$(run -- set nope EP-1)"
ck_has "  names the bad id"       "'nope' does not name an issue" "$WORK/out"
ck "  malformed epic id exits 1"  1 "$(run -- set EP-5 epic)"
ck "  nothing written"            "" "$(git -C "$REPO" config --get-regexp '^start\.' || true)"

echo "== 2. no marker: nothing to steer"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  says none"              "FORK-KEY: none — no fleet marker" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 3. marker for another epic: nothing to steer"
printf '{"scope":"EP-9","branch":"epic/ep-1","fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline.json"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  names the marker scope" "scoped to 'EP-9', not EP-1" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 4. marker for this epic without a branch: nothing to steer"
printf '{"scope":"EP-1","fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline.json"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  points at /epic-prep"   "no integration branch recorded (run /epic-prep EP-1" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 5. marker for this epic with a branch: the key is set, the checkout is not moved"
printf '{"scope":"EP-1","branch":"epic/ep-1","base":"monday","fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline.json"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck "  key set"                    "epic/ep-1" "$(key ep-5)"
ck_has "  reports the key"        "FORK-KEY: start.ep-5.wt-source-branch=epic/ep-1 (epic EP-1" "$WORK/out"
ck "  checkout still on monday"   "monday" "$(head_of)"
ck "  checkout-wide key untouched" "" "$(git -C "$REPO" config --get start.wt-source-branch || true)"
ck "  idempotent re-set exits 0"  0 "$(run -- set EP-5 EP-1)"
ck "  key unchanged"              "epic/ep-1" "$(key ep-5)"
ck "  lowercase ids normalize"    0 "$(run -- set ep-6 ep-1)"
ck "  lowercase key set"          "epic/ep-1" "$(key ep-6)"
ck "  only the two keys exist"    "start.ep-5.wt-source-branch epic/ep-1
start.ep-6.wt-source-branch epic/ep-1" "$(git -C "$REPO" config --get-regexp '^start\.' | sort)"

echo "== 6. a per-issue key already naming another branch is never repointed"
git -C "$REPO" branch -q seq/ep-7 monday
git -C "$REPO" config start.ep-7.wt-source-branch seq/ep-7
ck "  exits 1"                    1 "$(run -- set EP-7 EP-1)"
ck_has "  names the holder"       "start.ep-7.wt-source-branch is already 'seq/ep-7'" "$WORK/out"
ck "  key unchanged"              "seq/ep-7" "$(key ep-7)"
git -C "$REPO" config --unset start.ep-7.wt-source-branch

echo "== 7. a recorded branch that no longer exists falls back with a WARN — never stalls the pick"
printf '{"scope":"EP-1","branch":"epic/gone","fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline.json"
ck "  exits 0"                    0 "$(run -- set EP-8 EP-1)"
ck_has "  warns and names the branch" "FORK-KEY: none — WARN: the fleet marker names integration branch 'epic/gone' for epic EP-1 but no such local branch" "$WORK/out"
ck "  key unset"                  "" "$(key ep-8)"
printf '{"scope":"EP-1","branch":"epic/ep-1","fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline.json"

echo "== 8. unset clears the key and is a no-op on a missing one"
ck "  unset exits 0"              0 "$(run -- unset EP-5)"
ck_has "  reports the clear"      "FORK-KEY: cleared start.ep-5.wt-source-branch (was epic/ep-1)" "$WORK/out"
ck "  key gone"                   "" "$(key ep-5)"
ck "  sibling key survives"       "epic/ep-1" "$(key ep-6)"
ck "  second unset exits 0"       0 "$(run -- unset EP-5)"
ck_has "  says nothing to clear"  "FORK-KEY: nothing to clear" "$WORK/out"

echo "== 9. from a linked worktree the key lands in the main checkout's config"
WT="$WORK/wt-ep-6"
git -C "$REPO" worktree add -q "$WT" -b w/ep-6 epic/ep-1
ck "  set from the worktree exits 0" 0 "$(run "$WT" -- set EP-9 EP-1)"
ck "  main config carries it"     "epic/ep-1" "$(key ep-9)"
ck "  unset from the worktree"    0 "$(run "$WT" -- unset EP-9)"
ck "  cleared in the main config" "" "$(key ep-9)"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
