#!/bin/bash
# epic-pr.sh — resolve an epic's integration branch, base and shipped roster, then push the branch and open its one PR.
#
# Usage: epic-pr.sh [--dry-run] [--base <branch>] [--branch <branch>] [EPIC-ID]
#
# The post-fleet step /epic-prep and /fleet-launch both end on is `integration-pr.sh <branch> <base> <member IDs...>`,
# whose every argument is already recorded somewhere — the recommendation /epic-prep wrote, the marker /fleet-launch
# wrote, the branch name, Linear's graph — so nobody should have to type it. This resolves them and hands them to
# integration-pr.sh; run it by hand after an epic fleet (/epic-prep and /fleet-launch name the step), then /pr-update on
# the PR it reports.
#
# Resolution, first hit wins and is named in EPIC_SOURCE / BASE_SOURCE:
#   epic    the argument; else the checkout's branch when it is `epic/<id>`; else the one epic a running fleet's marker
#           names (tmp/fleet-deadline-<slug>.json — several fleets run side by side, lib/fleet-markers.sh); else the one
#           epic a recommendation names (tmp/fleet-recommendation-<slug>.json); else the one local `epic/*` branch.
#           Several candidates at any step, or none at the end, is ASK=epic (exit 3) with the candidates listed.
#   branch  --branch; else the epic's recommendation's or marker's (its live marker, else the newest archived run);
#           else `epic/<id-lowercased>`, which must exist locally.
#   base    --base; else the epic's recommendation's or marker's; else `start.wt-source-branch`;
#           else the checkout's current branch — unless that is the integration branch itself, which is ASK=base.
#   roster  every member of the live graph (epic-graph.sh: the epic's descendants and their blockers, terminal
#           included) except the root, nested `epic` containers, and Canceled/Duplicate members, split by whether a
#           commit subject on <branch> names the ID — LANDED, in the order they landed, is what the PR body lists;
#           NOT_LANDED is reported and left out, since the PR carries only what is on the branch.
#
# Output (stdout, key=value): EPIC, EPIC_SOURCE, BRANCH, BASE, BASE_SOURCE, LANDED, NOT_LANDED, SKIPPED, then
# integration-pr.sh's PR_URL / PR_NUMBER / CREATED / BEHIND, or DRY_RUN=1 in place of them. Exit 1 on an error,
# 3 when a choice needs the user (ASK=epic with CANDIDATES=, or ASK=base). Read-write only past --dry-run, and
# only through integration-pr.sh (pushes the branch, opens the PR). Never switches the checkout.

set -eo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry_run=0; base_opt=""; branch_opt=""; epic_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --base) [ -n "${2:-}" ] || { echo "ERROR: --base needs a branch name" >&2; exit 1; }; base_opt="$2"; shift ;;
    --branch) [ -n "${2:-}" ] || { echo "ERROR: --branch needs a branch name" >&2; exit 1; }; branch_opt="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    *) [ -z "$epic_arg" ] || { echo "ERROR: one epic id at most (got '$epic_arg' and '$1')" >&2; exit 1; }; epic_arg="$1" ;;
  esac
  shift
done
for cmd in git jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done

main_checkout=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$main_checkout" ] || { echo "ERROR: not inside a git repository" >&2; exit 1; }
. "$script_dir/../lib/fleet-markers.sh"
checkout_branch=$(git -C "$main_checkout" branch --show-current 2>/dev/null || true)

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_id() { [[ "$1" =~ ^[A-Z0-9]+-[0-9]+$ ]]; }
json_field() { # json_field <file> <jq-path> — empty when the file is missing or the field null
  [ -f "$1" ] && jq -r "$2 // empty" "$1" 2>/dev/null || true
}
scopes_of() { # <file>... → the distinct epics the files name, uppercased, one per line; always exits 0 (set -e)
  local f
  for f in "$@"; do if [ -f "$f" ]; then upper "$(json_field "$f" '.scope')"; echo; fi; done | awk 'NF' | sort -u
  return 0
}
ask_epic() { # <candidates, one per line> <reason>
  echo "ASK=epic"; echo "CANDIDATES=$(printf '%s\n' "$1" | paste -sd, -)"; echo "$2" >&2; exit 3
}

# ---- epic ----
epic=""; epic_source=""
if [ -n "$epic_arg" ]; then
  epic=$(upper "$epic_arg"); epic_source="arg"
  is_id "$epic" || { echo "ERROR: '$epic_arg' does not name an issue (expected a key like BF-123)" >&2; exit 1; }
elif [[ "$checkout_branch" =~ ^epic/([a-zA-Z0-9]+-[0-9]+)$ ]]; then
  epic=$(upper "${BASH_REMATCH[1]}"); epic_source="branch"
else
  live_markers=()
  while IFS= read -r f; do [ -n "$f" ] && live_markers+=("$f"); done < <(fleet_live_markers "$main_checkout")
  marker_scopes=$(scopes_of ${live_markers[@]+"${live_markers[@]}"})
  rec_scopes=$(scopes_of "$main_checkout"/tmp/fleet-recommendation-*.json)
  n_m=$(printf '%s\n' "$marker_scopes" | awk 'NF' | wc -l | tr -d ' ')
  n_r=$(printf '%s\n' "$rec_scopes" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$n_m" = 1 ]; then epic="$marker_scopes"; epic_source="marker"
  elif [ "$n_m" -gt 1 ]; then ask_epic "$marker_scopes" "Several running fleets name an epic; name the one."
  elif [ "$n_r" = 1 ]; then epic="$rec_scopes"; epic_source="recommendation"
  elif [ "$n_r" -gt 1 ]; then ask_epic "$rec_scopes" "Several recommendations name an epic; name the one."
  else
    candidates=$(git -C "$main_checkout" for-each-ref --format='%(refname:short)' 'refs/heads/epic/' 2>/dev/null | paste -sd, - || true)
    case "$candidates" in
      "") echo "ASK=epic"; echo "CANDIDATES="; echo "No epic id given, no epic/* branch checked out, no fleet marker or recommendation names one, and no local epic/* branch exists." >&2; exit 3 ;;
      *,*) echo "ASK=epic"; echo "CANDIDATES=$candidates"; echo "Several local epic/* branches; name the epic." >&2; exit 3 ;;
      *) epic=$(upper "${candidates#epic/}"); epic_source="sole-branch" ;;
    esac
  fi
