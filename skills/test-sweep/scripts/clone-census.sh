#!/usr/bin/env bash
# clone-census.sh — list jscpd's cross-file clone pairs between test files of one suite, ranked by duplicated lines, for /test-sweep.
#
# WHY THIS EXISTS: the rspec ranker sees cost and repeated descriptions and the story census sees repeated names; neither sees a
# block pasted from one spec or story file into another, and a project's clone gate, where it has one, grandfathers every clone
# the tree already carried when the gate landed, so nothing drains the copies in the test tree. jscpd finds them in seconds. This
# runs jscpd with the project's committed configuration and baseline when present and with the skill's defaults when not, keeps
# the pairs whose two files are both test files of the same suite, folds every block a file pair shares into one candidate, and
# ranks the pairs by duplicated lines so the scan's --top cap keeps the agent cost bounded.
#
# USAGE
#   clone-census.sh --repo DIR [--out DIR] [--top N] [--min-lines N] [--jscpd PATH]
#
#   --repo DIR       the project checkout
#   --out DIR        where the jscpd report lands as test-sweep-clone-report.json (default <repo>/tmp)
#   --top N          CLONE rows per suite (default 25; 0 prints every pair)
#   --min-lines N    the clone floor when the project has no .jscpd.json (default 10); a committed config's minLines wins
#   --jscpd PATH     the jscpd executable (default: <repo>/node_modules/.bin/jscpd, else jscpd on PATH, else `pnpm dlx jscpd@5.4.1`)
#
# OUTPUT (one verdict per line)
#   JSCPD <version> config=<.jscpd.json|defaults> baseline=<file|none> seconds=<N>
#   CLONES total=<N> cross-file=<N> test-pairs=<N> new=<N> file-pairs=<N> rspec=<N> storybook=<N> e2e=<N>
#   CLONE <suite> <lines> <blocks> <fileA> <fileB>                     one file pair, most duplicated lines first, at most --top per suite
#   CLONE-BLOCK <fileA>:<start>-<end> <fileB>:<start>-<end> <lines>    every block of the pair above it
#   NO-JSCPD <detail>                                                  no jscpd could be found or fetched
#
# Suites by file name: rspec = *_spec.rb; storybook = *.stories.tsx and *.stories.shared.tsx; e2e = *.spec.ts and *.spec.tsx. A pair
# whose files sit in different suites, or one of which is no test file, is not a candidate (a story cloning production code is the
# clone gate's business), and a same-file clone is the arm-matrix idiom, never one. With a committed baseline, a pair the baseline
# does not carry (jscpd's isNew) is a gate red for its author, not a sweep candidate, and is counted under new=. total, cross-file,
# test-pairs and new count jscpd's clone pairs; file-pairs and the per-suite counts are candidates after folding.
#
# Exit 0 census printed (also with no qualifying pair), 1 jscpd unavailable, 2 usage error or a jscpd run that wrote no report.
# Requires git, jq, awk, and jscpd (or pnpm to fetch it).

set -uo pipefail
export LC_ALL=C  # paths carry UTF-8; byte-wise awk/sort cannot abort on a multibyte sequence

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "clone-census: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "clone-census: $1 needs a value" >&2; usage; exit 2; }; }

DEFAULT_IGNORE='**/node_modules/**,**/dist/**,**/__generated__/**,**/generated/**,**/.next/**,.claude/worktrees/**,tmp/**'
REPO=""; OUT=""; TOP=25; MINL=10; JSCPD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --top) need_value "$1" $#; TOP="$2"; shift 2 ;;
    --min-lines) need_value "$1" $#; MINL="$2"; shift 2 ;;
    --jscpd) need_value "$1" $#; JSCPD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "clone-census: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { usage; exit 2; }
case "$TOP" in ''|*[!0-9]*) die "--top must be a non-negative integer" ;; esac
case "$MINL" in ''|*[!0-9]*|0) die "--min-lines must be a positive integer" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"
cd "$REPO" 2>/dev/null || die "no such directory: $REPO"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git checkout: $REPO"
REPO=$(pwd -P)
[ -n "$OUT" ] || OUT="$REPO/tmp"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd) || die "cannot enter $OUT"

# The project's own install first: its clone gate keys fingerprints with that version, and a baseline only means something to it.
RUN=()
if [ -n "$JSCPD" ]; then RUN=("$JSCPD")
elif [ -x "$REPO/node_modules/.bin/jscpd" ]; then RUN=("$REPO/node_modules/.bin/jscpd")
elif command -v jscpd >/dev/null 2>&1; then RUN=(jscpd)
elif command -v pnpm >/dev/null 2>&1; then RUN=(pnpm dlx jscpd@5.4.1)
else echo "NO-JSCPD no node_modules/.bin/jscpd under $REPO, no jscpd on PATH, and no pnpm to fetch one"; exit 1; fi
version=$("${RUN[@]}" --version 2>/dev/null | tail -n 1 | awk '{ print $NF }')
[ -n "$version" ] || { echo "NO-JSCPD ${RUN[*]} --version printed nothing"; exit 1; }

