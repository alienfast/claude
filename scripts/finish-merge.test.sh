#!/usr/bin/env bash
# Functional suite for finish-merge.sh's generated-artifact discard guard (assert_no_ours_discards)
# plus the merge/conflict seams around it. Builds throwaway repos with real linked worktrees and drives
# the real script end to end — including its unconditional with-repo-lock.py re-exec.
#
# The guard exists because a merge=ours driver on generated files (schema.json, codegen outputs,
# db/schema.rb) resolves a two-sided change by silently KEEPING the worktree branch's copy: a sibling
# issue's regenerated hunks are dropped from the shared branch with no conflict, every worktree forked
# afterwards inherits a red baseline, and CI can only rebuild derived outputs from the committed root
# artifact. The guard is content-based and audits every merge commit on the worktree branch, so it also
# catches a manual mid-issue `git merge <source>` that baked the loss before /finish ran.
#
# GROW THIS SUITE, NEVER PRUNE IT. Add the case WITH the fix; never delete one to "clean up".
#
# ENVIRONMENT FACTS THE CASES DEPEND ON:
#   • Each fixture repo sets `merge.ours.driver = true`, exactly as the consuming repos'
#     .gitattributes header prescribes. Without the config the driver named in .gitattributes is
#     undefined and git falls back to a normal text merge — the discard cases then CONFLICT instead of
#     silently keeping ours, and case 2 fails loudly on the wrong message rather than passing vacuously.
#   • Fixture worktrees are unstamped, so finish-merge.sh's wt-identity tier skips itself
#     (wt_identity_load fails → no corruption gate interferes with the cases).
#   • Every finish-merge.sh invocation re-execs under with-repo-lock.py, which keys a lock file on the
#     fixture repo and never deletes it — reclaim_locks below unlinks only locks whose recorded key
#     resolves inside THIS run's workspace, since parallel sessions hold live locks in the same shared
#     ~/.claude/locks/.
#   • No case may exit 3: that path self-enqueues to the merge queue under the REAL $HOME (registering
#     the fixture repo in merge-queue-repos.txt). The fixtures keep the main checkout clean, off source,
#     and not mid-operation, so 3 is unreachable; a regression that produces one fails its case's
#     exit-code assertion loudly.

set -uo pipefail

# Inherited overrides would silently change what the cases prove: the lock sentinel skips the re-exec,
# the identity skip disables a gate, and the guard skip turns every discard case green.
unset _FINISH_MERGE_LOCK_PID _WITH_REPO_LOCK_HELD _WT_SKIP_IDENTITY_CHECK _FM_SKIP_OURS_GUARD

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM="$DIR/finish-merge.sh"

ROOT=$(mktemp -d)
# `cd ""` succeeds and `git -C ""` probes the invoking directory, so an empty workspace would silently
# retarget the reclaim below at the real repository's locks.
[ -n "$ROOT" ] || { echo "ERROR: mktemp -d failed; refusing an empty workspace path." >&2; exit 1; }
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
[ -n "$ROOT_PHYS" ] || { echo "ERROR: could not resolve a physical path for '$ROOT'." >&2; exit 1; }

