#!/bin/bash
# detect-issue-id.sh — Resolve a Linear-style issue identifier (e.g., PL-13).
#
# Usage: detect-issue-id.sh [--input <ID>] [--validate-only]
#
# Default (extract) mode: try --input → current git branch → latest commit
# subject. Used by /finish, /checkpoint, and the other extract-mode consumers.
#
# --validate-only: requires --input; just normalizes to uppercase and validates
# the ^[A-Z]+-[0-9]+$ shape. Used by /start (no branch/commit fallback because
# /start creates the branch).
#
# A DERIVED identifier (branch/commit sources) is accepted only when its team
# prefix is known: DETECT_ISSUE_ID_TEAMS (comma/space-separated; lets tests run
# offline) beats workspace discovery via `linear-cli teams list`; LINEAR_TEAM is
# a non-authoritative fallback. Without an authoritative list a candidate is
# accepted with a WARN on stderr — fail open, so a real ID still resolves
# offline. --input is authoritative and never team-validated.
#
# stdout (success): the normalized identifier, single line (e.g., PL-13).
# stderr (failure): one-line diagnostic.
#
# Branch sources skipped: main, master, develop.
#
# Exit codes:
#   0 = found and printed to stdout
#   1 = not found / invalid format / refused

set -eo pipefail

input=""
validate_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    --validate-only) validate_only=1; shift ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

normalize() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

is_valid() {
  [[ "$1" =~ ^[A-Z]+-[0-9]+$ ]]
}

teams_cache=""
teams_source=""
load_teams() {
  if [ -n "$teams_source" ]; then return 0; fi
  if [ -n "${DETECT_ISSUE_ID_TEAMS:-}" ]; then
    teams_cache="$DETECT_ISSUE_ID_TEAMS"
    teams_source="env"
    return 0
  fi
  teams_cache=$(linear-cli teams list -o json -q 2>/dev/null </dev/null \
    | jq -r '[.. | objects | select(has("key")) | .key] | join(",")' 2>/dev/null || true)
  if [ "$teams_cache" = "null" ]; then teams_cache=""; fi
  if [ -n "$teams_cache" ]; then
    teams_source="discovered"
  elif [ -n "${LINEAR_TEAM:-}" ]; then
    teams_cache="$LINEAR_TEAM"
    teams_source="fallback"
  else
    teams_source="none"
  fi
}

# 0 = known team, 1 = definitively not a team, 2 = unverifiable. A LINEAR_TEAM-only list
# confirms members but cannot reject: a project routinely exports one team while legitimately
# using another, so non-members of the fallback stay unverifiable instead of becoming false
# rejections.
team_known() {
  load_teams
  local prefix="${1%%-*}" t
  local IFS=', '
  for t in $teams_cache; do
    if [ "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')" = "$prefix" ]; then
      return 0
    fi
  done
  case "$teams_source" in
    env|discovered) return 1 ;;
    *) return 2 ;;
  esac
}

accept_unverified() {
  echo "WARN: no authoritative team list — accepting '$1' with unverified team prefix" >&2
  printf '%s\n' "$1"
  exit 0
}

# 1. user input
if [ -n "$input" ]; then
  norm=$(normalize "$input")
  if is_valid "$norm"; then
    printf '%s\n' "$norm"
    exit 0
  fi
  echo "ERROR: --input '$input' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi

if [ "$validate_only" -eq 1 ]; then
  echo "ERROR: --validate-only requires --input" >&2
  exit 1
fi

# 2. branch name
branch=$(git branch --show-current 2>/dev/null || true)
case "$branch" in
  main|master|develop|"")
    ;;
  *)
    if [[ "$branch" =~ (^|/)([A-Za-z]+-[0-9]+)(-|$) ]]; then
      norm=$(normalize "${BASH_REMATCH[2]}")
      if is_valid "$norm"; then
        team_known "$norm" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
          printf '%s\n' "$norm"
          exit 0
        elif [ "$rc" -eq 2 ]; then
          accept_unverified "$norm"
        fi
        # rc=1: a word-number branch like hotfixes-1 — fall through to the commit subject
      fi
    fi
    ;;
esac

# 3. latest commit subject — scan every candidate; a known team anywhere in the subject beats
# a leftmost non-team token like UTF-8 or SHA-256.
subject=$(git log -1 --format=%s 2>/dev/null || true)
if [ -n "$subject" ]; then
  cands=$(printf '%s' "$subject" | grep -oE '[A-Za-z]+-[0-9]+' || true)
  unverified=""
  while IFS= read -r c; do
    if [ -z "$c" ]; then continue; fi
    norm=$(normalize "$c")
    team_known "$norm" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$norm"
      exit 0
    elif [ "$rc" -eq 2 ] && [ -z "$unverified" ]; then
      unverified="$norm"
    fi
  done <<< "$cands"
  if [ -n "$unverified" ]; then
    accept_unverified "$unverified"
  fi
fi

# 4. fail
if [ -n "$branch" ]; then
  echo "ERROR: no issue ID found (branch='$branch', commit subject='$subject')" >&2
else
  echo "ERROR: no issue ID found (not in a git repo or no current branch)" >&2
fi
exit 1
