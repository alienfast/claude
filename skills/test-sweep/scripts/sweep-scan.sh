#!/usr/bin/env bash
# sweep-scan.sh — /test-sweep scan mode: the unattended, read-only deep pass over the suites' costliest and most repeated tests.
#
# WHY THIS EXISTS: the rankers find candidates cheaply, but deciding whether a slow or repeated test is redundant means
# reading it against the layer that owns its mechanism — the policy spec, the shared dialog's own behavior file, the schema —
# which is an agent's job and takes minutes per file. This builds the candidate list from rank-rspec-files.sh and
# story-census.sh, chunks it into groups, and runs one headless `claude -p` per group with structured output
# (proposal.schema.json), writing one proposal per candidate for the interactive apply session. Nothing here edits the tree,
# runs a suite, or writes to Linear, and the agents have no sanctioned route to: `--restricted` ignores the user, project and local
# settings files (a headless run otherwise inherits every allow rule in them — rm, mv, bundle exec rspec, pnpm), `--strict-mcp-config`
# loads no MCP server, and an explicit deny list covers write-shaped Bash on top of the narrow read-only allow-list. The residual is
# `git diff|log|show --output=<file>`, which a prefix allow-list cannot exclude.
#
# USAGE
#   sweep-scan.sh [--repo DIR] [--out DIR] [--suite rspec|storybook|both] [--top N] [--group-size N] [--concurrency N]
#                 [--max-groups N] [--model NAME] [--api-dir REL] [--junit REL] [--slow N] [--force] [--dry-run] [--summary]
#                 [--check-current FILE ...] [--force-unlock]
#
#   --repo DIR        the project checkout (default: the checkout containing the cwd); a subdirectory resolves to the checkout root
#   --out DIR         where the census, candidates, proposals, and log go (default: <repo>/tmp)
#   --suite           which suites to sweep (default both); the candidate, todo and group files carry the suite in their names
#   --top N           rspec candidates taken from each of the by-seconds and by-seconds-per-example rankings (default 25)
#   --group-size N    candidates per agent (default 5; groups never mix suites)
#   --concurrency N   agents in flight at once (default 4)
#   --max-groups N    stop after N groups (a trial run)
#   --model NAME      model for every group (default opus)
#   --api-dir REL     the Rails app, relative to the repo (default apps/api)
#   --junit REL       the storybook junit report, relative to the repo (default tmp/storybook-junit.xml); forwarded to story-census.sh
#   --slow N          SLOW rows the story census prints (default 25); forwarded to story-census.sh
#   --force           re-scan candidates whose proposal is still current
#   --dry-run         build the candidates, write the first group's prompt and one placeholder proposal, call no agent
#   --summary         print the proposal counts by kind and the non-keep list, then exit
#   --check-current F print CURRENT or STALE for proposal file F (repeatable), then exit 1 if any is stale: a proposal is current
#                     only while no commit since its sha touched a candidate file or the target file
#   --force-unlock    remove a scan lock whose holder process is dead, then scan
#
# A project's own governing-rule citations go in <repo>/.claude/test-sweep-rules.md (committed), or <out>/test-sweep-rules.md when that
# is absent, appended to every group's prompt under "Project rules".
#
# OUTPUT (one verdict per line on stdout; per-group cost and duration also go to <out>/test-sweep-scan.log)
#   CANDIDATES <N> current=<N> to-scan=<N> groups=<N>
#   WARN <detail>                                  rspec timings or story files missing, or no storybook timings (no junit, a
#                                                  junit that does not match the tree, or one with no testcases)
#   GROUP <id> ok records=<N> cost=<usd> seconds=<N>    or  GROUP <id> FAILED|REFUSED <detail>
#   DRY-RUN prompt=<path> placeholder=<path>
#   SCAN-DONE proposals=<N this run> groups=<N> failed=<N> cost=<usd>     or  NOTHING-TO-SCAN
#   LOCKED <holder>                                another scan holds <out>/test-sweep-scan.lock
#   CURRENT <slug>  /  STALE <slug> <why>          from --check-current
#   --summary: PROPOSALS <N> seconds=<N> examples=<N>, KIND <kind> <N> mechanical=<N> seconds=<N> per kind, one tab-separated line
#   per non-keep proposal, and COST groups=<N> failed=<N> cost=<usd> from the log
#
# Resumable: a candidate whose proposal (pending, or under applied/) records a sha with no commit since on any of the
# candidate's files or its target is skipped; re-run after a crash or a refusal and it continues. A group that fails writes no
# proposals.
# Exit 0 done, 1 bad input (no candidates could be built, or a proposal is stale), 2 usage, environment error, or LOCKED,
# 3 a call was refused (session limit or auth) — proposals written before it stand.
# Requires git, jq, awk, and the claude CLI (except with --dry-run, --summary or --check-current).