# with-repo-lock.py keys a lock on each fixture repo and never deletes it; every run gets a fresh
# mktemp -d so the keys never repeat — unbounded growth in the shared locks dir unless reclaimed here.
# Same shape as wt-identity.test.sh's reclaim_locks: in-shell words only, one read per file, key
# re-emptied so an unreadable file cannot carry the previous file's key into its verdict.
reclaim_locks() {
  local dir=~/.claude/locks f key
  [ -n "$ROOT_PHYS" ] || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/repo-*.lock; do
    [ -f "$f" ] || continue
    key=""
    { IFS= read -r key < "$f"; } 2>/dev/null
    key=${key#*" key="}
    case "$key" in "$ROOT_PHYS"/*) rm -f "$f" 2>/dev/null || true ;; esac
  done
  return 0
}
trap 'reclaim_locks || true; rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual-text>
  if printf '%s' "$3" | grep -q -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}
ck_eq() { # ck_eq <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want = $2"; echo "        got    $3"; fi
}
ck_absent() { # ck_absent <label> <forbidden-substring> <actual-text>
  if printf '%s' "$3" | grep -q -- "$2"; then fail=$((fail+1)); echo "  FAIL  $1"; echo "        must not contain $2"
  else pass=$((pass+1)); echo "  PASS  $1"; fi
}

# mk_repo <name> — fresh main repo (on `main`) + `source` branch + linked worktree on `bf-t`.
# gen.txt carries merge=ours (the generated artifact); src.txt is an ordinary file.
mk_repo() {
  local d="$ROOT/$1"
  R="$d/repo"; WT="$d/wt"; MSG="$d/msg.md"
  mkdir -p "$d"
  git -C "$d" init -q -b main repo
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name tester
  git -C "$R" config merge.ours.driver true
  printf 'gen.txt merge=ours\n' > "$R/.gitattributes"
  printf 'g0\n' > "$R/gen.txt"
  printf 's0\n' > "$R/src.txt"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git -C "$R" branch -q source
  git -C "$R" worktree add -q -b bf-t "$WT" source
  printf 'Merge bf-t\n' > "$MSG"
}

src_commit() { # src_commit <file> <content> [<file> <content> ...] — commit on source, restore main
  git -C "$R" checkout -q source
  while [ $# -ge 2 ]; do printf '%s\n' "$2" > "$R/$1"; shift 2; done
  git -C "$R" add -A
  git -C "$R" commit -qm "source work"
  git -C "$R" checkout -q main
}

wt_commit() { # wt_commit <file> <content> [...]
  while [ $# -ge 2 ]; do printf '%s\n' "$2" > "$WT/$1"; shift 2; done
  git -C "$WT" add -A
  git -C "$WT" commit -qm "wt work"
}

run_fm() { # run_fm [VAR=val] — sets RC and OUT (combined output)
  local envpair="${1:-}"
  if [ -n "$envpair" ]; then
    OUT=$( (cd "$R" && env "$envpair" "$FM" "$WT" source bf-t "$MSG") 2>&1 ); RC=$?
  else
    OUT=$( (cd "$R" && "$FM" "$WT" source bf-t "$MSG") 2>&1 ); RC=$?
  fi
}

blob() { git -C "$R" show "source:$1" 2>/dev/null; }

echo "=== case 1: control — each side changes a different file, no driver involvement ==="
mk_repo c1
src_commit src.txt s1
wt_commit gen.txt g2
run_fm
ck_eq "exit 0" 0 "$RC"
ck_eq "source has wt's gen" g2 "$(blob gen.txt)"
ck_eq "source kept its src" s1 "$(blob src.txt)"
[ ! -d "$WT" ] && { pass=$((pass+1)); echo "  PASS  worktree removed"; } || { fail=$((fail+1)); echo "  FAIL  worktree still present"; }

echo "=== case 1b: source-only change to the generated file fast-paths in (no driver, no fire) ==="
mk_repo c1b
src_commit gen.txt g1 src.txt s1
wt_commit feat.txt f1
run_fm
ck_eq "exit 0" 0 "$RC"
ck_eq "source keeps its gen" g1 "$(blob gen.txt)"

echo "=== case 2: two-sided generated change — discard detected, then regen clears it ==="
mk_repo c2
src_commit gen.txt g1-source src.txt s1-source
wt_commit gen.txt g2-wt
run_fm
ck_eq "exit 2" 2 "$RC"
ck "GENERATED-DISCARD message" "GENERATED-DISCARD" "$OUT"
ck "names the file" "gen.txt" "$OUT"
ck_absent "not reported as a conflict" "CONFLICT:" "$OUT"
ck_eq "driver kept ours in the worktree" g2-wt "$(cat "$WT/gen.txt")"
ck_eq "merge brought source's ordinary file" s1-source "$(cat "$WT/src.txt")"
wt_commit gen.txt g3-union   # the post-merge regeneration
run_fm
ck_eq "re-run after regen: exit 0" 0 "$RC"
ck_eq "source has the regenerated union" g3-union "$(blob gen.txt)"
ck_eq "source kept its ordinary file" s1-source "$(blob src.txt)"
[ ! -d "$WT" ] && { pass=$((pass+1)); echo "  PASS  worktree removed"; } || { fail=$((fail+1)); echo "  FAIL  worktree still present"; }

echo "=== case 3: two-sided but identical content — nothing discarded, no fire ==="
mk_repo c3
src_commit gen.txt gX src.txt s1
wt_commit gen.txt gX
run_fm
ck_eq "exit 0" 0 "$RC"
ck_eq "gen content correct" gX "$(blob gen.txt)"

echo "=== case 4: manual mid-issue merge baked the discard before /finish — still caught ==="
mk_repo c4
src_commit gen.txt g1-source src.txt s1-source
wt_commit gen.txt g2-wt
git -C "$WT" merge -q --no-edit source >/dev/null 2>&1
run_fm
ck_eq "exit 2" 2 "$RC"
ck "caught the baked manual merge" "GENERATED-DISCARD" "$OUT"

echo "=== case 5: escape hatch ships a deliberate discard ==="
mk_repo c5
src_commit gen.txt g1-source src.txt s1-source
wt_commit gen.txt g2-wt
run_fm _FM_SKIP_OURS_GUARD=1
ck_eq "exit 0 under _FM_SKIP_OURS_GUARD=1" 0 "$RC"
ck_eq "discard shipped deliberately" g2-wt "$(blob gen.txt)"

echo "=== case 6: ordinary conflict path unchanged, and the guard stays silent on the resolved merge ==="
mk_repo c6
src_commit src.txt s1-source
wt_commit src.txt s1-wt
run_fm
ck_eq "exit 2" 2 "$RC"
ck "reported as a conflict" "CONFLICT" "$OUT"
ck_absent "not a discard" "GENERATED-DISCARD" "$OUT"
printf 'sR\n' > "$WT/src.txt"
git -C "$WT" add src.txt
git -C "$WT" commit -q -F "$MSG"
run_fm
ck_eq "re-run after resolution: exit 0" 0 "$RC"
ck_eq "source has the resolution" sR "$(blob src.txt)"

echo ""
echo "finish-merge.test.sh: $pass passed, $fail failed"
[ "$fail" = 0 ]
