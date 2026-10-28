#!/usr/bin/env bash
# Regression suite for auto-fork-key.sh — the per-issue fork key /auto sets before each dispatch. Drives the real script
# against a real repo: the property under test is that the key lands (or does not) in the MAIN checkout's config exactly
# when the epic's own marker (tmp/fleet-deadline-<slug>.json) says it has an integration branch — or, with no epic
# named, when some live epic fleet's marker lists the issue as a member — that nothing else is ever written, and that
# the checkout's HEAD is never touched.
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
M1="$REPO/tmp/fleet-deadline-ep-1.json"
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
ck "  set with no id exits 1"     1 "$(run -- set)"
ck "  set with three ids exits 1" 1 "$(run -- set EP-5 EP-1 EP-2)"
ck "  unset with two ids exits 1" 1 "$(run -- unset EP-5 EP-1)"
ck "  unknown action exits 1"     1 "$(run -- point EP-5 EP-1)"
ck "  malformed issue id exits 1" 1 "$(run -- set nope EP-1)"
ck_has "  names the bad id"       "'nope' does not name an issue" "$WORK/out"
ck "  malformed epic id exits 1"  1 "$(run -- set EP-5 epic)"
ck "  nothing written"            "" "$(git -C "$REPO" config --get-regexp '^start\.' || true)"

echo "== 2. no marker: nothing to steer"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  says none"              "FORK-KEY: none — no fleet marker for epic EP-1 (tmp/fleet-deadline-ep-1.json)" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 3. a marker at this epic's path but scoped to another epic (moved by hand): nothing to steer"
printf '{"scope":"EP-9","branch":"epic/ep-1","fleet_sessions":[]}\n' > "$M1"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  names the marker scope" "scoped to 'EP-9', not EP-1" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 4. marker for this epic without a branch: nothing to steer"
printf '{"scope":"EP-1","fleet_sessions":[]}\n' > "$M1"
ck "  exits 0"                    0 "$(run -- set EP-5 EP-1)"
ck_has "  points at /epic-prep"   "no integration branch recorded (run /epic-prep EP-1" "$WORK/out"
ck "  key unset"                  "" "$(key ep-5)"

echo "== 5. marker for this epic with a branch: the key is set, the checkout is not moved"
printf '{"scope":"EP-1","branch":"epic/ep-1","base":"monday","fleet_sessions":[]}\n' > "$M1"
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
printf '{"scope":"EP-1","branch":"epic/gone","fleet_sessions":[]}\n' > "$M1"
ck "  exits 0"                    0 "$(run -- set EP-8 EP-1)"
ck_has "  warns and names the branch" "FORK-KEY: none — WARN: the fleet marker names integration branch 'epic/gone' for epic EP-1 but no such local branch" "$WORK/out"
ck "  key unset"                  "" "$(key ep-8)"
printf '{"scope":"EP-1","branch":"epic/ep-1","fleet_sessions":[]}\n' > "$M1"

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

echo "== 10. two fleets side by side: each epic reads only its own marker"
git -C "$REPO" branch -q epic/ep-2 monday
M2="$REPO/tmp/fleet-deadline-ep-2.json"
printf '{"scope":"EP-1","branch":"epic/ep-1","members":["EP-1","EP-5","EP-11"],"fleet_sessions":[]}\n' > "$M1"
printf '{"scope":"EP-2","branch":"epic/ep-2","members":["EP-2","EP-21","EP-11"],"fleet_sessions":[]}\n' > "$M2"
ck "  EP-1 member steers onto epic/ep-1" 0 "$(run -- set EP-5 EP-1)"
ck "  key for the EP-1 pick"      "epic/ep-1" "$(key ep-5)"
ck "  EP-2 member steers onto epic/ep-2" 0 "$(run -- set EP-21 EP-2)"
ck "  key for the EP-2 pick"      "epic/ep-2" "$(key ep-21)"
ck "  a team marker beside them is not an epic" 0 "$(printf '{"count":2,"fleet_sessions":[]}\n' > "$REPO/tmp/fleet-deadline-team.json"; run -- set EP-5 EP-1)"
ck "  key still epic/ep-1"        "epic/ep-1" "$(key ep-5)"
git -C "$REPO" config --unset start.ep-5.wt-source-branch
git -C "$REPO" config --unset start.ep-21.wt-source-branch

echo "== 11. no epic named (a team or targeted run): the fleet whose members list the issue steers it"
ck "  member of EP-1 only"        0 "$(run -- set EP-5)"
ck "  key points at epic/ep-1"    "epic/ep-1" "$(key ep-5)"
ck_has "  line names the epic"    "FORK-KEY: start.ep-5.wt-source-branch=epic/ep-1 (epic EP-1" "$WORK/out"
ck "  member of EP-2 only"        0 "$(run -- set EP-21)"
ck "  key points at epic/ep-2"    "epic/ep-2" "$(key ep-21)"
ck "  member of neither"          0 "$(run -- set EP-99)"
ck_has "  says no fleet lists it" "FORK-KEY: none — no live epic fleet lists EP-99 as a member" "$WORK/out"
ck "  key unset"                  "" "$(key ep-99)"
# A shared member (a common blocker): the first fleet by slug steers, and the line says which other fleet lists it.
ck "  shared member exits 0"      0 "$(run -- set EP-11)"
ck "  shared member lands on the first slug" "epic/ep-1" "$(key ep-11)"
ck_has "  line names the other fleet" "also a member of EP-2 — the first fleet by slug steers it" "$WORK/out"
# An archived marker (an ended run a later launch displaced) is never read as a running fleet.
printf '{"scope":"EP-3","branch":"epic/ep-1","members":["EP-31"],"fleet_sessions":["aa000001"]}\n' > "$REPO/tmp/fleet-deadline-ep-3.1790000000.json"
ck "  archived marker steers nobody" 0 "$(run -- set EP-31)"
ck_has "  archived: says none"    "no live epic fleet lists EP-31" "$WORK/out"
# An epic fleet whose marker has no branch is not a steer either; a stopped one still is (its branch and PR outlive the fleet).
printf '{"scope":"EP-2","members":["EP-22"],"fleet_sessions":[]}\n' > "$M2"
ck "  member of a branchless fleet" 0 "$(run -- set EP-22)"
ck_has "  branchless: points at /epic-prep" "no integration branch recorded (run /epic-prep EP-2" "$WORK/out"
printf '{"scope":"EP-2","branch":"epic/ep-2","members":["EP-22"],"stopped":true,"fleet_sessions":[]}\n' > "$M2"
ck "  member of a stopped fleet"  0 "$(run -- set EP-22)"
ck "  stopped fleet still steers" "epic/ep-2" "$(key ep-22)"
for k in ep-5 ep-21 ep-11 ep-22; do git -C "$REPO" config --unset "start.$k.wt-source-branch"; done

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
