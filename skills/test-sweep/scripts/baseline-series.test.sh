#!/usr/bin/env bash
# Functional suite for baseline-series.sh — the /test-sweep growth-rate series. Drives the real script against fixture repos and
# fixture baseline records: which record stands for a commit (the clean one, else the latest dirty one), what the CLEAN/DIRTY-FALLBACK
# line says, and when the per-week figure is withheld.
#
# GROW THIS SUITE, NEVER PRUNE IT. A hole found in the series belongs below as a case, added WITH the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/baseline-series.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null 2>&1 || { echo "baseline-series.test: jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "baseline-series.test: git is required" >&2; exit 2; }

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}
ckno() { # ckno <label> <unexpected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then fail=$((fail+1)); echo "  FAIL  $1"; echo "        must not contain: $2"; echo "        got    $3"
  else pass=$((pass+1)); echo "  PASS  $1"; fi
}
ckrc() { # ckrc <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (exit want $2, got $3)"; fi
}

# mkrepo_dated <name> <iso committer dates...> — a repo with one commit per date; SHAS/TREES hold them oldest first, CACHE the baseline dir
mkrepo_dated() {
  local name="$1" d i=0; shift
  R="$ROOT/$name"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  SHAS=(); TREES=()
  for d in "$@"; do
    i=$((i + 1))
    echo "$i" > "$R/f"
    git -C "$R" add -A
    GIT_COMMITTER_DATE="$d" GIT_AUTHOR_DATE="$d" git -C "$R" commit -q -m "c$i"
    SHAS+=("$(git -C "$R" rev-parse HEAD)")
    TREES+=("$(git -C "$R" rev-parse 'HEAD^{tree}')")
  done
  CACHE="$R/.git/suite-baselines/rspec"
  mkdir -p "$CACHE"
  N=0
}
rec() { # rec <commit> <key|-> <examples> <recorded_at> — key "-" omits the field
  N=$((N + 1))
  if [ "$2" = "-" ]; then
    jq -n --arg c "$1" --arg n "$3" --arg at "$4" '{suite: "rspec", commit: $c, recorded_at: $at, summary: "rspec: \($n) examples / 0 failures / 8 of 8 workers"}' > "$CACHE/r$N.json"
  else
    jq -n --arg c "$1" --arg k "$2" --arg n "$3" --arg at "$4" '{suite: "rspec", key: $k, commit: $c, recorded_at: $at, summary: "rspec: \($n) examples / 0 failures / 8 of 8 workers"}' > "$CACHE/r$N.json"
  fi
}
run() { out=$(bash "$SCRIPT" --repo "$R" --suite rspec --days 0 2>&1); rc=$?; }

echo "== one record per commit: the clean one, else the latest dirty one =="
mkrepo_dated clean "2026-09-01T12:00:00Z" "2026-09-04T12:00:00Z" "2026-09-08T12:00:00Z" "2026-09-12T12:00:00Z"
rec "${SHAS[0]}" "${TREES[0]}" 100 2026-10-01T10:00:00Z
rec "${SHAS[0]}" "dirty-a" 90 2026-10-01T11:00:00Z
rec "${SHAS[1]}" "dirty-b" 190 2026-10-01T10:00:00Z
rec "${SHAS[1]}" "dirty-c" 200 2026-10-01T12:00:00Z
rec "${SHAS[2]}" "-" 300 2026-10-01T10:00:00Z
rec "${SHAS[3]}" "${TREES[3]}" 390 2026-10-01T10:00:00Z
rec "${SHAS[3]}" "${TREES[3]}" 400 2026-10-01T13:00:00Z
rec "${SHAS[3]}" "dirty-d" 410 2026-10-01T14:00:00Z
run
ckrc "a series prints" 0 "$rc"
ck "a later dirty record does not displace the clean one" "SERIES 2026-10-01T10:00:00Z 100 ${SHAS[0]:0:10}" "$out"
ck "a commit with only dirty records keeps the latest" "SERIES 2026-10-01T12:00:00Z 200 ${SHAS[1]:0:10}" "$out"
ck "a record with no key is a dirty fallback" "SERIES 2026-10-01T10:00:00Z 300 ${SHAS[2]:0:10}" "$out"
ck "of two clean records the latest wins" "SERIES 2026-10-01T13:00:00Z 400 ${SHAS[3]:0:10}" "$out"
ck "every dropped record is a duplicate" "SKIPPED 4 duplicate-commit" "$out"
ck "the clean and fallback counts are reported" "CLEAN 2 DIRTY-FALLBACK 2" "$out"
ck "four points over eleven days give a per-week figure" "points=4" "$out"
ckno "the per-week figure is not withheld" "per-week=-" "$out"

