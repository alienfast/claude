#!/usr/bin/env bash
# suite-baseline-cache.sh — share one full-suite result between every session working on a repo, keyed by the
# hash of the working tree the run measured.
#
# WHY THIS EXISTS: a suite `pnpm check` does not run (basefund's rspec) owes a full-suite baseline before the
# first edit so that post-change failures can be attributed. Every session in a fleet forks the same tip, so
# each first pick spends minutes and eight workers re-measuring a tree a sibling measured moments earlier, and
# a serialized sequence re-measures the tree its predecessor just verified. The result is a function of the
# tree alone — gems, Ruby and MySQL are machine-local and identical across worktrees — so one measurement can
# serve every session on this machine that forks that tree.
#
# The key is the hash of the WORKING tree (tracked and untracked non-ignored files), not of HEAD: a post-change
# verification run measures uncommitted work, and its result becomes a successor's baseline exactly when the
# tree that successor forks — the merge commit's tree — hashes identically, which fails closed by construction
# whenever an edit landed after the run or another merge interleaved. `record` re-hashes at record time and
# refuses when the tree moved since the key was captured, so a run whose tree changed underneath it (the
# tree-as-of-START hazard) is never recorded.
#
# Storage: <git common dir>/suite-baselines/<suite>/<tree>.json — one store per repo shared by all its
# worktrees, never committed, never inside a tmp/ that gets cleaned, reachable from any worktree without
# knowing the main checkout's path.
#
# USAGE
#   suite-baseline-cache.sh key    [--repo DIR]
#   suite-baseline-cache.sh lookup <suite> [--repo DIR]
#   suite-baseline-cache.sh record <suite> --key-file F --summary-file F --failing-file F [--note TEXT] [--repo DIR]
#   suite-baseline-cache.sh list   <suite> [--repo DIR]
#   suite-baseline-cache.sh prune  <suite> --days N [--repo DIR]
#
# key     prints the working-tree hash — capture it to a file at launch and hand that file to record.
# lookup  prints KEY=<tree>, then on a hit HIT <path>, SUMMARY <line>, RECORDED <when> commit=<sha> branch=<name>
#         and one FAILING <example> line per recorded failure; on a miss, MISS. Exit 0 hit / 1 miss / 2 error.
# record  prints RECORDED <path>. Exit 0, 2 on a usage error, 3 when the tree no longer matches --key-file.
# Values arrive in files rather than on the command line because a worktree-isolated session cannot use $(…).
#
# Requires git and jq (1.6+ for --rawfile).

set -uo pipefail

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "suite-baseline-cache: $*" >&2; exit 2; }

# Absolute form of a `git rev-parse --git-path`/`--git-common-dir` answer, which git prints relative to the
# repo when it can. `--path-format=absolute` would do this but needs git 2.31.
git_abs() {  # git_abs <repo> <rev-parse flag...>
  local repo="$1"; shift
  local p
  p=$(git -C "$repo" rev-parse "$@") || return 1
  case "$p" in
    /*) echo "$p" ;;
    *)  echo "$repo/$p" ;;
  esac
}

cache_root() {  # cache_root <repo> → <common dir>/suite-baselines, created
  local root
  root=$(git_abs "$1" --git-common-dir) || return 1
  root="$root/suite-baselines"
  mkdir -p "$root" || return 1
  echo "$root"
}

# Hash of the working tree: tracked files as they are on disk plus untracked non-ignored files, honoring
# .gitignore, unmerged paths refused. Works on a private copy of the index so the real index is never opened
# for writing; the copy's stat cache is what makes update-index re-hash only the files that changed.
tree_key() {  # tree_key <repo>
  local repo="$1" root real_index tmp_index tree rc
  root=$(cache_root "$repo") || return 1
  real_index=$(git_abs "$repo" --git-path index) || return 1
  tmp_index=$(mktemp "$root/.index.XXXXXX") || return 1
  if [ -s "$real_index" ]; then
    cp "$real_index" "$tmp_index" || { rm -f "$tmp_index"; return 1; }
  else
    rm -f "$tmp_index"   # a zero-byte file is not a valid index; git creates a fresh one at a missing path
  fi
  git -C "$repo" ls-files -z --cached --others --exclude-standard \
    | GIT_INDEX_FILE="$tmp_index" git -C "$repo" update-index -z --add --remove --stdin >/dev/null 2>&1
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$repo" write-tree 2>/dev/null); rc=$?
  rm -f "$tmp_index"
  [ $rc -eq 0 ] && [ -n "$tree" ] || { echo "suite-baseline-cache: cannot hash the working tree (unmerged paths?)" >&2; return 1; }
  echo "$tree"
}

entry_path() {  # entry_path <repo> <suite> <key>
  local root
  root=$(cache_root "$1") || return 1
  mkdir -p "$root/$2" || return 1
  echo "$root/$2/$3.json"
}

# ---- argument parsing ------------------------------------------------------------------------------------------

[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
suite=""; repo_arg="."; key_file=""; summary_file=""; failing_file=""; note=""; days=""

case "$cmd" in
  key) ;;
  lookup|record|list|prune)
    [ $# -ge 1 ] && [ "${1#--}" = "$1" ] || { usage; die "$cmd needs a <suite> name"; }
    suite="$1"; shift
    case "$suite" in */*|.*) die "suite name must be a plain word, got '$suite'" ;; esac
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "unknown command '$cmd'" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         [ $# -ge 2 ] || die "--repo needs a value"; repo_arg="$2"; shift 2 ;;
    --key-file)     [ $# -ge 2 ] || die "--key-file needs a value"; key_file="$2"; shift 2 ;;
    --summary-file) [ $# -ge 2 ] || die "--summary-file needs a value"; summary_file="$2"; shift 2 ;;
    --failing-file) [ $# -ge 2 ] || die "--failing-file needs a value"; failing_file="$2"; shift 2 ;;
    --note)         [ $# -ge 2 ] || die "--note needs a value"; note="$2"; shift 2 ;;
    --days)         [ $# -ge 2 ] || die "--days needs a value"; days="$2"; shift 2 ;;
    *) usage; die "unexpected argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
