#!/usr/bin/env bash
# baseline-series.sh — the example-count growth rate of a suite, read from the shared full-run baseline cache, for /test-sweep.
#
# WHY THIS EXISTS: a sweep's case rests on growth — a suite that adds a few hundred examples a week outruns any one-off cleanup.
# ~/.claude/scripts/suite-baseline-cache.sh already stores one JSON per measured full run under <git common dir>/suite-baselines/<suite>/,
# with the run's example count inside `summary`; this turns those records into a series and a least-squares slope, so the growth rate
# is a measurement rather than an impression. The cache holds runs from every branch, stale base and dirty tree alike, and the same
# commit is often recorded more than once at different counts, so the series is limited to a recent window, to records whose commit
# sits on HEAD's first-parent history, and to one record per commit, and it is ordered by that history rather than by when each
# run was recorded. Each record's `key` is the hash of the working tree that was measured, so the record that counts for a commit is
# the CLEAN one — its key equals the commit's own tree — and a dirty-tree record (a post-change count recorded under the pre-change
# HEAD, which every /test-sweep apply produces) stands in only when the commit has no clean record, the latest such record winning.
# A record with no key is dirty; a commit whose tree cannot be resolved counts every record of it as dirty.
#
# USAGE
#   baseline-series.sh --repo DIR --suite NAME [--days N]
#
#   --repo DIR      the project checkout (any worktree; the cache is shared through the git common dir)
#   --suite NAME    the cache's suite name (basefund: rspec)
#   --days N        window length in days, by recorded_at (default 30); 0 means no window
#
# OUTPUT (one verdict per line)
#   SERIES <recorded_at> <examples> <commit>     one per commit, in first-parent order, oldest first
#   SKIPPED <N> <reason>                          no-count-or-date, incomplete-workers (fewer workers reporting than ran),
#                                                 not-first-parent (a commit missing or not on HEAD's first-parent history),
#                                                 outside-window, duplicate-commit (a further record of a commit, dropped for the one kept)
#   CLEAN <N> DIRTY-FALLBACK <M>                  how many series commits rest on a clean record (key equals the commit's tree) and how
#                                                 many only on a dirty-tree record because the commit has no clean one
#   WINDOW <from> <to> <N>                        the dates the window covers and the number of commits in the series
#   SLOPE per-commit=<examples/commit> per-week=<examples/week> points=<N> span=<first commit>..<last commit>
#                                                 least squares over the series, per week against commit time; "-" for a figure
#                                                 with fewer than two distinct x values (one point, or every commit in one instant);
#                                                 per-week is also "-" with fewer than 3 points or a first-to-last commit span under
#                                                 a day, where the extrapolation to a week means nothing
#
# Exit 0 series printed, 1 no cache or no usable record in the window, 2 usage or git error.
# Requires git and jq.

set -uo pipefail

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "baseline-series: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "baseline-series: $1 needs a value" >&2; usage; exit 2; }; }

REPO=""; SUITE=""; DAYS=30
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --suite) need_value "$1" $#; SUITE="$2"; shift 2 ;;
    --days) need_value "$1" $#; DAYS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "baseline-series: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$SUITE" ] || { usage; exit 2; }
