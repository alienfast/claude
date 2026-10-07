#!/usr/bin/env bash
# sweep-apply.sh — the /test-sweep apply gate for a batch of executed proposals: does the suite count, and does the ledger, account for it?
#
# WHY THIS EXISTS: a test deletion that lost coverage looks exactly like one that did not — the suite stays green either way.
# The only mechanical evidence is arithmetic: the post-change example count must equal the baseline minus what the proposals
# said they remove plus any assertion hoisted elsewhere, and every removed example or story must be named in the change's
# consolidation ledger beside its survivor. A count that moved by more than claimed means a second, unplanned removal; by less,
# a removal that did not happen. One baseline and one post count describe the whole batch, so the batch is gated once: the
# removals and hoists are summed and the removed names unioned. Each gate also refuses on missing evidence — an unreadable
# proposal field, an empty removed list, a missing ledger — rather than passing because there was nothing to check. This runs no
# suite and applies no mutation itself; it prints the proof steps the operator still owes.
#
# USAGE
#   sweep-apply.sh --proposal F [--proposal F ...] --baseline-count N --post-count N [--hoisted N ...] [--ledger F]
#
#   --proposal F         one proposal JSON from <out>/test-sweep-proposals/; repeatable, one per proposal in the frozen batch
#   --baseline-count N  the suite's example count before the change (rspec: the baseline cache's SUMMARY; storybook: the
#                        test-storybook test count or the census EXPORTS, whichever the ledger counts)
#   --post-count N       the same count measured after the whole batch
#   --hoisted N          assertions the change added elsewhere — a hoist-ddl schema assertion, a wiring case (default 0); repeatable, summed;
#                        refused when the sum exceeds the `examples_removed` of the batch's consolidate and hoist-ddl proposals, the only
#                        kinds that add anything back (nothing can be added back that was not removed)
#   --ledger F           the consolidation ledger (a commit message draft, a PR body); required whenever the batch removes anything.
#                        A line is `- "<removed description>" → <survivor file or description>` (`->` also reads); a removed name
#                        is covered only by a line whose quoted field equals it exactly.
#
# A proposal's `examples_removed` is GROSS: the examples or stories deleted or folded away, whether or not a copy is added back
# elsewhere. What is added back is `--hoisted`; the gate expects baseline - sum(examples_removed) + sum(hoisted) = post.
#
# OUTPUT (one verdict per line)
#   PROPOSAL <slug> kind=<kind> mechanical=<bool> examples_removed=<N> removed_names=<N>     one per proposal
#   REFUSED <gate> <detail>                       gates: proposal-shape, mechanical-gate, placeholder-gate, kind-gate, target-gate,
#                                                 mutation-gate, hoisted-gate, ledger-gate (also per proposal: names missing, empty, or multi-line)
#   BATCH proposals=<N> examples_removed=<N> hoisted=<N>
#   WARN hoist-ddl with --hoisted 0 ...
#   PASS count-gate expected=<N> post=<N>         or  REFUSED count-gate expected=<N> (baseline - removed + hoisted) post=<N>
#   PASS ledger-gate names=<N>                    or  REFUSED ledger-gate <missing --ledger | missing="<name>"...>
#   STEP mutation <slug> <text>                   the mutation each deleted routing arm's survivor must redden against
#   STEP broken-assertion <slug> <target>         break one relocated assertion deliberately, watch it fail, restore
#   GATES-PASSED <slug>                           one per proposal, only when nothing was refused
#
# Exit 0 every gate passes, 1 a gate refused, 2 usage error or a proposal that is not JSON.
# Requires jq, sed and grep.

set -uo pipefail

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "sweep-apply: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "sweep-apply: $1 needs a value" >&2; usage; exit 2; }; }