# shellcheck disable=SC2016  # the awk and jq programs live in single quotes by design
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true

# Spec and story text carries UTF-8; byte-wise awk/sort cannot abort on a multibyte sequence. Scoped to these calls so the
# headless agents never inherit LC_ALL=C.
awk_c() { LC_ALL=C awk "$@"; }
sort_c() { LC_ALL=C sort "$@"; }

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "sweep-scan: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "sweep-scan: $1 needs a value" >&2; usage; exit 2; }; }

is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=""; OUT=""; SUITE="both"; TOP=25; GROUP=5; CONC=4; MAXG=0; MODEL="opus"; API_DIR="apps/api"; JUNIT="tmp/storybook-junit.xml"; SLOWN=25
FORCE=0; DRY=0; SUMMARY=0; FORCE_UNLOCK=0; CHECK=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --suite) need_value "$1" $#; SUITE="$2"; shift 2 ;;
    --top) need_value "$1" $#; TOP="$2"; shift 2 ;;
    --group-size) need_value "$1" $#; GROUP="$2"; shift 2 ;;
    --concurrency) need_value "$1" $#; CONC="$2"; shift 2 ;;
    --max-groups) need_value "$1" $#; MAXG="$2"; shift 2 ;;
    --model) need_value "$1" $#; MODEL="$2"; shift 2 ;;
    --api-dir) need_value "$1" $#; API_DIR="$2"; shift 2 ;;
    --junit) need_value "$1" $#; JUNIT="$2"; shift 2 ;;
    --slow) need_value "$1" $#; SLOWN="$2"; shift 2 ;;
    --check-current) need_value "$1" $#; CHECK+=("$2"); shift 2 ;;
    --force) FORCE=1; shift ;;
    --force-unlock) FORCE_UNLOCK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sweep-scan: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
for v in "$TOP" "$GROUP" "$CONC" "$MAXG" "$SLOWN"; do is_count "$v" || die "--top, --group-size, --concurrency, --max-groups and --slow take integers"; done
[ "$GROUP" -ge 1 ] && [ "$CONC" -ge 1 ] || die "--group-size and --concurrency must be at least 1"
case "$SUITE" in rspec|storybook|both) ;; *) die "--suite must be rspec, storybook, or both" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"

[ -n "$REPO" ] || REPO=$PWD
top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $REPO — pass --repo <the project checkout>"
REPO=$top