case "$SUITE" in *[!A-Za-z0-9._-]*) die "invalid suite name: $SUITE" ;; esac
case "$DAYS" in ''|*[!0-9]*) die "--days must be a non-negative integer" ;; esac
[ "${#DAYS}" -le 5 ] || die "--days is out of range"
DAYS=$((10#$DAYS))
command -v jq >/dev/null 2>&1 || die "jq is required"

common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not a git checkout: $REPO"
dir="$common/suite-baselines/$SUITE"
if [ ! -d "$dir" ]; then
  echo "NO-BASELINES $dir"
  exit 1
fi

all=$(find "$dir" -maxdepth 1 -type f -name '*.json' -exec cat {} + | jq -s '.') || die "could not parse the baseline records under $dir"

# HEAD's first-parent history, oldest first: "<sha> <committer epoch>" per line. It is a file because a long history overflows an argument.
scratch=$(mktemp -d) || die "cannot create a scratch directory"
trap 'rm -rf "$scratch"' EXIT
git -C "$REPO" log --first-parent --reverse --format='%H %ct' HEAD > "$scratch/history" 2>/dev/null || die "cannot read the first-parent history of $REPO"
[ -s "$scratch/history" ] || die "HEAD has no history in $REPO"

# The tree each record's commit points at, to tell a clean record (its `key` is that tree) from a dirty-tree one: "<commit> <tree>" per
# line, "-" for a commit whose tree cannot be resolved. Only commits that are on the history are asked about.
cut -d' ' -f1 "$scratch/history" > "$scratch/shas"
printf '%s' "$all" | jq -r '.[] | (.commit // "") | tostring' | LC_ALL=C sort -u | { grep -Fxf "$scratch/shas" || true; } > "$scratch/commits" \
  || die "could not parse the baseline records under $dir"
: > "$scratch/trees"
if [ -s "$scratch/commits" ]; then
  sed 's/$/^{tree}/' "$scratch/commits" | git -C "$REPO" cat-file --batch-check > "$scratch/trees.raw" 2>/dev/null || die "cannot resolve commit trees in $REPO"
  [ "$(wc -l < "$scratch/commits")" -eq "$(wc -l < "$scratch/trees.raw")" ] || die "cannot resolve commit trees in $REPO"
  awk 'NR == FNR { c[FNR] = $0; next } { print c[FNR], ($2 == "missing" ? "-" : $1) }' "$scratch/commits" "$scratch/trees.raw" > "$scratch/trees"
fi

now=$(date +%s)
cutoff=0
[ "$DAYS" -gt 0 ] && cutoff=$((now - DAYS * 86400))

# shellcheck disable=SC2016  # jq program, not shell
out=$(printf '%s' "$all" | jq -r --rawfile history "$scratch/history" --rawfile trees "$scratch/trees" --argjson cutoff "$cutoff" --argjson now "$now" '
  def count: [(.summary // "") | strings | capture("(?<n>[0-9]+) examples") | .n | tonumber] | first;
  def workers_short: [(.summary // "") | strings | capture("(?<k>[0-9]+) of (?<n>[0-9]+) workers") | (.k | tonumber) < (.n | tonumber)] | first // false;
  def epoch: (.recorded_at // "") | (try fromdateiso8601 catch null);
  def commit: (.commit // "") | tostring;
  def rkey: (.key // "") | tostring;
  def day: strftime("%Y-%m-%d");
  def round_to($m): . * $m | round / $m;
  def lsq($x; $y):
    ($x | length) as $k
    | (($x | add) / $k) as $mx | (($y | add) / $k) as $my
    | ([range(0; $k) | ($x[.] - $mx) * ($y[.] - $my)] | add) as $sxy
    | ([range(0; $k) | ($x[.] - $mx) * ($x[.] - $mx)] | add) as $sxx
    | if $sxx == 0 then null else $sxy / $sxx end;
  def fig($m): if . == null then "-" else (round_to($m) | tostring) end;
  ($history | split("\n") | map(select(length > 0) | split(" "))) as $h
  | ([range(0; $h | length) as $i | { key: $h[$i][0], value: { i: $i, ct: ($h[$i][1] | tonumber) } }] | from_entries) as $pos
  | (map(select(count == null or epoch == null)) | length) as $unparsed
  | [ .[] | select(count != null and epoch != null) ] as $parsed
  | ($parsed | map(select(workers_short)) | length) as $short
  | [ $parsed[] | select(workers_short | not) ] as $complete
  | ([ $trees | split("\n")[] | select(length > 0) | split(" ") | { key: .[0], value: .[1] } ] | from_entries) as $tree
  | [ $complete[] | select($pos[commit] != null) ] as $onhist
  | (($complete | length) - ($onhist | length)) as $notfp
  | ($onhist | map(select(epoch < $cutoff)) | length) as $outside
  | [ $onhist[] | select(epoch >= $cutoff)
      | commit as $c | rkey as $rk
      | { at: .recorded_at, t: epoch, n: count, c: $c, i: $pos[$c].i, ct: $pos[$c].ct, clean: ($rk != "" and $rk == ($tree[$c] // "-")) } ] as $win
  | ($win | group_by(.c) | map([.[] | select(.clean)] as $cl | if ($cl | length) > 0 then ($cl | max_by(.t)) else max_by(.t) end)) as $kept
  | (($win | length) - ($kept | length)) as $dups
  | ($kept | map(select(.clean)) | length) as $nclean
  | ($kept | sort_by(.i)) as $s
  | ($s | length) as $k
  | ($s | map(.ct) | if length > 0 then (max - min) else 0 end) as $span
  | ($s | map(.c[0:10])) as $cs
  | ($s | map("SERIES \(.at) \(.n) \(.c[0:10])") | .[]),
    (if $unparsed > 0 then "SKIPPED \($unparsed) no-count-or-date" else empty end),
    (if $short > 0 then "SKIPPED \($short) incomplete-workers" else empty end),
    (if $notfp > 0 then "SKIPPED \($notfp) not-first-parent" else empty end),
    (if $outside > 0 then "SKIPPED \($outside) outside-window" else empty end),
    (if $dups > 0 then "SKIPPED \($dups) duplicate-commit" else empty end),
    "CLEAN \($nclean) DIRTY-FALLBACK \($k - $nclean)",
    "WINDOW \(if $cutoff > 0 then ($cutoff | day) elif $k > 0 then ($s | map(.t) | min | day) else "-" end) \($now | day) \($k)",
    (if $k == 0 then empty
     else
       "SLOPE per-commit=\(lsq($s | map(.i); $s | map(.n)) | fig(100)) per-week=\(if $k < 3 or $span < 86400 then "-" else lsq($s | map(.ct / 604800); $s | map(.n)) | fig(10) end) points=\($k) span=\($cs[0])..\($cs[-1])"
     end)
') || die "could not parse the baseline records under $dir"

printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^SERIES ' || exit 1
exit 0