repo=$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null) || die "'$repo_arg' is not inside a git work tree"

# ---- commands --------------------------------------------------------------------------------------------------

case "$cmd" in
  key)
    tree_key "$repo" || exit 2
    ;;

  lookup)
    key=$(tree_key "$repo") || exit 2
    echo "KEY=$key"
    path=$(entry_path "$repo" "$suite" "$key") || exit 2
    if [ -f "$path" ]; then
      echo "HIT $path"
      echo "SUMMARY $(jq -r '.summary' "$path")"
      echo "RECORDED $(jq -r '"\(.recorded_at) commit=\(.commit) branch=\(.branch)"' "$path")"
      jq -r '.failing[]? | "FAILING " + .' "$path"
      exit 0
    fi
    echo "MISS"
    exit 1
    ;;

  record)
    [ -n "$key_file" ] && [ -n "$summary_file" ] && [ -n "$failing_file" ] \
      || die "record needs --key-file, --summary-file and --failing-file"
    [ -f "$key_file" ] || die "key file not found: $key_file"
    [ -f "$summary_file" ] || die "summary file not found: $summary_file"
    [ -f "$failing_file" ] || die "failing file not found: $failing_file"
    launch_key=$(tr -d '[:space:]' < "$key_file")
    [ -n "$launch_key" ] || die "key file is empty: $key_file"
    summary=$(grep -m1 -v '^[[:space:]]*$' "$summary_file" || true)
    [ -n "$summary" ] || die "summary file has no aggregate line — never record a run without one: $summary_file"
    key=$(tree_key "$repo") || exit 2
    if [ "$key" != "$launch_key" ]; then
      echo "suite-baseline-cache: tree changed since the key was captured (now $key, launched as $launch_key) — the run measured a tree that no longer exists; not recording" >&2
      exit 3
    fi
    path=$(entry_path "$repo" "$suite" "$key") || exit 2
    if [ -f "$path" ]; then
      old=$(jq -r '.summary' "$path")
      [ "$old" = "$summary" ] || echo "suite-baseline-cache: WARN replacing an entry for this same tree whose result differed ('$old' → '$summary'); a differing result on an identical tree is a flaky example, not a cache error" >&2
    fi
    commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
    branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo "")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp="$path.tmp.$$"
    jq -n --arg suite "$suite" --arg key "$key" --arg commit "$commit" --arg branch "$branch" \
          --arg recorded_at "$now" --arg recorded_by "$repo" --arg summary "$summary" --arg note "$note" \
          --rawfile failing "$failing_file" \
          '{suite: $suite, key: $key, commit: $commit, branch: $branch, recorded_at: $recorded_at,
            recorded_by: $recorded_by, summary: $summary, note: $note,
            failing: ($failing | split("\n") | map(select(length > 0)))}' > "$tmp" \
      && mv -f "$tmp" "$path" || { rm -f "$tmp"; die "could not write $path"; }
    echo "RECORDED $path"
    ;;

  list)
    root=$(cache_root "$repo") || exit 2
    dir="$root/$suite"
    [ -d "$dir" ] || exit 0
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      jq -r '"\(.recorded_at) \(.key[0:12]) \(.summary)"' "$f"
    done | sort -r
    ;;

  prune)
    case "$days" in ''|*[!0-9]*) die "prune needs --days N" ;; esac
    root=$(cache_root "$repo") || exit 2
    dir="$root/$suite"
    [ -d "$dir" ] || { echo "PRUNED 0"; exit 0; }
    n=$(find "$dir" -name '*.json' -type f -mtime +"$days" -print -delete | wc -l | tr -d ' ')
    echo "PRUNED $n"
    ;;
esac
