#!/bin/zsh
# triage-apply-markers.sh — post the standalone `triage-revalidated:` marker comment for proposals, then
# move each applied proposal to DIR/triage-proposals/applied/ so a resumed apply session does not re-present it.
#
# Usage: triage-apply-markers.sh [--out DIR] [--dispositions keep,hand-to-spec] [--ids ID,ID,...] [--dry-run]
#   --dispositions   which proposal dispositions to mark (default: keep,hand-to-spec — the two that need no
#                    approval; pass the others only AFTER their batch was approved and its own writes landed)
#   --ids            restrict to these issues
#   --dry-run        print the bodies, post nothing, move nothing
#
# The marker's sha is the proposal's `sha` (what the agent measured), never HEAD at post time, and its
# subjects are the proposal's curated list — that is what the next script pass's fast path reads.
set -o pipefail
export PATH="$HOME/.cargo/bin:$PATH"
OUT="tmp"; DISP="keep,hand-to-spec"; IDS=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --dispositions) DISP="$2"; shift 2 ;;
    --ids) IDS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
PROP="$OUT/triage-proposals"; mkdir -p "$PROP/applied" "$OUT/triage-markers"
verdict_for() { case "$1" in keep) echo keep ;; hand-to-spec) echo spec ;; ask-filer) echo filer ;; regroom) echo regroom ;; narrow) echo narrowed ;; certify) echo certified ;; *) echo "$1" ;; esac; }
ok=0; fail=0; skipped=0
for f in "$PROP"/[A-Z]*-*.json; do
  [ -s "$f" ] || continue
  id=$(jq -r '.id' "$f"); disp=$(jq -r '.disposition' "$f")
  case ",$DISP," in *",$disp,"*) ;; *) skipped=$((skipped+1)); continue ;; esac
  if [ -n "$IDS" ]; then case ",$IDS," in *",$id,"*) ;; *) continue ;; esac; fi
  sha=$(jq -r '.sha' "$f"); date=$(jq -r '.scanned_at[:10]' "$f")
  subjects=$(jq -r '(.subjects // []) | map(select(length>0)) | if length==0 then "none" else join(",") end' "$f")
  note=$(jq -r '[.evidence, (if .disposition=="hand-to-spec" and (.open_question // "") != "" then "Open for /spec: " + .open_question else empty end), (if (.renames // []) | length > 0 then "Renames: " + (.renames | join("; ")) else empty end)] | join("\n")' "$f")
  body="$OUT/triage-markers/$id.md"
  printf 'triage-revalidated: %s %s verdict=%s subjects=%s\n%s\n' "$sha" "$date" "$(verdict_for "$disp")" "$subjects" "$note" >| "$body"
  if [ "$DRY" -eq 1 ]; then echo "== $id ($disp)"; cat "$body"; continue; fi
  if ~/.claude/scripts/linear-post.sh comment "$id" "$body" >/dev/null 2>&1; then
    mv "$f" "$PROP/applied/"; ok=$((ok+1)); echo "marked $id ($disp)"
  else fail=$((fail+1)); echo "FAILED $id"; fi
done
echo "markers posted=$ok failed=$fail skipped(other dispositions)=$skipped"
