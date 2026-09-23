#!/bin/zsh
# triage-scan.sh — /triage scan mode: the unattended, read-only deep pass over the pool.
#
# Consumes the script pass's output (triage-cheap-pass.sh: DIR/triage-cheap.ndjson) and writes one
# proposal per issue to DIR/triage-proposals/<ID>.json — verdict, disposition, evidence, curated subjects,
# questions, the full report, the sha the agent measured — for the interactive apply step to consume.
# Agents are headless `claude -p` runs with structured output (proposal.schema.json), read-only tools,
# and an allow-list of read commands; nothing here writes to Linear or the tree.
#
# Usage: triage-scan.sh [--out DIR] [--stage planned|backlog|triage|all] [--lane certified|uncertified|both]
#                       [--ids ID,ID,...] [--group-size N] [--concurrency N] [--max-groups N]
#                       [--model-light NAME] [--model-full NAME] [--force] [--summary]
#   --out DIR         where triage-cheap.ndjson lives and proposals go (default: tmp)
#   --stage/--lane    scope; default all stages, both lanes, in the house order (Planned, Backlog, Triage;
#                     certified lane first within a stage)
#   --ids             scan exactly these issues
#   --group-size      issues per agent (default 5; grouped by stage, lane, and subject area)
#   --concurrency     agents per batch (default 6)
#   --max-groups      stop after N groups (a trial run)
#   --model-light     model for certified-lane groups (default sonnet); records flagged escalate, or with a
#                     disposition other than keep, are re-run on --model-full
#   --model-full      model for uncertified-lane groups and escalations (default opus)
#   --force           re-scan issues that already have a proposal
#   --summary         print the proposal counts and per-disposition lists, then exit
#
# Resumable: an issue with a proposal file is skipped (unless --force); `unchanged` and `claimed` rows are
# never scanned. Re-run after a crash and it continues. Cost and duration per group go to DIR/triage-scan.log.
set -o pipefail
export PATH="$HOME/.cargo/bin:$PATH"
HERE=${0:A:h}
OUT="tmp"; STAGE="all"; LANE="both"; IDS=""; GROUP=5; CONC=6; MAXG=0; LIGHT="sonnet"; FULL="opus"; FORCE=0; SUMMARY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --ids) IDS="$2"; shift 2 ;;
    --group-size) GROUP="$2"; shift 2 ;;
    --concurrency) CONC="$2"; shift 2 ;;
    --max-groups) MAXG="$2"; shift 2 ;;
    --model-light) LIGHT="$2"; shift 2 ;;
    --model-full) FULL="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
CHEAP="$OUT/triage-cheap.ndjson"; PROP="$OUT/triage-proposals"; LOG="$OUT/triage-scan.log"
mkdir -p "$PROP/raw"
[ -s "$CHEAP" ] || { echo "no $CHEAP — run triage-cheap-pass.sh first" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "run from inside the project checkout" >&2; exit 1; }

