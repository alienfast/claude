#!/bin/bash
# linear-create-child.sh — create a Linear issue (optionally linked to a parent),
# with its description read from a file, and verify the parent link took.
#
# Usage: linear-create-child.sh <parent|-> <team> <state|-> <title> <body-file>
#
#   <parent>     Parent issue identifier (e.g., PL-396) to link under, or "-" / ""
#                for a top-level issue.
#   <team>       Team key or name (e.g., PL).
#   <state>      Workflow state name (e.g., Planned), or "-" / "" for the team default.
#   <title>      Issue title.
#   <body-file>  Path to a file holding the markdown description.
#
# stdout (success): the new issue identifier (e.g., PL-451), single line.
# stderr (failure): one-line diagnostic.
#
# Why a helper: `linear-cli issues create` has no `--parent` flag. You *can* set the
# parent's UUID as `parentId` via `--data` JSON (it carries `description` too on 0.3.26),
# but a bare create — `--data` or otherwise — never confirms the link took. So this
# creates the issue with the description via `-d -` (robust stdin for large markdown
# bodies, no JSON-escaping or ARG_MAX concerns), links the parent with `relations parent`,
# and then VERIFIES the link — failing hard on an orphan. The verification is what makes
# this safe: the orphan the "create then forget to link" anti-pattern risks cannot slip
# through. Centralizing it lets /prd and /quality-review file parent-linked issues
# without inline shell plumbing.
#
# Read-write: creates one Linear issue (and sets its parent).
#
# Exit codes:
#   0 = created and (if a parent was given) linked + verified; identifier on stdout
#   1 = usage / missing body file / create failed / parent link failed or unverified

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 5 ]; then
  echo "usage: linear-create-child.sh <parent|-> <team> <state|-> <title> <body-file>" >&2
  exit 1
fi

parent="$1"
team="$2"
state="$3"
title="$4"
body_file="$5"

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done
if [ ! -f "$body_file" ]; then
  echo "ERROR: body file not found: $body_file" >&2
  exit 1
fi

# Create with the description via `-d -` (stdin), then link the parent separately via
# `relations parent` so the link can be VERIFIED (below). The header explains why this
# two-step path is preferred over a single `--data` create.
create_args=(issues create "$title" --team "$team" -o json -d -)
if [ -n "$state" ] && [ "$state" != "-" ]; then
  create_args+=(--state "$state")
fi

created=$(linear-cli "${create_args[@]}" < "$body_file") || {
  echo "ERROR: failed to create issue '$title'" >&2; exit 1; }
new_id=$(printf '%s' "$created" | jq -r '.identifier // .id // empty')
if [ -z "$new_id" ]; then
  echo "ERROR: issue created but no identifier returned" >&2
  exit 1
fi

# Link the parent (relations parent <CHILD> <PARENT>) and VERIFY it took — a created
# issue with no parent link is the orphan this helper exists to prevent.
if [ -n "$parent" ] && [ "$parent" != "-" ]; then
  if ! linear-cli relations parent "$new_id" "$parent" >/dev/null 2>&1; then
    echo "ERROR: created $new_id but 'relations parent $new_id $parent' failed — issue is orphaned" >&2
    exit 1
  fi
  linked=$(linear-cli issues get "$new_id" -o json 2>/dev/null | jq -r '.parent.identifier // empty')
  if [ "$linked" != "$parent" ]; then
    echo "ERROR: created $new_id but its parent is '${linked:-none}', expected '$parent' — link failed" >&2
    exit 1
  fi
fi

printf '%s\n' "$new_id"
