#!/bin/bash
# linear-create-child.sh — create a Linear issue (optionally linked to a parent),
# with its description read from a file, and verify the parent link took.
#
# Usage: linear-create-child.sh [--allow-planned] [--allow-unrouted] [--search <token>]... [--seen <ID>]...
#                               <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]
#
#   --allow-planned  Required (leading) to pass `Planned` as the state. Unattended filings land in
#                Backlog — the human curates Planned (keeper ruling 2026-08-15) — and a caller-passed
#                Planned without this flag is refused before anything is created. The flag doubles as
#                the audit record that the placement was deliberate: quality-review's recipe passes it
#                only on its Critical/High-or-security path, and interactive skills (/spec, /prd) pass
#                it as the human-in-the-loop placement. Only the CALLER-passed state is gated — the
#                internal fallback below stays exempt, since it can resolve `planned` only when the
#                team has no Backlog/Todo state and refusing there would strand the filing in Triage.
#   --allow-unrouted  Required (leading, in either order with --allow-planned) to file with no routing
#                label in the slot: none of specified / needs decision / human / keeper, nor sentry /
#                dependencies, the two producer labels standards/issue-spec.md treats as routing.
#                Without it the call is refused before anything is created. The flag is the audit
#                record that the caller attaches the routing label in a later step of the same run —
#                quality-review's recipe certifies last, and /prd and /spec batches certify after
#                their collision pass.
#   --search <token>  Leading, repeatable: re-run linear-dedup-search.sh with these tokens (the filer's own
#                standards/linear-filing.md § 1 tokens) immediately before the create. An open hit filed in the
#                last LINEAR_CREATE_RECENT_MIN minutes (default 60) that is not acknowledged refuses the create
#                with exit 5. The filer's own search is a snapshot, and a sibling session can file the same fix
#                after it: on 2026-11-15 three sessions filed one fix shape within 4.5 minutes (BF-3306, BF-3310,
#                BF-3311), one off a search 14 minutes old, and two of them shipped rival hooks. Older hits were
#                there for the filer's own search to weigh, so they never refuse.
#   --seen <ID>  Leading, repeatable: acknowledge a hit the filer has already weighed. The parent and every
#                identifier the body names count as acknowledged without it.
#   <parent>     Parent issue identifier (e.g., PL-396) to link under, or "-" / ""
#                for a top-level issue.
#   <team>       Team key or name (e.g., PL).
#   <state>      Workflow state name (e.g., Backlog), or "-" / "" for the team default.
#   <title>      Issue title.
#   <body-file>  Path to a file holding the markdown description.
#   <label>      Optional issue label(s) to attach after create — a single name or a
#                comma-separated list (e.g., "specified,bug"), or "-" / "" / omitted to
#                skip (which, like a slot of class labels only, needs --allow-unrouted).
#                Must already exist in the workspace: a near-miss heals to the
#                canonical label, but a novel name is refused, never minted. BEST EFFORT:
#                the id still prints and the parent link is still attempted; a failed
#                attach exits 2 (filed-but-unlabelled; 4 when the parent was also at the
#                nesting cap), mirroring linear-file-improvement.sh.
#   <priority>   Optional Linear priority (0=none 1=urgent 2=high 3=normal 4=low), or
#                "-" / "" / omitted to skip. Set at create time. A severity graded into
#                an issue BODY is invisible to /next's priority_rank — this field is
#                what the ranking actually reads (BF-583).
#
# stdout: the new issue identifier (e.g., PL-451), single line — printed on EVERY path
#         where the issue was created, including the degraded ones (exits 2/3/4 and the
#         post-create exit-1 cases). Empty stdout means no issue exists.
# stderr (failure/degraded): one-line diagnostic. An exit 0 can also carry a WARN: the state
#         could not be read back, or the parent link was accepted on the link mutation's own
#         answer, or only after a second link.
#
# Why a helper: `linear-cli issues create` has no `--parent` flag. You *can* set the
# parent's UUID as `parentId` via `--data` JSON (it carries `description` too on 0.3.26),
# but a bare create — `--data` or otherwise — never confirms the link took. So this
# creates the issue with the description via `-d -` (robust stdin for large markdown
# bodies, no JSON-escaping or ARG_MAX concerns), links the parent with `relations parent`,
# and then VERIFIES the link from that mutation's own answer and a read of the issue,
# re-issuing it once before failing hard on an orphan, with one benign exception: a
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
#   5 = refused pre-create — nothing exists: --search found an unacknowledged open issue filed inside the
#       window; stderr lists each hit. Read them per standards/linear-filing.md § 1, then re-run.
#   1 = usage / caller-passed Planned without --allow-planned, or an unrouted label slot without
#       --allow-unrouted (both refused pre-create — nothing exists) / missing body file / the --search
#       re-search or its recent-filings read failed or was rate limited (pre-create — nothing exists) /
#       create failed / no identifier returned — or created but the state or the parent linkage could
#       not be established at all (stderr says which; id already on stdout whenever the issue
#       exists)

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

