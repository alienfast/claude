#!/usr/bin/env bash
# Functional suite for clone-census.sh — the /test-sweep clone-pair candidate source. Drives the real script against a fixture
# checkout with a stub jscpd that records its argv and returns a canned report: which pairs qualify, how a file pair's blocks fold,
# the per-suite ranking and cap, how the project's config and baseline reach jscpd, and what happens with no jscpd at all. Set
# CLONE_CENSUS_JSCPD=<path to a real jscpd 5> to also run the planted-copy case against the real binary.
#
# GROW THIS SUITE, NEVER PRUNE IT. A hole found in the census belongs below as a case, added WITH the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/clone-census.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null 2>&1 || { echo "clone-census.test: jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "clone-census.test: git is required" >&2; exit 2; }

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}
ckno() { # ckno <label> <unexpected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then fail=$((fail+1)); echo "  FAIL  $1"; echo "        must not contain: $2"; echo "        got    $3"
  else pass=$((pass+1)); echo "  PASS  $1"; fi
}
ckrc() { # ckrc <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (exit want $2, got $3)"; fi
}

R="$ROOT/repo"
mkdir -p "$R/apps/api/spec" "$R/apps/app" "$R/packages/e2e/tests"
git -C "$R" init -q
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
for f in apps/api/spec/a_spec.rb apps/api/spec/b_spec.rb apps/app/Foo.stories.tsx apps/app/Foo.behavior.stories.tsx \
  apps/app/Foo.stories.shared.tsx apps/app/prod.ts packages/e2e/tests/a.spec.ts packages/e2e/tests/b.spec.ts packages/e2e/tests/c.spec.ts; do
  echo a > "$R/$f"
done
git -C "$R" add -A
git -C "$R" commit -q -m base

# The stub stands in for jscpd 5.4.1: it answers --version, records its argv, and copies the prepared report into --output.
STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/jscpd" <<'STUBSCRIPT'
#!/usr/bin/env bash
[ "${1-}" = --version ] && { echo "jscpd ${CLONE_TEST_VERSION:-5.4.1}"; exit 0; }
[ -z "${CLONE_TEST_ARGV:-}" ] || printf '%s\n' "$@" > "$CLONE_TEST_ARGV"
out=""
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="${2-}"; shift; done
[ -z "${CLONE_TEST_REPORT:-}" ] && { echo "stub: no report to write" >&2; exit 1; }
cp "$CLONE_TEST_REPORT" "$out/jscpd-report.json"
STUBSCRIPT
chmod +x "$STUB/jscpd"

dup() { # dup <fileA> <fileB> <lines> [isNew] [startA] — one jscpd duplicate record
  jq -n --arg a "$1" --arg b "$2" --argjson l "$3" --argjson new "${4:-false}" --argjson sa "${5:-1}" \
    '{format: "x", kind: "exact", lines: $l, tokens: ($l * 10), isNew: $new,
      firstFile: {name: $a, start: $sa, end: ($sa + $l - 1)}, secondFile: {name: $b, start: 5, end: (4 + $l)}}'
}
{
  dup apps/api/spec/a_spec.rb apps/api/spec/b_spec.rb 20
  dup apps/api/spec/b_spec.rb apps/api/spec/a_spec.rb 12                     # the same pair, files in the other order
  dup apps/app/Foo.stories.tsx apps/app/Foo.behavior.stories.tsx 11
  dup ./apps/app/Foo.stories.tsx ./apps/app/Foo.stories.shared.tsx 10      # a ./ prefix is stripped
  dup apps/app/Foo.stories.tsx apps/app/Foo.stories.tsx 10 false 30         # same file: the matrix idiom
  dup apps/app/Foo.stories.tsx apps/app/prod.ts 10                          # a story cloning production code
  dup packages/e2e/tests/a.spec.ts packages/e2e/tests/b.spec.ts 15
  dup packages/e2e/tests/a.spec.ts packages/e2e/tests/c.spec.ts 30 true     # not in the baseline: the gate's red
  dup packages/e2e/tests/b.spec.ts packages/e2e/tests/c.spec.ts 13
} | jq -s '{duplicates: ., statistics: {total: {clones: length}}}' > "$ROOT/report.json"

