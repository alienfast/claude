#!/usr/bin/env bash
# Functional suite for sweep-scan.sh --check-current — the /test-sweep currency check. Drives the real script against a fixture git
# repo: which of a proposal's free-text target tokens join the watched files, and which inputs must read STALE rather than CURRENT
# because there was nothing to check.
#
# GROW THIS SUITE, NEVER PRUNE IT. A hole found in the currency check belongs below as a case, added WITH the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/sweep-scan.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null 2>&1 || { echo "sweep-scan.test: jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "sweep-scan.test: git is required" >&2; exit 2; }

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}
ckrc() { # ckrc <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (exit want $2, got $3)"; fi
}

R="$ROOT/repo"
mkdir -p "$R/apps/api/spec/policies" "$R/apps/api/spec/requests" "$R/apps/api/db" "$R/apps/app"
git -C "$R" init -q
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
echo a > "$R/apps/api/spec/policies/x_spec.rb"
echo a > "$R/apps/api/spec/requests/x_spec.rb"
echo a > "$R/apps/api/db/schema.rb"
echo a > "$R/apps/app/Foo.stories.tsx"
echo a > "$R/README.md"
mkdir -p "$R/tools" "$R/apps/api/tools" "$R/apps/app/src/app/(authenticated)/admin/kyc/[id]/_components"
echo a > "$R/tools/both.rb"
echo a > "$R/apps/api/tools/both.rb"
echo a > "$R/apps/app/src/app/(authenticated)/admin/kyc/[id]/_components/X.stories.tsx"
git -C "$R" add -A
git -C "$R" commit -q -m base
SHA=$(git -C "$R" rev-parse --short=10 HEAD)

out=""; rc=0
check() { out=$(bash "$SCRIPT" --repo "$R" --check-current "$1" 2>&1); rc=$?; }  # check <proposal file>

# mk <slug> <target> [candidate files json] — a proposal measured at the base commit
mk() {
  jq -n --arg slug "$1" --arg sha "$SHA" --arg target "$2" --argjson files "${3-[\"apps/api/spec/requests/x_spec.rb\"]}" \
    '{slug: $slug, sha: $sha, target: $target, candidate_files: $files}' > "$ROOT/$1.json"
}
touch_commit() { # touch_commit <path> — a commit that changes one tracked file
  echo "$RANDOM" >> "$R/$1"
  git -C "$R" add -A
  git -C "$R" commit -q -m "touch $1"
}

echo "== target shapes that must read CURRENT while nothing changed =="
mk api-relative 'spec/policies/x_spec.rb: allows a superuser'
check "$ROOT/api-relative.json"; ckrc "an api-relative path with a description is current" 0 "$rc"; ck "named" 'CURRENT api-relative' "$out"
mk schema 'db/schema.rb'
check "$ROOT/schema.json"; ckrc "db/schema.rb under the api dir is current" 0 "$rc"
mk future 'spec/policies/new_spec.rb'
check "$ROOT/future.json"; ckrc "a survivor that does not exist yet is current, not stale" 0 "$rc"
mk bare 'the shared dialog behavior file'
check "$ROOT/bare.json"; ckrc "a description with no path is current" 0 "$rc"
mk export 'apps/app/Foo.stories.tsx#Granted'
check "$ROOT/export.json"; ckrc "a path with an export suffix is current" 0 "$rc"
mk bare-export 'Foo.stories.tsx#Granted'
check "$ROOT/bare-export.json"; ckrc "an export suffix on a name no path resolves is current" 0 "$rc"
mk notarget ''
check "$ROOT/notarget.json"; ckrc "an empty target leaves currency to the candidate files" 0 "$rc"
mk nm-period 'see spec/policies/x_spec.rb.'
mk nm-line 'spec/policies/x_spec.rb:14'
mk nm-line-col 'spec/policies/x_spec.rb:14:3'
mk nm-wrapped 'see (spec/policies/x_spec.rb:14).'
mk nm-id 'spec/policies/x_spec.rb[1:2]'
mk nm-bare-line ':14'
mk nm-dots '...'
mk nm-range 'spec/policies/x_spec.rb:14-20'
mk nm-list 'spec/policies/x_spec.rb:14,20'
mk nm-brackets '[spec/policies/x_spec.rb]'
mk nm-bold '**spec/policies/x_spec.rb**'
mk nm-question 'spec/policies/x_spec.rb?'
mk nm-possessive "spec/policies/x_spec.rb's"
mk nm-const 'spec/policies/x_spec.rb::Foo'
mk nm-angle 'spec/policies/x_spec.rb>'
mk nm-extless 'db/schema'
mk nm-extonly '.rb'
mk nm-two-first 'spec/policies/nope_spec.rb,spec/policies/x_spec.rb'
mk nm-two-last 'spec/policies/x_spec.rb:spec/policies/nope_spec.rb'
mk nm-both 'tools/both.rb'
mk nm-routegroup 'apps/app/src/app/(authenticated)/admin/kyc/[id]/_components/X.stories.tsx#Granted'
mk nm-url 'https://example.com/foo.html'
mk nm-parent '../outside/foo.rb'
NM_SHAPES="nm-range nm-list nm-brackets nm-bold nm-question nm-possessive nm-const nm-angle"
for s in nm-period nm-line nm-line-col nm-wrapped nm-id nm-bare-line nm-dots $NM_SHAPES nm-extless nm-extonly nm-two-first nm-two-last nm-both nm-routegroup nm-url nm-parent; do
  check "$ROOT/$s.json"; ckrc "$s is current while nothing changed" 0 "$rc"; ck "$s named" "CURRENT $s" "$out"