allow_planned=0
allow_unrouted=0
search_tokens=()
seen_ids=()
while :; do
  case "${1:-}" in
    --allow-planned)  allow_planned=1;  shift ;;
    --allow-unrouted) allow_unrouted=1; shift ;;
    --search|--seen)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 needs a non-empty value" >&2
        exit 1
      fi
      if [ "$1" = "--search" ]; then search_tokens+=("$2"); else seen_ids+=("$2"); fi
      shift 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 5 ] || [ $# -gt 7 ]; then
  echo "usage: linear-create-child.sh [--allow-planned] [--allow-unrouted] [--search <token>]... [--seen <ID>]... <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]" >&2
  exit 1
fi

parent="$1"
team="$2"
state="$3"
title="$4"
body_file="$5"
label="${6:-}"
priority="${7:-}"

# Gate the CALLER-passed state only (the internal fallback below is exempt — see header). Runs
# before any create, so a refusal leaves nothing behind.
if [ "$allow_planned" -eq 0 ] && [ -n "$state" ] && [ "$state" != "-" ] && printf '%s' "$state" | grep -qxi 'planned'; then
  echo "ERROR: refusing caller-passed state 'Planned' without --allow-planned (leading flag) — unattended filings land in Backlog, the human curates Planned (keeper ruling 2026-08-15). Pass --allow-planned only when the placement is deliberate: Critical/High or security-labeled per quality-review's recipe, or a human-in-the-loop interactive filing" >&2
  exit 1
fi

# Routing gate — standards/issue-spec.md § An agent filing never lands unrouted. Pre-create, like the
# Planned gate: a refusal leaves nothing behind. The set is the standard's own — its four routing labels
# plus the two producer labels it treats as self-routing. The verdict writer's read-back sees only ids a
# verdict lists, so a follow-up filed outside one was never checked — measured 2026-10-04: one filed
# mid-implementation with `bug` alone sat unrouted 17.5 hours, until the next retro's filing audit.
norm() { tr '[:upper:]' '[:lower:]' | tr -d ' _-'; }
routed=0
if [ -n "$label" ] && [ "$label" != "-" ]; then
  IFS=',' read -ra _probe <<< "$label"
  for lb in "${_probe[@]}"; do
    case "$(printf '%s' "$lb" | norm)" in
      specified|needsdecision|human|keeper|sentry|dependencies) routed=1 ;;
    esac
  done
fi
if [ "$routed" -eq 0 ] && [ "$allow_unrouted" -eq 0 ]; then
  echo "ERROR: refusing to file UNROUTED — the label slot ('${label:-<empty>}') carries none of specified / needs decision / human / keeper (nor sentry / dependencies, the two producer labels standards/issue-spec.md treats as routing), and nothing ranks or parks an unrouted issue. Nothing was created: this is a refused invocation, not a failed create — correct it and re-run. Put a routing label in the slot (e.g. 'bug,specified', or 'needs decision'), or — only when a later step of THIS run attaches one, as /quality-review's filing recipe does at 'Certify last' — pass the leading flag --allow-unrouted" >&2
  exit 1
fi

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done
if [ ! -f "$body_file" ]; then
  echo "ERROR: body file not found: $body_file" >&2
  exit 1
fi

