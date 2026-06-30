#!/bin/bash
# linear-file-improvement.sh — file a single standalone "continuous-improvement" Linear
# issue from a /reflect session: status Planned, assigned to the session runner, labelled
# `ai-generated`, description read from a file.
#
# Usage: linear-file-improvement.sh <team> <title> <body-file>
#
#   <team>       Team key or name (e.g., PL) — derive from the worked issue's ID prefix.
#   <title>      Issue title.
#   <body-file>  Path to a file holding the markdown description.
#
# stdout (success): the new issue identifier (e.g., PL-451), single line.
# stderr (failure): one-line diagnostic.
#
# Why a helper: no single `linear-cli` invocation combines "ensure the label exists",
# "Planned-state fallback", and "set assignee + label" — and inlining that as shell in a
# SKILL.md would trip permission prompts on every reflection. The issue is deliberately
# STANDALONE (no parent link): a config/process improvement is not a child of the feature
# that surfaced it; /reflect references the originating issue inside the body instead. This
# mirrors scripts/linear-create-child.sh in style, minus the parent plumbing.
#
# Read-write: ensures the `ai-generated` issue label exists and creates one Linear issue.
#
# The label is BEST EFFORT: it must exist for the issue's TEAM (Linear rejects a cross-team
# label), and the CLI cannot create a team-scoped one — so a team that lacks it yields a
# filed-but-unlabelled issue plus a WARN, signalled by exit 2 (not a hard failure). Losing
# the proposal is the worse outcome.
#
# Exit codes:
#   0 = issue created (Planned, self-assigned) AND ai-generated label attached; id on stdout
#   2 = issue created (Planned, self-assigned) but the label could NOT be attached (team has
#       no attachable ai-generated label); id still on stdout, WARN on stderr
#   1 = usage / missing body file / no suitable state / create failed (no usable id)

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 3 ]; then
  echo "usage: linear-file-improvement.sh <team> <title> <body-file>" >&2
  exit 1
fi

team="$1"
title="$2"
body_file="$3"

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done
if [ ! -f "$body_file" ]; then
  echo "ERROR: body file not found: $body_file" >&2
  exit 1
fi

# Recursively pluck every `name` field regardless of the JSON envelope shape (array vs
# {labels:[...]} vs {nodes:[...]}), so this survives linear-cli output-shape changes.
names() { jq -r '.. | objects | select(has("name")) | .name'; }

# 1. Ensure an `ai-generated` ISSUE label exists. Two `-t issue` gotchas, both load-bearing:
#    - `labels list` with no `-t` returns PROJECT labels (its default) — so the existence
#      probe MUST pass `-t issue`, or it misses real issue labels and we'd create a junk one.
#    - `labels create` also defaults to `--type project`, and project labels can't go on
#      issues — so create with `-t issue`.
#    Both probe and create are WORKSPACE-WIDE (`-t` is the label TYPE, not a team filter, and
#    `labels create` has no --team) — so this only provisions a label for a workspace that has
#    NO ai-generated issue label at all. It canNOT create a team-scoped label, so a team that
#    lacks one still degrades to the best-effort WARN in step 4. Tolerate a concurrent create
#    (another session filing at the same moment) — "already exists" is success here.
have_label=$(linear-cli labels list -t issue -o json 2>/dev/null | names 2>/dev/null | grep -Fxi 'ai-generated' || true)
if [ -z "$have_label" ]; then
  linear-cli labels create "ai-generated" -t issue >/dev/null 2>&1 || true
fi

# 2. Resolve the workflow state up front. Prefer Planned; deferred-but-triaged proposals
#    should not land in Triage. Fall back to the first Backlog/Todo-like state, mirroring
#    /quality-review Step 6's algorithm — `ready` is intentionally excluded so we never
#    latch onto "Ready For Release"/"Ready For Review".
states_json=$(linear-cli statuses list -t "$team" -o json 2>/dev/null || echo '[]')
state=$(printf '%s' "$states_json" | names | grep -Fxi 'Planned' | head -1 || true)
if [ -z "$state" ]; then
  state=$(printf '%s' "$states_json" | names | grep -iE '^(planned|backlog|to.?do)$' | head -1 || true)
fi
if [ -z "$state" ]; then
  avail=$(printf '%s' "$states_json" | names | paste -sd, - 2>/dev/null || true)
  echo "ERROR: no Planned/Backlog/Todo-like state for team '$team' (available: ${avail:-none})" >&2
  exit 1
fi

# 3. Create the issue with state + self-assignment (both reliably supported on create).
# `-q` suppresses decorative tips/banners so stdout is pure JSON (matches the sibling api
# scripts). `-- "$title"` after the options so a title beginning with `-` is never parsed as
# a flag (clap otherwise reads e.g. `-p ...` as --priority). The `|| true` on the jq is
# belt-and-suspenders against any stray non-JSON create stdout aborting under `set -e`
# before the empty-id guard below.
created=$(linear-cli issues create -q --team "$team" --state "$state" --assignee me -o json -d - -- "$title" < "$body_file") || {
  echo "ERROR: failed to create issue '$title'" >&2; exit 1; }
new_id=$(printf '%s' "$created" | jq -r '.identifier // .id // empty' 2>/dev/null || true)
if [ -z "$new_id" ]; then
  echo "ERROR: issue created but no identifier returned" >&2
  exit 1
fi

# 4. Attach the `ai-generated` label — BEST EFFORT. An `ai-generated` issue label must exist
#    FOR THIS ISSUE'S TEAM; Linear rejects a cross-team label with "labelIds for incorrect
#    team", and the CLI cannot create a team-scoped label (no --team on `labels create`). A
#    missing team label degrades to a filed-but-unlabelled issue + WARN + exit 2 — a distinct,
#    machine-readable signal so the caller can annotate the outcome without scraping stderr.
#    The id is printed FIRST so it reaches stdout on every path; losing the proposal is impossible.
printf '%s\n' "$new_id"
if ! linear-cli issues update "$new_id" -l ai-generated >/dev/null 2>&1; then
  echo "WARN: filed $new_id but could not attach the 'ai-generated' label — most likely team '$team' has no attachable ai-generated issue label (create one scoped to '$team', or a workspace-level label, in Linear); a transient linear-cli error is also possible" >&2
  exit 2
fi
