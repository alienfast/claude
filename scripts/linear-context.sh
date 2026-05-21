#!/bin/bash
# linear-context.sh — Gather context for a Linear issue as a markdown digest.
#
# Usage:  linear-context.sh <issue-id>
# Output: markdown to stdout. Errors to stderr; non-zero exit on failure.
#
# Sections: header, description, parent chain (traversed upward), dependency
# graph (blockers + blocking), comments summary, attachment URLs.
#
# Section headers are stable for grep: lines starting with "## " mark sections.
#
# Read-only — no side effects, no downloads, no Linear writes.
#
# Input normalization: leading/trailing/internal whitespace is stripped via
# `tr -d '[:space:]'`. A user typing `pl-260` or `  pl-260 ` is normalized to
# `PL-260`; a typo like `P L-260` is collapsed to `PL-260` rather than
# rejected (forgiveness over strictness — the regex check downstream still
# rejects anything that doesn't look like a Linear ID after normalization).
#
# Round-trip cost: the script issues 1 fetch for the target issue, 1 for the
# dependency graph, and N for the parent chain (one per ancestor, depth-capped
# at 10). The Linear CLI does not expose a single-call full-ancestry fetch;
# parent walking is inherently sequential. For shallow chains (0–2 ancestors)
# this is 2–4 round-trips; for deep nesting it scales linearly.

set -eo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <issue-id>" >&2
  exit 1
fi

for cmd in linear jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

input=$(printf '%s' "$1" | tr -d '[:space:]')
if [ -z "$input" ]; then
  echo "ERROR: empty issue ID" >&2
  exit 1
fi
issue=$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')

if ! [[ "$issue" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue ID '$issue' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi

err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

if ! issue_json=$(linear i get "$issue" --output json 2>"$err_file"); then
  echo "ERROR: failed to fetch $issue" >&2
  cat "$err_file" >&2
  exit 1
fi

title=$(printf '%s' "$issue_json" | jq -r '.title // "?"')
state=$(printf '%s' "$issue_json" | jq -r '.state.name // "?"')
priority_num=$(printf '%s' "$issue_json" | jq -r '.priority // 0')
case "$priority_num" in
  1) priority="Urgent" ;;
  2) priority="High" ;;
  3) priority="Medium" ;;
  4) priority="Low" ;;
  *) priority="None" ;;
esac
# Shared jq helper: pick the first non-null, non-empty value from an array.
# Used to coalesce fields where the Linear API may return either `email` or
# `name` (or empty strings) depending on the entity (issue.assignee vs
# comment.user — see https://...).
JQ_PICK='def pick(default): map(select(. != null and . != "")) | first // default;'

