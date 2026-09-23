#!/bin/zsh
# triage-apply.sh — apply ONE approved disposition batch from proposals, for exactly the ids given.
#
# Usage: triage-apply.sh --disposition cancel|ship-close|duplicate|narrow|ask-filer --ids ID,ID,... [--out DIR] [--dry-run]
#
# The id list is the frozen set the user approved at presentation time. An id with no pending proposal, or whose
# proposal carries a different disposition, is skipped with a message — never re-selected by verdict at apply
# time (a verdict-keyed selector once canceled four issues whose proposals landed after the approval).
#
# Per disposition:
#   cancel      evidence comment (proposal's evidence + full report), then one verified Canceled batch
#   ship-close  the issue's own commit (subject or body carries the id) → Done when a release tag contains it,
#               else Ready for Release; evidence comment first
#   duplicate   comment, `relations add <ID> <duplicate_of> -r duplicate` (moves the state on its own; read back,
#               set explicitly only if it did not land), cross-comment on the canonical
#   narrow      comment recording what shipped and what remains; the description is NOT rewritten here
#   ask-filer   comment addressed to the filer with the proposal's questions, then the `needs decision` label
# Markers: narrow and ask-filer get their standalone marker through triage-apply-markers.sh; cancel, ship-close and
# duplicate leave the pool, so their proposals are filed under applied/ without a marker.
set -o pipefail
export PATH="$HOME/.cargo/bin:$PATH"
HERE=${0:A:h}
OUT="tmp"; DISP=""; IDS=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --disposition) DISP="$2"; shift 2 ;;
    --ids) IDS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$DISP" in cancel|ship-close|duplicate|narrow|ask-filer) ;; *) echo "usage: --disposition cancel|ship-close|duplicate|narrow|ask-filer --ids ID,ID" >&2; exit 1 ;; esac
[ -n "$IDS" ] || { echo "--ids is required: the frozen, approved list" >&2; exit 1; }
PROP="$OUT/triage-proposals"; CHEAP="$OUT/triage-cheap.ndjson"; BODIES="$OUT/triage-apply-bodies"; mkdir -p "$PROP/applied" "$BODIES"
DATE=$(date +%F)
first_name() { local e="$1"; e=${e%%@*}; e=${e%%.*}; printf '%s' "${(C)e}"; }
post() { [ "$DRY" -eq 1 ] && { echo "-- would post to $1:"; sed -n '1,6p' "$2"; return 0; }; ~/.claude/scripts/linear-post.sh comment "$1" "$2" >/dev/null; }