# ---- currency: a proposal is current while neither a candidate file nor its target changed since the sha it was measured at --
STALE_WHY=""
proposal_current() {  # proposal_current <proposal file> [extra files joined by |] → 0 current; sets STALE_WHY otherwise
  local p="$1" sha files tgt tok rest cand f fa hit shape='[]A-Za-z0-9_./()[-]+\.[A-Za-z0-9]+'
  fa=()
  STALE_WHY=""
  [ -s "$p" ] || { STALE_WHY="no proposal file"; return 1; }
  sha=$(jq -r '.sha // ""' "$p" 2>/dev/null)
  [ -n "$sha" ] || { STALE_WHY="no sha recorded"; return 1; }
  git -C "$REPO" cat-file -e "$sha^{commit}" 2>/dev/null || { STALE_WHY="sha $sha is not in this repository"; return 1; }
  files=$(jq -r '(.candidate_files // [])[]' "$p" 2>/dev/null)
  [ -z "${2:-}" ] || files="$files"$'\n'$(printf '%s' "$2" | tr '|' '\n')
  tgt=$(jq -r '.target // ""' "$p" 2>/dev/null)
  # A target is free text ("spec/policies/x_spec.rb: allows a superuser", "db/schema.rb", "Foo.stories.tsx#Granted"). Each whitespace token has
  # its leading decoration (quotes, a bracket, a paren, asterisks) trimmed, then is reduced to every substring shaped like a path through its file
  # extension, so whatever follows the extension (:14-20, [1:2], 's, ::Foo, #Export) drops out by construction. Brackets and parens stay path
  # characters because Next.js route groups and dynamic segments carry them (app/(authenticated)/kyc/[id]/…). A path that resolves to a tracked
  # file, as given then under the Rails app, joins the watched files; one that does not (a survivor not written yet, a description, no extension,
  # or a /-led or ../-led fragment git would place outside the repository) is skipped, so currency then rests on the candidate files alone. A git
  # failure while resolving an in-repository path is STALE, never a skip.
  while IFS= read -r tok; do
    rest=$(printf '%s' "$tok" | sed -E "s/^[][(\"'\`*]+//")
    while [[ $rest =~ $shape ]]; do
      cand=${BASH_REMATCH[0]}
      rest=${rest#*"$cand"}
      case "$cand" in /*|../*|*://*) continue ;; esac
      for f in "$cand" "$API_DIR/$cand"; do
        git -C "$REPO" --literal-pathspecs ls-files --error-unmatch -- "$f" >/dev/null 2>&1
        case $? in
          0) files="$files"$'\n'"$f"; break ;;
          1) ;;
          *) STALE_WHY="git ls-files failed resolving $f"; return 1 ;;
        esac
      done
    done
  done < <(printf '%s\n' "$tgt" | tr -s '[:space:]' '\n')
  while IFS= read -r f; do [ -n "$f" ] && fa+=("$f"); done < <(printf '%s\n' "$files" | sort_c -u)
  [ ${#fa[@]} -gt 0 ] || { STALE_WHY="no candidate files recorded"; return 1; }
  hit=$(git -C "$REPO" --literal-pathspecs log --format=%h -n 1 "$sha..HEAD" -- "${fa[@]}" 2>/dev/null)
  [ -z "$hit" ] && return 0
  for f in "${fa[@]}"; do
    if [ -n "$(git -C "$REPO" --literal-pathspecs log --format=%h -n 1 "$sha..HEAD" -- "$f" 2>/dev/null)" ]; then STALE_WHY="$f changed since $sha"; return 1; fi
  done
  STALE_WHY="files changed since $sha"
  return 1
}

if [ ${#CHECK[@]} -gt 0 ]; then
  rc=0
  for p in "${CHECK[@]}"; do
    slug=$(jq -r '.slug // "?"' "$p" 2>/dev/null || echo "?")
    if proposal_current "$p" ""; then echo "CURRENT $slug"; else echo "STALE $slug $STALE_WHY"; rc=1; fi
  done
  exit $rc
fi

[ -n "$OUT" ] || OUT="$REPO/tmp"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd) || die "cannot enter $OUT"

PROP="$OUT/test-sweep-proposals"; LOG="$OUT/test-sweep-scan.log"; CAND="$OUT/test-sweep-candidates-$SUITE.tsv"
RANK_OUT="$OUT/test-sweep-rspec-rank.txt"; CENSUS_OUT="$OUT/test-sweep-story-census.txt"
RULES_REL=".claude/test-sweep-rules.md"; RULES_FALLBACK="$OUT/test-sweep-rules.md"; LOCKDIR="$OUT/test-sweep-scan.lock"
mkdir -p "$PROP/raw"

if [ "$SUMMARY" -eq 1 ]; then
  n=0
  for f in "$PROP"/*.json; do [ -s "$f" ] && n=$((n + 1)); done
  if [ "$n" -eq 0 ]; then echo "PROPOSALS 0"; exit 0; fi
  cat "$PROP"/*.json | jq -rs '
    def secs: map(.estimated_seconds // 0) | add // 0 | . * 10 | round / 10;
    "PROPOSALS \(length) seconds=\(secs) examples=\(map(.examples_removed // 0) | add // 0)",
    (group_by(.kind)[] | "KIND \(.[0].kind) \(length) mechanical=\(map(select(.mechanical)) | length) seconds=\(secs)"),
    (map(select(.kind != "keep")) | sort_by(.kind, -(.estimated_seconds // 0))[]
      | "\(.kind)\t\(.slug)\t\(.estimated_seconds // "?")s\t-\(.examples_removed)\t\(if .mechanical then "mechanical" else "judgment" end)\t\((.evidence // "")[:160])")'
  [ -f "$LOG" ] && awk_c -F'\t' '$1 == "group" { c += $4; g++; if ($6 !~ /^ok/) f++ } END { printf "COST groups=%d failed=%d cost=$%.2f\n", g, f, c }' "$LOG"
  exit 0
fi

RUN="$(date +%Y%m%d-%H%M%S)-$$"

# One scan at a time per out dir: the census, candidate and group files, and the proposals are rewritten in place.
LOCK_HELD=0
# shellcheck disable=SC2329  # invoked by the EXIT trap
release_lock() { [ "$LOCK_HELD" -eq 1 ] && rm -rf "$LOCKDIR"; }
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  holder=$(cat "$LOCKDIR/holder" 2>/dev/null || echo "unknown holder")
  hpid=$(printf '%s' "$holder" | sed -n 's/^pid=\([0-9][0-9]*\) .*/\1/p')
  alive=0; { [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; } && alive=1
  if [ "$FORCE_UNLOCK" -eq 1 ] && [ "$alive" -eq 0 ]; then
    rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || die "cannot retake $LOCKDIR"
  else
    echo "LOCKED $holder alive=$alive"
    [ "$alive" -eq 0 ] && echo "sweep-scan: the holder is not running — re-run with --force-unlock" >&2
    exit 2
  fi
fi
LOCK_HELD=1
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'pid=%s run=%s since=%s\n' "$$" "$RUN" "$(date -u +%FT%TZ)" > "$LOCKDIR/holder"

# ---- candidates: slug <TAB> suite <TAB> files joined by | <TAB> why ------------------------------------------------------
SLUG_AWK='
  function slug(prefix, s) { gsub(/[^A-Za-z0-9._-]+/, "-", s); return prefix "-" s }
  function hash(s,   h, i) { h = 5381; for (i = 1; i <= length(s); i++) h = (h * 33 + index(CHARS, substr(s, i, 1))) % 1000000007; return sprintf("%x", h) }
  BEGIN { CHARS = " !\"#$%&\047()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~" }'
raw="$CAND.raw"
: > "$raw"
if [ "$SUITE" != "storybook" ]; then
  bash "$HERE/rank-rspec-files.sh" --repo "$REPO" --api-dir "$API_DIR" > "$RANK_OUT"
  rc=$?
  case "$rc" in
    0)
      grep '^RANK ' "$RANK_OUT" | head -n "$TOP" | awk_c -v api="$API_DIR" "$SLUG_AWK"'
        { f = api "/" $5; printf "%s\trspec\t%s\ttop latest-run seconds #%d: %ss over %s examples\n", slug("rspec", f), f, NR, $2, $3 }' >> "$raw"
      grep '^RANK ' "$RANK_OUT" | awk_c '$4 != "-"' | sort_c -k4,4nr | head -n "$TOP" | awk_c -v api="$API_DIR" "$SLUG_AWK"'
        { f = api "/" $5; printf "%s\trspec\t%s\ttop s/example #%d: %ss each over %s examples\n", slug("rspec", f), f, NR, $4, $3 }' >> "$raw"
      grep '^TAGGED ' "$RANK_OUT" | awk_c -v api="$API_DIR" "$SLUG_AWK"'
        { f = api "/" $2; printf "%s\trspec\t%s\ttagged with a slow DB strategy\n", slug("rspec", f), f }' >> "$raw"
      grep '^REPEAT ' "$RANK_OUT" | awk_c -v api="$API_DIR" "$SLUG_AWK"'
        {
          q1 = index($0, "\""); rest = substr($0, q1 + 1); q2 = index(rest, "\""); d = substr(rest, 1, q2 - 1)
          n = split(substr(rest, q2 + 2), fs, " "); files = ""
          for (i = 1; i <= n; i++) files = files (i > 1 ? "|" : "") api "/" fs[i]
          printf "%s\trspec\t%s\trepeat across %d files: \"%s\"\n", slug("rspec-repeat", substr(d, 1, 48)) "-" hash(d), files, n, d
        }' >> "$raw"
      ;;
    1) echo "WARN no rspec timings ledger — rspec candidates skipped (run the full suite once through run_rspec)" ;;
    *) die "rank-rspec-files.sh failed (exit $rc)" ;;
  esac
