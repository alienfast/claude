#!/usr/bin/env bash
# Regression suite for start-wt-create.sh's branch resolution: an issue retitled between a park and its resume must resume
# on the branch its first /start created, not the one the new title composes. BF-2822 is the fixture because it is the
# measured case: a split retitled it 33 minutes before an epic fleet launched, and four of five sessions then refused its
# parked worktree ("exists but is on … Investigate manually") while nothing shipped it. The attach path had the quieter
# twin — with the worktree dir gone it missed the old branch and forked a fresh one, stranding the parked commits.
#
# Driven the way start-wt-setup.sh drives it under the repo lock: cwd in the main checkout, a relative
# .claude/worktrees/<id> dir, 5 args. The last case runs setup itself with linear-cli and gh stubbed, because the BRANCH=
# that /start consumes is setup's line, and printing its own composed name there would undo the resolution silently.
set -uo pipefail
unset CDPATH CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_HARNESS_PID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE="$DIR/start-wt-create.sh"
WORK="$(mktemp -d)"
[ -n "$WORK" ] || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
G="git -c user.email=t@t -c user.name=t"
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_err() { # ck_err <label> <needle>
  if printf '%s' "$ERR" | grep -qF -- "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — stderr missing [$2]: $ERR"; fi
}
has_ref() { git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" >/dev/null && echo yes || echo no; }
kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

OLD="rosskevin/bf-2822-debt-series-and-debt-event-deletes-show"
NEW="rosskevin/bf-2822-debt-series-deletes-on-the-payment-book"
WTREL=".claude/worktrees/bf-2822"

mkrepo() { # name
  REPO="$WORK/$1/repo"; WT="$REPO/$WTREL"
  mkdir -p "$REPO/.claude/worktrees"
  git init -q -b main "$REPO"
  git -C "$REPO" config extensions.worktreeConfig true
  ( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm root ) >/dev/null
}
create() { # composed-branch [issue-id issue-lower wt-dir]
  local id="${2-BF-2822}" lower="${3-bf-2822}" dir="${4-$WTREL}"
  OUT=$(cd "$REPO" && env CLAUDE_SESSION_ID=sess-A "$CREATE" "$id" "$lower" "$1" main "$dir" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}
park() { # commit work in the worktree, as a parked session leaves it
  ( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "parked work" ) >/dev/null
  PARKED=$(git -C "$WT" rev-parse HEAD)
}

# --- reuse: the worktree survives on the pre-retitle branch (the fleet's refusal) ---
mkrepo reuse
create "$OLD"
ck "reuse: the first /start creates the worktree" "0" "$RC"
ck "reuse: on the branch the title composed then" "$OLD" "$(kv BRANCH)"
park
create "$NEW"
ck "reuse: the retitled resume succeeds" "0" "$RC"
ck "reuse: BRANCH= names the existing branch" "$OLD" "$(kv BRANCH)"
ck "reuse: reported as a reuse" "0" "$(kv CREATED_WT)"
ck "reuse: the worktree stays on its branch" "$OLD" "$(git -C "$WT" branch --show-current)"
ck "reuse: the parked work is HEAD" "$PARKED" "$(git -C "$WT" rev-parse HEAD)"
ck "reuse: no branch is minted from the new title" "no" "$(has_ref "$NEW")"
ck "reuse: the identity stamp records the existing branch" "$OLD" "$(git -C "$WT" config --worktree --get start.worktree-branch)"
ck_err "reuse: says why BRANCH= differs from the title" "resuming BF-2822 on its existing branch '$OLD'"

# --- attach: the worktree dir is gone, the branch with the parked commits survives (the silent twin) ---
mkrepo attach
create "$OLD"; park
git -C "$REPO" worktree remove --force "$WTREL"
create "$NEW"
ck "attach: the retitled resume succeeds" "0" "$RC"
ck "attach: re-attaches the existing branch" "$OLD" "$(kv BRANCH)"
ck "attach: reported as created" "1" "$(kv CREATED_WT)"
ck "attach: the parked work is HEAD" "$PARKED" "$(git -C "$WT" rev-parse HEAD)"
ck "attach: no fresh branch strands the work" "no" "$(has_ref "$NEW")"

# --- the composed name, when it exists, still wins over an older branch of the issue ---
mkrepo exact
git -C "$REPO" branch "$OLD"; git -C "$REPO" branch "$NEW"
create "$NEW"
ck "exact: succeeds" "0" "$RC"
ck "exact: attaches the composed name" "$NEW" "$(kv BRANCH)"

# --- two earlier branches and no composed one: refuse rather than pick, since either may hold the work ---
mkrepo ambiguous
git -C "$REPO" branch "$OLD"; git -C "$REPO" branch "rosskevin/bf-2822-debt-series-deletes"
create "$NEW"
ck "ambiguous: refuses" "1" "$RC"
ck_err "ambiguous: lists the first candidate" "  $OLD"
ck_err "ambiguous: lists the second candidate" "  rosskevin/bf-2822-debt-series-deletes"
ck "ambiguous: creates no worktree" "no" "$([ -d "$WT" ] && echo yes || echo no)"
ck "ambiguous: mints no branch" "no" "$(has_ref "$NEW")"

# --- branches that are not this issue's earlier work are never adopted ---
mkrepo recovered
git -C "$REPO" branch "$OLD-recovered"
create "$NEW"
ck "recovered: finish-recover.sh's branch is left to it" "$NEW" "$(kv BRANCH)"
ck "recovered: forks fresh" "1" "$(kv CREATED_WT)"
ck "recovered: the recovered branch is untouched" "$(git -C "$REPO" rev-parse main)" "$(git -C "$REPO" rev-parse "$OLD-recovered")"

# A shared numeric prefix (bf-282 vs bf-2822) is a different issue. With the bf-2822 branch the only one under the user,
# the candidate loop's last iteration is a non-match, the shape that would abort a `while … && printf` under pipefail.
mkrepo prefix
git -C "$REPO" branch "$OLD"
create "rosskevin/bf-282-something" BF-282 bf-282 .claude/worktrees/bf-282
ck "prefix: succeeds" "0" "$RC"
ck "prefix: bf-282 does not adopt a bf-2822 branch" "rosskevin/bf-282-something" "$(kv BRANCH)"

mkrepo otheruser
git -C "$REPO" branch "someoneelse/bf-2822-debt-series-and-debt-event-deletes-show"
create "$NEW"
ck "otheruser: another user's branch of the issue is not adopted" "$NEW" "$(kv BRANCH)"

# The reuse guard still refuses a worktree another issue's branch has taken over: that is the clobber it exists to catch.
mkrepo foreign
git -C "$REPO" worktree add -q "$WTREL" -b rosskevin/bf-2833-some-other-issue
create "$NEW"
ck "foreign: refuses" "1" "$RC"
ck_err "foreign: names the branch it found" "exists but is on 'rosskevin/bf-2833-some-other-issue'"

# --- setup: BRANCH= is the branch create resolved, not the one setup composed from the title ---
# A scratch HOME keeps the lock (with-repo-lock.py expands ~) and the reaper registry out of the real ~/.claude. The stub
# answers with BF-2822's live `issues get` payload, cut to the fields setup reads, so the 40-character title cut runs too.
mkrepo setup
create "$OLD"; park
SHIM="$WORK/shim"; mkdir -p "$SHIM" "$WORK/home"
cat > "$SHIM/linear-cli" <<'SHIM_EOF'
#!/bin/bash
[ "$1 $2" = "issues get" ] || exit 1
echo '{"title":"Debt series deletes on the payment book show raw transport text for a refused or unconfirmed delete and never re-read the list","state":{"name":"Done"},"assignee":{"email":"assignee@example.com"}}'
SHIM_EOF
printf '#!/bin/bash\necho rosskevin\n' > "$SHIM/gh"
chmod +x "$SHIM/linear-cli" "$SHIM/gh"
OUT=$(cd "$REPO" && env HOME="$WORK/home" PATH="$SHIM:$PATH" CLAUDE_SESSION_ID=sess-A bash "$DIR/start-wt-setup.sh" BF-2822 2>"$WORK/err"); RC=$?
ERR=$(cat "$WORK/err")
ck "setup: the retitled resume succeeds" "0" "$RC"
ck_err "setup: the stubbed title composes the post-retitle name" "the current title composes '$NEW'"
ck "setup: BRANCH= names the existing branch" "$OLD" "$(kv BRANCH)"
ck "setup: no branch is minted from the new title" "no" "$(has_ref "$NEW")"

echo "--- start-wt-create.test.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
