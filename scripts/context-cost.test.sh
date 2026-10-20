#!/usr/bin/env bash
# Regression suite for context-cost.sh: a fixture user tree and project tree with known byte sizes, so the always-on
# total, the per-sample rule matching (including the `**/`, root-only and `{a,b}` glob shapes) and the description sum
# are all asserted against arithmetic the test does itself. The real ~/.claude is never read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/context-cost.sh"
. "$HERE/../lib/lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck_has() { # ck_has <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; cat "$3"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; cat "$3"; else PASS=$((PASS+1)); fi
}
bytes() { wc -c < "$1" | tr -d ' '; }

U="$WORK/user"; P="$WORK/proj"
mkdir -p "$U/rules" "$U/skills/alpha" "$P/.claude/rules/nested" "$P/.claude/skills/beta"
printf 'user claude\n' > "$U/CLAUDE.md"
printf -- '---\npaths:\n  - "**/*"\n---\nevery file\n' > "$U/rules/comments.md"
printf -- '---\npaths:\n  - "**/*.{ts,tsx}"\n---\nts rule\n' > "$U/rules/typescript.md"
printf -- '---\nname: alpha\ndescription: Alpha skill desc\n---\nbody\n' > "$U/skills/alpha/SKILL.md"
printf 'project claude is longer\n' > "$P/CLAUDE.md"
printf 'always on, no frontmatter\n' > "$P/.claude/rules/planning.md"
printf -- '---\npaths:\n  - "__never-auto-inject__/**"\n---\nreference only\n' > "$P/.claude/rules/api-reference.md"
printf -- '---\npaths: ["apps/api/**/*.rb", "ops/**"]\n---\napi rule\n' > "$P/.claude/rules/api.md"
printf -- '---\npaths:\n  - "*.md"\n---\nroot markdown only\n' > "$P/.claude/rules/nested/root-md.md"
printf -- '---\nname: beta\ndescription: >\n  Beta\n  folded\nwhen_to_use: Use it\n---\nbody\n' > "$P/.claude/skills/beta/SKILL.md"

OUT="$WORK/out"
# The script's glob compiler is a hand-rolled scanner: a branch that stops advancing loops forever (the first draft did, on
# the `{ts` half of a comma-split brace glob), and this suite sits in `pnpm test`'s chain, so the run is bounded.
CLAUDE_USER_DIR="$U" run_bounded 30 "$SCRIPT" "$P" --paths "apps/api/app/models/user.rb,src/a.ts,src/b.tsx,README.md,doc/x.md,ops/stacks/a/index.ts" > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then FAIL=$((FAIL+1)); echo "FAIL: context-cost.sh overran its 30s bound (exit $rc)"; fi

always=$(( $(bytes "$U/CLAUDE.md") + $(bytes "$P/CLAUDE.md") + $(bytes "$P/.claude/rules/planning.md") ))
comments=$(bytes "$U/rules/comments.md"); ts=$(bytes "$U/rules/typescript.md"); api=$(bytes "$P/.claude/rules/api.md")
rootmd=$(bytes "$P/.claude/rules/nested/root-md.md")

ck_has "always-on total"            "  TOTAL" "$OUT"
ck_has "always-on lists planning"   "project rules/planning.md" "$OUT"
ck_lacks "reference rule not always-on in total section" "TOTAL (~$(( (always + $(bytes "$P/.claude/rules/api-reference.md")) / 4 ))" "$OUT"
ck_has "rb edit = always + comments + api" "apps/api/app/models/user.rb  = $(( always + comments + api ))" "$OUT"
ck_has "ts edit = always + comments + ts (brace glob)" "src/a.ts  = $(( always + comments + ts ))" "$OUT"
ck_has "tsx edit matches brace glob too" "src/b.tsx  = $(( always + comments + ts ))" "$OUT"
ck_has "root README matches *.md"   "README.md  = $(( always + comments + rootmd ))" "$OUT"
ck_has "nested doc does not match *.md" "doc/x.md  = $(( always + comments ))" "$OUT"
ck_has "ops path matches ops/**"    "ops/stacks/a/index.ts  = $(( always + comments + ts + api ))" "$OUT"
ck_lacks "never-inject rule never matches" "api-reference.md" "$OUT"
ck_has "description sum (folded + when_to_use)" "user 1 skills 16 chars; project 1 skills 18 chars; total 34 chars" "$OUT"

echo "context-cost.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