fi
if [ "$SUITE" != "rspec" ]; then
  bash "$HERE/story-census.sh" --repo "$REPO" --junit "$JUNIT" --slow "$SLOWN" > "$CENSUS_OUT"
  rc=$?
  case "$rc" in
    0)
      awk_c "$SLUG_AWK"'
        $1 == "BIG" { printf "%s\tstorybook\t%s\tbig: %s exports\n", slug("storybook", $3), $3, $2 }
        $1 == "SHARED" || $1 == "HELPER" {
          files = ""; for (i = 4; i <= NF; i++) files = files (i > 4 ? "|" : "") $i
          printf "%s\tstorybook\t%s\t%s: %s in %s files\n", slug("storybook-" tolower($1), $2), files, tolower($1), $2, $3
        }
        $1 == "DETAG-CANDIDATE" { s = $3; sub(/^sibling=/, "", s); printf "%s\tstorybook\t%s|%s\tdetag: no play, behavior sibling exists\n", slug("storybook", $2), $2, s }
        $1 == "MATRIX" { printf "%s\tstorybook\t%s\tmatrix: %s exports named %s*\n", slug("storybook", $2), $2, $4, $3 }' "$CENSUS_OUT" >> "$raw"
      if grep -q '^WARN junit-subset' "$CENSUS_OUT"; then echo "WARN storybook junit does not match the current tree — no storybook timings; estimated_seconds will be null"
      elif grep -qE '^(NO-JUNIT|WARN junit-no-testcases)' "$CENSUS_OUT"; then echo "WARN no storybook timings (no usable junit at $JUNIT); estimated_seconds will be null"; fi
      ;;
    1) echo "WARN no story files — storybook candidates skipped" ;;
    *) die "story-census.sh failed (exit $rc)" ;;
  esac