assignee=$(printf '%s' "$issue_json" | jq -r "
  $JQ_PICK
  [.assignee.email, .assignee.name] | pick(\"Unassigned\")
")
project_name=$(printf '%s' "$issue_json" | jq -r '.project.name // ""')
project_id=$(printf '%s' "$issue_json" | jq -r '.project.id // ""')
parent_id=$(printf '%s' "$issue_json" | jq -r '.parent.identifier // ""')
url=$(printf '%s' "$issue_json" | jq -r '.url // ""')
description=$(printf '%s' "$issue_json" | jq -r '.description // ""')

printf '# %s — %s\n\n' "$issue" "$title"
printf '**State:** %s | **Priority:** %s | **Assignee:** %s | **Project:** %s\n' \
  "$state" "$priority" "$assignee" "${project_name:-<none>}"
if [ -n "$project_id" ]; then
  printf '**Project ID:** %s\n' "$project_id"
fi
printf '**URL:** %s\n\n' "$url"

printf '## Description\n\n'
if [ -n "$description" ]; then
  printf '%s\n\n' "$description"
else
  printf '_(no description)_\n\n'
fi

printf '## Parent chain\n\n'
if [ -z "$parent_id" ]; then
  printf '_(none — top-level issue)_\n\n'
else
  # Visited tracking: cycle detection via delimited string (bash 3.2 compatible).
  visited="|"
  current="$parent_id"
  depth=0
  max_depth=10
  while [ -n "$current" ] && [ "$depth" -lt "$max_depth" ]; do
    if [[ "$visited" == *"|$current|"* ]]; then
      printf '  - _(cycle detected at %s — stopping)_\n' "$current"
      break
    fi
    visited="${visited}${current}|"
    if parent_json=$(linear i get "$current" --output json 2>/dev/null); then
      p_title=$(printf '%s' "$parent_json" | jq -r '.title // "?"')
      p_state=$(printf '%s' "$parent_json" | jq -r '.state.name // "?"')
      indent=$(printf '%*s' "$((depth * 2))" '')
      printf '%s- **%s** — %s _(%s)_\n' "$indent" "$current" "$p_title" "$p_state"
      current=$(printf '%s' "$parent_json" | jq -r '.parent.identifier // ""')
    else
      printf '  - _(failed to fetch %s)_\n' "$current"
      break
    fi
    depth=$((depth + 1))
  done
  if [ "$depth" -ge "$max_depth" ]; then
    printf '\n_Depth cap (%d) reached. Investigate manually if ancestry is real._\n' "$max_depth"
  fi
  printf '\n'
fi

printf '## Dependencies\n\n'
if deps_json=$(linear deps "$issue" --output json 2>/dev/null) \
   && [ -n "$deps_json" ] && [ "$deps_json" != "null" ]; then
  # Defensive: accept .state as string OR object — the deps endpoint currently
  # returns string, but other linear endpoints return {name, type, ...}.
  state_map=$(printf '%s' "$deps_json" | jq '
    (.nodes // []) | map({
      key: .identifier,
      value: (.state | if type == "object" then (.name // "?") else (. // "?") end)
    }) | from_entries
  ')
  title_map=$(printf '%s' "$deps_json" | jq '(.nodes // []) | map({key: .identifier, value: (.title // "?")}) | from_entries')

  blockers_json=$(printf '%s' "$deps_json" | jq -c --arg id "$issue" \
    '[(.edges // [])[] | select(.to == $id and .type == "blocks") | .from] | unique')
  blocking_json=$(printf '%s' "$deps_json" | jq -c --arg id "$issue" \
    '[(.edges // [])[] | select(.from == $id and .type == "blocks") | .to] | unique')

  blocker_count=$(printf '%s' "$blockers_json" | jq 'length')
  if [ "$blocker_count" -eq 0 ]; then
    printf '**Blockers (issues blocking this):** _none_\n\n'
  else
    printf '**Blockers (issues blocking this):**\n\n'
    printf '%s' "$blockers_json" | jq -r --argjson sm "$state_map" --argjson tm "$title_map" \
      '.[] | "- **" + . + "** — " + ($tm[.] // "?") + " _(" + ($sm[.] // "?") + ")_"'
    printf '\n'
  fi

  blocking_count=$(printf '%s' "$blocking_json" | jq 'length')
  if [ "$blocking_count" -eq 0 ]; then
    printf '**Blocks (issues this blocks):** _none_\n\n'
  else
    printf '**Blocks (issues this blocks):**\n\n'
    printf '%s' "$blocking_json" | jq -r --argjson sm "$state_map" --argjson tm "$title_map" \
      '.[] | "- **" + . + "** — " + ($tm[.] // "?") + " _(" + ($sm[.] // "?") + ")_"'
    printf '\n'
  fi
else
  printf '_(no dependency data)_\n\n'
fi

printf '## Comments\n\n'
comment_count=$(printf '%s' "$issue_json" | jq '(.comments // []) | length')
if [ "$comment_count" -eq 0 ]; then
  printf '_(no comments)_\n\n'
else
  printf '**Total:** %d\n\n' "$comment_count"
  printf '%s' "$issue_json" | jq -r "
    $JQ_PICK
    (.comments // []) |
    sort_by(.createdAt) | reverse |
    .[] |
    \"- \" + (.createdAt | split(\"T\")[0]) +
    \" — \" + ([.user.name, .user.email] | pick(\"?\")) +
    \" — \" + ((.body // \"\") | split(\"\\n\")[0] | .[0:140])
  "
  printf '\n_Use `linear i comments %s` for full bodies._\n\n' "$issue"
fi

printf '## Attachments\n\n'
# Capture URLs liberally (up to whitespace), then strip common trailing punctuation
# that wraps URLs in prose: ),],},>,,;.:!?
attachments=$(printf '%s' "$description" \
  | grep -oE 'https://uploads\.linear\.app/[^[:space:]]+' \
  | sed -E 's/[].,;:!?>})]+$//' \
  | sort -u || true)
if [ -n "$attachments" ]; then
  printf '%s\n' "$attachments" | while IFS= read -r u; do
    printf -- '- %s\n' "$u"
  done
  printf '\n_To view: `linear attachments download "<URL>"` then `Read` the resulting path._\n'
else
  printf '_(none)_\n'
fi
