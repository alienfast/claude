#!/bin/zsh
# triage-cheap-pass.sh — /triage Steps 1+2: paginated pool fetch, then the per-issue cheap pass.
#
# Usage: triage-cheap-pass.sh --team KEY [--out DIR] [--ids ID,ID,...]
#   --team KEY   Linear team key (required; $LINEAR_TEAM is NOT read — pass it explicitly).
#   --out DIR    output directory (default: tmp). Writes DIR/triage-pool.ndjson, DIR/triage-cheap.ndjson,
#                DIR/triage-head.sha (the sha every marker of this run must carry) and a coverage summary on stdout.
#   --ids        targeted mode: skip the pool fetch's state filter and fetch exactly these issues.
#
# Run from the project checkout (git facts come from cwd). Read-only against Linear and git.
#
# Per issue it records: stage, lane, claimed, marker (newest comment starting `triage-revalidated:`),
# baseline (marker sha, marker date, or createdAt), named subjects (paths the text names that exist on
# disk, plus files that its named identifiers resolve to), unresolved identifiers, commits touching the
# subjects since the baseline, the commit-subject test (a commit whose SUBJECT LINE leads with the id),
# body-only mentions, and a class:
#   claimed | unchanged | shipped? | drifted | touched | no-subjects | never-revalidated
# `drifted` means a named subject no longer resolves (a rename or removal signal); `touched` means commits
# landed on the subjects since the baseline. Only `unchanged` is a skip; the deep pass reads the rest.
#
# Identifier normalization (measured 2026-09-22 on BF, where 72 of 518 unresolved tokens carried a
# line suffix and every checked `unresolved` in the Planned stage but two was a rename or a false
# negative): strip `:NN` / `:NN-NN` locators; a bare `Name.ext` resolves through `git ls-files`, not
# content grep; `Class#method` / `Class.method` / `A::B::C` are searched by their last segment; a dotted
# GraphQL path is searched by its head token. An identifier resolving to more than MAX_FILES_PER_IDENT
# files is too generic and is dropped; an issue keeps at most MAX_SUBJECTS files, explicit paths first.
set -o pipefail
export PATH="$HOME/.cargo/bin:$PATH"

TEAM=""; OUT="tmp"; IDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --ids) IDS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$TEAM" ] || { echo "usage: triage-cheap-pass.sh --team KEY [--out DIR] [--ids ID,ID]" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "run from inside the project checkout" >&2; exit 1; }
command -v linear-cli >/dev/null || { echo "linear-cli not found" >&2; exit 1; }
mkdir -p "$OUT"
POOL="$OUT/triage-pool.ndjson"; CHEAP="$OUT/triage-cheap.ndjson"
MAX_FILES_PER_IDENT=10; MAX_IDENTS=8; MAX_SUBJECTS=15

FIELDS='identifier title description createdAt updatedAt url creator{name email} assignee{email} priority state{name type} labels{nodes{name}} parent{identifier} relations{nodes{type relatedIssue{identifier state{name}}}} inverseRelations{nodes{type issue{identifier state{name}}}} comments(first:50){nodes{createdAt body user{name}}}'

echo "== step 1: fetch pool ($TEAM) =="
: >| "$POOL"
if [ -n "$IDS" ]; then
  for id in ${(s:,:)IDS}; do
    linear-cli api query -q -o json -v id="$id" "query(\$id:String!){issue(id:\$id){$FIELDS}}" | jq -c '.data.issue | select(. != null)' >> "$POOL"
  done
else
  q="query(\$team:String!,\$after:String){issues(filter:{team:{key:{eq:\$team}}, state:{type:{in:[\"triage\",\"backlog\",\"unstarted\"]}}}, first:100, after:\$after){nodes{$FIELDS} pageInfo{hasNextPage endCursor}}}"
  after=""
  while :; do
    if [ -z "$after" ]; then page=$(linear-cli api query -q -o json -v team="$TEAM" "$q")
    else page=$(linear-cli api query -q -o json -v team="$TEAM" -v after="$after" "$q"); fi
    if [ "$(printf '%s' "$page" | jq -r '.data.issues.pageInfo | type')" != "object" ]; then
      echo "ERROR: page without pageInfo (query error?):" >&2; printf '%s\n' "$page" | head -c 2000 >&2; exit 2
    fi
    printf '%s\n' "$page" | jq -c '.data.issues.nodes[]' >> "$POOL"
    [ "$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage')" = "true" ] || break
    after=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor')
  done
fi
ME=$(linear-cli users me -o json | jq -r '.email')
echo "pool rows: $(wc -l < "$POOL" | tr -d ' ')  viewer: $ME"

