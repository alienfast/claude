#!/usr/bin/env bash
# Regression suite for auto-push-main.sh — the fleet's lazy push of main. Builds a bare origin plus a throwaway clone
# per case and drives the real script against real git, so every fixture is the live feed's own shape. GROW THIS
# SUITE, NEVER PRUNE IT: the script moves origin/main under a running fleet, and every way it could push the wrong
# thing, force anything, or move the local branch belongs below.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/auto-push-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
REAL_GIT="$(command -v git)"
G="$REAL_GIT -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"

PASS=0 FAIL=0
ck() { # ck <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — no [$2] in: $(cat "$3")"; fi
}

fresh() { # fresh <name> → bare origin with c1 c2 on main, and a clone of it at $CLONE (clone sets origin/HEAD)
  ORIGIN="$WORK/$1-origin.git"; SEED="$WORK/$1-seed"; CLONE="$WORK/$1-clone"
  $G init -q --bare "$ORIGIN"
  $G init -q "$SEED" && (cd "$SEED" && echo one > a && $G add a && $G commit -q -m c1 && echo two > b && $G add b && $G commit -q -m c2 && $G push -q "$ORIGIN" main)
  $G clone -q "$ORIGIN" "$CLONE"
  (cd "$CLONE" && git config user.email t@t && git config user.name t && git config commit.gpgsign false)
}
local_commit() { (cd "$CLONE" && echo "$1" > "$1" && git add "$1" && git commit -q -m "$1"); }
advance_origin() { (cd "$SEED" && echo "$1" > "$1" && $G add "$1" && $G commit -q -m "$1" && $G push -q "$ORIGIN" main); }
origin_sha() { $G -C "$ORIGIN" rev-parse main; }
local_sha() { git -C "$CLONE" rev-parse main; }
run() { # run <env assignments or -u VAR ...> → exit code; stdout+stderr in $WORK/out
  (cd "$CLONE" && env "$@" bash "$SCRIPT" > "$WORK/out" 2>&1); echo $?
}

echo "== 1. flag unset: refuses, pushes nothing"
fresh one; local_commit c3
before=$(origin_sha); rc=$(run -u AUTO_PUSH_MAIN)
ck "  exit 3" 3 "$rc"
ck_has "  DISABLED line" "DISABLED: AUTO_PUSH_MAIN is not set" "$WORK/out"
ck "  origin untouched" "$before" "$(origin_sha)"

echo "== 2. unknown mode: refuses loudly, pushes nothing"
rc=$(run AUTO_PUSH_MAIN=always)
ck "  exit 2" 2 "$rc"
ck_has "  names the value" "AUTO_PUSH_MAIN=always is not a mode" "$WORK/out"
ck "  origin untouched" "$before" "$(origin_sha)"

echo "== 3. lazy, nothing ahead"
fresh three; rc=$(run AUTO_PUSH_MAIN=lazy)
ck "  exit 0" 0 "$rc"
ck_has "  NOTHING-TO-PUSH" "NOTHING-TO-PUSH: main is at origin/main" "$WORK/out"

echo "== 4. lazy, two ahead: fast-forward push"
fresh four; local_commit c3; local_commit c4
rc=$(run AUTO_PUSH_MAIN=lazy)
ck "  exit 0" 0 "$rc"
ck_has "  PUSHED 2" "PUSHED: 2 commit(s)" "$WORK/out"
ck "  origin at local head" "$(local_sha)" "$(origin_sha)"

echo "== 5. lazy, diverged: origin holds a commit the checkout lacks"
fresh five; local_commit c3; advance_origin z1
before=$(origin_sha); lbefore=$(local_sha); rc=$(run AUTO_PUSH_MAIN=lazy)
ck "  exit 4" 4 "$rc"
ck_has "  DIVERGED names the count" "DIVERGED: origin/main has 1 commit(s) this checkout lacks" "$WORK/out"
ck "  origin untouched" "$before" "$(origin_sha)"
ck "  local main untouched" "$lbefore" "$(local_sha)"
ck "  no merge in progress" "" "$(cd "$CLONE" && git status --porcelain)"

echo "== 6. lazy, on a feature branch: refuses"
fresh six; (cd "$CLONE" && git checkout -q -b feature/x); local_commit c3
before=$(origin_sha); rc=$(run AUTO_PUSH_MAIN=lazy)
ck "  exit 2" 2 "$rc"
ck_has "  names the branch" "on 'feature/x', not the default branch 'main'" "$WORK/out"
ck "  origin untouched" "$before" "$(origin_sha)"

echo "== 7. lazy, from a linked worktree: refuses"
fresh seven; local_commit c3; (cd "$CLONE" && git worktree add -q "$WORK/seven-wt" -b wt/x >/dev/null 2>&1)
before=$(origin_sha)
rc=$( (cd "$WORK/seven-wt" && env AUTO_PUSH_MAIN=lazy bash "$SCRIPT" > "$WORK/out" 2>&1); echo $? )
ck "  exit 2" 2 "$rc"
ck_has "  names the worktree" "run from the main checkout" "$WORK/out"
ck "  origin untouched" "$before" "$(origin_sha)"

echo "== 8. lazy, fetch fails: transient, exit 1"
fresh eight; local_commit c3; (cd "$CLONE" && git remote set-url origin "$WORK/does-not-exist.git")
rc=$(run AUTO_PUSH_MAIN=lazy)
ck "  exit 1" 1 "$rc"
ck_has "  FETCH-FAILED" "FETCH-FAILED:" "$WORK/out"

echo "== 9. lazy, origin moves between the fetch and the push: re-fetch once, DIVERGED, never a force"
fresh nine; local_commit c3
mkdir -p "$WORK/bin"
# A git shim: the FIRST push first lands a different commit on origin from the seed, then delegates — so the real push is
# rejected as non-fast-forward exactly as a human push landing mid-run would reject it.
printf '%s\n' '#!/usr/bin/env bash' "REAL_GIT='$REAL_GIT'" "SEED='$SEED'" "ORIGIN='$ORIGIN'" "MARK='$WORK/nine-raced'" \
  'if [ "${1:-}" = push ] && [ ! -e "$MARK" ]; then touch "$MARK"; (cd "$SEED" && echo z2 > z2 && "$REAL_GIT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add z2 && "$REAL_GIT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m z2 && "$REAL_GIT" push -q "$ORIGIN" main); fi' \
  'exec "$REAL_GIT" "$@"' > "$WORK/bin/git"
chmod +x "$WORK/bin/git"
before_local=$(local_sha)
rc=$( (cd "$CLONE" && PATH="$WORK/bin:$PATH" AUTO_PUSH_MAIN=lazy bash "$SCRIPT" > "$WORK/out" 2>&1); echo $? )
ck "  exit 4" 4 "$rc"
ck_has "  DIVERGED during the push" "moved to" "$WORK/out"
ck "  origin kept its own commit" "$($G -C "$SEED" rev-parse main)" "$(origin_sha)"
ck "  local main untouched" "$before_local" "$(local_sha)"

echo "== 10. static: no force flag, no + refspec, no rebase/merge/pull/reset of the local branch"
ck "  no --force" 0 "$(grep -c -- '--force\|push -f\|push --force' "$SCRIPT")"
ck "  no + refspec" 0 "$(grep -cE 'push[^|#]*\+refs|origin \+' "$SCRIPT")"
ck "  no local branch moves" 0 "$(grep -cE '^\s*git (pull|rebase|merge|reset)' "$SCRIPT")"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