done

echo "== a commit to a candidate file or a resolved target makes the proposal stale =="
touch_commit apps/api/spec/policies/x_spec.rb
check "$ROOT/api-relative.json"; ckrc "the api-relative target changed" 1 "$rc"; ck "names the file" 'STALE api-relative apps/api/spec/policies/x_spec.rb changed' "$out"
check "$ROOT/future.json"; ckrc "a not-yet-existing survivor stays current when its neighbours change" 0 "$rc"
for s in nm-period nm-line nm-line-col nm-wrapped nm-id $NM_SHAPES nm-two-first nm-two-last; do
  check "$ROOT/$s.json"; ckrc "$s: a near-miss spelling of the changed target is stale, not dropped" 1 "$rc"
  ck "$s names the file" "STALE $s apps/api/spec/policies/x_spec.rb changed since" "$out"
done
check "$ROOT/nm-bare-line.json"; ckrc "a bare :line token resolves nothing and stays current" 0 "$rc"
check "$ROOT/nm-dots.json"; ckrc "a punctuation-only token resolves nothing and stays current" 0 "$rc"
check "$ROOT/nm-extonly.json"; ckrc "an extension-only token resolves nothing and stays current" 0 "$rc"
touch_commit apps/api/db/schema.rb
check "$ROOT/nm-extless.json"; ckrc "an extensionless token is not a file shape and does not watch schema.rb" 0 "$rc"
touch_commit apps/api/tools/both.rb
check "$ROOT/nm-both.json"; ckrc "a path under both the repo root and the api dir resolves to the repo root: the api copy changing is not watched" 0 "$rc"
touch_commit tools/both.rb
check "$ROOT/nm-both.json"; ckrc "the repo-root copy changing stales it" 1 "$rc"; ck "names the root copy" 'STALE nm-both tools/both.rb changed since' "$out"
check "$ROOT/schema.json"; ckrc "db/schema.rb changed" 1 "$rc"
touch_commit 'apps/app/src/app/(authenticated)/admin/kyc/[id]/_components/X.stories.tsx'
check "$ROOT/nm-routegroup.json"; ckrc "a route-group and dynamic-segment path is watched whole" 1 "$rc"; ck "names the bracketed file" 'STALE nm-routegroup apps/app/src/app/(authenticated)/admin/kyc/[id]/_components/X.stories.tsx changed since' "$out"
check "$ROOT/nm-url.json"; ckrc "a URL fragment git would place outside the repository is skipped, not stale" 0 "$rc"
check "$ROOT/nm-parent.json"; ckrc "a ../-led fragment is skipped, not stale" 0 "$rc"
touch_commit apps/app/Foo.stories.tsx
check "$ROOT/export.json"; ckrc "the file behind an export suffix changed" 1 "$rc"
check "$ROOT/bare-export.json"; ckrc "an unresolved export-suffixed name does not go stale on someone else's file" 0 "$rc"
touch_commit apps/api/spec/requests/x_spec.rb
check "$ROOT/future.json"; ckrc "a candidate file changed" 1 "$rc"
check "$ROOT/bare.json"; ckrc "a description-only target goes stale on the candidate file" 1 "$rc"
check "$ROOT/notarget.json"; ckrc "an empty target goes stale on the candidate file" 1 "$rc"

echo "== a glob in a target is a literal, never expanded against the cwd =="
BASE_SHA=$SHA
SHA=$(git -C "$R" rev-parse --short=10 HEAD)
mk glob '*.md' '["apps/api/db/schema.rb"]'
out=$(cd "$R" && bash "$SCRIPT" --repo "$R" --check-current "$ROOT/glob.json" 2>&1); rc=$?
ckrc "a glob token is current while the candidate is untouched" 0 "$rc"
ck "no match is a skipped token" 'CURRENT glob' "$out"
touch_commit README.md
out=$(cd "$R" && bash "$SCRIPT" --repo "$R" --check-current "$ROOT/glob.json" 2>&1); rc=$?
ckrc "a file the glob would have expanded to does not stale the proposal" 0 "$rc"

