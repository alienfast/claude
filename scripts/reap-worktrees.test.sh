#!/usr/bin/env bash
# Functional suite for reap-worktrees.sh — the completion-evidence and liveness gates that decide whether
# a /start wt worktree is destroyed. Builds throwaway repos with real linked worktrees and drives the real
# script end to end (so `reap` also exercises the with-repo-lock.py re-exec, which is unconditional).
#
# GROW THIS SUITE, NEVER PRUNE IT. This script deletes work; every hole ever found in its gates belongs
# below as a case, added WITH the fix. The PL-459 case in particular is not a hypothetical — the reaper
# once removed a live, freshly-forked worktree, and its session's edits then landed in the main checkout.
#
# TWO ENVIRONMENT FACTS THE CASES DEPEND ON, both easy to get silently wrong:
#   • extensions.worktreeConfig must be on, exactly as start-wt-setup.sh does it. Without it
#     `git config --worktree` fails outright, no start.baseline-sha is recorded, and the zero-commit guard
#     no-ops — every zero-commit case then falls through to "branch merged" and passes for the wrong reason.
#   • HOME is faked. linear_state_type() prepends $HOME/.cargo/bin to PATH, so the REAL linear-cli outranks
#     a stub placed anywhere else and every issue state resolves against live Linear. $HOME/.cargo/bin IS
#     the stub dir here; $HOME/.claude symlinks to the real one so $SELF, with-repo-lock.py, and
#     wt-identity.sh still resolve. Cases pass an explicit repo arg, so the repo registries are never read.

set -uo pipefail

REAL_HOME="$HOME"
SCRIPT="$REAL_HOME/.claude/scripts/reap-worktrees.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/home/.cargo/bin"; mkdir -p "$BIN"
ln -s "$REAL_HOME/.claude" "$ROOT/home/.claude"
export HOME="$ROOT/home"

# Stub linear-cli: the issue's state type is whatever the file named after the issue id holds.
cat > "$BIN/linear-cli" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in id=*) issue="${a#id=}" ;; esac; done
printf '{"data":{"issue":{"state":{"type":"%s"}}}}' "$(cat "$LINEAR_STUB_DIR/$issue" 2>/dev/null || true)"
EOF
# Stub gh: never a merged PR, so the Linear tier is what decides in the cases below.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/linear-cli" "$BIN/gh"
export LINEAR_STUB_DIR="$ROOT/linear"; mkdir -p "$LINEAR_STUB_DIR"

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}

# build_case <name> <issue> <linear-state> <commits:0|1> <dirty:0|1> <age:fresh|idle> → repo path
# age=idle backdates the worktree's index so liveness guard B sees no session; fresh leaves it now.
build_case() {
  local name="$1" issue="$2" state="$3" commits="$4" dirty="$5" age="$6"
  local repo="$ROOT/$name" slug wt base
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$repo" config extensions.worktreeConfig true   # start-wt-setup.sh does this in the real flow
  printf '%s' "$state" > "$LINEAR_STUB_DIR/$issue"
  slug=$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')
  wt="$repo/.claude/worktrees/$slug"
  git -C "$repo" worktree add -q -b "user/$slug" "$wt" main
  base=$(git -C "$repo" rev-parse main)
  git -C "$wt" config --worktree start.source-branch main
  git -C "$wt" config --worktree start.baseline-sha "$base"
  [ "$commits" = 1 ] && { echo x > "$wt/f"; git -C "$wt" add f
    git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m work; }
  [ "$dirty" = 1 ] && echo scratch > "$wt/untracked"
  [ "$age" = idle ] && touch -t 200001010000 "$(git -C "$wt" rev-parse --absolute-git-dir)/index"
  printf '%s' "$repo"
}

echo "== zero-commit worktrees: terminal issue is evidence, a trivial 'merged' is not =="

# The leak this path exists to close: /start wt forks a worktree, the issue is canceled in Linear before
# the first commit, and no /start session is left to surface cleanup. Nothing else reclaims it.
r=$(build_case canceled_zero BF-901 canceled 0 0 idle)
ck "zero-commit + canceled + idle + clean → eligible" \
   'REAP-ELIGIBLE.*canceled, no commits' "$($SCRIPT list "$r" 2>&1)"

r=$(build_case dup_zero BF-905 duplicate 0 0 idle)
ck "zero-commit + duplicate (a terminal type too) → eligible" \
   'REAP-ELIGIBLE.*duplicate' "$($SCRIPT list "$r" 2>&1)"

# The PL-459 failure itself: a zero-commit branch is TRIVIALLY an ancestor of its source, so "branch
# merged" alone must never reap one — that fired on a worktree whose session had just set it up.
r=$(build_case active_zero BF-902 started 0 0 idle)
ck "zero-commit + issue active → KEEP despite the trivial merge" \
   'KEEP — no commits since baseline (just-forked' "$($SCRIPT list "$r" 2>&1)"

# Terminal issue is not sufficient on its own — both liveness guards still apply.
r=$(build_case fresh_zero BF-903 canceled 0 0 fresh)
ck "zero-commit + canceled but index FRESH → KEEP (guard B holds)" \
   'KEEP — active within' "$($SCRIPT list "$r" 2>&1)"

r=$(build_case dirty_zero BF-904 canceled 0 1 idle)
ck "zero-commit + canceled + DIRTY → KEEP (untracked work is never destroyed)" \
   'KEEP — no commits since baseline and the worktree is dirty' "$($SCRIPT list "$r" 2>&1)"

echo "== worktrees with commits: unchanged by the zero-commit path =="

r=$(build_case unmerged BF-906 started 1 0 idle)
ck "commits + issue active + unmerged → KEEP" \
   'KEEP — active (not merged' "$($SCRIPT list "$r" 2>&1)"

# Terminal evidence does not override the unsaved-commits gate. Guards against the zero_commit shortcut
# in that gate leaking onto branches that DO have commits of their own.
r=$(build_case unpushed BF-907 canceled 1 0 idle)
ck "commits + canceled + local-only commits → KEEP, reported for manual resolution" \
   'local-only commits' "$($SCRIPT list "$r" 2>&1)"

echo "== reap mode removes what list called eligible =="

r=$(build_case reap_zero BF-908 canceled 0 0 idle)
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the worktree" 'REAPED' "$out"
ck "worktree directory is gone" GONE \
   "$([ -d "$r/.claude/worktrees/bf-908" ] && echo PRESENT || echo GONE)"
ck "branch is deleted" NOBRANCH \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-908 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"

echo
echo "reap-worktrees: $pass passed, $fail failed"
[ "$fail" = 0 ]
