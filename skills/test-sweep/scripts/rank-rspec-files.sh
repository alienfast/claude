#!/usr/bin/env bash
# rank-rspec-files.sh — rank a Rails project's spec files by recorded cost, for /test-sweep.
#
# WHY THIS EXISTS: suite cost is concentrated in a few dozen files, but no run output says which files those are or which
# spend the most per example — the shape that marks a fixture-heavy or truncation-tagged file. basefund's apps/api/ci
# run_rspec already merges every full run's per-file junit times into <git common dir>/rspec-file-times.tsv, shared by
# every worktree; this reads that ledger plus the last run's per-worker junit for example counts, and adds the two signals
# timings cannot show: files carrying a slow DB-strategy tag, and identical example descriptions repeated across spec layers
# (a request spec re-walking a policy spec's matrix is the usual shape). The ledger keeps the most recent run's seconds per
# file, so a RANK seconds figure is one sample (one file went from 60 s to 19 s between consecutive runs): an
# order-of-magnitude figure, with s/example from the junit the steadier second signal.
#
# USAGE
#   rank-rspec-files.sh --repo DIR [--top N] [--api-dir REL] [--junit-dir REL] [--tags LIST]
#
#   --repo DIR       the project checkout (any worktree; the timings ledger is shared through the git common dir)
#   --top N          print only the N slowest RANK rows (default: all)
#   --api-dir REL    the Rails app, relative to the repo (default apps/api); ledger and output paths are relative to it
#   --junit-dir REL  per-worker junit from the last run, relative to the api dir (default test-reports/rspec)
#   --tags LIST      `|`-separated RSpec metadata symbols marking a slow-strategy spec file (default ':truncation|:unfenced_user_email');
#                    a file is TAGGED when a describe/context/it header carries `:name` or `name: true`, comment lines excluded
#
# OUTPUT (one verdict per line)
#   TIMINGS <tsv path> rows=<N> recorded=<mtime>
#   JUNIT <dir> files=<N> examples=<N> recorded=<newest mtime> shards=<w0..wN>      or  NO-JUNIT <dir>
#                                                                     only the newest run's contiguous shards are read
#   STALE <N>                                                         ledger rows naming a spec file that no longer exists; not ranked
#   RANK <seconds> <examples|-> <s/example|-> <spec path>             longest first; seconds are the most recent run's per-file
#                                                                     time from the ledger, the counts and s/example from the junit
#   TAGGED <spec path>
#   REPEAT "<it description>" <spec path> <spec path>...              one description under two or more top-level spec dirs
#
# Exit 0 ranked (also when no example description repeats), 1 no timings ledger yet (run the full suite once through run_rspec),
# 2 usage or git error.
# Requires git, awk, grep.

set -uo pipefail
export LC_ALL=C  # spec and story text carries UTF-8; byte-wise awk/sort cannot abort on a multibyte sequence

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "rank-rspec-files: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "rank-rspec-files: $1 needs a value" >&2; usage; exit 2; }; }

file_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

iso_mtime() {
  local epoch
  epoch=$(file_epoch "$1")
  date -u -r "$epoch" +%FT%TZ 2>/dev/null || date -u -d "@$epoch" +%FT%TZ
}

REPO=""; TOP=0; API_DIR="apps/api"; JUNIT_DIR="test-reports/rspec"; TAGS=':truncation|:unfenced_user_email'
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --top) need_value "$1" $#; TOP="$2"; shift 2 ;;
    --api-dir) need_value "$1" $#; API_DIR="$2"; shift 2 ;;
    --junit-dir) need_value "$1" $#; JUNIT_DIR="$2"; shift 2 ;;
    --tags) need_value "$1" $#; TAGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "rank-rspec-files: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { usage; exit 2; }
case "$TOP" in ''|*[!0-9]*) die "--top must be a non-negative integer" ;; esac
[ -n "$TAGS" ] || die "--tags needs at least one tag"
[ -d "$REPO" ] || die "no such directory: $REPO"

common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not a git checkout: $REPO"
api="$REPO/$API_DIR"
[ -d "$api/spec" ] || die "no spec directory at $api/spec (pass --api-dir)"

tsv="$common/rspec-file-times.tsv"
if [ ! -s "$tsv" ]; then
  echo "NO-TIMINGS $tsv"
  exit 1
fi
echo "TIMINGS $tsv rows=$(awk 'END {print NR}' "$tsv") recorded=$(iso_mtime "$tsv")"

jdir="$api/$JUNIT_DIR"

# run_rspec clears only the shards of the run it executes, so an older, wider run leaves junit_w8/w9 behind: read the shards
# whose mtimes sit within SHARD_WINDOW seconds of the newest, as the contiguous set starting at the lowest worker number.
SHARD_WINDOW=600
newest=""; newest_epoch=0; all_shards=()
for f in "$jdir"/junit_w*.xml; do
  [ -f "$f" ] || continue
  all_shards+=("$f")
  e=$(file_epoch "$f")
  if [ "$e" -gt "$newest_epoch" ]; then newest_epoch=$e; newest=$f; fi