echo "== step 2: cheap pass =="
HEAD_SHA=$(git rev-parse --short=10 HEAD)
printf '%s\n' "$HEAD_SHA" >| "$OUT/triage-head.sha"
git log --all --format='%h %s' >| "$OUT/triage-commit-subjects.txt"
git log --all --format='%h %s%n%b' >| "$OUT/triage-commit-bodies.txt"
git ls-files >| "$OUT/triage-ls-files.txt"
: >| "$CHEAP"
n=0
while IFS= read -r row; do
  n=$((n+1))
  id=$(printf '%s' "$row" | jq -r '.identifier')
  created=$(printf '%s' "$row" | jq -r '.createdAt')
  assignee=$(printf '%s' "$row" | jq -r '.assignee.email // ""')
  claimed=false; [ -n "$assignee" ] && [ "$assignee" != "$ME" ] && claimed=true
  marker=$(printf '%s' "$row" | jq -r '[.comments.nodes[] | select(.body | startswith("triage-revalidated:"))] | sort_by(.createdAt) | last | .body // ""' | head -1)
  msha=""; mdate=""
  if [ -n "$marker" ]; then msha=$(printf '%s' "$marker" | awk '{print $2}'); mdate=$(printf '%s' "$marker" | awk '{print $3}'); fi
  text=$(printf '%s' "$row" | jq -r '[.title, (.description // ""), (.comments.nodes[] | select(.body | startswith("triage-revalidated:") | not) | .body)] | join("\n")')

  # Explicit paths: slash-bearing tokens that exist on disk (line locators and trailing punctuation stripped).
  explicit=()
  for p in $(printf '%s' "$text" | grep -oE '[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@\[\]()-]+)+' | sed -E 's/[.,;:)`]+$//; s/:[0-9]+(-[0-9]+)?$//' | sort -u); do
    [ -e "$p" ] && explicit+=("$p")
  done
  derived=(); unresolved=()
  # Marker fast path: the previous deep pass curated this issue's subjects into the marker's `subjects=` list,
  # which beats re-deriving them from generic identifiers. A marker subject that no longer exists is real drift.
  msubjects=""
  [ -n "$marker" ] && msubjects=$(printf '%s' "$marker" | head -1 | sed -n 's/.*subjects=//p' | tr ',' '\n' | grep -v '^$' | grep -vx 'none')
  if [ -n "$msubjects" ]; then
    for p in ${(f)msubjects}; do
      if [ -e "$p" ]; then derived+=("$p"); else unresolved+=("$p"); fi
    done
    idents=""
  else
    idents=$(printf '%s' "$text" | grep -oE '`[^`]{4,100}`' | tr -d '`' | sed -E 's/:[0-9]+(-[0-9]+)?$//' | grep -E '^[A-Za-z_][A-Za-z0-9_:.#?!/-]*$' | grep -vE '^(https?|specified|Backlog|Planned|Triage|true|false|null)$' | sort -u | head -"$MAX_IDENTS")
  fi
  # Identifiers (no marker): backticked tokens, normalized, resolved to files; generic ones dropped, missing ones recorded.
  for ident in ${(f)idents}; do
    [ -n "$ident" ] || continue
    case "$ident" in
      */*) continue ;;                                   # paths were handled above
    esac
    if printf '%s' "$ident" | grep -qE '^[A-Za-z0-9_-]+\.[a-z]{1,5}$'; then
      # bare filename → resolve by path, not by content
      hits=$(grep -F "/$ident" "$OUT/triage-ls-files.txt" | head -"$((MAX_FILES_PER_IDENT+1))")
      [ -z "$hits" ] && hits=$(grep -xF "$ident" "$OUT/triage-ls-files.txt")
      if [ -z "$hits" ]; then unresolved+=("$ident"); else for f in ${(f)hits}; do derived+=("$f"); done; fi
      continue
    fi
    # Class#method, Class.method, A::B::C, graphql.dotted.path → last segment (method) or head token (dotted path)
    term="$ident"
    case "$ident" in
      *'#'*) term=${ident##*'#'} ;;
      *::*) term=${ident##*::} ;;
      *.*)  term=${ident%%.*} ;;
    esac
    term=${term%%[?!]}
    [ ${#term} -ge 4 ] || continue
    files=$(git grep -l -w -F -e "$term" -- . 2>/dev/null | head -"$((MAX_FILES_PER_IDENT+1))")
    cnt=$(printf '%s' "$files" | grep -c .)
    if [ "$cnt" -eq 0 ]; then unresolved+=("$ident")
    elif [ "$cnt" -le "$MAX_FILES_PER_IDENT" ]; then for f in ${(f)files}; do derived+=("$f"); done
    fi
  done
  subjects=(${(u)explicit} ${(u)derived})
  subjects=(${(u)subjects})
  [ ${#subjects[@]} -gt "$MAX_SUBJECTS" ] && subjects=(${subjects[1,$MAX_SUBJECTS]})

  changed=0; base="createdAt"
  if [ ${#subjects[@]} -gt 0 ]; then
    if [ -n "$msha" ] && git cat-file -e "$msha^{commit}" 2>/dev/null && git merge-base --is-ancestor "$msha" HEAD 2>/dev/null; then
      base="marker"; changed=$(git log --oneline "$msha..HEAD" -- "${subjects[@]}" | wc -l | tr -d ' ')
    elif [ -n "$mdate" ]; then
      base="marker-date"; changed=$(git log --oneline --since="$mdate" -- "${subjects[@]}" | wc -l | tr -d ' ')
    else
      changed=$(git log --oneline --since="$created" -- "${subjects[@]}" | wc -l | tr -d ' ')
    fi
  fi
  # Commit-subject test. A hit already adjudicated by an earlier run (its commit is an ancestor of the marker sha)
  # is not re-flagged — BF-290's comment-only commit would otherwise read as shipped? on every run.
  shipped=""
  for line in ${(f)"$(grep -E "^[0-9a-f]+ ${id}:" "$OUT/triage-commit-subjects.txt" | head -3)"}; do
    [ -n "$line" ] || continue
    c=${line%% *}
    if [ -n "$msha" ] && git merge-base --is-ancestor "$c" "$msha" 2>/dev/null; then continue; fi
    shipped="${shipped:+$shipped|}$line"
  done
  bodyhits=$(grep -cE "\b${id}\b" "$OUT/triage-commit-bodies.txt")

  if [ "$claimed" = true ]; then cls="claimed"
  elif [ -n "$shipped" ]; then cls="shipped?"
  elif [ ${#unresolved[@]} -gt 0 ]; then cls="drifted"
  elif [ -n "$marker" ] && [ ${#subjects[@]} -gt 0 ] && [ "$changed" -eq 0 ]; then cls="unchanged"
  elif [ ${#subjects[@]} -eq 0 ]; then cls="no-subjects"
  elif [ "$changed" -gt 0 ]; then cls="touched"
  else cls="never-revalidated"; fi

  jq -cn --arg id "$id" --arg cls "$cls" --arg created "$created" --arg claimed "$claimed" \
    --arg marker "$marker" --arg msha "$msha" --arg mdate "$mdate" --arg base "$base" \
    --argjson changed "$changed" --arg shipped "$shipped" --argjson bodyhits "$bodyhits" \
    --argjson subjects "$(printf '%s\n' "${subjects[@]}" | grep . | jq -R . | jq -s .)" \
    --argjson unresolved "$(printf '%s\n' "${unresolved[@]}" | grep . | jq -R . | jq -s .)" \
    --argjson row "$row" \
    '{id:$id, class:$cls, stage:$row.state.name, state_type:$row.state.type,
      lane:(if ([$row.labels.nodes[].name]|index("specified")) then "certified" else "uncertified" end),
      labels:[$row.labels.nodes[].name], priority:$row.priority, created:$created, claimed:($claimed=="true"),
      creator:$row.creator.name, creator_email:$row.creator.email, title:$row.title, url:$row.url,
      marker:$marker, marker_sha:$msha, marker_date:$mdate, base:$base, changed:$changed,
      shipped_subject:$shipped, body_mentions:$bodyhits, subjects:$subjects, unresolved:$unresolved,
      ncomments:($row.comments.nodes|length), parent:($row.parent.identifier // null)}' >> "$CHEAP"
  [ $((n % 50)) -eq 0 ] && echo "  ...$n"
done < "$POOL"

echo "HEAD=$HEAD_SHA (written to $OUT/triage-head.sha — every marker of this run carries THIS sha)"
echo "== coverage =="
pool=$(jq -rs '[.[] | select(.claimed|not)] | length' "$CHEAP")
claimed=$(jq -rs '[.[] | select(.claimed)] | length' "$CHEAP")
unchanged=$(jq -rs '[.[] | select(.class=="unchanged")] | length' "$CHEAP")
never=$(jq -rs '[.[] | select((.claimed|not) and .marker=="")] | length' "$CHEAP")
echo "pool $pool unclaimed ($claimed claimed by others dropped) · skipped unchanged $unchanged · candidates $((pool-unchanged)) · never revalidated $never"
jq -rs 'group_by(.class) | map("  \(.[0].class): \(length)") | .[]' "$CHEAP"
echo "== by stage/lane (unclaimed) =="
jq -rs '[.[] | select(.claimed|not)] | group_by(.stage + "/" + .lane) | map("  \(.[0].stage)/\(.[0].lane): \(length)") | .[]' "$CHEAP"
echo "== queue heads (no marker first, oldest first; certified lane first within a stage) =="
jq -rs '[.[] | select(.claimed|not)] | group_by(.stage) | .[] | (.[0].stage) as $st
  | ["certified","uncertified"][] as $ln
  | [ .[] | select(.lane==$ln) ] | sort_by((.marker != ""), .marker_date, .created) | .[0:2][]
  | "  \($st)/\(.lane)\t\(.id)\t\(.created[:10])\t\(.class)\t\(.title[:70])"' "$CHEAP"
echo "DONE"