fi
slug=$(fleet_slug "$epic")
rec=$(fleet_rec_path "$main_checkout" "$slug")
marker=$(fleet_marker_path "$main_checkout" "$slug")

# ---- branch and base: a recorded pair is taken only when it was recorded for THIS epic — its recommendation, its live
# marker, then its archived runs newest first (an ended fleet's PR is opened after a later launch displaced its marker) ----
rec_branch=""; rec_base=""; rec_kind=""
recorded=("$rec" "$marker")
while IFS= read -r f; do [ -n "$f" ] && recorded+=("$f"); done < <(ls -1r "$main_checkout"/tmp/fleet-deadline-"$slug".*.json 2>/dev/null)
for f in "${recorded[@]}"; do
  [ -f "$f" ] || continue
  if [ "$(upper "$(json_field "$f" '.scope')")" = "$epic" ]; then
    rec_branch=$(json_field "$f" '.branch'); rec_base=$(json_field "$f" '.base')
    case "$f" in "$rec") rec_kind="recommendation" ;; *) rec_kind="marker" ;; esac
    [ -n "$rec_branch" ] && break
  fi
done
branch="${branch_opt:-${rec_branch:-epic/$(lower "$epic")}}"
git -C "$main_checkout" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
  || { echo "ERROR: no local branch '$branch' for epic $epic — /epic-prep $epic creates it" >&2; exit 1; }

base=""; base_source=""
if [ -n "$base_opt" ]; then base="$base_opt"; base_source="arg"
elif [ -n "$rec_base" ]; then base="$rec_base"; base_source="$rec_kind"
else
  cfg=$(git -C "$main_checkout" config --get start.wt-source-branch 2>/dev/null || true)
  if [ -n "$cfg" ]; then base="$cfg"; base_source="config"
  elif [ -n "$checkout_branch" ] && [ "$checkout_branch" != "$branch" ]; then base="$checkout_branch"; base_source="checkout"
  else
    printf 'EPIC=%s\nEPIC_SOURCE=%s\nBRANCH=%s\nASK=base\n' "$epic" "$epic_source" "$branch"
    echo "No recorded base for $branch and the checkout is on it (or detached); pass --base <branch>." >&2
    exit 3
  fi
fi

# ---- roster: the live graph, split by what is on the branch ----
graph=$("$script_dir/epic-graph.sh" "$epic") || { echo "ERROR: could not resolve epic $epic's graph" >&2; exit 1; }
candidates_ids=$(printf '%s' "$graph" | jq -r --arg root "$epic" '
  [ (.members[] | select(.identifier != $root and (any(.labels[]?; ascii_downcase == "epic") | not)) | .identifier),
    (.terminal[] | select((.state_type // "" | ascii_downcase) as $t | $t != "canceled" and $t != "duplicate") | .identifier) ]
  | unique | .[]')
skipped=$(printf '%s' "$graph" | jq -r --arg root "$epic" '
  [ (.members[] | select(.identifier != $root and any(.labels[]?; ascii_downcase == "epic")) | "\(.identifier)(epic)"),
    (.terminal[] | select((.state_type // "" | ascii_downcase) as $t | $t == "canceled" or $t == "duplicate") | "\(.identifier)(\(.state))") ]
  | join(",")')

# One oldest-first walk of the branch: each id lands at the first commit whose SUBJECT names it, anchored so BF-12 never
# matches BF-123. /finish puts the id in the subject (`<ID>: …`, `Merge <ID>`); a body citing the id ("leaves <ID> for
# later") is not that issue's change, which is why this reads subjects rather than --grep over the whole message. The
# commit's position, not its timestamp, orders the roster — merges landing within one second would otherwise tie.
landed=$(git -C "$main_checkout" log --reverse --format='%s' "$branch" 2>/dev/null \
  | awk -v ids="$(printf '%s ' $candidates_ids)" '
      BEGIN { n = split(ids, want, " ") }
      { for (i = 1; i <= n; i++) if (want[i] != "" && !(want[i] in at) && $0 ~ (want[i] "([^0-9]|$)")) at[want[i]] = NR }
      END { for (id in at) print at[id], id }' \
  | sort -n | awk '{print $2}' | paste -sd, - || true)
not_landed=""
for id in $candidates_ids; do
  case ",$landed," in *",$id,"*) ;; *) not_landed="$not_landed${not_landed:+,}$id" ;; esac
done

printf 'EPIC=%s\nEPIC_SOURCE=%s\nBRANCH=%s\nBASE=%s\nBASE_SOURCE=%s\nLANDED=%s\nNOT_LANDED=%s\nSKIPPED=%s\n' \
  "$epic" "$epic_source" "$branch" "$base" "$base_source" "$landed" "$not_landed" "$skipped"
[ -n "$landed" ] || echo "WARN: no member's commit is on $branch yet — the PR body would carry no roster" >&2

if [ "$dry_run" = 1 ]; then echo "DRY_RUN=1"; exit 0; fi
ids=$(printf '%s' "$landed" | tr ',' ' ')
# shellcheck disable=SC2086 — the ids are the argument list
exec "$script_dir/integration-pr.sh" "$branch" "$base" $ids