echo "== a commit that is not in the repository, and a tree that cannot be matched =="
rec 0000000000000000000000000000000000000000 "${TREES[0]}" 999 2026-10-01T15:00:00Z
run
ck "a record of a commit outside the history is skipped" "SKIPPED 1 not-first-parent" "$out"
ckno "its count never reaches the series" " 999 " "$out"
ck "the counts are unchanged by it" "CLEAN 2 DIRTY-FALLBACK 2" "$out"

echo "== a commit whose records are all dirty and keyless reads as a fallback, never a crash =="
mkrepo_dated keyless "2026-09-01T12:00:00Z"
rec "${SHAS[0]}" "-" 50 2026-10-01T10:00:00Z
run
ckrc "a lone keyless record still prints a series" 0 "$rc"
ck "it is a fallback" "CLEAN 0 DIRTY-FALLBACK 1" "$out"
ck "its per-week figure is withheld" "per-week=-" "$out"

echo "== the per-week figure is withheld when it would extrapolate nothing =="
mkrepo_dated close "2026-09-01T12:00:00Z" "2026-09-01T12:05:00Z" "2026-09-01T12:10:00Z"
rec "${SHAS[0]}" "${TREES[0]}" 100 2026-10-01T10:00:00Z
rec "${SHAS[1]}" "${TREES[1]}" 200 2026-10-01T11:00:00Z
rec "${SHAS[2]}" "${TREES[2]}" 300 2026-10-01T12:00:00Z
run
ck "three commits inside one day have no per-week" "per-week=- points=3" "$out"
ck "the per-commit figure still prints" "per-commit=100" "$out"
mkrepo_dated two "2026-09-01T12:00:00Z" "2026-09-20T12:00:00Z"
rec "${SHAS[0]}" "${TREES[0]}" 100 2026-10-01T10:00:00Z
rec "${SHAS[1]}" "${TREES[1]}" 200 2026-10-01T11:00:00Z
run
ck "two points however far apart have no per-week" "per-week=- points=2" "$out"
mkrepo_dated spread "2026-09-01T12:00:00Z" "2026-09-08T12:00:00Z" "2026-09-15T12:00:00Z"
rec "${SHAS[0]}" "${TREES[0]}" 100 2026-10-01T10:00:00Z
rec "${SHAS[1]}" "${TREES[1]}" 200 2026-10-01T11:00:00Z
rec "${SHAS[2]}" "${TREES[2]}" 300 2026-10-01T12:00:00Z
run
ck "three commits a week apart give 100 a week" "per-week=100 points=3" "$out"

echo "== no usable record =="
mkrepo_dated empty "2026-09-01T12:00:00Z"
run
ck "an empty cache reports nothing kept" "CLEAN 0 DIRTY-FALLBACK 0" "$out"
ckno "and prints no series" "SERIES" "$out"
ckrc "and exits 1" 1 "$rc"
rm -rf "$CACHE"
run
ck "a repository with no cache directory has no baselines" "NO-BASELINES" "$out"

echo
echo "baseline-series: $pass passed, $fail failed"
[ "$fail" = 0 ]
