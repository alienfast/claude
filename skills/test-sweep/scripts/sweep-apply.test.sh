#!/usr/bin/env bash
# Functional suite for sweep-apply.sh — the /test-sweep deletion gate. Drives the real script against fixture proposals and
# ledgers: the count arithmetic, the batch summing, and every gate that must refuse on missing or malformed evidence rather
# than pass because there was nothing to check.
#
# GROW THIS SUITE, NEVER PRUNE IT. A hole found in a gate belongs below as a case, added WITH the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/sweep-apply.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null 2>&1 || { echo "sweep-apply.test: jq is required" >&2; exit 2; }

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

out=""; rc=0
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

# mk <file> <slug> <examples_removed> <removed-json> [kind] [mechanical-json] [target] [mutation] — a well-formed proposal by default
mk() {
  jq -n --arg slug "$2" --argjson r "$3" --argjson n "$4" --arg kind "${5:-retire}" --argjson mech "${6:-true}" \
    --arg target "${7-spec/policies/x_spec.rb: allows a superuser}" --arg mut "${8-app/policies/x.rb: swap the superuser clause}" \
    '{slug: $slug, file: "spec/requests/x_spec.rb", suite: "rspec", kind: $kind, target: $target, evidence: "e", estimated_seconds: 1.5,
      examples_removed: $r, removed: $n, governing_rule: "g", mechanical: $mech, mutation: $mut, report: "r"}' > "$1"
}
ledger() { # ledger <file> <lines...>
  local f="$1"; shift
  : > "$f"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

D="$ROOT/p"; mkdir -p "$D"
mk "$D/a.json" a 3 '["a one","a two","a three"]'
mk "$D/b.json" b 5 '["b1","b2","b3","b4","b5"]'
ledger "$ROOT/ledger-ab.md" '- "a one" → spec/policies/x_spec.rb: allows a superuser' '- "a two" → spec/policies/x_spec.rb: allows a superuser' \
  '- "a three" -> spec/policies/x_spec.rb: allows a superuser' '* "b1" → s' '- "b2" → s' '- "b3" → s' '- "b4" → s' '- "b5" → s'

echo "== count gate: one proposal =="
run --proposal "$D/a.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "exact count passes" 0 "$rc"
ck "pass line"                                  'PASS count-gate expected=97 post=97' "$out"
ck "gates passed"                               'GATES-PASSED a' "$out"
ck "mutation step names the slug"               'STEP mutation a app/policies/x.rb: swap the superuser clause' "$out"
ck "broken-assertion step names the slug"       'STEP broken-assertion a spec/policies/x_spec.rb: allows a superuser' "$out"
run --proposal "$D/a.json" --baseline-count 100 --post-count 95 --ledger "$ROOT/ledger-ab.md"
ckrc "a second unplanned removal is refused" 1 "$rc"
ck "refused count"                              'REFUSED count-gate expected=97 (100 - 3 + 0) post=95' "$out"
ckno "no steps after a refusal"                 'STEP ' "$out"
run --proposal "$D/a.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a removal that did not happen is refused" 1 "$rc"
mk "$D/a-cons.json" a 3 '["a one","a two","a three"]' consolidate
run --proposal "$D/a-cons.json" --baseline-count 100 --post-count 98 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "a hoisted addition is part of the arithmetic" 0 "$rc"
run --proposal "$D/a-cons.json" --baseline-count 100 --post-count 99 --hoisted 1 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "repeated --hoisted values are summed" 0 "$rc"
mk "$D/a-hoist.json" a 3 '["a one","a two","a three"]' hoist-ddl
run --proposal "$D/a-hoist.json" --baseline-count 100 --post-count 98 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "a hoist-ddl batch may add an assertion back" 0 "$rc"
run --proposal "$D/a.json" --baseline-count 100 --post-count 98 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "--hoisted on a retire-only batch is refused" 1 "$rc"
ck "names the hoisted gate"                     'REFUSED hoisted-gate hoisted=1 exceeds consolidate/hoist-ddl removals=0' "$out"
ckno "no steps after the hoisted refusal"       'STEP ' "$out"
run --proposal "$D/a.json" --baseline-count 100 --post-count 97 --hoisted 0 --ledger "$ROOT/ledger-ab.md"
ckrc "an explicit --hoisted 0 needs no adding-back proposal" 0 "$rc"
run --proposal "$D/a-cons.json" --baseline-count 100 --post-count 100 --hoisted 3 --ledger "$ROOT/ledger-ab.md"
ckrc "hoisting exactly what the consolidate removed passes" 0 "$rc"
run --proposal "$D/a-cons.json" --baseline-count 100 --post-count 101 --hoisted 4 --ledger "$ROOT/ledger-ab.md"
ckrc "hoisting one more than the consolidate removed is refused" 1 "$rc"
ck "names both figures"                         'REFUSED hoisted-gate hoisted=4 exceeds consolidate/hoist-ddl removals=3' "$out"
ckno "no steps after the over-hoist refusal"    'STEP ' "$out"
mk "$D/cons-zero.json" cons-zero 0 '[]' consolidate true "" ""
run --proposal "$D/a.json" --proposal "$D/cons-zero.json" --baseline-count 100 --post-count 100 --hoisted 3 --ledger "$ROOT/ledger-ab.md"
ckrc "a retire plus a consolidate removing nothing cannot hoist" 1 "$rc"
ck "the removals it counts are 0"               'REFUSED hoisted-gate hoisted=3 exceeds consolidate/hoist-ddl removals=0' "$out"
mk "$D/cons2.json" cons2 2 '["b1","b2"]' consolidate
run --proposal "$D/a.json" --proposal "$D/cons2.json" --baseline-count 100 --post-count 98 --hoisted 3 --ledger "$ROOT/ledger-ab.md"
ckrc "a retire's removals do not count toward the hoist cap" 1 "$rc"
ck "only the consolidate's 2 count"             'REFUSED hoisted-gate hoisted=3 exceeds consolidate/hoist-ddl removals=2' "$out"
run --proposal "$D/a.json" --baseline-count 100 --post-count 98 --hoisted abc --ledger "$ROOT/ledger-ab.md"
ckrc "a malformed --hoisted is a usage error" 2 "$rc"
run --proposal "$ROOT/no-such.json" --baseline-count 100 --post-count 99 --hoisted 1
ckrc "--hoisted with no readable proposal is an error exit" 2 "$rc"
printf '{}' > "$D/obj-hoist.json"
run --proposal "$D/obj-hoist.json" --baseline-count 100 --post-count 101 --hoisted 1
ckrc "--hoisted with only a malformed proposal is refused" 1 "$rc"
ck "the hoisted gate refuses beside the shape gate" 'REFUSED hoisted-gate' "$out"
mk "$D/c-cons.json" c-cons 2 '["b1","b2"]' consolidate
run --proposal "$D/a.json" --proposal "$D/c-cons.json" --baseline-count 100 --post-count 96 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "one consolidate in a mixed batch satisfies the hoisted gate" 0 "$rc"
ck "mixed batch sums removals and the hoist"    'BATCH proposals=2 examples_removed=5 hoisted=1' "$out"
run --proposal "$D/a.json" --baseline-count 0100 --post-count 097 --ledger "$ROOT/ledger-ab.md"
ckrc "leading zeros are decimal, not octal" 0 "$rc"
run --proposal "$D/a.json" --baseline-count 09 --post-count 06 --ledger "$ROOT/ledger-ab.md"
ckrc "a leading-zero 09 does not abort the arithmetic" 0 "$rc"
run --proposal "$D/a.json" --baseline-count abc --post-count 97
ckrc "a non-integer count is a usage error" 2 "$rc"
run --proposal "$D/a.json" --baseline-count 100 --post-count -1
ckrc "a negative count is a usage error" 2 "$rc"
run --proposal "$D/a.json" --baseline-count 1000000000000000000 --post-count 1
ckrc "an out-of-range count is a usage error" 2 "$rc"
run --proposal "$D/a.json" --baseline-count 100
ckrc "a missing --post-count is a usage error" 2 "$rc"
run --baseline-count 100 --post-count 97
ckrc "no proposal is a usage error" 2 "$rc"
run --proposal "$D/a.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/no-such-ledger"
ckrc "a ledger path that does not exist is a usage error" 2 "$rc"
run --proposal "$D/a.json" --baseline-count
ckrc "a flag with no value is a usage error" 2 "$rc"
run --help
ckrc "--help exits 0" 0 "$rc"

echo "== count gate: a batch is gated once =="
run --proposal "$D/a.json" --baseline-count 22174 --post-count 22166 --ledger "$ROOT/ledger-ab.md"
ckrc "each proposal alone is refused against the batch post count" 1 "$rc"
ck "single proposal expects 22171"              'REFUSED count-gate expected=22171' "$out"
run --proposal "$D/a.json" --proposal "$D/b.json" --baseline-count 22174 --post-count 22166 --ledger "$ROOT/ledger-ab.md"
ckrc "the batch passes on the summed removal" 0 "$rc"
ck "batch line sums removals"                   'BATCH proposals=2 examples_removed=8 hoisted=0' "$out"
ck "batch count gate"                           'PASS count-gate expected=22166 post=22166' "$out"
ck "both proposals pass"                        'GATES-PASSED b' "$out"
run --proposal "$D/a.json" --proposal "$D/a.json" --baseline-count 22174 --post-count 22171 --ledger "$ROOT/ledger-ab.md"
ckrc "a proposal named twice is refused, not double counted" 1 "$rc"
ck "duplicate named"                            'REFUSED proposal-shape a: listed twice' "$out"
run --proposals-dir "$D" --baseline-count 1 --post-count 1
ckrc "--proposals-dir no longer exists" 2 "$rc"

echo "== ledger gate =="
mk "$D/zero-names.json" zero-names 3 '[]'
run --proposal "$D/zero-names.json" --baseline-count 100 --post-count 97
ckrc "examples_removed 3 with removed [] and no ledger is refused" 1 "$rc"
ck "names the empty list"                       'REFUSED ledger-gate zero-names: removes 3 but its removed list is empty' "$out"
ck "no PASS ledger line beside a ledger refusal" 'REFUSED ledger-gate' "$out"
ckno "no false PASS ledger-gate"                'PASS ledger-gate' "$out"
run --proposal "$D/zero-names.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "removed [] is refused even with a ledger" 1 "$rc"
mk "$D/short.json" short 3 '["a one","a two"]'
run --proposal "$D/short.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "fewer names than examples_removed is refused" 1 "$rc"
ck "names the shortfall"                        'removed lists 2 names for 3 removals' "$out"
mk "$D/empty-name.json" empty-name 1 '[""]'
run --proposal "$D/empty-name.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "an empty name is refused" 1 "$rc"
ck "names the empty name"                       'holds 1 empty name(s)' "$out"
mk "$D/blank-name.json" blank-name 1 '["   "]'
run --proposal "$D/blank-name.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a whitespace-only name is refused" 1 "$rc"
mk "$D/multi-name.json" multi-name 1 '["two\nlines"]'
run --proposal "$D/multi-name.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a multi-line name is refused" 1 "$rc"
mk "$D/sub.json" sub 1 '["allows a superuser"]'
ledger "$ROOT/ledger-sub.md" '- "allows a superuser holding no TenantAccess anywhere" → spec/policies/x_spec.rb: that example'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-sub.md"
ckrc "a name that is only a substring of a ledger entry is refused" 1 "$rc"
ck "names what is missing"                      'missing="allows a superuser"' "$out"
ledger "$ROOT/ledger-exact.md" '- "allows a superuser holding no TenantAccess anywhere" → s' '- "allows a superuser" → spec/policies/x_spec.rb: that example'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-exact.md"
ckrc "an exact quoted name passes" 0 "$rc"
ck "ledger pass counts names"                   'PASS ledger-gate names=1' "$out"
ledger "$ROOT/ledger-prefix.md" '- "allows a superuser holding no TenantAccess anywhere" → s' '- "super" → s'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-prefix.md"
ckrc "a name that is a prefix of another is not covered by it" 1 "$rc"
ledger "$ROOT/ledger-bare.md" 'allows a superuser'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-bare.md"
ckrc "a bare mention outside a ledger entry does not count" 1 "$rc"
ledger "$ROOT/ledger-nosurv.md" '- "allows a superuser" →'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-nosurv.md"
ckrc "an entry with no survivor does not count" 1 "$rc"
ledger "$ROOT/ledger-noquote.md" '- allows a superuser → spec/x_spec.rb'
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-noquote.md"
ckrc "an unquoted entry does not count" 1 "$rc"
: > "$ROOT/ledger-empty.md"
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-empty.md"
ckrc "an empty ledger file covers nothing" 1 "$rc"
run --proposal "$D/sub.json" --baseline-count 100 --post-count 99
ckrc "a removal with no --ledger is refused" 1 "$rc"
ck "names the missing flag"                     'REFUSED ledger-gate missing --ledger' "$out"
mk "$D/quoted.json" quoted 1 '["says \"hi\" to the user"]'
ledger "$ROOT/ledger-quoted.md" '- "says "hi" to the user" → spec/x_spec.rb: greeting'
run --proposal "$D/quoted.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-quoted.md"
ckrc "a name containing double quotes matches its entry" 0 "$rc"
mk "$D/regexy.json" regexy 1 '["a.c [x] (y) * +"]'
ledger "$ROOT/ledger-regexy.md" '- "abc" → s'
run --proposal "$D/regexy.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-regexy.md"
ckrc "regex metacharacters in a name are matched literally" 1 "$rc"
ledger "$ROOT/ledger-regexy2.md" '- "a.c [x] (y) * +" → s'
run --proposal "$D/regexy.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-regexy2.md"
ckrc "a name full of metacharacters passes on its exact entry" 0 "$rc"
mk "$D/dash.json" dash 1 '["-leading dash"]'
ledger "$ROOT/ledger-dash.md" '- "-leading dash" → s'
run --proposal "$D/dash.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-dash.md"
ckrc "a name that starts with a dash is not read as a grep option" 0 "$rc"
mk "$D/names-no-count.json" names-no-count 0 '["listed but not counted"]' detag true "" ""
run --proposal "$D/names-no-count.json" --baseline-count 100 --post-count 100
ckrc "names listed with examples_removed 0 still need the ledger" 1 "$rc"
mk "$D/mixed.json" mixed 1 '["a one"]'
run --proposal "$D/mixed.json" --proposal "$D/sub.json" --baseline-count 100 --post-count 98 --ledger "$ROOT/ledger-sub.md"
ckrc "one covered and one uncovered name refuses the batch" 1 "$rc"
ck "only the uncovered name is listed"          'missing="a one" "allows a superuser"' "$out"

echo "== proposal gates =="
mk "$D/judg.json" judg 1 '["a one"]' retire false
run --proposal "$D/judg.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "mechanical false is refused" 1 "$rc"
ck "names the gate"                             'REFUSED mechanical-gate judg' "$out"
ckno "no steps for a judgment item"             'STEP ' "$out"
mk "$D/mechstr.json" mechstr 1 '["a one"]' retire '"true"'
run --proposal "$D/mechstr.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "mechanical as the string true is refused" 1 "$rc"
ck "names the field"                            'REFUSED proposal-shape mechstr: missing or wrong-typed field(s): mechanical' "$out"
jq 'del(.mechanical)' "$D/a.json" > "$D/nomech.json"
jq '.slug = "nomech"' "$D/nomech.json" > "$D/nomech2.json"
run --proposal "$D/nomech2.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "a proposal with no mechanical field is refused" 1 "$rc"
ck "no mechanical=null pass"                    'field(s): mechanical' "$out"
jq '. + {placeholder: true}' "$D/a.json" | jq '.slug = "ph"' > "$D/ph.json"
run --proposal "$D/ph.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "a dry-run placeholder is refused" 1 "$rc"
ck "names the placeholder gate"                 'REFUSED placeholder-gate ph' "$out"
mk "$D/keep.json" keepme 0 '[]' keep true "" ""
run --proposal "$D/keep.json" --baseline-count 100 --post-count 100
ckrc "a keep proposal is refused" 1 "$rc"
ck "names the kind gate"                        'REFUSED kind-gate keepme' "$out"
mk "$D/notarget.json" notarget 1 '["a one"]' retire true ""
run --proposal "$D/notarget.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "an empty target with removals is refused" 1 "$rc"
ck "names the target gate"                      'REFUSED target-gate notarget' "$out"
mk "$D/wstarget.json" wstarget 1 '["a one"]' retire true "   "
run --proposal "$D/wstarget.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a whitespace target is refused" 1 "$rc"
mk "$D/nomut.json" nomut 1 '["a one"]' retire true "spec/x_spec.rb: s" ""
run --proposal "$D/nomut.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "an empty mutation with removals is refused" 1 "$rc"
ck "names the mutation gate"                    'REFUSED mutation-gate nomut' "$out"
mk "$D/hoist-empty.json" hoist-empty 2 '["a one","a two"]' hoist-ddl true "" ""
run --proposal "$D/hoist-empty.json" --baseline-count 100 --post-count 99 --hoisted 1 --ledger "$ROOT/ledger-ab.md"
ckrc "a hoist-ddl removing 2 with no target and no mutation is refused" 1 "$rc"
ck "both gates named"                           'REFUSED mutation-gate hoist-empty' "$out"
ck "warns when the hoisted count is missing"    'WARN hoist-ddl with --hoisted 0' "$(bash "$SCRIPT" --proposal "$D/hoist-empty.json" --baseline-count 100 --post-count 98 --ledger "$ROOT/ledger-ab.md" 2>&1)"
mk "$D/detag.json" detag-ok 0 '[]' detag true "" ""
run --proposal "$D/detag.json" --baseline-count 100 --post-count 100
ckrc "a detag removing nothing needs no target, mutation or ledger" 0 "$rc"
ck "detag passes"                               'GATES-PASSED detag-ok' "$out"
ck "detag with nothing removed passes the ledger" 'PASS ledger-gate names=0' "$out"
ckno "detag prints no steps"                    'STEP ' "$out"

echo "== malformed proposals =="
printf '{not json' > "$D/bad.json"
run --proposal "$D/bad.json" --baseline-count 1 --post-count 1
ckrc "invalid JSON is an error exit" 2 "$rc"
ck "says so"                                    'not valid JSON' "$out"
: > "$D/zero-byte.json"
run --proposal "$D/zero-byte.json" --baseline-count 1 --post-count 1
ckrc "an empty file is an error exit" 2 "$rc"
run --proposal "$D/no-such.json" --baseline-count 1 --post-count 1
ckrc "a missing file is an error exit" 2 "$rc"
printf '[]' > "$D/array.json"
run --proposal "$D/array.json" --baseline-count 1 --post-count 1
ckrc "a JSON array is refused" 1 "$rc"
ck "array names every field"                    'REFUSED proposal-shape' "$out"
printf 'null' > "$D/null.json"
run --proposal "$D/null.json" --baseline-count 1 --post-count 1
ckrc "JSON null is refused" 1 "$rc"
printf '{}' > "$D/obj.json"
run --proposal "$D/obj.json" --baseline-count 1 --post-count 1
ckrc "an empty object is refused" 1 "$rc"
jq -c '.' "$D/a.json" "$D/b.json" > "$D/two.json"
run --proposal "$D/two.json" --baseline-count 1 --post-count 1
ckrc "two JSON values in one file are refused" 1 "$rc"
ck "says so"                                    'holds more than one JSON value' "$out"
mk "$D/removed-str.json" removed-str 1 '"a one"'
run --proposal "$D/removed-str.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "removed as a string is refused" 1 "$rc"
ck "names removed"                              'field(s): removed' "$out"
mk "$D/removed-null.json" removed-null 1 '[null]'
run --proposal "$D/removed-null.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a null element in removed is refused" 1 "$rc"
mk "$D/removed-num.json" removed-num 1 '[3]'
run --proposal "$D/removed-num.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "a number in removed is refused" 1 "$rc"
mk "$D/neg.json" neg -1 '[]'
run --proposal "$D/neg.json" --baseline-count 100 --post-count 101
ckrc "a negative examples_removed is refused" 1 "$rc"
mk "$D/frac.json" frac 2.5 '[]'
run --proposal "$D/frac.json" --baseline-count 100 --post-count 98
ckrc "a fractional examples_removed is refused" 1 "$rc"
mk "$D/strnum.json" strnum '"3"' '["a one","a two","a three"]'
run --proposal "$D/strnum.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "examples_removed as a string is refused" 1 "$rc"
mk "$D/nullnum.json" nullnum null '[]'
run --proposal "$D/nullnum.json" --baseline-count 100 --post-count 100
ckrc "a null examples_removed is refused" 1 "$rc"
mk "$D/badkind.json" badkind 1 '["a one"]' delete
run --proposal "$D/badkind.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "an unknown kind is refused" 1 "$rc"
jq '.target = 5' "$D/a.json" | jq '.slug = "numtarget"' > "$D/numtarget.json"
run --proposal "$D/numtarget.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "a non-string target is refused" 1 "$rc"
jq 'del(.target, .mutation)' "$D/a.json" | jq '.slug = "notarget-fields"' > "$D/notarget-fields.json"
run --proposal "$D/notarget-fields.json" --baseline-count 100 --post-count 97 --ledger "$ROOT/ledger-ab.md"
ckrc "absent target and mutation fields count as empty" 1 "$rc"
ck "named as empty"                             'REFUSED target-gate notarget-fields' "$out"
mk "$D/good-after-bad.json" good-after-bad 1 '["a one"]'
run --proposal "$D/array.json" --proposal "$D/good-after-bad.json" --baseline-count 100 --post-count 99 --ledger "$ROOT/ledger-ab.md"
ckrc "one malformed proposal refuses the whole batch" 1 "$rc"
ckno "and no steps are printed for the good one" 'STEP ' "$out"

echo
echo "sweep-apply: $pass passed, $fail failed"
[ "$fail" = 0 ]