if [ "$SUMMARY" -eq 1 ]; then
  n=$(ls "$PROP"/*.json 2>/dev/null | grep -vc '/raw/'); echo "proposals: $n"
  cat "$PROP"/BF-*.json "$PROP"/[A-Z]*-*.json 2>/dev/null | jq -rs 'unique_by(.id) | group_by(.disposition) | map("  \(.[0].disposition): \(length)") | .[]'
  echo "--- by disposition (id · verdict · evidence) ---"
  cat "$PROP"/[A-Z]*-*.json 2>/dev/null | jq -rs 'unique_by(.id) | sort_by(.disposition, .id) | .[] | select(.disposition != "keep") | "\(.disposition)\t\(.id)\t\(.verdict)\t\(.evidence[:160])"'
  echo "--- escalated/unsettled ---"; cat "$PROP"/[A-Z]*-*.json 2>/dev/null | jq -rs '.[] | select(.escalate) | "  \(.id)\t\(.evidence[:120])"'
  [ -f "$LOG" ] && { echo "--- cost ---"; awk -F'\t' '/^group/ {c+=$5; d+=$6; g++} END {printf "  groups=%d cost=$%.2f wall=%.0fmin\n", g, c, d/60000}' "$LOG"; }
  exit 0
fi

# ---- selection and ordering -------------------------------------------------------------------
stage_rank() { case "$1" in Planned|Todo) echo 0 ;; Backlog) echo 1 ;; Triage) echo 2 ;; *) echo 3 ;; esac; }
class_rank() { case "$1" in 'shipped?') echo 0 ;; drifted) echo 1 ;; touched) echo 2 ;; no-subjects) echo 3 ;; never-revalidated) echo 4 ;; *) echo 9 ;; esac; }
sel=$(mktemp)
jq -c 'select(.claimed|not) | select(.class != "unchanged")' "$CHEAP" | while IFS= read -r row; do
  id=$(printf '%s' "$row" | jq -r '.id'); st=$(printf '%s' "$row" | jq -r '.stage'); ln=$(printf '%s' "$row" | jq -r '.lane'); cl=$(printf '%s' "$row" | jq -r '.class')
  if [ -n "$IDS" ]; then case ",$IDS," in *",$id,"*) ;; *) continue ;; esac; fi
  case "$STAGE" in all) ;; planned) [ "$st" = "Planned" ] || [ "$st" = "Todo" ] || continue ;; backlog) [ "$st" = "Backlog" ] || continue ;; triage) [ "$st" = "Triage" ] || continue ;; esac
  case "$LANE" in both) ;; certified|uncertified) [ "$ln" = "$LANE" ] || continue ;; esac
  [ "$FORCE" -eq 0 ] && [ -s "$PROP/$id.json" ] && continue
  area=$(printf '%s' "$row" | jq -r '(.subjects[0] // "") | split("/") | .[0:3] | join("/")'); [ -n "$area" ] || area=$(printf '%s' "$row" | jq -r '.parent // "misc"')
  lr=0; [ "$ln" = "uncertified" ] && lr=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(stage_rank "$st")" "$lr" "$area" "$(class_rank "$cl")" "$id" "$ln" "$st" >> "$sel"
done
total=$(wc -l < "$sel" | tr -d ' ')
[ "$total" -gt 0 ] || { echo "nothing to scan (all proposed, unchanged, or claimed)"; rm -f "$sel"; exit 0; }
sort -t$'\t' -k1,1n -k2,2n -k3,3 -k4,4n -k5,5V "$sel" >| "$sel.sorted"

# ---- group builder: chunks of GROUP within (stage, lane) --------------------------------------
groups=(); cur=(); curkey=""
while IFS=$'\t' read -r sr lr area cr id ln st; do
  key="$sr/$lr"
  if [ -n "$curkey" ] && { [ "$key" != "$curkey" ] || [ ${#cur[@]} -ge "$GROUP" ]; }; then groups+=("$curkey|${(j:,:)cur}"); cur=(); fi
  curkey="$key"; cur+=("$id")
done < "$sel.sorted"
[ ${#cur[@]} -gt 0 ] && groups+=("$curkey|${(j:,:)cur}")
rm -f "$sel" "$sel.sorted"
echo "scan: $total issues in ${#groups[@]} groups (group-size $GROUP, concurrency $CONC, light=$LIGHT full=$FULL)"

SCHEMA=$(cat "$HERE/proposal.schema.json")
ALLOWED=( 'Bash(git log:*)' 'Bash(git show:*)' 'Bash(git grep:*)' 'Bash(git diff:*)' 'Bash(git ls-files:*)' 'Bash(git rev-parse:*)' 'Bash(git blame:*)' 'Bash(git tag:*)' 'Bash(git branch:*)' 'Bash(git merge-base:*)' 'Bash(jq:*)' 'Bash(cat:*)' 'Bash(ls:*)' 'Bash(grep:*)' 'Bash(rg:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(wc:*)' 'Bash(find:*)' 'Bash(sed:*)' 'Bash(linear-cli issues get:*)' 'Bash(linear-cli search issues:*)' 'Bash(linear-cli relations list:*)' 'Bash(linear-cli comments list:*)' 'Bash(linear-cli api query:*)' )

run_group() {   # $1 = group index, $2 = model, $3 = comma ids
  local gi="$1" model="$2" ids="$3" id lines="" row
  for id in ${(s:,:)ids}; do
    [ -s "$OUT/triage-digest-$id.md" ] || ~/.claude/scripts/linear-context.sh "$id" >| "$OUT/triage-digest-$id.md" 2>/dev/null
    row=$(jq -c --arg id "$id" 'select(.id==$id)' "$CHEAP" | head -1)
    lines+="- $id — $(printf '%s' "$row" | jq -r '"\(.title) (\(.stage)/\(.lane); labels: \([.labels[]]|join(",")); filed \(.created[:10]) by \(.creator))"')"$'\n'
  done
  local prompt; prompt=$(<"$HERE/scan-prompt.md"); prompt=${prompt//\{\{OUT\}\}/$OUT}; prompt=${prompt//\{\{ISSUES\}\}/$lines}
  local t0=$(date +%s) raw="$PROP/raw/group-$gi-$model.json"
  claude -p "$prompt" --model "$model" --output-format json --json-schema "$SCHEMA" --tools "Bash,Read,Grep,Glob" --allowedTools "${ALLOWED[@]}" --permission-mode dontAsk >| "$raw" 2>"$raw.err"
  local rc=$? t1=$(date +%s) cost dur
  cost=$(jq -r '.total_cost_usd // 0' "$raw" 2>/dev/null); dur=$(( (t1-t0)*1000 ))
  local ok; ok=$(jq -r '.structured_output.issues | length' "$raw" 2>/dev/null)
  if [ "$(jq -r '.is_error // false' "$raw" 2>/dev/null)" = "true" ]; then
    # A refused call (session/usage limit, auth) is is_error:true under subtype:success. A group launched after the
    # limit costs $0 and 3-4 s; a group in flight when it lands is cut off with its partial work billed and no proposals.
    # Stop the run at the first refusal — further launches are pointless — and re-run after the reset the message names.
    local msg; msg=$(jq -r '.result // ""' "$raw" | head -c 200)
    printf 'group\t%s\t%s\t%s\t%s\t%s\tFAILED refused: %s\n' "$gi" "$model" "$ids" "${cost:-0}" "$dur" "$msg" >> "$LOG"
    echo "  group $gi ($model) REFUSED: $msg"; touch "$PROP/.stop"; return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$ok" ] || [ "$ok" = "null" ]; then
    printf 'group\t%s\t%s\t%s\t%s\t%s\tFAILED rc=%s\n' "$gi" "$model" "$ids" "${cost:-0}" "$dur" "$rc" >> "$LOG"; echo "  group $gi ($model) FAILED rc=$rc — see $raw.err"; return 1
  fi
  local sha; sha=$(jq -r '.structured_output.sha' "$raw")
  jq -c --arg sha "$sha" --arg model "$model" --arg gi "$gi" --arg at "$(date -u +%FT%TZ)" '.structured_output.issues[] | . + {sha: $sha, model: $model, group: $gi, scanned_at: $at}' "$raw" | while IFS= read -r rec; do
    id=$(printf '%s' "$rec" | jq -r '.id'); printf '%s\n' "$rec" | jq '.' >| "$PROP/$id.json"
  done
  printf 'group\t%s\t%s\t%s\t%s\t%s\tok issues=%s\n' "$gi" "$model" "$ids" "${cost:-0}" "$dur" "$ok" >> "$LOG"
  echo "  group $gi ($model): $ok records, \$$cost, $((dur/1000))s — $(jq -r '.structured_output.issues[] | "\(.id)=\(.disposition)"' "$raw" | paste -sd ' ' -)"
}

# ---- batches -----------------------------------------------------------------------------------
RUN=$(date +%H%M%S); rm -f "$PROP/.stop"
gi=0; done_groups=0; escalate_ids=()
for g in "${groups[@]}"; do
  [ -f "$PROP/.stop" ] && { echo "stopping: a group was refused (session limit or auth) — re-run after the reset; proposals written so far stand"; break; }
  key=${g%%|*}; ids=${g#*|}; lr=${key#*/}
  model="$FULL"; [ "$lr" = "0" ] && model="$LIGHT"
  gi=$((gi+1)); run_group "$RUN-$gi" "$model" "$ids" &
  if [ $((gi % CONC)) -eq 0 ]; then wait; fi
  done_groups=$((done_groups+1)); [ "$MAXG" -gt 0 ] && [ "$done_groups" -ge "$MAXG" ] && break