cancel_ids=(); marker_ids=(); applied=()
for id in ${(s:,:)IDS}; do
  f="$PROP/$id.json"
  [ -s "$f" ] || { echo "skip $id: no pending proposal"; continue; }
  d=$(jq -r '.disposition' "$f"); [ "$d" = "$DISP" ] || { echo "skip $id: proposal says $d, not $DISP"; continue; }
  sha=$(jq -r '.sha' "$f"); ev=$(jq -r '.evidence' "$f"); report=$(jq -r '.report' "$f"); body="$BODIES/$id-$DISP.md"
  case "$DISP" in
    cancel)
      printf 'Canceled by /triage (revalidated against %s, %s): the request no longer applies or was satisfied by other work.\n\n%s\n\n<details><summary>Revalidation report</summary>\n\n%s\n\n</details>\n' "$sha" "$DATE" "$ev" "$report" >| "$body"
      post "$id" "$body" && { cancel_ids+=("$id"); applied+=("$id"); echo "commented $id (cancel)"; } || echo "FAILED comment $id" ;;
    ship-close)
      fix=$(git log --all --format='%h' --grep="${id}\b" | head -1); tag=""; [ -n "$fix" ] && tag=$(git tag --contains "$fix" 2>/dev/null | sort -V | head -1)
      state="Ready for Release"; [ -n "$tag" ] && state="Done"
      printf 'Closed as shipped by /triage (revalidated against %s, %s): the fix landed in %s%s while the issue never left its state.\n\n%s\n\n<details><summary>Revalidation report</summary>\n\n%s\n\n</details>\n' "$sha" "$DATE" "${fix:-an unidentified commit}" "${tag:+, released in $tag}" "$ev" "$report" >| "$body"
      post "$id" "$body" && echo "commented $id (ship-close → $state)" || echo "FAILED comment $id"
      [ "$DRY" -eq 1 ] || ~/.claude/scripts/linear-set-state.sh "$state" "$id" 2>&1 | tail -1
      applied+=("$id") ;;
    duplicate)
      dup_of=$(jq -r '.duplicate_of // ""' "$f"); [ -n "$dup_of" ] || { echo "skip $id: proposal names no duplicate_of"; continue; }
      printf 'Marked duplicate of %s by /triage (revalidated against %s, %s).\n\n%s\n\n<details><summary>Revalidation report</summary>\n\n%s\n\n</details>\n' "$dup_of" "$sha" "$DATE" "$ev" "$report" >| "$body"
      post "$id" "$body" && echo "commented $id (duplicate of $dup_of)" || echo "FAILED comment $id"
      if [ "$DRY" -eq 0 ]; then
        linear-cli relations add "$id" "$dup_of" -r duplicate 2>&1 | tail -1
        printf 'Absorbed %s by /triage: the same defect and fix. Its revalidation report is on that issue.\n' "$id" >| "$BODIES/$dup_of-absorbs-$id.md"; post "$dup_of" "$BODIES/$dup_of-absorbs-$id.md"
        st=$(linear-cli issues get "$id" -o json -q --no-cache | jq -r '.state.name'); echo "  $id state after relation: $st"
        [ "$st" = "Duplicate" ] || ~/.claude/scripts/linear-set-state.sh Duplicate "$id" 2>&1 | tail -1
      fi
      applied+=("$id") ;;
    narrow)
      printf 'Revalidated by /triage against %s on %s: partly shipped, a remainder stands.\n\n%s\n\nThe description still describes the original scope; a rewrite around the remainder is queued for a spec pass.\n\n<details><summary>Revalidation report</summary>\n\n%s\n\n</details>\n' "$sha" "$DATE" "$ev" "$report" >| "$body"
      post "$id" "$body" && { marker_ids+=("$id"); echo "commented $id (narrow)"; } || echo "FAILED comment $id" ;;
    ask-filer)
      creator=$(jq -r --arg id "$id" 'select(.id==$id) | .creator' "$CHEAP" | head -1); name=$(first_name "${creator:-there}")
      qs=$(jq -r '(.questions // []) | to_entries | map("\(.key+1). \(.value)") | join("\n")' "$f")
      [ -n "$qs" ] || qs="1. What outcome would make this issue done, stated so it can be checked against the running app?"
      printf '%s, triage revalidated this against the code on %s and needs answers before it can be specified.\n\nWhat the code does today: %s\n\n%s\n\nLabeled `needs decision` until answered. It is invisible to automated pickup while the label is on.\n\n<details><summary>Revalidation report</summary>\n\n%s\n\n</details>\n' "$name" "$DATE" "$ev" "$qs" "$report" >| "$body"
      if post "$id" "$body"; then
        [ "$DRY" -eq 1 ] || ~/.claude/scripts/linear-add-label.sh "$id" 'needs decision' >/dev/null 2>&1
        marker_ids+=("$id"); echo "commented $id → $name"
      else echo "FAILED comment $id"; fi ;;
  esac
done

if [ ${#cancel_ids[@]} -gt 0 ] && [ "$DRY" -eq 0 ]; then
  echo "== Canceled batch (${#cancel_ids[@]}) =="; ~/.claude/scripts/linear-set-state.sh Canceled "${cancel_ids[@]}" 2>&1 | tail -$(( ${#cancel_ids[@]} + 1 ))
fi
if [ ${#marker_ids[@]} -gt 0 ]; then
  args=(--out "$OUT" --dispositions "$DISP" --ids "${(j:,:)marker_ids}"); [ "$DRY" -eq 1 ] && args+=(--dry-run)
  zsh "$HERE/triage-apply-markers.sh" "${args[@]}" | tail -1
fi
if [ "$DRY" -eq 0 ]; then
  for id in "${applied[@]}"; do [ -s "$PROP/$id.json" ] && mv "$PROP/$id.json" "$PROP/applied/"; done
  echo "== read-back =="; for id in "${applied[@]}" "${marker_ids[@]}"; do linear-cli issues get "$id" -o json -q --no-cache | jq -r --arg id "$id" '"\($id): \(.state.name) [\([.labels | .. | objects | .name? | select(. != null)] | unique | join(","))]"'; done
fi