# Leading zeros read as octal in shell arithmetic; 10# forces decimal, and the length cap keeps the value inside 64 bits.
norm_count() {  # norm_count <label> <value> → the value as a plain decimal
  case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer" ;; esac
  [ "${#2}" -le 15 ] || die "$1 is out of range"
  echo $((10#$2))
}

PROPS=(); BASE=""; POST=""; HOISTED=0; LEDGER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --proposal) need_value "$1" $#; PROPS+=("$2"); shift 2 ;;
    --baseline-count) need_value "$1" $#; BASE=$(norm_count "$1" "$2") || exit 2; shift 2 ;;
    --post-count) need_value "$1" $#; POST=$(norm_count "$1" "$2") || exit 2; shift 2 ;;
    --hoisted) need_value "$1" $#; h=$(norm_count "$1" "$2") || exit 2; HOISTED=$((HOISTED + h)); shift 2 ;;
    --ledger) need_value "$1" $#; LEDGER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sweep-apply: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ ${#PROPS[@]} -gt 0 ] && [ -n "$BASE" ] && [ -n "$POST" ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -z "$LEDGER" ] || [ -f "$LEDGER" ] || die "no such ledger file: $LEDGER"

US=$(printf '\037')
# shellcheck disable=SC2016  # jq program, not shell
FIELDS_JQ='
  def isint: type == "number" and . == floor and . >= 0;
  def clean: if type == "string" then gsub("\n"; " ") | gsub($us; " ") else "" end;
  (if type == "object" then . else {} end) as $p
  | ($p.removed | if type == "array" then . else [] end) as $r
  | ([ (if ($p.slug | type) == "string" and ($p.slug | length) > 0 then empty else "slug" end),
       (if ($p.kind | type) == "string" and (["retire", "consolidate", "detag", "hoist-ddl", "keep"] | index($p.kind)) != null then empty else "kind" end),
       (if ($p.mechanical | type) == "boolean" then empty else "mechanical" end),
       (if ($p.examples_removed | isint) then empty else "examples_removed" end),
       (if ($p.removed | type) == "array" and ($r | all(.[]; type == "string")) then empty else "removed" end),
       (if (($p.target // "") | type) == "string" then empty else "target" end),
       (if (($p.mutation // "") | type) == "string" then empty else "mutation" end),
       (if (($p.placeholder // false) | type) == "boolean" then empty else "placeholder" end) ] | join(",")) as $problems
  | [ $problems, ($p.slug | clean), ($p.kind | clean), ($p.mechanical | tostring),
      ($p.examples_removed | if isint then floor | tostring else "0" end), ($r | length | tostring),
      (($p.placeholder // false) | tostring), (($p.target // "") | clean), (($p.mutation // "") | clean),
      ($r | map(select(type == "string" and test("^\\s*$"))) | length | tostring),
      ($r | map(select(type == "string" and test("\n"))) | length | tostring) ] | join($us)'

refused=0; ledger_bad=0
refuse() {  # refuse <gate> <detail>
  echo "REFUSED $1 $2"
  refused=1
  [ "$1" = ledger-gate ] && ledger_bad=1
}

SEEN=$'\n'; ALL_NAMES=""; NAMES_TOTAL=0; TOTAL_REMOVED=0; N_OK=0; ANY_HOIST_DDL=0; ADDS_BACK_REMOVED=0
OK_SLUG=(); OK_MUT=(); OK_TARGET=()
for pf in "${PROPS[@]}"; do
  [ -s "$pf" ] || die "no such proposal: $pf"
  fields=$(jq -r --arg us "$US" "$FIELDS_JQ" "$pf" 2>/dev/null) || die "not valid JSON: $pf"
  case "$fields" in *$'\n'*) refuse proposal-shape "$pf: holds more than one JSON value"; continue ;; esac
  IFS=$US read -r problems slug kind mechanical removed nnames placeholder target mutation nempty nmulti <<< "$fields"
  label=${slug:-$pf}
  if [ -n "$problems" ]; then refuse proposal-shape "$label: missing or wrong-typed field(s): $problems"; continue; fi
  case "$SEEN" in *$'\n'"$slug"$'\n'*) refuse proposal-shape "$label: listed twice"; continue ;; esac
  SEEN="$SEEN$slug"$'\n'

  echo "PROPOSAL $slug kind=$kind mechanical=$mechanical examples_removed=$removed removed_names=$nnames"
  [ "$mechanical" = true ] || refuse mechanical-gate "$slug: a judgment item is filed as a Linear issue, never executed here"
  [ "$placeholder" != true ] || refuse placeholder-gate "$slug: a dry-run placeholder; no agent measured it"
  [ "$kind" != keep ] || refuse kind-gate "$slug: keep changes nothing, so there is nothing to apply"
  [ "$kind" != hoist-ddl ] || ANY_HOIST_DDL=1
  if [ "$removed" -gt 0 ]; then
    [ -n "${target//[[:space:]]/}" ] || refuse target-gate "$slug: removes $removed but names no target (the survivor)"
    [ -n "${mutation//[[:space:]]/}" ] || refuse mutation-gate "$slug: removes $removed but records no mutation for the survivor to redden against"
    if [ "$nnames" -eq 0 ]; then refuse ledger-gate "$slug: removes $removed but its removed list is empty"
    elif [ "$nnames" -lt "$removed" ]; then refuse ledger-gate "$slug: removed lists $nnames names for $removed removals"; fi
  fi
  [ "$nempty" -eq 0 ] || refuse ledger-gate "$slug: removed holds $nempty empty name(s)"
  [ "$nmulti" -eq 0 ] || refuse ledger-gate "$slug: removed holds $nmulti multi-line name(s), which a one-line ledger entry cannot match"
  if [ "$nnames" -gt 0 ] && [ "$nempty" -eq 0 ] && [ "$nmulti" -eq 0 ]; then
    ALL_NAMES="$ALL_NAMES$(jq -r '.removed[]' "$pf")"$'\n'
    NAMES_TOTAL=$((NAMES_TOTAL + nnames))
  fi
  TOTAL_REMOVED=$((TOTAL_REMOVED + removed))
  case "$kind" in consolidate|hoist-ddl) ADDS_BACK_REMOVED=$((ADDS_BACK_REMOVED + removed)) ;; esac
  N_OK=$((N_OK + 1))
  OK_SLUG+=("$slug"); OK_MUT+=("$mutation"); OK_TARGET+=("$target")
done

echo "BATCH proposals=${#PROPS[@]} examples_removed=$TOTAL_REMOVED hoisted=$HOISTED"
[ "$ANY_HOIST_DDL" -eq 0 ] || [ "$HOISTED" -gt 0 ] || echo "WARN hoist-ddl with --hoisted 0: the schema assertion it adds is not counted"
[ "$HOISTED" -le "$ADDS_BACK_REMOVED" ] \
  || refuse hoisted-gate "hoisted=$HOISTED exceeds consolidate/hoist-ddl removals=$ADDS_BACK_REMOVED"

expected=$((BASE - TOTAL_REMOVED + HOISTED))
if [ "$POST" -eq "$expected" ]; then
  echo "PASS count-gate expected=$expected post=$POST"
else
  echo "REFUSED count-gate expected=$expected ($BASE - $TOTAL_REMOVED + $HOISTED) post=$POST"
  refused=1
fi

if [ "$TOTAL_REMOVED" -gt 0 ] || [ "$NAMES_TOTAL" -gt 0 ]; then
  if [ -z "$LEDGER" ]; then
    refuse ledger-gate "missing --ledger: the batch removes $TOTAL_REMOVED examples or stories"
  else
    ledger_names=$(LC_ALL=C sed -nE 's/^[[:space:]]*[-*][[:space:]]+"(.*)"[[:space:]]+(→|->)[[:space:]]+[^[:space:]].*$/\1/p' "$LEDGER")
    missing=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '%s\n' "$ledger_names" | grep -qFx -- "$name" || missing="$missing \"$name\""
    done <<< "$ALL_NAMES"
    if [ -n "$missing" ]; then
      refuse ledger-gate "missing=${missing# } (each needs a ledger line: - \"<name>\" → <survivor>)"
    fi
  fi
fi
[ "$ledger_bad" -eq 1 ] || echo "PASS ledger-gate names=$NAMES_TOTAL"

[ "$refused" -eq 0 ] || exit 1

i=0
while [ "$i" -lt "$N_OK" ]; do
  [ -n "${OK_MUT[$i]//[[:space:]]/}" ] && echo "STEP mutation ${OK_SLUG[$i]} ${OK_MUT[$i]}"
  [ -n "${OK_TARGET[$i]//[[:space:]]/}" ] && echo "STEP broken-assertion ${OK_SLUG[$i]} ${OK_TARGET[$i]}"
  echo "GATES-PASSED ${OK_SLUG[$i]}"
  i=$((i + 1))
done
exit 0
