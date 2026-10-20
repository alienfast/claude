#!/usr/bin/env bash
# Regression suite for epic-pr.sh — the post-fleet epic PR resolver. Fixtures pin: the epic resolution order
# (argument, then the checked-out epic/* branch, then the recommendation's scope, then the one local epic/* branch) and
# its two ASK exits (no candidate, several candidates); the base order (--base, recorded, config, checkout) and the
# ASK when the checkout sits on the integration branch; the roster split — landed members in landing order, a
# subject-only, id-anchored match (EP-20 never lands EP-2; a body citing EP-4 does not land it), the root and
# Canceled/Duplicate members skipped; --dry-run writing nothing; and the real run handing integration-pr.sh the landed
# ids in order, creating the PR once and finding it on the next run.
#
# Isolation: a throwaway repo with a bare origin; linear-cli and gh are PATH shims; HOME is an empty dir so
# epic-graph.sh's cargo-bin prepend cannot resurrect the real CLI. Run by hand: bash ~/.claude/scripts/epic-pr.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/epic-pr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi; }
ck_has() { if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi; }
ck_lacks() { if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi; }
val() { grep -E "^$2=" "$1" | head -1 | sed "s/^$2=//"; }

FIX="$WORK/fix"; mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

node() { # node <ID> <title> <state> <type> <labels-json> <parent|null> <children-json> <relations-json> <inverse-json>
  local parent='null'; [ "$6" != "null" ] && parent="{\"identifier\":\"$6\"}"
  printf '{"data":{"issue":{"identifier":"%s","title":"%s","state":{"name":"%s","type":"%s"},"team":{"key":"EP"},"labels":{"nodes":%s},"parent":%s,"children":{"nodes":%s},"relations":{"nodes":%s},"inverseRelations":{"nodes":%s}}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$parent" "$7" "$8" "$9" > "$FIX/$1.json"
}
kids() { local out="[" sep=""; for c in "$@"; do out="$out$sep{\"identifier\":\"$c\"}"; sep=","; done; printf '%s]' "$out"; }
# EP-1 epic → EP-2 (Done, landed second), EP-3 (Planned, landed first), EP-4 (Planned, only cited in a body),
# EP-5 (Canceled), EP-6 (nested epic container → EP-7, Planned, not landed)
node EP-1 "the epic"        Planned  unstarted '[{"name":"epic"}]'      null "$(kids EP-2 EP-3 EP-4 EP-5 EP-6)" '[]' '[]'
node EP-2 "second card"     Done     completed '[{"name":"specified"}]' EP-1 '[]' '[]' '[]'
node EP-3 "first card"      Planned  unstarted '[{"name":"specified"}]' EP-1 '[]' '[]' '[]'
node EP-4 "cited only"      Planned  unstarted '[{"name":"specified"}]' EP-1 '[]' '[]' '[]'
node EP-5 "dropped"         Canceled canceled  '[]'                     EP-1 '[]' '[]' '[]'
node EP-6 "nested epic"     Planned  unstarted '[{"name":"epic"}]'      EP-1 "$(kids EP-7)" '[]' '[]'
node EP-7 "under nested"    Planned  unstarted '[{"name":"specified"}]' EP-6 '[]' '[]' '[]'

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
if [ "\$1" = issues ] && [ "\$2" = get ]; then
  [ -f "\$FIX/\$3.json" ] && jq -c '.data.issue' "\$FIX/\$3.json" && exit 0
  exit 2
