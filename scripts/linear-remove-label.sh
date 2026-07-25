#!/bin/bash
# linear-remove-label.sh — remove ONE issue label from a Linear issue, preserving the rest.
#
# Usage: linear-remove-label.sh <ISSUE-ID> <label>
#
# Mirror of linear-add-label.sh: `linear-cli issues update -l` SETS the whole label set,
# so removal is read-filter-set. One extra wrinkle removal has that add doesn't: a result
# of ZERO labels cannot be expressed via -l flags (omitting them means "don't touch
# labels"), so that case falls back to a raw issueUpdate with labelIds: [].
#
# Exit codes:
#   0 = label absent from the issue (including already-absent no-op)
#   1 = usage error, missing dependency, or the issue could not be read/parsed
#   2 = the update failed, or it succeeded but verification could not confirm it

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 2 ] || [ -z "$2" ]; then
  echo "usage: linear-remove-label.sh <ISSUE-ID> <label>" >&2
  exit 1
fi

issue_id=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
label="$2"
if ! [[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue id '$issue_id' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi
if [[ "$label" == -* ]] || [[ "$label" =~ [[:cntrl:]] ]]; then
  echo "usage: linear-remove-label.sh <ISSUE-ID> <label> — label must not start with '-' or contain control characters" >&2
  exit 1
fi

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

label_names() { jq -r '.labels | (if type == "object" then (.nodes // []) else . end) | .[]?.name? // empty'; }

# Same shape guard as linear-add-label.sh: a GraphQL error envelope or degenerate labels
# field must not read as "zero labels" — on the initial read that would no-op a real
# removal; on the verify re-read it would falsely confirm one.
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
  echo "ERROR: could not read/parse $issue_id (linear-cli returned unexpected output, not the issue with its labels field)" >&2
  exit 1
fi
current=$(printf '%s' "$issue_json" | label_names)

if ! grep -Fxqi -- "$label" <<< "$current"; then
  exit 0
fi

remaining=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" ]; then
    remaining+=("$name")
  fi
done <<< "$current"

if [ "${#remaining[@]}" -gt 0 ]; then
  args=()
  for name in "${remaining[@]}"; do
    args+=(-l "$name")
  done
  linear-cli issues update "$issue_id" "${args[@]}" >/dev/null 2>&1 \
    || { echo "ERROR: could not update $issue_id's label set to remove '$label'. Labels unchanged." >&2; exit 2; }
else
  issue_uuid=$(printf '%s' "$issue_json" | jq -r '.id // empty')
  if [ -z "$issue_uuid" ]; then
    echo "ERROR: $issue_id's JSON has no id field — cannot clear its last label via issueUpdate." >&2
    exit 2
  fi
  linear-cli api mutate 'mutation($id: String!) { issueUpdate(id: $id, input: { labelIds: [] }) { success } }' \
    --variable "id=$issue_uuid" >/dev/null 2>&1 \
    || { echo "ERROR: issueUpdate(labelIds: []) failed clearing '$label' from $issue_id. Labels unchanged." >&2; exit 2; }
fi

# `|| true` is load-bearing under set -e: a transient re-read failure must reach the
# handling below, not exit with the CLI's raw code.
after_json=$(linear-cli issues get "$issue_id" -o json -q --no-cache 2>/dev/null) || true
if [ -z "$after_json" ] || ! printf '%s' "$after_json" | is_issue_json; then
  echo "ERROR: removed '$label' from $issue_id but the verification re-read failed — the removal likely succeeded but could not be confirmed; re-run to verify." >&2
  exit 2
fi
after=$(printf '%s' "$after_json" | label_names)

if grep -Fxqi -- "$label" <<< "$after"; then
  echo "ERROR: '$label' is still on $issue_id after the update (concurrent modification?)." >&2
  exit 2
fi
missing=()
for name in "${remaining[@]}"; do
  grep -Fxqi -- "$name" <<< "$after" || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: removal dropped other labels on $issue_id — expected to keep [${remaining[*]}], missing [${missing[*]}]. Re-add them manually." >&2
  exit 2
fi
