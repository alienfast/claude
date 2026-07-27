#!/bin/bash
# linear-file-improvement.sh — file a single standalone "continuous-improvement" Linear
# issue from a /reflect session: status Planned, labelled `specified` + `reflection`,
# description read from a file. `specified` is the /auto-eligibility certification;
# `reflection` marks it as a config/process improvement so /next ranks it ahead of
# product work (improvements change how all future work runs).
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
# "Planned-state fallback", and "set label" — and inlining that as shell in a SKILL.md
# would trip permission prompts on every reflection. The issue is deliberately
# STANDALONE (no parent link): a config/process improvement is not a child of the feature
# that surfaced it; /reflect references the originating issue inside the body instead. It
# is also deliberately UNASSIGNED and unprioritized: the `specified` label (not assignment)
# is what keeps it visible to /auto, and without a priority it ranks as fill-in work
# rather than jumping the product backlog. This mirrors scripts/linear-create-child.sh
# in style, minus the parent plumbing.
#
# Read-write: ensures the `specified` issue label exists and creates one Linear issue.
#
# The label is BEST EFFORT: it must be attachable for the issue's TEAM (Linear rejects a
# cross-team label), and the CLI cannot create a team-scoped one — so a team that lacks it
# yields a filed-but-unlabelled issue plus a WARN, signalled by exit 2 (not a hard
# failure). Losing the proposal is the worse outcome — but an unlabelled issue is
# invisible to /auto until certified (standards/issue-spec.md).
#
# Exit codes:
#   0 = issue created (Planned) AND specified label attached (reflection is best-effort
#       within 0 — a WARN names it when only specified could attach); id on stdout
#   2 = issue created (Planned) but the specified label could NOT be attached (team has
#       no attachable specified label); id still on stdout, WARN on stderr
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

# 1. Ensure the `specified` and `reflection` ISSUE labels exist (one probe, shared by both). Two `-t issue` gotchas, both load-bearing:
#    - `labels list` with no `-t` returns PROJECT labels (its default) — so the existence
#      probe MUST pass `-t issue`, or it misses real issue labels and we'd create a junk one.
#    - `labels create` also defaults to `--type project`, and project labels can't go on
#      issues — so create with `-t issue`.
#    `--all` makes the probe pagination-safe (a workspace with many issue labels could
#    otherwise miss `specified` on a later page and create a duplicate). The probe's grep
#    output IS the workspace's canonical-cased name (e.g. "Specified") — captured below and
#    reused for the attach in step 4, since Linear label matching is case-sensitive there.
#    `--no-cache` avoids a stale miss if the label was just created (e.g. via the Linear UI
#    right after an earlier exit-2 WARN).
#    Both probe and create are WORKSPACE-WIDE (`-t` is the label TYPE, not a team filter, and
#    `labels create` has no --team) — so this only provisions a label for a workspace that has
#    NO specified issue label at all. It canNOT create a team-scoped label, so a team that
#    lacks one still degrades to the best-effort WARN in step 4. Tolerate a concurrent create
#    (another session filing at the same moment) — "already exists" is success here.
all_labels=$(linear-cli labels list -t issue --all --no-cache -o json 2>/dev/null | names 2>/dev/null || true)
have_specified=$(printf '%s' "$all_labels" | grep -Fxi 'specified' | head -1 || true)
if [ -z "$have_specified" ]; then
  linear-cli labels create "specified" -t issue >/dev/null 2>&1 || true
fi
specified_label="${have_specified:-specified}"
have_reflection=$(printf '%s' "$all_labels" | grep -Fxi 'reflection' | head -1 || true)
if [ -z "$have_reflection" ]; then
  linear-cli labels create "reflection" -t issue >/dev/null 2>&1 || true
fi
reflection_label="${have_reflection:-reflection}"

# 2. Resolve the workflow state up front. Prefer Planned; deferred-but-triaged proposals
#    should not land in Triage. Fall back to the first Backlog/Todo-like state, mirroring
#    /quality-review Step 6's algorithm — `ready` is intentionally excluded so we never
#    latch onto "Ready For Release"/"Ready For Review".
if ! states_json=$(linear-cli statuses list -t "$team" -o json 2>/dev/null); then
  echo "ERROR: could not list workflow states for team '$team' (auth? network?)" >&2
  exit 1
fi
state=$(printf '%s' "$states_json" | names | grep -Fxi 'Planned' | head -1 || true)
if [ -z "$state" ]; then
  state=$(printf '%s' "$states_json" | names | grep -iE '^(planned|backlog|to.?do)$' | head -1 || true)
fi
if [ -z "$state" ]; then
  avail=$(printf '%s' "$states_json" | names | paste -sd, - 2>/dev/null || true)
  echo "ERROR: no Planned/Backlog/Todo-like state for team '$team' (available: ${avail:-none})" >&2
  exit 1
fi

# 3. Create the issue with the resolved state. `-q` suppresses decorative tips/banners so
# stdout is pure JSON (matches the sibling api scripts). `-- "$title"` after the options so
# a title beginning with `-` is never parsed as a flag (clap otherwise reads e.g. `-p ...`
# as --priority). The `|| true` on the jq is belt-and-suspenders against any stray non-JSON
# create stdout aborting under `set -e` before the empty-id guard below.
created=$(linear-cli issues create -q --team "$team" --state "$state" -o json -d - -- "$title" < "$body_file") || {
  echo "ERROR: failed to create issue '$title'" >&2; exit 1; }
new_id=$(printf '%s' "$created" | jq -r '.identifier // .id // empty' 2>/dev/null || true)
if [ -z "$new_id" ]; then
  echo "ERROR: issue created but no identifier returned" >&2
  exit 1
fi

# 4. Attach the `specified` + `reflection` labels — BEST EFFORT (cross-team constraint documented above in the
#    header and step 1). The direct `-l` (not linear-add-label.sh) is deliberate — do not "fix" it to call that
#    helper: this issue was just created with an empty label set, so replace semantics are harmless and skipping
#    the helper saves API calls. Both labels must ride ONE update (-l sets the whole set; two sequential updates
#    would clobber the first label with the second). The id is printed FIRST, before the attach attempt, so it
#    reaches stdout on every path. If the pair fails, retry `specified` alone: certification is the load-bearing
#    label (/auto eligibility), and a missing/team-scoped `reflection` label must never cost the pickup.
printf '%s\n' "$new_id"
if linear-cli issues update "$new_id" -l "$specified_label" -l "$reflection_label" >/dev/null 2>&1; then
  exit 0
fi
if linear-cli issues update "$new_id" -l "$specified_label" >/dev/null 2>&1; then
  echo "WARN: filed $new_id with 'specified' but could not attach the 'reflection' label — /next will rank it as ordinary certified work instead of boosting it. Most likely team '$team' has a conflicting team-scoped reflection label (create an attachable one: linear-cli labels create \"reflection\" -t issue)" >&2
  exit 0
fi
echo "WARN: filed $new_id but could not attach the 'specified' label — /auto will not pick it up until it is labeled. Most likely team '$team' has no attachable specified issue label (create one: linear-cli labels create \"specified\" -t issue); a transient linear-cli error is also possible" >&2
exit 2