echo "== inputs with no data to check read STALE =="
printf '{not json' > "$ROOT/bad.json"
check "$ROOT/bad.json"; ckrc "a non-JSON proposal is stale" 1 "$rc"; ck "says no sha" 'no sha recorded' "$out"
check "$ROOT/no-such.json"; ckrc "a missing file is stale" 1 "$rc"; ck "says no proposal file" 'no proposal file' "$out"
jq 'del(.sha)' "$ROOT/notarget.json" > "$ROOT/nosha.json"
check "$ROOT/nosha.json"; ckrc "no sha is stale" 1 "$rc"
jq '.sha = "0000000000"' "$ROOT/notarget.json" > "$ROOT/badsha.json"
check "$ROOT/badsha.json"; ckrc "a sha outside the repository is stale" 1 "$rc"; ck "says so" 'is not in this repository' "$out"
mk nofiles 'the shared dialog behavior file' '[]'
check "$ROOT/nofiles.json"; ckrc "no candidate files and no resolvable target is stale" 1 "$rc"; ck "says so" 'no candidate files recorded' "$out"
printf 'not an index' > "$ROOT/badindex"
mk gitfail 'spec/policies/x_spec.rb' '["apps/api/db/schema.rb"]'
out=$(GIT_INDEX_FILE="$ROOT/badindex" bash "$SCRIPT" --repo "$R" --check-current "$ROOT/gitfail.json" 2>&1); rc=$?
ckrc "a git failure while resolving a target is stale, not a skipped token" 1 "$rc"; ck "says so" 'STALE gitfail git ls-files failed resolving' "$out"
SHA=$BASE_SHA
mk nofiles-resolved 'spec/policies/x_spec.rb' '[]'
check "$ROOT/nofiles-resolved.json"; ckrc "a resolved target alone is enough to watch" 1 "$rc"; ck "stale because the target changed" 'changed since' "$out"

echo "== the agent invocation carries the read-only flags =="
# Measured 2026-10-05: without --restricted a headless scan agent inherited the keeper's user-level allow rules (rm, mv, cp, tee,
# pnpm, bundle exec rspec, linear-cli), each prompt-free under dontAsk, and a `mv` ran with no denial. The flags are pinned where
# they are passed: a stub `claude` records its argv while the real script builds one rspec group from a one-row timings ledger.
STUBDIR="$ROOT/stub"; mkdir -p "$STUBDIR"
ARGV="$ROOT/claude.argv"
cat > "$STUBDIR/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SWEEP_TEST_ARGV"
printf '{"structured_output":{"sha":"abcdef0123","candidates":[]},"total_cost_usd":0,"is_error":false}'
STUB
chmod +x "$STUBDIR/claude"
printf 'spec/requests/x_spec.rb\t1.5\n' > "$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/rspec-file-times.tsv"
SCANOUT="$ROOT/scanout"
out=$(PATH="$STUBDIR:$PATH" SWEEP_TEST_ARGV="$ARGV" bash "$SCRIPT" --repo "$R" --out "$SCANOUT" --suite rspec --max-groups 1 2>&1); rc=$?
ckrc "the scan ran one group to completion" 0 "$rc"
ck "one candidate, one group" 'CANDIDATES 1 current=0 to-scan=1 groups=1' "$out"
if [ -f "$ARGV" ]; then
  argline() { grep -qFx -- "$1" "$ARGV" && echo present || echo absent; }
  ck "--restricted is passed" present "$(argline --restricted)"
  ck "--strict-mcp-config is passed" present "$(argline --strict-mcp-config)"
  ck "--permission-mode dontAsk is passed" present "$(argline dontAsk)"
  ck "--disallowedTools is passed" present "$(argline --disallowedTools)"
  for d in 'Bash(rm:*)' 'Bash(mv:*)' 'Bash(tee:*)' 'Bash(pnpm:*)' 'Bash(bundle exec:*)' 'Bash(./tools/ci:*)' 'Bash(git stash:*)' 'Bash(git restore:*)' 'Bash(git checkout:*)'; do
    ck "denied: $d" present "$(argline "$d")"
  done
  ck "--add-dir names the out dir" "$(cd "$SCANOUT" && pwd)" "$(grep -A1 -Fx -- '--add-dir' "$ARGV" | tail -n 1)"
else
  fail=$((fail+1)); echo "  FAIL  the stub claude was never invoked"; echo "$out"
fi

echo
echo "sweep-scan: $pass passed, $fail failed"
[ "$fail" = 0 ]