fi
id=""
for a in "\$@"; do case "\$a" in id=*) id="\${a#id=}" ;; esac; done
if [ -f "\$FIX/\$id.json" ]; then cat "\$FIX/\$id.json"; exit 0; fi
printf '%s\n' '{"code":2,"details":[{"message":"Entity not found: Issue","path":["issue"]}],"error":true,"message":"GraphQL error"}'
exit 2
EOF
cat > "$WORK/bin/gh" <<EOF
#!/bin/bash
WORK="$WORK"
printf '%s\n' "\$*" >> "\$WORK/gh.log"
case "\$1 \$2" in
  "pr list") if [ -f "\$WORK/pr-created" ]; then echo '[{"url":"https://example.test/pull/42","number":42}]'; else echo '[]'; fi ;;
  "pr create") while [ \$# -gt 0 ]; do [ "\$1" = --body-file ] && cp "\$2" "\$WORK/pr-body.md"; [ "\$1" = --title ] && printf '%s\n' "\$2" > "\$WORK/pr-title.txt"; shift; done; : > "\$WORK/pr-created" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home"

# A repo with a bare origin, main and release pushed, and epic/ep-1 carrying the landing commits in order.
REPO="$WORK/repo"; ORIGIN="$WORK/origin.git"
git init -q -b main "$REPO"; git init -q --bare "$ORIGIN"
g() { git -C "$REPO" -c user.name=t -c user.email=t@example.test "$@"; }
g commit -q --allow-empty -m "root"
g remote add origin "$ORIGIN"; g push -q -u origin main
g branch release main; g push -q origin release
g branch epic/ep-1 main
g checkout -q epic/ep-1
g commit -q --allow-empty -m "EP-3: first card"
g commit -q --allow-empty -m "EP-20: a different issue whose id starts with EP-2"
g commit -q --allow-empty -m "Merge EP-2" -m "leaves EP-4 for later"
g checkout -q main
cd "$REPO" || exit 1

run() { # run <outfile> <args...> → exit code on stdout
  local out="$1"; shift
  "$SCRIPT" "$@" > "$out" 2> "$out.err"; echo $?
}

# T1 — nothing names an epic, and the only epic/* branch is the one: sole-branch resolution; base from the checkout.
rc=$(run "$WORK/t1" --dry-run)
ck "T1 exit" 0 "$rc"
ck "T1 epic" EP-1 "$(val "$WORK/t1" EPIC)"
ck "T1 epic source" sole-branch "$(val "$WORK/t1" EPIC_SOURCE)"
ck "T1 branch" epic/ep-1 "$(val "$WORK/t1" BRANCH)"
ck "T1 base" main "$(val "$WORK/t1" BASE)"
ck "T1 base source" checkout "$(val "$WORK/t1" BASE_SOURCE)"
ck "T1 landed, in landing order" "EP-3,EP-2" "$(val "$WORK/t1" LANDED)"
ck "T1 not landed (body citation and nested child excluded from landed)" "EP-4,EP-7" "$(val "$WORK/t1" NOT_LANDED)"
ck "T1 skipped" "EP-6(epic),EP-5(Canceled)" "$(val "$WORK/t1" SKIPPED)"
ck "T1 dry run" 1 "$(val "$WORK/t1" DRY_RUN)"
ck "T1 pushed nothing" "" "$(git -C "$ORIGIN" branch --list 'epic/*')"

# T2 — several epic/* branches and nothing else naming one: ASK=epic with the candidates.
g branch epic/ep-9 main
rc=$(run "$WORK/t2" --dry-run)
ck "T2 exit" 3 "$rc"
ck "T2 ask" epic "$(val "$WORK/t2" ASK)"
ck "T2 candidates" "epic/ep-1,epic/ep-9" "$(val "$WORK/t2" CANDIDATES)"
g branch -q -D epic/ep-9

# T3 — the argument wins, case-folded; a recorded recommendation for this epic supplies branch and base.
mkdir -p "$REPO/tmp"
printf '{"scope":"EP-1","branch":"epic/ep-1","base":"release","sessions":2}\n' > "$REPO/tmp/fleet-recommendation.json"
rc=$(run "$WORK/t3" --dry-run ep-1)
ck "T3 exit" 0 "$rc"
ck "T3 epic source" arg "$(val "$WORK/t3" EPIC_SOURCE)"
ck "T3 base recorded" release "$(val "$WORK/t3" BASE)"
ck "T3 base source" recommendation "$(val "$WORK/t3" BASE_SOURCE)"

# T4 — no argument: the recommendation's scope is read when the checkout is not on an epic/* branch.
rc=$(run "$WORK/t4" --dry-run)
ck "T4 epic source" recommendation "$(val "$WORK/t4" EPIC_SOURCE)"
# A recommendation for ANOTHER epic contributes neither branch nor base.
printf '{"scope":"EP-8","branch":"epic/ep-8","base":"release"}\n' > "$REPO/tmp/fleet-recommendation.json"
rc=$(run "$WORK/t4b" --dry-run EP-1)
ck "T4b base falls back past a foreign recommendation" main "$(val "$WORK/t4b" BASE)"
ck "T4b base source" checkout "$(val "$WORK/t4b" BASE_SOURCE)"
rm -f "$REPO/tmp/fleet-recommendation.json"

# T5 — the checkout on the integration branch itself: the epic comes from the branch; the base must be asked for.
g checkout -q epic/ep-1
rc=$(run "$WORK/t5" --dry-run)
ck "T5 exit" 3 "$rc"
ck "T5 epic source" branch "$(val "$WORK/t5" EPIC_SOURCE)"
ck "T5 ask" base "$(val "$WORK/t5" ASK)"
rc=$(run "$WORK/t5b" --dry-run --base release)
ck "T5b --base answers it" 0 "$rc"
ck "T5b base source" arg "$(val "$WORK/t5b" BASE_SOURCE)"
# start.wt-source-branch is read ahead of the checkout.
g config start.wt-source-branch release
rc=$(run "$WORK/t5c" --dry-run)
ck "T5c config base" release "$(val "$WORK/t5c" BASE)"
ck "T5c base source" config "$(val "$WORK/t5c" BASE_SOURCE)"
g config --unset start.wt-source-branch
g checkout -q main

# T6 — the real run: pushes the branch, creates the PR with the landed ids in order, bare; a second run finds it.
rc=$(run "$WORK/t6" EP-1)
ck "T6 exit" 0 "$rc"
ck "T6 created" 1 "$(val "$WORK/t6" CREATED)"
ck "T6 number" 42 "$(val "$WORK/t6" PR_NUMBER)"
ck "T6 branch pushed" "  epic/ep-1" "$(git -C "$ORIGIN" branch --list 'epic/*')"
ck "T6 title lists landed ids in order" "epic/ep-1: EP-3, EP-2" "$(cat "$WORK/pr-title.txt")"
ck_has "T6 body names EP-3 with its title" "- EP-3: first card" "$WORK/pr-body.md"
ck_has "T6 body names EP-2" "- EP-2: second card" "$WORK/pr-body.md"
ck_lacks "T6 body omits the unlanded member" "EP-4" "$WORK/pr-body.md"
ck_lacks "T6 body omits the canceled member" "EP-5" "$WORK/pr-body.md"
ck "T6 checkout untouched" main "$(g branch --show-current)"
rc=$(run "$WORK/t6b" EP-1)
ck "T6b second run finds the PR" 0 "$(val "$WORK/t6b" CREATED)"
ck "T6b same number" 42 "$(val "$WORK/t6b" PR_NUMBER)"

# T7 — a bad id and a missing branch are errors, not asks.
rc=$(run "$WORK/t7" --dry-run notanid)
ck "T7 bad id" 1 "$rc"
rc=$(run "$WORK/t7b" --dry-run EP-8)
ck "T7b no branch for the epic" 1 "$rc"
ck_has "T7b names the remedy" "/epic-prep EP-8" "$WORK/t7b.err"

echo "epic-pr.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