done
junit_files=(); shard_range=""
if [ ${#all_shards[@]} -gt 0 ]; then
  nums=""
  for f in "${all_shards[@]}"; do
    n=${f##*/junit_w}; n=${n%.xml}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$(file_epoch "$f")" -ge $((newest_epoch - SHARD_WINDOW)) ] && nums="$nums $((10#$n))"
  done
  prev=""; first=""
  for n in $(tr -s ' ' '\n' <<< "$nums" | sort -n); do
    if [ -n "$prev" ] && [ "$n" -ne $((prev + 1)) ]; then break; fi
    [ -n "$prev" ] || first=$n
    junit_files+=("$jdir/junit_w$n.xml")
    prev=$n
  done
  [ ${#junit_files[@]} -gt 0 ] && shard_range="w$first..w$prev"
fi

junit_stream() {
  [ ${#junit_files[@]} -gt 0 ] || return 0
  grep -ho '<testcase [^>]*' "${junit_files[@]}" | awk '
    function attr(s, k) {
      if (match(s, " " k "=\"[^\"]*\"")) return substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4)
      return ""
    }
    { f = attr($0, "file"); sub(/^\.\//, "", f); if (f != "") printf "J\t%s\t%s\n", f, attr($0, "time") + 0 }'
}

if [ ${#junit_files[@]} -gt 0 ]; then
  junit_stream | awk -F'\t' -v dir="$jdir" -v at="$(iso_mtime "$newest")" -v shards="$shard_range" '
    { c++; seen[$2] = 1 }
    END { k = 0; for (f in seen) k++; printf "JUNIT %s files=%d examples=%d recorded=%s shards=%s\n", dir, k, c, at, shards }'
else
  echo "NO-JUNIT $jdir"
fi

# The ledger never prunes rows for files a run did not reach, so rows naming a deleted spec are dropped here rather than ranked.
live_rows=""; stale=0
while IFS=$'\t' read -r row_path row_secs _ || [ -n "${row_path:-}" ]; do
  [ -n "$row_path" ] && [ -n "${row_secs:-}" ] || continue
  if [ -f "$api/$row_path" ]; then live_rows="${live_rows}T"$'\t'"$row_path"$'\t'"$row_secs"$'\n'; else stale=$((stale + 1)); fi
done < "$tsv"
echo "STALE $stale"

{ junit_stream; printf '%s' "$live_rows"; } | awk -F'\t' '
  $1 == "J" { n[$2]++; s[$2] += $3; next }
  $1 == "T" {
    if ($2 in n) printf "RANK %.3f %d %.3f %s\n", $3, n[$2], s[$2] / n[$2], $2
    else printf "RANK %.3f - - %s\n", $3, $2
  }' | sort -k2,2nr -k5,5 | if [ "$TOP" -gt 0 ]; then head -n "$TOP"; else cat; fi

# `:name` or `name: true` in the header of a describe/context/it call (which may span lines up to its `do`); a comment that
# mentions the tag is not a tag.
tag_pattern=""
IFS='|' read -r -a tag_list <<< "$TAGS"
for t in "${tag_list[@]}"; do
  case "$t" in
    :*) name=${t#:}; alt=":${name}([^A-Za-z0-9_]|\$)|${name}:[[:space:]]*true" ;;
    *) alt=$t ;;
  esac
  tag_pattern="${tag_pattern:+$tag_pattern|}$alt"
done
# shellcheck disable=SC2016  # awk program, not shell
TAG_AWK='
  function code(s,   i, c, q, o) {  # the line with quoted strings and any trailing comment dropped
    q = ""; o = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == "\\") i++; else if (c == q) q = ""; continue }
      if (c == "\047" || c == "\"") { q = c; continue }
      if (c == "#") break
      o = o c
    }
    return o
  }
  /^[[:space:]]*#/ { next }
  !hdr && /^[[:space:]]*(RSpec\.)?(describe|context|it|specify)[[:space:](]/ { hdr = 1 }
  hdr {
    c = code($0)
    if (c ~ pat) { found = 1; exit }
    if (c ~ /(^|[[:space:]])do([[:space:]]|$)|\{/) hdr = 0
  }
  END { exit !found }'
(cd "$api" && grep -rlE --include='*_spec.rb' -e "$tag_pattern" spec | sort | while IFS= read -r spec_file; do
  awk -v pat="$tag_pattern" "$TAG_AWK" "$spec_file" && echo "TAGGED $spec_file"
done)

(cd "$api" && grep -rHoE --include='*_spec.rb' -e "^[[:space:]]*it[[:space:]]+'[^']+'" -e '^[[:space:]]*it[[:space:]]+"[^"]+"' spec) | awk '
    {
      i = index($0, ":"); f = substr($0, 1, i - 1); d = substr($0, i + 1)
      sub(/^[[:space:]]*it[[:space:]]+/, "", d); d = substr(d, 2, length(d) - 2); gsub(/"/, "\047", d)
      split(f, p, "/"); top = (p[2] ~ /_spec\.rb$/) ? p[1] : p[1] "/" p[2]
      key = d SUBSEP f
      if (key in seen) next
      seen[key] = 1
      files[d] = files[d] " " f
      if (!((d SUBSEP top) in dirs)) { dirs[d SUBSEP top] = 1; ndirs[d]++ }
    }
    END { for (d in ndirs) if (ndirs[d] >= 2) printf "REPEAT \"%s\"%s\n", d, files[d] }' | sort

exit 0