done
wait
[ -f "$PROP/.stop" ] && { echo "run stopped on a refusal; $(ls "$PROP"/[A-Z]*-*.json 2>/dev/null | wc -l | tr -d ' ') proposals on disk"; exit 3; }
# ---- escalations: light-tier records that are not a confident keep re-run on the full model ----
for f in "$PROP"/[A-Z]*-*.json; do
  [ -s "$f" ] || continue
  if [ "$(jq -r --arg l "$LIGHT" 'select(.model==$l) | select(.escalate or .disposition != "keep") | .id' "$f")" != "" ]; then escalate_ids+=("$(jq -r '.id' "$f")"); fi
done
if [ ${#escalate_ids[@]} -gt 0 ] && [ "$LIGHT" != "$FULL" ]; then
  echo "escalating ${#escalate_ids[@]} light-tier records to $FULL"
  ei=0; chunk=()
  for id in "${escalate_ids[@]}"; do
    [ -f "$PROP/.stop" ] && break
    chunk+=("$id"); if [ ${#chunk[@]} -ge "$GROUP" ]; then gi=$((gi+1)); run_group "$RUN-e$gi" "$FULL" "${(j:,:)chunk}" & chunk=(); ei=$((ei+1)); [ $((ei % CONC)) -eq 0 ] && wait; fi
  done
  [ ${#chunk[@]} -gt 0 ] && [ ! -f "$PROP/.stop" ] && { gi=$((gi+1)); run_group "$RUN-e$gi" "$FULL" "${(j:,:)chunk}" & }
  wait
  [ -f "$PROP/.stop" ] && { echo "escalation stopped on a refusal — re-run after the reset"; exit 3; }
fi
echo "scan done — $(ls "$PROP"/[A-Z]*-*.json 2>/dev/null | wc -l | tr -d ' ') proposals; log: $LOG"
awk -F'\t' '/^group/ {c+=$5; d+=$6; g++; if ($7 ~ /FAILED/) f++} END {printf "groups=%d failed=%d cost=$%.2f\n", g, f, c}' "$LOG"