fi

awk_c -F'\t' '
  {
    if (!($1 in suite)) { order[++n] = $1; suite[$1] = $2; files[$1] = $3; why[$1] = $4; next }
    k = split($3, a, "|")
    for (i = 1; i <= k; i++) if (index("|" files[$1] "|", "|" a[i] "|") == 0) files[$1] = files[$1] "|" a[i]
    why[$1] = why[$1] "; " $4
  }
  END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\n", order[i], suite[order[i]], files[order[i]], why[order[i]] }' "$raw" > "$CAND"
rm -f "$raw"
total=$(awk_c 'END { print NR }' "$CAND")
[ "$total" -gt 0 ] || { echo "sweep-scan: no candidates could be built (see $RANK_OUT and $CENSUS_OUT)" >&2; exit 1; }

# ---- resumability: skip a candidate whose proposal is still current -----------------------------------------------------------
is_current() {  # is_current <slug> <files joined by |>
  local p
  for p in "$PROP/$1.json" "$PROP/applied/$1.json"; do
    [ -s "$p" ] || continue
    proposal_current "$p" "$2" && return 0
  done
  return 1
}
todo="$OUT/test-sweep-todo-$SUITE.tsv"
: > "$todo"
current=0
while IFS=$'\t' read -r slug suite files why; do
  if [ "$FORCE" -eq 0 ] && is_current "$slug" "$files"; then current=$((current + 1)); continue; fi
  printf '%s\t%s\t%s\t%s\n' "$slug" "$suite" "$files" "$why" >> "$todo"
done < "$CAND"

groups_file="$OUT/test-sweep-groups-$SUITE.txt"
awk_c -F'\t' -v size="$GROUP" '
  { if ($2 != cur || k >= size) { if (k > 0) print line; line = $2 "\t" $1; k = 1; cur = $2 } else { line = line "," $1; k++ } }
  END { if (k > 0) print line }' "$todo" > "$groups_file"
ngroups=$(awk_c 'END { print NR }' "$groups_file")
echo "CANDIDATES $total current=$current to-scan=$(awk_c 'END { print NR }' "$todo") groups=$ngroups"
if [ "$ngroups" -eq 0 ]; then echo "NOTHING-TO-SCAN"; exit 0; fi

