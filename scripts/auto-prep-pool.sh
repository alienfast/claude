#!/bin/bash
# auto-prep-pool.sh — the /auto-prep pool fetch and collision extraction as a tested tool.
#
# Usage:
#   auto-prep-pool.sh --team KEY [--out tmp/pool.json]              # paginated pool fetch
#   auto-prep-pool.sh --team KEY --collisions [--checkout DIR]      # collision CANDIDATES from the pool
#
# Fetch mode writes {nodes:[...]} across the team's unstarted workable states
# (Backlog/Planned/Todo — /next's WORKABLE_STATES) and prints the pool size — the only
# tell a short fetch has: `first:` is a hard API cap (250) and overflow is silent, so a
# one-shot query hides whichever issues sort last with no error and exit 0. Measured on
# BF 2026-08-08: 266 workable issues, 16 hidden.
#
# Collision mode implements /auto-prep Step 3's extraction for every certified
# (`specified`) candidate in the pool: split the description into EDIT sections
# (Success Criteria / Requirements / Must Have / Nice to Have / In Scope) and CITE
# sections (everything else — Problem / Notes / Context / Decisions / Out of Scope /
# Boundaries and any unrecognized heading, because a false edge hides a workable issue
# from every ranking while a missed edge costs at most one merge conflict), then from
# the EDIT half plus the title extract:
#   - repo paths, tolerating a trailing :NNN or :NN-NN line citation — the regex whose
#     absence silently dropped every `file.rb:101` mention on the 2026-08-08 run;
#   - CamelCase and Foo::Bar identifiers, resolved against the checkout's tracked files
#     (basename match first, definition grep second) — the strong signal: both real
#     collisions that run were symbol-only, while every path collision the section rule
#     surfaced was a false positive.
# Groups on the RESOLVED paths and emits {path, issues:[...]} candidates for human
# confirmation — candidates to confirm with Step 3's clause-level edit-vs-citation read,
# NEVER edges to wire blind. Prints what it skipped: an issue yielding no edit-section
# path and no resolvable symbol is invisible to the analysis (35 of 62 on that run), and
# a symbol resolving to nothing means renamed or moved, not gone.
#
# Exit codes: 0 success, 1 arg error, 2 Linear/network failure, 3 missing dependency.
# Read-only — no Linear writes, no git mutations.

set -eo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

team=""
out=""
collisions=0
checkout="$PWD"

while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --collisions) collisions=1; shift ;;
    --checkout) checkout="$2"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

team="${team:-${LINEAR_TEAM:-}}"
[ -n "$team" ] || { echo "ERROR: --team KEY required (or \$LINEAR_TEAM)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 3; }
command -v linear-cli >/dev/null || { echo "ERROR: linear-cli not found" >&2; exit 3; }
[ "$collisions" = 0 ] || command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 3; }

mkdir -p tmp
out="${out:-tmp/pool.json}"

q='query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}}, state:{name:{in:["Backlog","Planned","Todo"]}}}, first:250, after:$after){nodes{identifier title description priority labels{nodes{name}} state{name} parent{identifier state{name}} relations{nodes{type relatedIssue{identifier state{name}}}} inverseRelations{nodes{type issue{identifier state{name}}}}} pageInfo{hasNextPage endCursor}}}'

pages="$(mktemp tmp/pool-pages-XXXXXX)"
trap 'rm -f "$pages"' EXIT
after=''
while :; do
  if [ -z "$after" ]; then page=$(linear-cli api query -q -o json -v team="$team" "$q")
  else page=$(linear-cli api query -q -o json -v team="$team" -v after="$after" "$q"); fi
  [ -n "$page" ] || { echo "ERROR: issue fetch returned nothing (auth? network?)" >&2; exit 2; }
  if [ "$(printf '%s' "$page" | jq 'has("errors")')" = "true" ]; then
    printf '%s' "$page" | jq -c '.errors' >&2; exit 2
  fi
  printf '%s\n' "$(printf '%s' "$page" | jq -c '.data.issues.nodes // []')" >> "$pages"
  # The envelope prefix on this path is load-bearing (linear gotcha #6): the un-prefixed
  # copy of the query's own path is null at exit 0, which reads as "last page" on page 1.
  has=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage // false')
  after=$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor // empty')
  { [ "$has" = "true" ] && [ -n "$after" ]; } || break
done
jq -s 'add | {nodes: .}' "$pages" > "$out.tmp" && mv "$out.tmp" "$out"
echo "pool: $(jq '.nodes | length' "$out") workable issues -> $out"

[ "$collisions" = 1 ] || exit 0

git -C "$checkout" rev-parse --show-toplevel >/dev/null 2>&1 \
  || { echo "ERROR: --checkout '$checkout' is not a git repo (symbol resolution needs the project tree)" >&2; exit 1; }