CONFIG=""; BASELINE=""
[ ! -s ".jscpd.json" ] || CONFIG=".jscpd.json"
[ ! -s ".jscpd-baseline.json" ] || BASELINE=".jscpd-baseline.json"

scratch=$(mktemp -d "$OUT/test-sweep-jscpd.XXXXXX") || die "cannot create a scratch directory under $OUT"
trap 'rm -rf "$scratch"' EXIT
args=(--reporters json --output "$scratch" --silent)
if [ -n "$CONFIG" ]; then args+=(--config "$CONFIG")
else args+=(--min-lines "$MINL" --format typescript,tsx,ruby --formats-exts ruby:rb,rake --ignore "$DEFAULT_IGNORE" .); fi
[ -z "$BASELINE" ] || args+=(--baseline "$BASELINE")
t0=$(date +%s)
"${RUN[@]}" "${args[@]}" > "$scratch/jscpd.log" 2>&1
rc=$?
secs=$(( $(date +%s) - t0 ))
REPORT="$OUT/test-sweep-clone-report.json"
if [ ! -s "$scratch/jscpd-report.json" ]; then
  echo "clone-census: jscpd wrote no report (exit $rc); its last lines:" >&2
  tail -n 5 "$scratch/jscpd.log" >&2
  exit 2
fi
mv -f "$scratch/jscpd-report.json" "$REPORT" || die "cannot write $REPORT"
echo "JSCPD $version config=${CONFIG:-defaults} baseline=${BASELINE:-none} seconds=$secs"

# One row per jscpd clone: class, suite, the two files in name order (so a pair folds whichever file jscpd listed first), each
# side's line range, and the block's lines. jscpd names files relative to the single scanned path, so names are repo-relative.
# shellcheck disable=SC2016  # jq program, not shell
jq -r '
  def suite: if test("_spec\\.rb$") then "rspec"
    elif test("\\.stories(\\.shared)?\\.tsx$") then "storybook"
    elif test("\\.spec\\.tsx?$") then "e2e" else "" end;
  def rel: sub("^\\./"; "");
  (.duplicates // [])[]
  | (.firstFile.name | rel) as $a | (.secondFile.name | rel) as $b
  | ($a | suite) as $sa | ($b | suite) as $sb
  | (if $a == $b then "same" elif $sa == "" or $sa != $sb then "mixed" elif (.isNew // false) then "new" else "pair" end) as $class
  | if $a <= $b
    then [$class, $sa, $a, $b, "\(.firstFile.start)-\(.firstFile.end)", "\(.secondFile.start)-\(.secondFile.end)", (.lines | tostring)]
    else [$class, $sa, $b, $a, "\(.secondFile.start)-\(.secondFile.end)", "\(.firstFile.start)-\(.firstFile.end)", (.lines | tostring)] end
  | @tsv' "$REPORT" > "$scratch/rows.tsv" 2>/dev/null || die "$REPORT is not a jscpd JSON report"

awk -F'\t' -v OFS='\t' '
  { total++ }
  $1 == "same" { next }
  { cross++ }
  $1 == "mixed" { next }
  { testpairs++ }
  $1 == "new" { newc++; next }
  {
    k = $2 "\t" $3 "\t" $4
    if (!(k in lines)) { order[++n] = k; lines[k] = 0; blocks[k] = 0; bl[k] = "" }
    blocks[k]++; lines[k] += $7
    bl[k] = bl[k] (bl[k] == "" ? "" : ";") $3 ":" $5 " " $4 ":" $6 " " $7
  }
  END {
    for (i = 1; i <= n; i++) { k = order[i]; split(k, p, "\t"); cnt[p[1]]++; print "PAIR", p[1], lines[k], blocks[k], p[2], p[3], bl[k] }
    print "TOTALS", total + 0, cross + 0, testpairs + 0, newc + 0, n + 0, cnt["rspec"] + 0, cnt["storybook"] + 0, cnt["e2e"] + 0
  }' "$scratch/rows.tsv" > "$scratch/agg.tsv"
awk -F'\t' '$1 == "TOTALS" { printf "CLONES total=%d cross-file=%d test-pairs=%d new=%d file-pairs=%d rspec=%d storybook=%d e2e=%d\n", $2, $3, $4, $5, $6, $7, $8, $9 }' "$scratch/agg.tsv"
TAB=$(printf '\t')
grep '^PAIR' "$scratch/agg.tsv" | sort -t "$TAB" -k2,2 -k3,3nr -k4,4nr -k5,5 -k6,6 | awk -F'\t' -v top="$TOP" '
  {
    if (top > 0 && ++seen[$2] > top) next
    printf "CLONE %s %s %s %s %s\n", $2, $3, $4, $5, $6
    n = split($7, b, ";"); for (i = 1; i <= n; i++) printf "CLONE-BLOCK %s\n", b[i]
  }'
exit 0