head_sha=$(git -C "$REPO" rev-parse --short=10 HEAD)

candidate_lines() {  # candidate_lines <comma-separated slugs>
  awk_c -F'\t' -v want="$1" '
    BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) keep[w[i]] = i }
    $1 in keep { files = $3; gsub(/\|/, ", ", files); line[keep[$1]] = sprintf("- slug: %s | suite: %s | files: %s | why: %s", $1, $2, files, $4) }
    END { for (i = 1; i <= n; i++) if (i in line) print line[i] }' "$todo"
}

build_prompt() {  # build_prompt <comma-separated slugs>
  local prompt lines rules=""
  [ ! -s "$REPO/$RULES_REL" ] || rules="$REPO/$RULES_REL"
  [ -n "$rules" ] || [ ! -s "$RULES_FALLBACK" ] || rules="$RULES_FALLBACK"
  lines=$(candidate_lines "$1")
  prompt=$(cat "$HERE/scan-prompt.md")
  prompt=${prompt//\{\{CANDIDATES\}\}/$lines}
  prompt=${prompt//\{\{OUT\}\}/$OUT}
  prompt=${prompt//\{\{API_DIR\}\}/$API_DIR}
  prompt=${prompt//\{\{JUNIT\}\}/$JUNIT}
  [ -z "$rules" ] || prompt="$prompt"$'\n\n## Project rules\n\n'"$(cat "$rules")"
  printf '%s\n' "$prompt"
}

if [ "$DRY" -eq 1 ]; then
  IFS=$'\t' read -r gsuite gslugs < "$groups_file"
  pfile="$PROP/raw/dry-run-$RUN.prompt.md"
  build_prompt "$gslugs" > "$pfile"
  first=${gslugs%%,*}
  row=$(awk_c -F'\t' -v s="$first" '$1 == s' "$todo" | head -n 1)
  files=$(printf '%s' "$row" | cut -f3); why=$(printf '%s' "$row" | cut -f4)
  mkdir -p "$PROP/dry-run"
  placeholder="$PROP/dry-run/$first.json"
  jq -n --arg slug "$first" --arg suite "$gsuite" --arg files "$files" --arg why "$why" --arg sha "$head_sha" --arg at "$(date -u +%FT%TZ)" '{
    slug: $slug, file: ($files | split("|") | .[0]), suite: $suite, kind: "keep", target: "",
    evidence: "DRY RUN placeholder: no agent read this candidate", estimated_seconds: 0, examples_removed: 0, removed: [],
    governing_rule: "", mechanical: false, mutation: "", report: "Placeholder written by sweep-scan.sh --dry-run.",
    sha: $sha, model: "dry-run", group: "dry-run", scanned_at: $at, placeholder: true,
    candidate_files: ($files | split("|")), census: $why }' > "$placeholder"
  echo "DRY-RUN prompt=$pfile placeholder=$placeholder"
  exit 0
fi

command -v claude >/dev/null 2>&1 || die "the claude CLI is not on PATH"
SCHEMA=$(cat "$HERE/proposal.schema.json")
ALLOWED=( 'Bash(git log:*)' 'Bash(git show:*)' 'Bash(git diff:*)' 'Bash(git ls-files:*)' 'Bash(git rev-parse:*)'
  'Bash(git blame:*)' 'Bash(jq:*)' 'Bash(cat:*)' 'Bash(ls:*)' 'Bash(grep:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(wc:*)' )
DENIED=( 'Bash(rm:*)' 'Bash(mv:*)' 'Bash(bundle exec:*)' 'Bash(pnpm:*)' 'Bash(./tools/ci:*)' 'Bash(git stash:*)' 'Bash(git restore:*)'
  'Bash(git checkout:*)' 'Bash(tee:*)' )

run_group() {  # run_group <group id> <comma-separated slugs>
  local gid="$1" slugs="$2" raw t0 rc cost dur ok sha msg rec slug row
  raw="$PROP/raw/group-$gid.json"
  t0=$(date +%s)
  (cd "$REPO" && claude -p "$(build_prompt "$slugs")" --model "$MODEL" --output-format json --json-schema "$SCHEMA" \
    --tools "Bash,Read,Grep,Glob" --restricted --strict-mcp-config --permission-mode dontAsk --allowedTools "${ALLOWED[@]}" \
    --disallowedTools "${DENIED[@]}" --add-dir "$OUT") < /dev/null > "$raw" 2> "$raw.err"
  rc=$?
  dur=$(( $(date +%s) - t0 ))
  cost=$(jq -r '.total_cost_usd // 0' "$raw" 2>/dev/null || echo 0)
  if [ "$(jq -r '.is_error // false' "$raw" 2>/dev/null)" = "true" ]; then
    # A refused call (session limit, auth) arrives as is_error:true under subtype:success; further launches are pointless.
    msg=$(jq -r '.result // ""' "$raw" | head -c 200 | tr '\n\t' '  ')
    printf 'group\t%s\t%s\t%s\t%s\tREFUSED %s\t%s\n' "$gid" "$MODEL" "${cost:-0}" "$dur" "$msg" "$slugs" >> "$LOG"
    echo "GROUP $gid REFUSED $msg"
    touch "$PROP/.stop"
    return 1
  fi
  ok=$(jq -r '.structured_output.candidates | length' "$raw" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$ok" ] || [ "$ok" = "null" ]; then
    printf 'group\t%s\t%s\t%s\t%s\tFAILED rc=%s\t%s\n' "$gid" "$MODEL" "${cost:-0}" "$dur" "$rc" "$slugs" >> "$LOG"
    echo "GROUP $gid FAILED rc=$rc see $raw.err"
    return 1
  fi
  sha=$(jq -r '.structured_output.sha // empty' "$raw")
  [ -n "$sha" ] || sha=$head_sha
  jq -c '.structured_output.candidates[]' "$raw" | while IFS= read -r rec; do
    slug=$(printf '%s' "$rec" | jq -r '.slug')
    case ",$slugs," in *",$slug,"*) ;; *) echo "GROUP $gid WARN unknown slug in output: $slug"; continue ;; esac
    row=$(awk_c -F'\t' -v s="$slug" '$1 == s' "$todo" | head -n 1)
    printf '%s' "$rec" | jq --arg sha "$sha" --arg model "$MODEL" --arg gid "$gid" --arg at "$(date -u +%FT%TZ)" \
      --arg files "$(printf '%s' "$row" | cut -f3)" --arg why "$(printf '%s' "$row" | cut -f4)" \
      '. + {sha: $sha, model: $model, group: $gid, scanned_at: $at, candidate_files: ($files | split("|")), census: $why}' > "$PROP/$slug.json"
  done
  printf 'group\t%s\t%s\t%s\t%s\tok records=%s\t%s\n' "$gid" "$MODEL" "${cost:-0}" "$dur" "$ok" "$slugs" >> "$LOG"
  echo "GROUP $gid ok records=$ok cost=$cost seconds=$dur"
}

rm -f "$PROP/.stop"
printf 'run\t%s\t%s\tcandidates=%s\tcurrent=%s\tgroups=%s\n' "$RUN" "$MODEL" "$total" "$current" "$ngroups" >> "$LOG"
gi=0
while IFS=$'\t' read -r _ gslugs; do
  [ -f "$PROP/.stop" ] && break
  gi=$((gi + 1))
  run_group "$RUN-$gi" "$gslugs" &
  [ $((gi % CONC)) -eq 0 ] && wait
  [ "$MAXG" -gt 0 ] && [ "$gi" -ge "$MAXG" ] && break
done < "$groups_file"
wait

summary=$(awk_c -F'\t' -v run="$RUN" '
  $1 == "group" && index($2, run "-") == 1 { c += $4; g++; if ($6 !~ /^ok/) f++; else { r = $6; sub(/^ok records=/, "", r); p += r } }
  END { printf "proposals=%d groups=%d failed=%d cost=$%.2f", p, g, f, c }' "$LOG")
echo "SCAN-DONE $summary"
if [ -f "$PROP/.stop" ]; then
  echo "sweep-scan: stopped on a refused call — re-run after the reset; proposals written so far stand" >&2
  exit 3
fi
exit 0
