#!/bin/bash
# linear-dedup-search.sh — the pre-filing duplicate search, one token per call, with the failure modes that read as
# "no duplicate" made loud.
#
# Usage: linear-dedup-search.sh [--phrase "<verbatim title text>"]... <token>...
#
#   <token>     A single code identifier, basename, symbol or error string. One `linear-cli search issues <token>
#               -o json` call each. A token containing whitespace is refused (exit 2): `search issues` matches a
#               contiguous substring, so a composed phrase returns empty at exit 0 (linear skill gotcha #14).
#   --phrase    Text seen VERBATIM in an existing issue title — the one multi-word query gotcha #14 allows. Still
#               one call per value. Repeatable.
#   -h|--help   Print this usage and exit 0.
#
# stdout: one line per DISTINCT identifier across every query, in first-seen order:
#           <ID> | <state name> | <title>
#         A Done / Canceled / Cancelled / Duplicate hit is prefixed `prior-art: ` — the body's `Prior art:` line
#         (standards/linear-filing.md § 1). Empty stdout with exit 0 means a clean search. On exit 1 or 3 stdout is
#         empty by construction: nothing is printed until every query has answered.
# stderr: usage errors, the first rate-limit line (exit 3), or the failing call's own stderr (exit 1).
#
# Why a helper: in the 2026-11-03 fleets every dedup search discarded stderr (a RATELIMITED envelope then reads as
# "no duplicate"), used multi-word phrases, filtered terminal issues by `.state.type` (a search row carries
# `state: {name}` only — states.md gotcha #19), or indexed `.nodes` on what is a bare array (json.md gotcha #13).
#
# Read-only: issues no write.
#
# Exit codes:
#   0 = search ran; hits or none
#   1 = linear-cli (or jq) missing, linear-cli exited non-zero for a reason other than a rate limit, or answered
#       something other than a JSON array
#   2 = usage: no query, an unknown flag, --phrase without a value, or a positional token containing whitespace
#       (nothing was run)
#   3 = rate limited — WAIT for the hourly window, never re-rank or retry at once (paging.md gotcha #26)

set -uo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

usage() {
  sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'
}

queries=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --phrase)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --phrase needs a non-empty value" >&2
        exit 2
      fi
      queries+=("$2"); shift 2 ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2 ;;
    *)
      if [ -z "$1" ] || [[ "$1" =~ [[:space:]] ]]; then
        echo "ERROR: positional token '$1' is empty or holds whitespace — a multi-word query matches only a contiguous substring and otherwise returns empty at exit 0 (linear skill gotcha #14). Search one token per call, or pass text seen verbatim in an existing title as --phrase \"...\"" >&2
        exit 2
      fi
      queries+=("$1"); shift ;;
  esac
done

if [ "${#queries[@]}" -eq 0 ]; then
  echo "ERROR: no query given" >&2
  usage >&2
  exit 2
fi

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rows="$work/rows.tsv"
: > "$rows"

for q in "${queries[@]}"; do
  rc=0
  linear-cli search issues "$q" -o json > "$work/out" 2> "$work/err" || rc=$?

  # The envelope rides on stderr with empty stdout; a non-zero exit's stdout is checked too in case a mode prints it there.
  limit_src="$work/err"
  if ! grep -qE 'RATELIMITED|Rate limit exceeded' "$limit_src"; then
    limit_src=""
    if [ "$rc" -ne 0 ] && grep -qE 'RATELIMITED|Rate limit exceeded' "$work/out"; then limit_src="$work/out"; fi
  fi
  if [ -n "$limit_src" ]; then
    grep -E -m1 'RATELIMITED|Rate limit exceeded' "$limit_src" >&2
    exit 3
  fi

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: linear-cli search issues '$q' exited $rc" >&2
    cat "$work/err" >&2
    exit 1
  fi

  if ! jq -e 'type == "array"' "$work/out" >/dev/null 2>&1; then
    echo "ERROR: linear-cli search issues '$q' did not return a JSON array" >&2
    cat "$work/err" >&2
    exit 1
  fi

  jq -r '.[] | [.identifier, (.state.name // ""), .title] | map(tostring | gsub("[\t\r\n]+"; " ")) | join("\t")' "$work/out" >> "$rows"
done

# Terminal set per standards/linear-filing.md § 1, judged by state NAME because a search row carries no state type.
# Confirm the names against `linear-cli statuses list -t <KEY> --no-cache` (states.md gotcha #19).
awk -F'\t' '
  !($1 in seen) {
    seen[$1] = 1
    tag = ($2 == "Done" || $2 == "Canceled" || $2 == "Cancelled" || $2 == "Duplicate") ? "prior-art: " : ""
    printf "%s%s | %s | %s\n", tag, $1, $2, $3
  }
' "$rows"