out=""; rc=0
ARGV="$ROOT/jscpd.argv"
census() { # census <args...> — the stub on PATH, the prepared report, argv recorded
  rm -f "$ARGV"
  out=$(PATH="$STUB:$PATH" CLONE_TEST_REPORT="$ROOT/report.json" CLONE_TEST_ARGV="$ARGV" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" "$@" 2>&1); rc=$?
}
argline() { grep -qFx -- "$1" "$ARGV" && echo present || echo absent; }

echo "== which pairs qualify, and how a file pair folds =="
census
ckrc "the census runs" 0 "$rc"
ck "names the jscpd version and the defaults"   'JSCPD 5.4.1 config=defaults baseline=none seconds=' "$out"
ck "totals: jscpd pairs, then candidates"       'CLONES total=9 cross-file=8 test-pairs=7 new=1 file-pairs=5 rspec=1 storybook=2 e2e=2' "$out"
ck "two blocks fold into one rspec pair"        'CLONE rspec 32 2 apps/api/spec/a_spec.rb apps/api/spec/b_spec.rb' "$out"
ck "the first block keeps its ranges"           'CLONE-BLOCK apps/api/spec/a_spec.rb:1-20 apps/api/spec/b_spec.rb:5-24 20' "$out"
ck "the reversed block is put in name order"    'CLONE-BLOCK apps/api/spec/a_spec.rb:5-16 apps/api/spec/b_spec.rb:1-12 12' "$out"
ck "a behavior file pairs with its story file"  'CLONE storybook 11 1 apps/app/Foo.behavior.stories.tsx apps/app/Foo.stories.tsx' "$out"
ck "a shared module counts as a story file"     'CLONE storybook 10 1 apps/app/Foo.stories.shared.tsx apps/app/Foo.stories.tsx' "$out"
ckno "the ./ prefix is gone"                    './apps' "$out"
ckno "a same-file clone is not a candidate"     'apps/app/Foo.stories.tsx apps/app/Foo.stories.tsx' "$out"
ckno "a story and a production file are not"    'prod.ts' "$out"
ck "e2e specs pair"                             'CLONE e2e 15 1 packages/e2e/tests/a.spec.ts packages/e2e/tests/b.spec.ts' "$out"
ck "and the smaller e2e pair follows"           'CLONE e2e 13 1 packages/e2e/tests/b.spec.ts packages/e2e/tests/c.spec.ts' "$out"
ckno "a pair the baseline lacks is not one"     'packages/e2e/tests/a.spec.ts packages/e2e/tests/c.spec.ts' "$out"
ck "a suite's pairs are ranked by lines"        'CLONE e2e 15' "$(printf '%s\n' "$out" | grep '^CLONE e2e' | head -n 1)"
ck "the rspec pair carries two block rows"      2 "$(printf '%s\n' "$out" | grep -c 'CLONE-BLOCK apps/api/spec')"
ck "the report is kept beside the census"       present "$([ -s "$ROOT/out/test-sweep-clone-report.json" ] && echo present || echo absent)"
ck "no scratch directory is left behind"        none "$(ls -d "$ROOT"/out/test-sweep-jscpd.* 2>/dev/null | head -n 1 | sed 's/.*/left/'; echo none)"
ck "defaults: the floor is passed"              present "$(argline --min-lines)"
ck "defaults: 10 lines"                         present "$(argline 10)"
ck "defaults: the three formats"                present "$(argline typescript,tsx,ruby)"
ck "defaults: the json reporter"                present "$(argline json)"
ck "defaults: no config"                        absent "$(argline --config)"
ck "defaults: no baseline"                      absent "$(argline --baseline)"

echo "== the cap and the floor =="
census --top 1
ckrc "--top 1 runs" 0 "$rc"
ck "one row per suite"                          3 "$(printf '%s\n' "$out" | grep -c '^CLONE ')"
ck "the e2e survivor is the longest"            'CLONE e2e 15 1' "$out"
ckno "the shorter e2e pair is cut"              'CLONE e2e 13' "$out"
ck "the totals still count every candidate"     'file-pairs=5' "$out"
census --top 0
ck "--top 0 prints every pair"                  5 "$(printf '%s\n' "$out" | grep -c '^CLONE ')"
census --min-lines 7
ck "--min-lines reaches jscpd without a config" present "$(argline 7)"
census --top x
ckrc "a non-integer --top is a usage error" 2 "$rc"
census --min-lines 0
ckrc "a zero floor is a usage error" 2 "$rc"
out=$(bash "$SCRIPT" 2>&1); rc=$?
ckrc "no --repo is a usage error" 2 "$rc"
out=$(bash "$SCRIPT" --repo "$ROOT" 2>&1); rc=$?
ckrc "a directory that is not a checkout is a usage error" 2 "$rc"

echo "== the project's config and baseline reach jscpd =="
printf '{"minLines": 10, "path": ["."], "pattern": "**/*.rb"}\n' > "$R/.jscpd.json"
printf '{"version": 1, "fingerprints": {"aaaa": 1}}\n' > "$R/.jscpd-baseline.json"
census
ckrc "runs with a config" 0 "$rc"
ck "names both files"                           'JSCPD 5.4.1 config=.jscpd.json baseline=.jscpd-baseline.json' "$out"
ck "--config is passed"                         present "$(argline --config)"
ck "with the config file"                       present "$(argline .jscpd.json)"
ck "--baseline is passed"                       present "$(argline --baseline)"
ck "with the baseline file"                     present "$(argline .jscpd-baseline.json)"
ck "the config's floor wins: no --min-lines"    absent "$(argline --min-lines)"
ck "and no default formats"                     absent "$(argline typescript,tsx,ruby)"
rm -f "$R/.jscpd-baseline.json"
census
ck "a config without a baseline"                'config=.jscpd.json baseline=none' "$out"
ck "passes no --baseline"                       absent "$(argline --baseline)"
rm -f "$R/.jscpd.json"

echo "== which jscpd runs =="
out=$(CLONE_TEST_REPORT="$ROOT/report.json" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" --jscpd "$STUB/jscpd" 2>&1); rc=$?
ckrc "--jscpd names the executable with nothing on PATH" 0 "$rc"
mkdir -p "$R/node_modules/.bin"
cp "$STUB/jscpd" "$R/node_modules/.bin/jscpd"
out=$(PATH="$STUB:$PATH" CLONE_TEST_REPORT="$ROOT/report.json" CLONE_TEST_VERSION=5.9.9 bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "the project's install runs" 0 "$rc"
ck "and its version is the one reported"        'JSCPD 5.9.9' "$out"
rm -rf "$R/node_modules"
NOJS="$ROOT/nojscpd"; mkdir -p "$NOJS"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOJS/jscpd"; cp "$NOJS/jscpd" "$NOJS/pnpm"; chmod +x "$NOJS/jscpd" "$NOJS/pnpm"
out=$(PATH="$NOJS:$PATH" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "no working jscpd and no pnpm is exit 1" 1 "$rc"
ck "with a NO-JSCPD line"                       'NO-JSCPD' "$out"
out=$(PATH="$STUB:$PATH" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "a jscpd that writes no report is an error exit" 2 "$rc"
ck "says so"                                    'wrote no report' "$out"
ck "and shows its last lines"                   'stub: no report to write' "$out"

echo "== empty and odd reports =="
printf '{"duplicates": [], "statistics": {}}' > "$ROOT/empty.json"
out=$(PATH="$STUB:$PATH" CLONE_TEST_REPORT="$ROOT/empty.json" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "no clones is still a census" 0 "$rc"
ck "with zero totals"                           'CLONES total=0 cross-file=0 test-pairs=0 new=0 file-pairs=0 rspec=0 storybook=0 e2e=0' "$out"
ckno "and no pair rows"                         'CLONE ' "$(printf '%s\n' "$out" | grep -v '^CLONES')"
printf '{"statistics": {}}' > "$ROOT/nodups.json"
out=$(PATH="$STUB:$PATH" CLONE_TEST_REPORT="$ROOT/nodups.json" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "a report with no duplicates key is empty, not an error" 0 "$rc"
ck "zero totals again"                          'CLONES total=0' "$out"
printf 'not json' > "$ROOT/notjson.json"
out=$(PATH="$STUB:$PATH" CLONE_TEST_REPORT="$ROOT/notjson.json" bash "$SCRIPT" --repo "$R" --out "$ROOT/out" 2>&1); rc=$?
ckrc "a report that is not JSON is an error exit" 2 "$rc"
ck "names the report"                           'is not a jscpd JSON report' "$out"

echo "== a real jscpd finds a planted copy =="
if [ -n "${CLONE_CENSUS_JSCPD:-}" ] && [ -x "$CLONE_CENSUS_JSCPD" ]; then
  RR="$ROOT/real"
  mkdir -p "$RR/apps/api/spec/a" "$RR/apps/api/spec/b" "$RR/apps/app"
  git -C "$RR" init -q
  for i in $(seq 1 14); do echo "    let(:thing_$i) { create(:thing, position: $i, label: 'row $i') }"; done > "$RR/apps/api/spec/a/one_spec.rb"
  cp "$RR/apps/api/spec/a/one_spec.rb" "$RR/apps/api/spec/b/two_spec.rb"
  for i in $(seq 1 14); do echo "export const Story$i = { args: { position: $i, label: 'row $i', open: true } }"; done > "$RR/apps/app/One.stories.tsx"
  cp "$RR/apps/app/One.stories.tsx" "$RR/apps/app/Two.stories.tsx"
  out=$(bash "$SCRIPT" --repo "$RR" --out "$ROOT/real-out" --jscpd "$CLONE_CENSUS_JSCPD" 2>&1); rc=$?
  ckrc "the real jscpd runs on the fixture" 0 "$rc"
  ck "the rspec copy is found"                  'CLONE rspec 14 1 apps/api/spec/a/one_spec.rb apps/api/spec/b/two_spec.rb' "$out"
  ck "the story copy is found"                  'CLONE storybook 14 1 apps/app/One.stories.tsx apps/app/Two.stories.tsx' "$out"
  ck "with line ranges"                         'CLONE-BLOCK apps/api/spec/a/one_spec.rb:1-14 apps/api/spec/b/two_spec.rb:1-14 14' "$out"
else
  echo "  SKIP  CLONE_CENSUS_JSCPD is not set to a jscpd executable"
fi

echo
echo "clone-census: $pass passed, $fail failed"
[ "$fail" = 0 ]
