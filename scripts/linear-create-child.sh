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
#                skip. BEST EFFORT: the id still prints and the parent link is still
#                attempted; a failed attach exits 2 (filed-but-unlabelled; 4 when the
#                parent was also at the nesting cap), mirroring linear-file-improvement.sh.
#   <priority>   Optional Linear priority (0=none 1=urgent 2=high 3=normal 4=low), or
#                "-" / "" / omitted to skip. Set at create time. A severity graded into
#                an issue BODY is invisible to /next's priority_rank — this field is
#                what the ranking actually reads (BF-583).
#
# stdout: the new issue identifier (e.g., PL-451), single line — printed on EVERY path
#         where the issue was created, including the degraded ones (exits 2/3/4 and the
#         post-create exit-1 cases). Empty stdout means no issue exists.
# stderr (failure/degraded): one-line diagnostic.
#
# Why a helper: `linear-cli issues create` has no `--parent` flag. You *can* set the
# parent's UUID as `parentId` via `--data` JSON (it carries `description` too on 0.3.26),
# but a bare create — `--data` or otherwise — never confirms the link took. So this
# creates the issue with the description via `-d -` (robust stdin for large markdown
# bodies, no JSON-escaping or ARG_MAX concerns), links the parent with `relations parent`,
# and then VERIFIES the link — failing hard on an orphan, with one benign exception: a
# parent at Linear's sub-issue nesting cap (10 ancestors) deterministically rejects every
# new child, so the helper wires a `related` peer edge instead and exits 3 (or 4). The
# verification is what makes this safe: the orphan the "create then forget to link"
# anti-pattern risks cannot slip through. Centralizing it lets /prd and /quality-review
# file parent-linked issues without inline shell plumbing.
#
# Read-write: creates one Linear issue (and sets its parent; optionally attaches a label).
#
# Exit codes:
#   0 = created, (if a parent was given) linked + verified, (if a label was given)
#       attached; identifier on stdout
#   2 = created and linked + verified, but the requested label could NOT be attached;
#       id still on stdout, WARN on stderr
#   3 = created and labelled, but the parent is at Linear's sub-issue nesting cap so the
#       parent link was REJECTED (deterministic — retrying never helps); wired as a
#       `related` peer edge instead. id on stdout, WARN on stderr. Callers: the issue
#       EXISTS and is fully usable — do NOT treat the item as unfiled; annotate it as
#       related-not-sub-issue.
#   4 = both 2 and 3: parent at cap (`related` edge wired) AND the label attach failed
#   1 = usage / missing body file / create failed / no identifier returned — or created
#       but the state or the parent linkage could not be established at all (stderr says
#       which; id already on stdout whenever the issue exists)

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
# Resolve a workable state whenever the caller did not name one. "Team default" is NOT a
# safe fallback: on a triage-enabled team, omitting --state lands the issue in Triage, and
# next-candidates.sh's WORKABLE_STATES covers only Backlog/Planned/Todo — so a `specified`
# issue filed that way is invisible to /next and /auto permanently, with no note anywhere
# (the hidden-count notes cover the label gates only). Verified on BF: --state Planned
# lands in Planned, omitting it lands in Triage. Same preference order and `ready`
# exclusion as linear-file-improvement.sh, which already guards this.
if [ -z "$state" ] || [ "$state" = "-" ]; then
  if states_json=$(linear-cli statuses list -t "$team" -o json 2>/dev/null); then
    state_names=$(printf '%s' "$states_json" | jq -r '.. | objects | select(has("name")) | .name' 2>/dev/null || true)
    state=$(printf '%s\n' "$state_names" | grep -Fxi 'Planned' | head -1 || true)
    [ -z "$state" ] && state=$(printf '%s\n' "$state_names" | grep -iE '^(planned|backlog|to.?do)$' | head -1 || true)
  fi
fi
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

# stdout FIRST — the id must reach the caller's `id=$(...)` on every path where the issue
# exists. Printing it only after a successful parent link turned a benign nesting-cap
# rejection into an empty capture and an `Argument Validation Error` downstream (BF-723).
printf '%s\n' "$new_id"

