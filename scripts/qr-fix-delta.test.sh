#!/usr/bin/env bash
# Functional suite for qr-fix-delta.sh — the /quality-review snapshot-and-delta recipe as a script.
#
# WHY THIS SUITE EXISTS. The recipe lived as a hand-typed compound command (`rm -rf … && for file in
# ${(f)"$(git status …)"}; do cp …; done`) that the Bash tool refuses: the 2026-11-06 bf-2982 retro counted
# the built-in rm safety check refusing it in 11 sessions since 2026-10-25, with the diff step tripping the
# worktree guard's no-`$(…)` rule the same way, after which each review improvised its own helper script.
# What the script must get right is exactly what the hand-typed form got wrong on its good days: derive the
# dirty set rather than predict it, keep paths with spaces and renames intact (`cut -c4-` breaks both), clear
# the issue-scoped base every time, and tell a path the snapshot holds from one it never saw.
#
# Fixtures are real: a `git init` repo driven into every porcelain status class the recipe meets, and a real
# linked worktree for the root-resolution case — `--show-toplevel` only differs from the main checkout inside
# one, so a plain-clone run would make that assertion vacuous. Snapshotted against git 2.51.2 on 2026-11-06.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/qr-fix-delta.sh"
pass=0; fail=0

ck() { # ck <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # has <desc> <needle> <haystack-file>
  if grep -Fq -- "$2" "$3"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n         missing: %s\n         in: %s\n' "$1" "$2" "$3"; fi
}
lacks() { # lacks <desc> <needle> <haystack-file>
  if grep -Fq -- "$2" "$3"; then fail=$((fail+1)); printf '  FAIL %s\n         unexpected: %s\n         in: %s\n' "$1" "$2" "$3"
  else pass=$((pass+1)); printf '  ok   %s\n' "$1"; fi
}

root=$(mktemp -d "${TMPDIR:-/tmp}/qrfd-test-XXXXXX")
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd -P)   # git prints canonical paths; macOS mktemp hands back the /var symlink form

repo="$root/repo"
mkdir -p "$repo/app" "$repo/lib" "$repo/doc"
git -C "$repo" init -q || { echo "git init failed"; exit 1; }
git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
printf 'a1\na2\n' > "$repo/app/a.rb"
printf 'b1\n' > "$repo/app/b.rb"
printf 'c1\n' > "$repo/app/c.rb"
printf 'old\n' > "$repo/lib/old.rb"
printf 'd1\n' > "$repo/doc/d.md"
printf 's1\n' > "$repo/app/space name.rb"
git -C "$repo" add -A; git -C "$repo" commit -qm seed

# ---- the implementation's own dirtiness, one of each status class -----------------------------------
printf 'a1\na2\nimpl\n' > "$repo/app/a.rb"                   # ' M' unstaged modification
printf 'b1\nimpl\n' > "$repo/app/b.rb"; git -C "$repo" add app/b.rb   # 'M ' staged modification
printf 'new impl\n' > "$repo/app/new_impl.rb"                # '??' untracked
rm "$repo/doc/d.md"                                          # ' D' deleted
git -C "$repo" mv lib/old.rb lib/new.rb; printf 'old\nmoved\n' > "$repo/lib/new.rb"   # 'RM' rename + edit
printf 's1\nimpl\n' > "$repo/app/space name.rb"              # a path with a space
mkdir -p "$repo/app/sub"; printf 'x\n' > "$repo/app/sub/x.rb" # untracked inside an untracked directory
mkdir -p "$repo/tmp"; printf 'scratch\n' > "$repo/tmp/scratch.txt"   # must be excluded

echo "# dirty"
( cd "$repo" && "$SCRIPT" dirty ) > "$root/dirty.out" 2>"$root/dirty.err"
ck "dirty exits 0" 0 $?
ck "dirty lists the seven dirty paths outside tmp/" 7 "$(wc -l < "$root/dirty.out" | tr -d ' ')"
has "dirty keeps the spaced path whole" "app/space name.rb" "$root/dirty.out"
has "dirty names a rename by its new path" "lib/new.rb" "$root/dirty.out"
lacks "dirty omits the rename's old path" "lib/old.rb" "$root/dirty.out"
lacks "dirty excludes tmp/" "tmp/scratch.txt" "$root/dirty.out"
ck "dirty -0 is NUL-terminated" 7 "$( (cd "$repo" && "$SCRIPT" dirty -0) | tr -cd '\0' | wc -c | tr -d ' ')"

