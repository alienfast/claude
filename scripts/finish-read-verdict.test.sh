#!/usr/bin/env bash
# Regression suite for finish-read-verdict.sh's staleness gate: a verdict older than HEAD is stale unless every path
# committed since it sits under .claude/.
#
# WHY THIS SUITE EXISTS. The carve-out test ran `printf … | grep -qv` under pipefail, so on a path list larger than the
# pipe buffer grep exited at the first outside path, printf died of SIGPIPE, and the negated pipeline read the window as
# .claude/-only: the gate answered "not stale" for exactly the largest post-verdict changes (measured 2026-11-12, a
# 1,200-file commit). A small fixture can never show that, so the large arms here build a window past the buffer and
# assert its size before trusting the answer.
#
# Fixtures are real `git init` repos with a verdict file back-dated before the commits under test. `linear-cli` is
# stubbed, and HOME is redirected so the script's own `~/.cargo/bin` PATH prefix cannot reach the real one.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/finish-read-verdict.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}

BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/home"
printf '#!/usr/bin/env bash\necho "{}"\n' > "$BIN/linear-cli"
chmod +x "$BIN/linear-cli"

PIPE_BUFFER=65536
OUTSIDE=apps/a-long-directory-name-for-width/another-level-of-nesting
INSIDE=.claude/rules/a-long-directory-name-for-width/another-level-of-nesting

mk_repo() { # mk_repo <name> → prints the path of a repo whose TT-1 verdict predates every commit made after this call
  local repo="$WORK/$1"
  mkdir -p "$repo/tmp"
  git -C "$repo" init -q
  echo 'tmp/' >> "$repo/.git/info/exclude"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'Verdict: passed-clean\nCycles: 1\n' > "$repo/tmp/quality-review-verdict-tt-1.md"
  touch -t 202501010000 "$repo/tmp/quality-review-verdict-tt-1.md"
  printf '%s' "$repo"
}
commit_files() { # commit_files <repo> <dir> <count> — one commit adding <count> files under <dir>
  local repo="$1" dir="$2" n="$3" i=0
  mkdir -p "$repo/$dir"
  while [ "$i" -lt "$n" ]; do echo x > "$repo/$dir/file-number-$i-with-a-long-name-for-width.ts"; i=$((i+1)); done
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "after the verdict: $n under $dir"
}
field() { # field <repo> <KEY> → the script's KEY=value answer for TT-1
  ( cd "$1" && HOME="$WORK/home" PATH="$BIN:$PATH" "$SCRIPT" TT-1 2>/dev/null ) | sed -n "s/^$2=//p"
}
past_buffer() { # past_buffer <repo> → 1 when the post-verdict path list is larger than the pipe buffer
  local bytes
  bytes=$(git -C "$1" log --since=@1 --name-only --format='' HEAD | sed '/^$/d' | sort -u | wc -c | tr -d ' ')
  echo $(( bytes > PIPE_BUFFER ))
}

# ---- a verdict written after the last commit is current ----
repo=$(mk_repo fresh)
commit_files "$repo" "$OUTSIDE" 3
touch "$repo/tmp/quality-review-verdict-tt-1.md"
ck "the verdict is parsed"              "passed-clean" "$(field "$repo" VERDICT)"
ck "a verdict newer than HEAD is current" "0" "$(field "$repo" VERDICT_STALE)"

# ---- commits after the verdict: stale, unless every path is under .claude/ ----
repo=$(mk_repo small-outside)
commit_files "$repo" "$OUTSIDE" 3
ck "a change outside .claude/ is stale" "1" "$(field "$repo" VERDICT_STALE)"

repo=$(mk_repo small-inside)
commit_files "$repo" "$INSIDE" 3
ck "a .claude/-only change is not stale" "0" "$(field "$repo" VERDICT_STALE)"

repo=$(mk_repo mixed)
commit_files "$repo" "$INSIDE" 3
commit_files "$repo" zz-sorts-last 1
ck "one outside path among .claude/ ones is stale" "1" "$(field "$repo" VERDICT_STALE)"

# ---- the same answers on a path list larger than the pipe buffer ----
repo=$(mk_repo large-outside)
commit_files "$repo" "$OUTSIDE" 1200
ck "the large window is past the pipe buffer" "1" "$(past_buffer "$repo")"
ck "a large change outside .claude/ is stale" "1" "$(field "$repo" VERDICT_STALE)"

repo=$(mk_repo large-inside)
commit_files "$repo" "$INSIDE" 1200
ck "the large .claude/ window is past the pipe buffer" "1" "$(past_buffer "$repo")"
ck "a large .claude/-only change is not stale" "0" "$(field "$repo" VERDICT_STALE)"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