# Verify the state landed. `issues create --state` can report success without the state
# taking (the create sibling of linear/SKILL.md gotcha #8), and the silent-failure landing
# spot on a triage-enabled team is Triage — invisible to /next forever. Correct it rather
# than failing: the issue and its body already exist, and stranding it is the outcome this
# check exists to prevent. Only a state we could not fix is worth aborting for.
if [ -n "$state" ] && [ "$state" != "-" ]; then
  landed=$(linear-cli issues get "$new_id" -o json --no-cache 2>/dev/null | jq -r '.state.name // empty')
  if [ -n "$landed" ] && ! printf '%s' "$landed" | grep -Fqxi -- "$state"; then
    linear-cli issues update "$new_id" -s "$state" >/dev/null 2>&1 || true
    landed=$(linear-cli issues get "$new_id" -o json --no-cache 2>/dev/null | jq -r '.state.name // empty')
    if ! printf '%s' "$landed" | grep -Fqxi -- "$state"; then
      echo "ERROR: created $new_id but its state is '${landed:-unknown}', expected '$state', and the correcting update did not take" >&2
      exit 1
    fi
  fi
fi

# Attach the optional label BEFORE the parent link — labels do not depend on the parent,
# and ordering them after it meant every parent failure filed an unlabeled issue, which
# without `specified` is invisible to /auto and unranked by /next (BF-703). Probe/create
# mechanics mirror linear-file-improvement.sh (the `-t issue` gotchas and the
# canonical-casing capture are documented there); the direct `-l` replace semantics are
# safe only because this issue was just created with an empty label set
# (standards/issue-spec.md — existing issues must go through linear-add-label.sh instead).
label_failed=0
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
    label_failed=1
  fi
fi

# Link the parent (relations parent <CHILD> <PARENT>) and VERIFY it took — a created
# issue with no linkage at all is the orphan this helper exists to prevent. One benign
# exception: Linear caps sub-issue nesting at 10 ancestors, and a parent already at the
# cap rejects every new child with `GraphQL error: invalid parent` — deterministic, so
# retrying never helps. Pre-detect it (Linear exposes no depth field, but `parent{}`
# nests in a single read-only query) and wire a `related` peer edge up front instead of
# creating an orphan and discovering it after (BF-723).
capped=0
if [ -n "$parent" ] && [ "$parent" != "-" ]; then
  chain=$(linear-cli api query 'query($id:String!){issue(id:$id){identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier parent{identifier}}}}}}}}}}}}' \
    --variable "id=$parent" 2>/dev/null | jq '[.. | objects | .identifier? // empty] | length' 2>/dev/null || echo 0)
  [ "${chain:-0}" -ge 11 ] && capped=1

  if [ "$capped" -eq 0 ]; then
    perr=$(linear-cli relations parent "$new_id" "$parent" 2>&1 >/dev/null) || {
      case "$perr" in
        *"invalid parent"*) capped=1 ;;   # backstop: pre-check raced or under-counted
        *) echo "ERROR: created $new_id but 'relations parent $new_id $parent' failed — issue has no parent link: $perr" >&2; exit 1 ;;
      esac
    }
  fi

  if [ "$capped" -eq 1 ]; then
    # Peer edge instead of a parent edge. If THIS fails the issue has no linkage at all —
    # that is the orphan this helper exists to prevent, so it stays a hard failure.
    if ! linear-cli relations add "$new_id" "$parent" -r related >/dev/null 2>&1; then
      echo "ERROR: created $new_id, parent '$parent' is at Linear's sub-issue nesting cap, AND the 'related' fallback failed — issue is orphaned" >&2
      exit 1
    fi
    echo "WARN: created $new_id but parent '$parent' is at Linear's sub-issue nesting cap (10 ancestors) — wired as 'related' instead of a sub-issue" >&2
  else
    linked=$(linear-cli issues get "$new_id" -o json 2>/dev/null | jq -r '.parent.identifier // empty')
    if [ "$linked" != "$parent" ]; then
      echo "ERROR: created $new_id but its parent is '${linked:-none}', expected '$parent' — link failed" >&2
      exit 1
    fi
  fi
fi

if [ "$label_failed" -eq 1 ] && [ "$capped" -eq 1 ]; then
  exit 4
elif [ "$label_failed" -eq 1 ]; then
  exit 2
elif [ "$capped" -eq 1 ]; then
  exit 3
fi
exit 0
