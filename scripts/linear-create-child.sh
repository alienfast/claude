#!/bin/bash
# linear-create-child.sh — create a Linear issue (optionally linked to a parent),
# with its description read from a file, and verify the parent link took.
#
# Usage: linear-create-child.sh <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]
#
#   <parent>     Parent issue identifier (e.g., PL-396) to link under, or "-" / ""
#                for a top-level issue.
#   <team>       Team key or name (e.g., PL).
#   <state>      Workflow state name (e.g., Planned), or "-" / "" for the team default.
#   <title>      Issue title.
#   <body-file>  Path to a file holding the markdown description.
#   <label>      Optional issue label(s) to attach after create — a single name or a
#                comma-separated list (e.g., "specified,bug"), or "-" / "" / omitted to
#                skip. BEST EFFORT: the id still prints and the parent link still
#                verifies; a failed attach exits 2 (filed-but-unlabelled), mirroring
#                linear-file-improvement.sh.
#   <priority>   Optional Linear priority (0=none 1=urgent 2=high 3=normal 4=low), or
#                "-" / "" / omitted to skip. Set at create time. A severity graded into
#                an issue BODY is invisible to /next's priority_rank — this field is
#                what the ranking actually reads (BF-583).
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
# Read-write: creates one Linear issue (and sets its parent; optionally attaches a label).
#
# Exit codes:
#   0 = created, (if a parent was given) linked + verified, (if a label was given)
#       attached; identifier on stdout
#   2 = created and linked + verified, but the requested label could NOT be attached;
#       id still on stdout, WARN on stderr
#   1 = usage / missing body file / create failed / parent link failed or unverified

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -lt 5 ] || [ $# -gt 7 ]; then
  echo "usage: linear-create-child.sh <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]" >&2
  exit 1
fi

parent="$1"
team="$2"
state="$3"
title="$4"
body_file="$5"
label="${6:-}"
priority="${7:-}"

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
if [ -n "$priority" ] && [ "$priority" != "-" ]; then
  if ! [[ "$priority" =~ ^[0-4]$ ]]; then
    echo "ERROR: priority must be 0-4 (got '$priority')" >&2
    exit 1
  fi
  create_args+=(--priority "$priority")
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

# Attach the optional label — BEST EFFORT, with the id printed FIRST so it reaches stdout
# on every path. Probe/create mechanics mirror linear-file-improvement.sh (the `-t issue`
# gotchas and the canonical-casing capture are documented there); the direct `-l` replace
# semantics are safe only because this issue was just created with an empty label set
# (standards/issue-spec.md — existing issues must go through linear-add-label.sh instead).
printf '%s\n' "$new_id"
if [ -n "$label" ] && [ "$label" != "-" ]; then
  all_names=$(linear-cli labels list -t issue --all --no-cache -o json 2>/dev/null \
    | jq -r '.. | objects | select(has("name")) | .name' 2>/dev/null || true)
  update_args=(issues update "$new_id")
  IFS=',' read -ra _labels <<< "$label"
  for lb in "${_labels[@]}"; do
    lb=$(printf '%s' "$lb" | tr -d '[:space:]')
    [ -z "$lb" ] && continue
    have_label=$(printf '%s\n' "$all_names" | grep -Fxi -- "$lb" | head -1 || true)
    if [ -z "$have_label" ]; then
      linear-cli labels create "$lb" -t issue >/dev/null 2>&1 || true
    fi
    update_args+=(-l "${have_label:-$lb}")
  done
  # One replace-semantics update carrying every -l — safe only because the label set is
  # empty on a just-created issue (existing issues must use linear-add-label.sh).
  if ! linear-cli "${update_args[@]}" >/dev/null 2>&1; then
    echo "WARN: created $new_id but could not attach label(s) '$label' — if this gates /auto pickup, attach manually (~/.claude/scripts/linear-add-label.sh $new_id <label>)" >&2
    exit 2
  fi
fi