POOL_JSON="$out" CHECKOUT="$checkout" python3 <<'PY'
import json, os, re, subprocess, sys
from collections import defaultdict

pool = json.load(open(os.environ["POOL_JSON"]))["nodes"]
checkout = os.environ["CHECKOUT"]

certified = [n for n in pool if any(l["name"].lower() == "specified" for l in n["labels"]["nodes"])]

EDIT = ("success criteria", "requirements", "must have", "nice to have", "in scope")
CITE = ("out of scope",)  # checked before EDIT: "in scope" is a substring of "out of scope"

def edit_text(body, title):
    """Title + the EDIT-section halves of the body. Unrecognized headings are CITE."""
    parts = [title]
    section_is_edit = False
    for line in (body or "").splitlines():
        m = re.match(r"^#{1,6}\s+(.*)$", line) or re.match(r"^\*\*([^*]+)\*\*:?\s*$", line)
        if m:
            h = m.group(1).lower()
            section_is_edit = (not any(c in h for c in CITE)) and any(e in h for e in EDIT)
            continue
        if section_is_edit:
            parts.append(line)
    return "\n".join(parts)

# `[\w./-]+\.\w+` alone anchors on the extension and silently drops `file.rb:101` —
# the dominant citation form in this repo; the optional group is the fix.
PATH_RE = re.compile(r"\b((?:[\w.-]+/)+[\w.-]+\.[A-Za-z]{1,10})(?::\d+(?:-\d+)?)?\b")
SYM_RE = re.compile(r"\b([A-Z]\w*(?:::[A-Z]\w*)+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+)\b")

tracked = subprocess.run(["git", "-C", checkout, "ls-files"], capture_output=True, text=True).stdout.splitlines()
by_base = defaultdict(list)
for p in tracked:
    by_base[os.path.splitext(os.path.basename(p))[0]].append(p)

def snake(s):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "_", s).lower()

def resolve(sym):
    last = sym.rsplit("::", 1)[-1]
    hits = by_base.get(last, []) + by_base.get(snake(last), [])
    if "::" in sym:  # keep only paths consistent with the namespace, when any are
        ns = [snake(p) for p in sym.split("::")[:-1]]
        scoped = [h for h in hits if all(n in h for n in ns)]
        hits = scoped or hits
    if not hits:
        r = subprocess.run(["git", "-C", checkout, "grep", "-lE",
                            rf"(class|module|interface|type|const|def|function)\s+{re.escape(last)}\b"],
                           capture_output=True, text=True)
        hits = r.stdout.splitlines()
    return sorted(set(hits))

owners = defaultdict(dict)   # resolved path -> {issue-id: subject it came in as}
skipped, unresolved, ambiguous = [], [], []
for n in certified:
    iid = n["identifier"]
    text = edit_text(n.get("description"), n.get("title", ""))
    found = False
    for m in PATH_RE.finditer(text):
        p = m.group(1).lstrip("./")
        if p in tracked:
            owners[p][iid] = p; found = True
        else:
            unresolved.append((iid, p))
    for sym in sorted(set(SYM_RE.findall(text))):
        hits = resolve(sym)
        if not hits:
            unresolved.append((iid, sym)); continue
        if len(hits) > 8:
            ambiguous.append((iid, sym, len(hits))); continue
        found = True
        for h in hits:
            owners[h].setdefault(iid, sym)
    if not found:
        skipped.append(iid)

groups = sorted((p, sorted(ids)) for p, ids in owners.items() if len(ids) >= 2)
print(f"\ncertified candidates analyzed: {len(certified)}")
print(f"collision CANDIDATES (confirm each with Step 3's edit-vs-citation read; never wire blind): {len(groups)}")
for p, ids in groups:
    via = ", ".join(f"{i} via {owners[p][i]}" for i in ids)
    print(f"- {p}: {ids}  ({via})")
json.dump([{"path": p, "issues": ids} for p, ids in groups], open("tmp/pool-collisions.json", "w"), indent=2)
print("-> tmp/pool-collisions.json")
if ambiguous:
    print(f"\nambiguous symbols (>8 files; excluded from grouping — narrow by hand if load-bearing):")
    for iid, sym, k in sorted(set(ambiguous)):
        print(f"- {iid}: {sym} ({k} files)")
if unresolved:
    print(f"\nunresolved mentions (path not tracked / symbol not found — renamed or moved is likelier than gone; `git log -S <symbol>` before dropping):")
    for iid, s in sorted(set(unresolved)):
        print(f"- {iid}: {s}")
if skipped:
    print(f"\nSKIPPED — no edit-section path and no resolvable symbol; INVISIBLE to this analysis ({len(skipped)} of {len(certified)}):")
    for iid in skipped:
        print(f"- {iid}")
PY
