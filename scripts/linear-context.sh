#!/bin/bash
# linear-context.sh — Gather context for a Linear issue as a markdown digest.
#
# Usage:  linear-context.sh <issue-id>
# Output: markdown to stdout. Errors to stderr; non-zero exit on failure.
#
# Sections: header, description, parent chain (traversed upward), dependency
# graph (blockers + blocking), comments (standalone + anchored), attachment URLs.
#
# Section markers: the script emits a fixed set of "## " headings (Description, Parent
# chain, Dependencies, Comments, Attachments). Note the issue DESCRIPTION is echoed
# verbatim and may itself contain "## " lines, so this digest is meant to be READ, not
# split programmatically on "^## " — do not treat every "## " as a section boundary.
#
# Anchored comments: Linear stores inline comments — created by highlighting issue
# description text and commenting on it — against the description's `documentContent`,
# NOT against `issue.comments`. They are invisible to every CLI's `issues get` /
# `comments list`, which query only `issue.comments`. We pull them via the raw
# GraphQL API (root `comments` filtered by the documentContent id) and fold them into
# the Comments section, so reviewer corrections anchored to the description reach the
# agent's brief. This was the whole reason for switching off the previous CLI.
#
# Read-only — no side effects, no downloads, no Linear writes.
#
# Input normalization: leading/trailing/internal whitespace is stripped via
# `tr -d '[:space:]'`. A user typing `pl-260` or `  pl-260 ` is normalized to
# `PL-260`; a typo like `P L-260` is collapsed to `PL-260` rather than rejected
# (forgiveness over strictness — the regex check downstream still rejects anything
# that doesn't look like a Linear ID after normalization).
#
# Round-trip cost: 1 GraphQL call for the target (fields + dependencies + standalone
# comments + the documentContent id in a single query), 1 for anchored comments, and
# N for the parent chain (one per ancestor, depth-capped at 10). Linear exposes no
# single-call full-ancestry fetch, so parent walking is inherently sequential.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <issue-id>" >&2
  exit 1
fi

for cmd in linear-cli jq; do
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

# Shared jq helper: pick the first non-null, non-empty value from an array. Coalesces
# user-display fields (displayName vs name vs email) which vary by entity.
JQ_PICK='def pick(default): map(select(. != null and . != "")) | first // default;'

# api_issue <id> <graphql-selection> — run issue(id:$id){<selection>} and echo the
# `.data.issue` object (or empty on error / not-found). Diagnostics flow to stderr
# (the CLI's own error, or a GraphQL `errors` payload) so callers that capture stderr
# can surface a real cause; callers that tolerate failure redirect stderr themselves.
api_issue() {
  local id="$1" sel="$2" out
  out=$(linear-cli api query -q -o json -v id="$id" \
    "query(\$id:String!){issue(id:\$id){$sel}}") || return 1
  if [ "$(printf '%s' "$out" | jq 'has("errors")')" = "true" ]; then
    printf 'GraphQL errors: %s\n' "$(printf '%s' "$out" | jq -c '.errors')" >&2
    return 1
  fi
  printf '%s' "$out" | jq -c '.data.issue'
}

err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

if ! linear-cli auth status >/dev/null 2>&1; then
  echo "ERROR: linear-cli is not authenticated — run 'linear-cli auth oauth'" >&2
  exit 1
fi

# One call: scalar fields, project, immediate parent, the documentContent id,
# standalone comments, and both relation directions for the dependency graph.
main_sel='identifier title url priority state{name} assignee{displayName email}
  project{name id} parent{identifier} description documentContent{id}
  comments{nodes{body createdAt user{displayName email}}}
  relations{nodes{type relatedIssue{identifier title state{name}}}}
  inverseRelations{nodes{type issue{identifier title state{name}}}}'

