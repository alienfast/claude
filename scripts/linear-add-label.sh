#!/bin/bash
# linear-add-label.sh — add ONE issue label to a Linear issue without clobbering the rest.
#
# Usage: linear-add-label.sh <ISSUE-ID> <label>
#
# Why a helper: `linear-cli issues update -l` SETS the whole label set (there is no
# add/remove subcommand), so an additive label requires read-merge-set — fetch current
# names, re-send them all plus the new one. Centralizing that keeps skills from
# hand-rolling the merge and silently dropping labels. Both reads use --no-cache: a
# stale initial read could re-send a label set that's missing a label another actor
# just added (silently deleting it), and the verify re-read needs fresh data to
# confirm the attach actually landed.
#
# Exit codes:
#   0 = label present on the issue (including already-present no-op)
#   1 = usage error (bad issue id, invalid label), missing dependency, or the issue
#       could not be read/parsed
#   2 = the attach failed, or it succeeded but verification could not confirm it
#       (concurrent label change, or a transient re-read failure) — stderr names
#       the case and, for a missing label: linear-cli labels create "<label>" -t issue

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 2 ] || [ -z "$2" ]; then
  echo "usage: linear-add-label.sh <ISSUE-ID> <label>" >&2
  exit 1
fi

issue_id=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
label="$2"
if ! [[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue id '$issue_id' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi
# clap would misparse a leading '-' as a flag, and control characters (incl. newlines)
# break the line-oriented grep matching used below.
if [[ "$label" == -* ]]; then
  echo "usage: linear-add-label.sh <ISSUE-ID> <label> — label must not start with '-'" >&2
  exit 1
fi
if [[ "$label" =~ [[:cntrl:]] ]]; then
  echo "usage: linear-add-label.sh <ISSUE-ID> <label> — label must not contain newlines or control characters" >&2
  exit 1
fi

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

# Tolerates the two labels shapes is_issue_json() accepts below: {nodes:[...]} (today's shape) or
# a bare array (if the CLI changes).
label_names() { jq -r '.labels | (if type == "object" then (.nodes // []) else . end) | .[]?.name? // empty'; }

# Recursively plucks every `name` field regardless of the `labels list` envelope shape.
workspace_label_names() { jq -r '.. | objects | select(has("name")) | .name'; }

# A bare `jq -e .` accepts any truthy JSON — a GraphQL error envelope ({"errors":[...]}) then misreads as
# "zero labels", while a bare array or scalar crashes label_names outside the 0/1/2 exit contract. The
# "zero labels" misread is wrong on both call sites this guards: on the initial read it would make the
# update below REPLACE the whole label set with just the new one; on the verify re-read it would falsely
# trigger the concurrent-modification alarm. has("labels") alone isn't enough: `.labels: null` passes it
# but reads as zero labels, and `.labels: "weird"` passes it but reads as zero labels too. Require labels
# to be an array of objects with non-degenerate string names, in either shape label_names tolerates:
# {nodes:[...]} or a bare array.
is_issue_json() {
  jq -e --arg id "$issue_id" '
    def usable: type == "array" and all(.[];
      type == "object"
      and (.name | type) == "string"
      and .name != ""
      and (.name | test("[\\x00-\\x1f]") | not)
    );
    type == "object" and .identifier == $id
    and (
      ((.labels | type) == "object" and (.labels.nodes | usable))
      or (.labels | usable)
    )' >/dev/null 2>&1
}

issue_json=$(linear-cli issues get "$issue_id" -o json -q --no-cache 2>/dev/null) \
  || { echo "ERROR: could not read $issue_id (auth? network? bad id?)" >&2; exit 1; }
if ! printf '%s' "$issue_json" | is_issue_json; then
  returned_id=$(printf '%s' "$issue_json" | jq -r '.identifier // empty' 2>/dev/null) || true
  echo "ERROR: could not read/parse $issue_id (linear-cli returned unexpected output, not the issue with its labels field)${returned_id:+ (CLI returned issue $returned_id)}" >&2
  exit 1
fi
current=$(printf '%s' "$issue_json" | label_names)

if grep -Fxqi -- "$label" <<< "$current"; then
  exit 0
fi

# Attach path only (the no-op above stays probe-free): resolve the workspace's canonical
# casing first, or a case-differing label (e.g. "Specified" vs "specified") fails the
# attach persistently and points the caller toward creating a duplicate. --no-cache avoids
# a stale miss if the label was just created (e.g. right after an earlier exit-2 pointer).
canonical=$(linear-cli labels list -t issue --all --no-cache -o json 2>/dev/null | workspace_label_names 2>/dev/null | grep -Fxi -- "$label" | head -1 || true)
[ -n "$canonical" ] && label="$canonical"

current_names=()
while IFS= read -r name; do
  [ -n "$name" ] && current_names+=("$name")
done <<< "$current"

args=()
for name in "${current_names[@]}"; do
  args+=(-l "$name")
done
args+=(-l "$label")

fail() {
  echo "ERROR: could not attach '$label' to $issue_id — the label may not exist (create it: linear-cli labels create \"$label\" -t issue), may be scoped to another team, or a transient linear-cli error occurred. Existing labels were preserved." >&2
  exit 2
}

linear-cli issues update "$issue_id" "${args[@]}" >/dev/null 2>&1 || fail

# `|| true` is load-bearing: under `set -e`, a bare non-zero here would exit the script
# immediately with the CLI's raw code, skipping the verify-failure handling below.
after_json=$(linear-cli issues get "$issue_id" -o json -q --no-cache 2>/dev/null) || true
if [ -z "$after_json" ] || ! printf '%s' "$after_json" | is_issue_json; then
  returned_id=$(printf '%s' "$after_json" | jq -r '.identifier // empty' 2>/dev/null) || true
  echo "ERROR: attached '$label' to $issue_id but the verification re-read failed (transient linear-cli/network error) — the attach likely succeeded but could not be confirmed; re-run to verify.${returned_id:+ (CLI returned issue $returned_id)}" >&2
  exit 2
fi
after=$(printf '%s' "$after_json" | label_names)

# Confirm every label that was sent is still present, not just the new one — a concurrent
# add/remove between the read and the write would otherwise exit 0 silently.
expected=("${current_names[@]}" "$label")
missing=()
for name in "${expected[@]}"; do
  grep -Fxqi -- "$name" <<< "$after" || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: label set on $issue_id may have been modified concurrently — expected [${expected[*]}], found [$(printf '%s' "$after" | tr '\n' ' ')], missing [${missing[*]}]." >&2
  exit 2
fi