echo "# snapshot"
base="$repo/tmp/qr-fix-base-bf-3071-1"
mkdir -p "$base/stale"; printf 'other issue\n' > "$base/stale/leftover.rb"   # a stale base from an earlier run
( cd "$repo/app" && "$SCRIPT" snapshot BF-3071 1 ) > "$root/snap.out" 2>"$root/snap.err"
ck "snapshot exits 0 from a subdirectory" 0 $?
ck "snapshot summary" "snapshot: 6 file(s) copied, 1 deleted path(s) recorded -> $base" "$(cat "$root/snap.out")"
ck "issue id is lowercased into the directory name" yes "$([ -d "$base" ] && echo yes || echo no)"
ck "a stale base is cleared first" gone "$([ -e "$base/stale/leftover.rb" ] && echo present || echo gone)"
ck "unstaged modification copied with its content" "a1 a2 impl" "$(tr '\n' ' ' < "$base/app/a.rb" | sed 's/ $//')"
ck "staged modification copied" yes "$([ -f "$base/app/b.rb" ] && echo yes || echo no)"
ck "untracked file copied" yes "$([ -f "$base/app/new_impl.rb" ] && echo yes || echo no)"
ck "file inside an untracked directory copied" yes "$([ -f "$base/app/sub/x.rb" ] && echo yes || echo no)"
ck "spaced path copied" yes "$([ -f "$base/app/space name.rb" ] && echo yes || echo no)"
ck "renamed file copied under its new path" yes "$([ -f "$base/lib/new.rb" ] && echo yes || echo no)"
ck "tmp/ is not copied" no "$([ -e "$base/tmp/scratch.txt" ] && echo yes || echo no)"
ck "deleted path recorded in the manifest" "D doc/d.md" "$(tr '\0' ' ' < "$base/.qr-manifest" | grep -o 'D doc/d.md')"

echo "# delta before any fix"
( cd "$repo" && "$SCRIPT" delta bf-3071 1 ) > "$root/d0.out" 2>"$root/d0.err"
ck "empty delta exits 0" 0 $?
ck "empty delta prints nothing on stdout" 0 "$(wc -c < "$root/d0.out" | tr -d ' ')"
has "empty delta says so on stderr" "delta: empty" "$root/d0.err"

# ---- the cycle's fixes ----------------------------------------------------------------------------
printf 'a1\na2\nimpl\nfix line\n' > "$repo/app/a.rb"       # edit a snapshotted file
git -C "$repo" show HEAD:app/b.rb > "$repo/app/b.rb"       # revert a snapshotted file's worktree copy
printf 'fix new\n' > "$repo/app/fix_new.rb"               # new untracked file, unseen by the snapshot
printf 'c1\nfix\n' > "$repo/app/c.rb"                      # tracked, clean at snapshot, modified now
rm "$repo/app/new_impl.rb"                                 # snapshotted untracked file deleted
printf 'd back\n' > "$repo/doc/d.md"                       # deleted at snapshot, recreated now
printf 'junk\n' > "$repo/tmp/more.txt"                     # tmp/ churn must stay invisible

echo "# delta after fixes"
( cd "$repo" && "$SCRIPT" delta bf-3071 1 ) > "$root/d1.out" 2>"$root/d1.err"
ck "delta exits 0" 0 $?
has "edited file diffs snapshot -> tree with a/ b/ labels" "--- a/app/a.rb" "$root/d1.out"
has "edited file's b/ label" "+++ b/app/a.rb" "$root/d1.out"
has "edited file's added line" "+fix line" "$root/d1.out"
lacks "edited file's pre-fix implementation line is not in the delta as a change" "+impl" "$root/d1.out"
has "reverted file shows the reversion" "-impl" "$root/d1.out"
has "deleted snapshotted file diffs to /dev/null" "+++ /dev/null" "$root/d1.out"
has "deleted snapshotted file's content removed" "-new impl" "$root/d1.out"
has "recreated path diffs from /dev/null" "+++ b/doc/d.md" "$root/d1.out"
has "new untracked file diffs from /dev/null" "+++ b/app/fix_new.rb" "$root/d1.out"
has "clean-at-snapshot tracked file falls back to git diff HEAD" "+++ b/app/c.rb" "$root/d1.out"
has "fallback hunk carries only the post-snapshot change" "+fix" "$root/d1.out"
lacks "unchanged snapshotted rename is absent" "lib/new.rb" "$root/d1.out"
lacks "unchanged spaced path is absent" "space name" "$root/d1.out"
lacks "tmp/ churn is absent" "tmp/" "$root/d1.out"
has "summary counts files" "delta: 6 file(s)," "$root/d1.err"
has "summary names the fallback set" "fallback (clean at snapshot, diffed against HEAD): app/c.rb app/fix_new.rb" "$root/d1.err"
ck "summary line count matches stdout" "$(wc -l < "$root/d1.out" | tr -d ' ')" "$(sed -n 's/.* \([0-9]*\) line(s).*/\1/p' "$root/d1.err")"