if ! issue_json=$(api_issue "$issue" "$main_sel" 2>"$err_file") || [ "$issue_json" = "null" ] || [ -z "$issue_json" ]; then
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
assignee=$(printf '%s' "$issue_json" | jq -r "
  $JQ_PICK
  [.assignee.displayName, .assignee.email] | pick(\"Unassigned\")
")
project_name=$(printf '%s' "$issue_json" | jq -r '.project.name // ""')
project_id=$(printf '%s' "$issue_json" | jq -r '.project.id // ""')
parent_id=$(printf '%s' "$issue_json" | jq -r '.parent.identifier // ""')
url=$(printf '%s' "$issue_json" | jq -r '.url // ""')
description=$(printf '%s' "$issue_json" | jq -r '.description // ""')
doc_id=$(printf '%s' "$issue_json" | jq -r '.documentContent.id // ""')

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
    if parent_json=$(api_issue "$current" 'title state{name} parent{identifier}' 2>/dev/null); then
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
# Blockers (issues blocking this) = inverseRelations of type "blocks" (this issue is
# the target). Blocks (issues this blocks) = relations of type "blocks" (the source).
blockers=$(printf '%s' "$issue_json" | jq -r '
  [(.inverseRelations.nodes // [])[] | select(.type == "blocks") | .issue]
  | sort_by(.identifier)[]
  | "- **" + .identifier + "** — " + (.title // "?") + " _(" + (.state.name // "?") + ")_"')
blocking=$(printf '%s' "$issue_json" | jq -r '
  [(.relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue]
  | sort_by(.identifier)[]
  | "- **" + .identifier + "** — " + (.title // "?") + " _(" + (.state.name // "?") + ")_"')

if [ -n "$blockers" ]; then
  printf '**Blockers (issues blocking this):**\n\n%s\n\n' "$blockers"
else
  printf '**Blockers (issues blocking this):** _none_\n\n'
fi
if [ -n "$blocking" ]; then
  printf '**Blocks (issues this blocks):**\n\n%s\n\n' "$blocking"
else
  printf '**Blocks (issues this blocks):** _none_\n\n'
fi

# Anchored comments live on the documentContent; fetch them with a second call.
anchored_json='[]'
if [ -n "$doc_id" ]; then
  anc_out=$(linear-cli api query -q -o json -v doc="$doc_id" \
    'query($doc:ID!){comments(filter:{documentContent:{id:{eq:$doc}}}){nodes{body createdAt parent{id} user{displayName email}}}}' 2>/dev/null) || anc_out=""
  if [ -n "$anc_out" ] && [ "$(printf '%s' "$anc_out" | jq 'has("errors")')" != "true" ]; then
    anchored_json=$(printf '%s' "$anc_out" | jq -c '.data.comments.nodes // []')
  fi
fi

printf '## Comments\n\n'
standalone_count=$(printf '%s' "$issue_json" | jq '(.comments.nodes // []) | length')
anchored_count=$(printf '%s' "$anchored_json" | jq 'length')

if [ "$standalone_count" -eq 0 ] && [ "$anchored_count" -eq 0 ]; then
  printf '_(no comments)_\n\n'
else
  printf '**Standalone:** %d | **Anchored (highlighted in description):** %d\n\n' \
    "$standalone_count" "$anchored_count"

  if [ "$standalone_count" -gt 0 ]; then
    printf '%s' "$issue_json" | jq -r "
      $JQ_PICK
      (.comments.nodes // []) | sort_by(.createdAt) | reverse | .[] |
      \"- \" + (.createdAt | split(\"T\")[0]) +
      \" — \" + ([.user.displayName, .user.email] | pick(\"?\")) +
      \" — \" + ((.body // \"\") | split(\"\\n\")[0] | .[0:140])
    "
    printf '\n'
  fi

  # Anchored comments carry reviewer corrections; show them in FULL (not first-line
  # truncated like standalone) — they are the high-signal content and usually short.
  if [ "$anchored_count" -gt 0 ]; then
    printf '**Anchored comments (full text — reviewer corrections on the description):**\n\n'
    printf '%s' "$anchored_json" | jq -r "
      $JQ_PICK
      sort_by(.createdAt) | .[] |
      (if .parent then \"  ↳ reply \" else \"- \" end) +
      \"**\" + ([.user.displayName, .user.email] | pick(\"?\")) + \"**: \" +
      ((.body // \"\") | gsub(\"\\n\"; \" \"))
    "
    printf '\n'
  fi
fi

printf '## Attachments\n\n'
# Scan the description AND every comment body (standalone + anchored): inline images are
# routinely pasted into comments, not the description. This section is also the only place
# the FULL upload URL can surface — the Comments section truncates standalone bodies to 140
# chars, which chops a long `![](uploads.linear.app/.../<uuid>)` mid-UUID into a 404ing URL.
# Capture liberally (up to whitespace), then strip trailing prose punctuation: ),],},>,,;.:!?
attachments=$( {
    printf '%s\n' "$description"
    printf '%s' "$issue_json"    | jq -r '(.comments.nodes // [])[] | (.body // "")'
    printf '%s' "$anchored_json" | jq -r '.[] | (.body // "")'
  } \
  | grep -oE 'https://uploads\.linear\.app/[^[:space:]]+' \
  | sed -E 's/[].,;:!?>})]+$//' \
  | sort -u || true)
if [ -n "$attachments" ]; then
  printf '%s\n' "$attachments" | while IFS= read -r u; do
    printf -- '- %s\n' "$u"
  done
  printf '\n_To view: `linear-cli uploads fetch "<URL>"` then `Read` the resulting path._\n'
else
  printf '_(none)_\n'
fi