if [ "${#search_tokens[@]}" -gt 0 ]; then
  recent_min="${LINEAR_CREATE_RECENT_MIN:-60}"
  if ! [[ "$recent_min" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LINEAR_CREATE_RECENT_MIN must be a positive whole number of minutes (got '$recent_min')" >&2
    exit 1
  fi
  dedup_err=$(mktemp)
  trap 'rm -f "$dedup_err"' EXIT
  drc=0
  hits=$("$(dirname "$0")/linear-dedup-search.sh" "${search_tokens[@]}" 2>"$dedup_err") || drc=$?
  if [ "$drc" -eq 3 ]; then
    echo "ERROR: the create-time search was rate limited — nothing was created; wait for the hourly window, then re-run the same create: $(head -1 "$dedup_err")" >&2
    exit 1
  elif [ "$drc" -ne 0 ]; then
    echo "ERROR: the create-time search failed (linear-dedup-search.sh exit $drc) — nothing was created: $(head -3 "$dedup_err" | tr '\n' ' ')" >&2
    exit 1
  fi

  open_hits=$(printf '%s\n' "$hits" | grep -v -e '^prior-art: ' -e '^$' || true)
  acknowledged=$( { printf '%s\n' "${seen_ids[@]}" "$parent"; grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' "$body_file" || true; } \
    | tr '[:lower:]' '[:upper:]' | grep . | sort -u || true)
  candidates=$(printf '%s\n' "$open_hits" | awk -F' [|] ' 'NF { print $1 }' | grep -vxF -f <(printf '%s\n' "$acknowledged") || true)

  if [ -n "$candidates" ]; then
    qrc=0
    recent=$(linear-cli api query 'query($since: DateTimeOrDuration!) { issues(filter: { createdAt: { gte: $since } }, first: 250) { nodes { identifier createdAt } } }' \
      --variable "since=-PT${recent_min}M" -o json 2>&1) || qrc=$?
    if [ "$qrc" -ne 0 ] || ! printf '%s' "$recent" | jq -e '.data.issues.nodes | type == "array"' >/dev/null 2>&1; then
      if printf '%s' "$recent" | grep -qE 'RATELIMITED|Rate limit exceeded'; then
        next="rate limited: wait for the hourly window, then re-run the same create"
      else
        next="re-run the same create"
      fi
      echo "ERROR: could not read the issues filed in the last ${recent_min} minutes — nothing was created; ${next}: $(printf '%s' "$recent" | head -2 | tr '\n' ' ')" >&2
      exit 1
    fi
    blocking=$(printf '%s' "$recent" | jq -r '.data.issues.nodes[] | "\(.identifier)\t\(.createdAt)"' \
      | while IFS=$'\t' read -r id at; do
          printf '%s\n' "$candidates" | grep -qxF -- "$id" || continue
          printf '  %s | filed %s\n' "$(printf '%s\n' "$open_hits" | awk -F' [|] ' -v id="$id" '$1 == id { print; exit }')" "$at"
        done) || true
    if [ -n "$blocking" ]; then
      {
        echo "REFUSED: $(printf '%s\n' "$blocking" | grep -c .) open issue(s) filed in the last ${recent_min} minutes match --search and are not acknowledged — nothing was created:"
        printf '%s\n' "$blocking"
        echo "Read each one (standards/linear-filing.md § 1, On a hit): same root cause → append your evidence to it instead of filing; the same fix shape at another site → one issue, so regroup; adjacent but distinct → re-run this create with --seen <ID> and wire its edge in § 4."
      } >&2
      exit 5
    fi
  fi
fi

# Create with the description via `-d -` (stdin), then link the parent separately via
# `relations parent` so the link can be VERIFIED (below). The header explains why this
# two-step path is preferred over a single `--data` create.
create_args=(issues create "$title" --team "$team" -o json -d -)
# Resolve a workable state whenever the caller did not name one. "Team default" is NOT a
# safe fallback: on a triage-enabled team, omitting --state lands the issue in Triage, and
# next-candidates.sh's WORKABLE_STATES covers only Backlog/Planned/Todo — so a `specified`
# issue filed that way is invisible to /next and /auto permanently, with no note anywhere
# (the hidden-count notes cover the label gates only). Backlog, not Planned (keeper ruling
# 2026-08-15): unattended filings never enter the curated release scope — the human plans;
# Backlog + `specified` stays fleet-eligible via stage-first ranking. Same `ready`
# exclusion as linear-file-improvement.sh.
if [ -z "$state" ] || [ "$state" = "-" ]; then
  if states_json=$(linear-cli statuses list -t "$team" --no-cache -o json 2>/dev/null); then
    state_names=$(printf '%s' "$states_json" | jq -r '.. | objects | select(has("name")) | .name' 2>/dev/null || true)
    state=$(printf '%s\n' "$state_names" | grep -Fxi 'Backlog' | head -1 || true)
    [ -z "$state" ] && state=$(printf '%s\n' "$state_names" | grep -iE '^(backlog|planned|to.?do)$' | head -1 || true)
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
  # `|| true`: under `set -eo pipefail` a failed read would end the script here with linear-cli's own exit code (4 on a
  # rate limit), before the labels and the parent link, and 2, 3 and 4 each tell a caller the issue was filed.
  state_of() { linear-cli issues get "$new_id" -o json --no-cache 2>/dev/null | jq -r '.state.name // empty' 2>/dev/null || true; }
  landed=$(state_of)
  [ -n "$landed" ] || echo "WARN: created $new_id but its state could not be read back — '$state' is unverified" >&2
  if [ -n "$landed" ] && ! printf '%s' "$landed" | grep -Fqxi -- "$state"; then
    linear-cli issues update "$new_id" -s "$state" >/dev/null 2>&1 || true
    landed=$(state_of)
    if ! printf '%s' "$landed" | grep -Fqxi -- "$state"; then
      echo "ERROR: created $new_id but its state is '${landed:-unknown}', expected '$state', and the correcting update did not take" >&2
      exit 1
    fi
  fi
fi

# Attach the optional label BEFORE the parent link — labels do not depend on the parent,
# and ordering them after it meant every parent failure filed an unlabeled issue, which
# without `specified` is invisible to /auto and unranked by /next (BF-703). Probe
# mechanics mirror linear-file-improvement.sh (the `-t issue` gotchas and the
# canonical-casing capture are documented there); the direct `-l` replace semantics are
# safe only because this issue was just created with an empty label set
# (standards/issue-spec.md — existing issues must go through linear-add-label.sh instead).
label_failed=0
if [ -n "$label" ] && [ "$label" != "-" ]; then
  all_names=$(linear-cli labels list -t issue --all --no-cache -o json 2>/dev/null \
    | jq -r '.. | objects | select(has("name")) | .name' 2>/dev/null || true)
  # Normalized identity, mirroring linear-add-label.sh's healing: a multi-word label must keep its
  # internal spacing (the old `tr -d '[:space:]'` turned `needs decision` into `needsdecision`,
  # missed the canonical label, and MINTED the corruption — twice: BF-1109, BF-1243 — which then
  # leaked issues past next-candidates.sh's exact-string park gate). `norm` is defined at the routing gate.
  update_args=(issues update "$new_id")
  IFS=',' read -ra _labels <<< "$label"
  for lb in "${_labels[@]}"; do
    lb=$(printf '%s' "$lb" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$lb" ] && continue
    have_label=$(printf '%s\n' "$all_names" | grep -Fxi -- "$lb" | head -1 || true)
    if [ -z "$have_label" ] && [ -n "$all_names" ]; then
      want=$(printf '%s' "$lb" | norm)
      # The trailing `|| true` is load-bearing under set -eo pipefail: a last label that does NOT
      # match leaves the loop body's final status 1, and the assignment would kill the script.
      matches=$(while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$(printf '%s' "$n" | norm)" = "$want" ] && printf '%s\n' "$n"
      done <<< "$all_names" | sort -u) || true
      match_count=$(printf '%s' "$matches" | grep -c . || true)
      if [ "$match_count" = "1" ]; then
        have_label="$matches"
        echo "NOTE: requested label '$lb' does not exist; using existing label '$have_label' (normalized match) instead of minting a near-miss twin." >&2
      elif [ "$match_count" != "0" ]; then
        echo "WARN: requested label '$lb' does not exist and several existing labels normalize to it: $(printf '%s' "$matches" | tr '\n' ' ')— name one exactly; skipping this label." >&2
        label_failed=1
        continue
      fi
    fi
    # Never mint: a filing session that passes a token that is not a label (quality-review's
    # `suggested` reply, 2026-08-19) would otherwise create it here, and every later session
    # then finds it in `labels list` and reuses it — fourteen filings carried it in place of
    # `specified`. A genuinely new label is a /linear-setup decision, not a side effect.
    if [ -z "$have_label" ]; then
      echo "WARN: requested label '$lb' does not exist — not minting it. Create it deliberately (/linear-setup, or linear-cli labels create '$lb' -t issue) and attach with ~/.claude/scripts/linear-add-label.sh $new_id '$lb'. Skipping this label." >&2
      label_failed=1
      continue
    fi
    update_args+=(-l "$have_label")
  done
  # One replace-semantics update carrying every -l — safe only because the label set is
  # empty on a just-created issue (existing issues must use linear-add-label.sh). Skipped
  # when every requested label was ambiguous (nothing to attach).
  if [ "${#update_args[@]}" -gt 3 ]; then
    if ! linear-cli "${update_args[@]}" >/dev/null 2>&1; then
      echo "WARN: created $new_id but could not attach label(s) '$label' — if this gates /auto pickup, attach manually (~/.claude/scripts/linear-add-label.sh $new_id <label>)" >&2
      label_failed=1
    fi
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
    # `-o json` keeps the mutation's own answer: `relations parent` selects issue{parent{identifier}}, and its table
    # line prints the REQUESTED parent when that answer carries none, so only the JSON form is evidence.
    pout=$(linear-cli relations parent "$new_id" "$parent" -o json 2>&1) || {
      case "$pout" in
        *"invalid parent"*) capped=1 ;;   # backstop: pre-check raced or under-counted
        *) echo "ERROR: created $new_id but 'relations parent $new_id $parent' failed — issue has no parent link: $pout" >&2; exit 1 ;;
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
    # Two signals, each empty when it could not be read: the parent the link mutation's own response names, and a
    # separate read of the issue. The read taken straight after the write can show no parent for a link that landed
    # (BF-3343, 2026-11-17: this check exited 1 on 'none', and a bare read four seconds later, with no second write,
    # showed the parent), so the response is consulted before the issue is called an orphan. Whether `relations parent`
    # can also report success without writing, as `issues update` does (linear gotcha #8), is unmeasured; re-issuing
    # the same parent once covers it. Each WARN names the signals that disagreed, never a mechanism. The `|| true`
    # keeps a failed read from ending the script under `set -eo pipefail` with linear-cli's own exit code, since 2, 3
    # and 4 mean something else here.
    answered_parent() { printf '%s' "$1" | jq -r '.issue.parent.identifier // .data.issueUpdate.issue.parent.identifier // empty' 2>/dev/null || true; }
    read_parent() { linear-cli issues get "$new_id" -o json --no-cache 2>/dev/null | jq -r '.parent.identifier // empty' 2>/dev/null || true; }
    answered=$(answered_parent "$pout")
    linked=$(read_parent)
    if [ "$linked" != "$parent" ]; then
      if [ "$answered" = "$parent" ]; then
        echo "WARN: created $new_id — the link mutation answered parent '$parent' but the read straight after showed '${linked:-none}'; linked on the mutation's answer" >&2
      else
        answered=$(answered_parent "$(linear-cli relations parent "$new_id" "$parent" -o json 2>/dev/null || true)")
        [ "$answered" = "$parent" ] || linked=$(read_parent)
        if [ "$answered" = "$parent" ] || [ "$linked" = "$parent" ]; then
          echo "WARN: created $new_id — its parent '$parent' was confirmed only after a second 'relations parent'" >&2
        else
          echo "ERROR: created $new_id but could not confirm its parent after re-issuing the link: the mutation answered '${answered:-nothing}' and the issue reads '${linked:-none}', expected '$parent' — confirm or re-link: linear-cli relations parent $new_id $parent" >&2
          exit 1
        fi
      fi
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