echo "# delta --out"
( cd "$repo" && "$SCRIPT" delta bf-3071 1 --out "$repo/tmp/qr-fix-delta-bf-3071-1.diff" ) > "$root/d2.out" 2>"$root/d2.err"
ck "--out exits 0" 0 $?
ck "--out writes the same delta" "$(cat "$root/d1.out")" "$(cat "$repo/tmp/qr-fix-delta-bf-3071-1.diff")"
ck "--out leaves stdout empty" 0 "$(wc -c < "$root/d2.out" | tr -d ' ')"
has "--out summary names the file" "-> $repo/tmp/qr-fix-delta-bf-3071-1.diff" "$root/d2.err"

echo "# arguments"
( cd "$repo" && "$SCRIPT" snapshot no-issue deferred ) > /dev/null 2>&1; ck "no-issue + deferred accepted" 0 $?
ck "no-issue/deferred directory" yes "$([ -d "$repo/tmp/qr-fix-base-no-issue-deferred" ] && echo yes || echo no)"
( cd "$repo" && "$SCRIPT" snapshot bf-1 corrective ) > /dev/null 2>&1; ck "corrective accepted" 0 $?
( cd "$repo" && "$SCRIPT" snapshot bf-3071 x ) > /dev/null 2>"$root/arg1.err"; ck "bad cycle exits 2" 2 $?
has "bad cycle names the rule" "cycle must be an integer, deferred or corrective" "$root/arg1.err"
( cd "$repo" && "$SCRIPT" snapshot "../../etc" 1 ) > /dev/null 2>"$root/arg2.err"; ck "path-shaped issue exits 2" 2 $?
has "path-shaped issue names the rule" "issue must be a Linear id" "$root/arg2.err"
( cd "$repo" && "$SCRIPT" snapshot ) > /dev/null 2>&1; ck "missing arguments exit 2" 2 $?
( cd "$repo" && "$SCRIPT" ) > /dev/null 2>&1; ck "no subcommand exits 2" 2 $?
( cd "$repo" && "$SCRIPT" delta bf-9999 1 ) > /dev/null 2>"$root/arg3.err"; ck "delta without a snapshot exits 2" 2 $?
has "delta without a snapshot says to take one first" "take it with 'snapshot' before the cycle's fixes land" "$root/arg3.err"
( cd "$repo" && "$SCRIPT" delta bf-3071 1 --bogus ) > /dev/null 2>&1; ck "unknown delta flag exits 2" 2 $?
( cd "$root" && "$SCRIPT" snapshot bf-1 1 ) > /dev/null 2>"$root/arg4.err"; ck "outside a repo exits 2" 2 $?
has "outside a repo says so" "not inside a git repository" "$root/arg4.err"

echo "# linked worktree"
wt="$root/wt-bf-500"
git -C "$repo" worktree add -q -b bf-500 "$wt" HEAD >/dev/null 2>&1 || { echo "worktree add failed"; exit 1; }
printf 'wt edit\n' >> "$wt/app/c.rb"
( cd "$wt/app" && "$SCRIPT" snapshot bf-500 1 ) > "$root/wt.out" 2>&1
ck "snapshot from a worktree subdirectory exits 0" 0 $?
ck "snapshot lands in the worktree's tmp/, not the main checkout's" yes "$([ -f "$wt/tmp/qr-fix-base-bf-500-1/app/c.rb" ] && echo yes || echo no)"
ck "main checkout's tmp/ has no bf-500 base" no "$([ -e "$repo/tmp/qr-fix-base-bf-500-1" ] && echo yes || echo no)"
printf 'wt fix\n' >> "$wt/app/c.rb"
( cd "$wt" && "$SCRIPT" delta bf-500 1 ) > "$root/wtd.out" 2>"$root/wtd.err"
ck "delta in the worktree exits 0" 0 $?
has "worktree delta carries the fix line" "+wt fix" "$root/wtd.out"
lacks "worktree delta omits the pre-snapshot edit as a change" "+wt edit" "$root/wtd.out"

echo
echo "qr-fix-delta: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
