#!/usr/bin/env bash
# Functional suite for quality-review-write-verdict.sh — the script that publishes a /quality-review
# verdict to BOTH the current worktree's tmp/ and the main checkout's tmp/, so a later /finish (Step 1.5,
# via finish-read-verdict.sh) finds it after /finish merge has deleted the worktree.
#
# WHY THIS SUITE EXISTS. The script had no direct tests until the 2026-08-03 fleet retro. That fleet lost
# the verdicts of 4 of its 12 shipped issues (BF-708, BF-711, BF-832, BF-872) — every one had staged the
# body into the worktree's tmp/ correctly with the Write tool and then never made the publish call, so the
# only copy died with the worktree at /finish merge. The reviews themselves had all run; what was lost was
# the audit trail. The stdin mode tested below is the fix: it removes the unpublished intermediate state
# the failure needs. Test the modes, not just the happy path — the retro's failure was a MISSING second
# call, so the single-call forms are the ones that matter most.
#
# Fixture topology is load-bearing. The dual-write assertions require a REAL linked worktree: the script
# resolves the main checkout through `git rev-parse --git-common-dir`, which only differs from
# --show-toplevel inside one. A test run in a plain clone silently exercises the single-write path and
# every dual-write assertion becomes vacuous while still passing.

set -uo pipefail

SCRIPT="${SCRIPT_UNDER_TEST:-$HOME/.claude/scripts/quality-review-write-verdict.sh}"
pass=0; fail=0

ck() { # ck <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fi
}

ck_file() { # ck_file <desc> <path> <expected-first-line>
  local got; got=$(head -1 "$2" 2>/dev/null || echo "<missing:$2>")
  ck "$1" "$3" "$got"
}

# The schema guard exits 3 on any body missing one of the Output block's seven field lines, so
# every fixture asserting exit 0 must be fully conformant — mode tests included.
body_ok() { # body_ok <first-line>
  printf '%s\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 1 (HIGH/impl: example finding)\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' "$1"
}

root=$(mktemp -d "${TMPDIR:-/tmp}/qrv-test-XXXXXX")
trap 'rm -rf "$root"' EXIT

# ---- fixture: a main checkout plus a linked worktree -------------------------------------------------
main="$root/main"
mkdir -p "$main"
git -C "$main" init -q 2>/dev/null || { echo "git init failed"; exit 1; }
git -C "$main" config user.email t@t.t; git -C "$main" config user.name t
echo seed > "$main/seed.txt"; git -C "$main" add -A; git -C "$main" commit -qm seed
wt="$root/wt-bf-999"
git -C "$main" worktree add -q -b test-bf-999 "$wt" >/dev/null 2>&1

echo "== 1. stdin mode (-) publishes to BOTH locations from a worktree"
body_ok '# Verdict — BF-999' | (cd "$wt" && "$SCRIPT" BF-999 -) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  worktree copy written"     "$wt/tmp/quality-review-verdict-bf-999.md"   "# Verdict — BF-999"
ck_file "  main-checkout copy written" "$main/tmp/quality-review-verdict-bf-999.md" "# Verdict — BF-999"

echo "== 2. issue id is lowercased in the filename"
ck "  lowercased path exists" "yes" "$([ -f "$main/tmp/quality-review-verdict-bf-999.md" ] && echo yes || echo no)"
# Assert on the DIRECTORY ENTRY, not on [ -f <uppercase> ]: macOS's default filesystem is
# case-insensitive, so the uppercase path resolves to the lowercase file and an absence test
# there passes trivially on Linux while failing on macOS for a script that is behaving correctly.
ck "  entry is stored lowercase" "1" \
  "$(ls "$main/tmp" | grep -cx 'quality-review-verdict-bf-999\.md')"
ck "  no uppercase entry"        "0" \
  "$(ls "$main/tmp" | grep -cx 'quality-review-verdict-BF-999\.md')"

echo "== 3. omitted body arg defaults to the worktree staging path"
mkdir -p "$wt/tmp"
body_ok '# Staged BF-888' > "$wt/tmp/quality-review-verdict-bf-888.md"
(cd "$wt" && "$SCRIPT" BF-888) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  main-checkout copy published from staging" "$main/tmp/quality-review-verdict-bf-888.md" "# Staged BF-888"
ck_file "  staging file survives in place"            "$wt/tmp/quality-review-verdict-bf-888.md"   "# Staged BF-888"

echo "== 4. explicit body file (the pre-existing two-arg form) still works"
body_ok '# Explicit BF-777' > "$root/body.md"
(cd "$wt" && "$SCRIPT" BF-777 "$root/body.md") >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  published" "$main/tmp/quality-review-verdict-bf-777.md" "# Explicit BF-777"

echo "== 5. run from the main checkout writes once, does not error"
body_ok '# Main BF-666' | (cd "$main" && "$SCRIPT" BF-666 -) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  written" "$main/tmp/quality-review-verdict-bf-666.md" "# Main BF-666"

echo "== 6. markdown bodies with code fences and backticks survive stdin verbatim"
{ body_ok '# Fenced BF-555'; printf '\n```ruby\nputs `date`\n```\n'; } \
  | (cd "$wt" && "$SCRIPT" BF-555 -) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck "  fence preserved"   "yes" "$(grep -qF '```ruby'      "$main/tmp/quality-review-verdict-bf-555.md" && echo yes || echo no)"
ck "  backticks preserved" "yes" "$(grep -qF 'puts `date`' "$main/tmp/quality-review-verdict-bf-555.md" && echo yes || echo no)"

echo "== 7. empty body is rejected (exit 2), nothing published"
printf '' | (cd "$wt" && "$SCRIPT" BF-444 -) >/dev/null 2>&1
ck "  exit 2" 2 $?
ck "  nothing published" "yes" "$([ ! -f "$main/tmp/quality-review-verdict-bf-444.md" ] && echo yes || echo no)"

echo "== 8. missing staging file is rejected (exit 2)"
(cd "$wt" && "$SCRIPT" BF-333) >/dev/null 2>&1
ck "  exit 2" 2 $?

echo "== 9. argument validation"
(cd "$wt" && "$SCRIPT") >/dev/null 2>&1;                       ck "  no args      -> exit 2" 2 $?
(cd "$wt" && "$SCRIPT" A B C) >/dev/null 2>&1;                 ck "  three args   -> exit 2" 2 $?
printf 'x\n' | (cd "$root" && "$SCRIPT" BF-222 -) >/dev/null 2>&1; ck "  outside a repo -> exit 1" 1 $?

echo "== 10. republish is idempotent and overwrites"
body_ok '# First'  | (cd "$wt" && "$SCRIPT" BF-111 -) >/dev/null 2>&1
body_ok '# Second' | (cd "$wt" && "$SCRIPT" BF-111 -) >/dev/null 2>&1
ck_file "  main copy carries the newer body" "$main/tmp/quality-review-verdict-bf-111.md" "# Second"

echo "== 11. published file is 0644, not mktemp's 0600"
perms=$(stat -f '%Lp' "$main/tmp/quality-review-verdict-bf-111.md" 2>/dev/null \
     || stat -c '%a'  "$main/tmp/quality-review-verdict-bf-111.md" 2>/dev/null)
ck "  mode 644" "644" "$perms"

echo "== 12. off-schema bodies still publish but exit 3 (the 2026-08-06 fleet shapes)"
# bf-699/bf-958 shape: rich prose carrying no field line but Verdict:/Cycles:
err=$(printf '# Review of BF-699\n\nLong prose about what was reviewed and fixed.\n\nVerdict: passed-after-fixes\nCycles: 3 (initial + 2 re-reviews)\n\nMore narrative.\n' \
  | (cd "$wt" && "$SCRIPT" BF-699 -) 2>&1 >/dev/null); rc=$?
ck "  prose body -> exit 3" 3 $rc
ck_file "  still published to main"     "$main/tmp/quality-review-verdict-bf-699.md" "# Review of BF-699"
ck_file "  still published to worktree" "$wt/tmp/quality-review-verdict-bf-699.md"   "# Review of BF-699"
ck "  stderr names the five missing lines" "yes" \
  "$(printf '%s' "$err" | grep -q 'missing/unparseable lines: Findings resolved, Deferred fixed in-session, Deferred filed as issues, Deferred dropped, Open items' && echo yes || echo no)"

# bf-973 shape: "## Findings resolved" as a HEADING with the count on the next line
err=$(printf '# Review of BF-973\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\n\n## Findings resolved\n\n4\n\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-973 -) 2>&1 >/dev/null); rc=$?
ck "  heading form -> exit 3" 3 $rc
ck "  names exactly Findings resolved" "yes" \
  "$(printf '%s' "$err" | grep -q 'missing/unparseable lines: Findings resolved$' && echo yes || echo no)"

# unsubstituted schema: a literal "Cycles: N"
err=$(printf '# BF-433\n\nVerdict: passed-clean\nCycles: N (initial + N-1 re-reviews)\nFindings resolved: none\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-433 -) 2>&1 >/dev/null); rc=$?
ck "  literal 'Cycles: N' -> exit 3" 3 $rc
ck "  names exactly Cycles" "yes" \
  "$(printf '%s' "$err" | grep -q 'missing/unparseable lines: Cycles$' && echo yes || echo no)"

# unsubstituted enum: a pipe-separated Verdict line
err=$(printf '# BF-422\n\nVerdict: passed-clean | passed-after-fixes\nCycles: 1 (initial)\nFindings resolved: none\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-422 -) 2>&1 >/dev/null); rc=$?
ck "  pipe-separated Verdict -> exit 3" 3 $rc
ck "  names exactly Verdict" "yes" \
  "$(printf '%s' "$err" | grep -q 'missing/unparseable lines: Verdict$' && echo yes || echo no)"

# a fully-conformant seven-field block passes untouched
body_ok '# Conformant BF-599' | (cd "$wt" && "$SCRIPT" BF-599 -) >/dev/null 2>&1
ck "  conformant block -> exit 0" 0 $?

echo "== 13. no stdin temp files leak into TMPDIR"
ck "  qr-verdict-stdin-* cleaned up" "0" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'qr-verdict-stdin-*' 2>/dev/null | wc -l | tr -d ' ')"

echo "== 14. origin-class WARNs (exit 0, publish-then-warn — BF-1248)"
# findings resolved but zero parseable SEVERITY/origin tags anywhere (6 of the 2026-08-17 fleet's 11
# verdicts): warn, never refuse.
err=$(printf '# BF-311\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 2 (HIGH: race in retry loop; MEDIUM: unchecked cast)\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-311 -) 2>&1 >/dev/null); rc=$?
ck "  untagged findings -> exit 0" 0 $rc
ck "  WARN fires" "yes" "$(printf '%s' "$err" | grep -q 'no severity tag carries a parseable origin class' && echo yes || echo no)"

# off-enum origin word beside a legal one (the BF-611 shape: HIGH/implementation looks tagged to its
# author, but the aggregator's trailing \b rejects it) — a zero-token check alone passes this body.
err=$(printf '# BF-322\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 2 (HIGH/impl: a; HIGH/implementation: b)\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-322 -) 2>&1 >/dev/null); rc=$?
ck "  off-enum tag -> exit 0" 0 $rc
ck "  no zero-token WARN (a legal tag exists)" "no" "$(printf '%s' "$err" | grep -q 'no severity tag carries a parseable origin class' && echo yes || echo no)"
ck "  off-enum WARN names the token" "yes" "$(printf '%s' "$err" | grep -q 'off-enum origin class: HIGH/implementation' && echo yes || echo no)"

# NICE-TO-HAVE/<legal-class> is compliant (the mandate covers wherever a severity tag renders;
# fleet-metrics.py's widened V_ORIGIN counts it) — neither WARN may fire.
err=$(printf '# BF-355\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 1 (NICE-TO-HAVE/plan: cosmetic rename)\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-355 -) 2>&1 >/dev/null); rc=$?
ck "  NICE-TO-HAVE/plan -> exit 0" 0 $rc
ck "  no origin WARNs" "no" "$(printf '%s' "$err" | grep -Eq 'origin class' && echo yes || echo no)"

# Findings resolved: none — nothing to tag, nothing to warn about.
err=$(printf '# BF-366\n\nVerdict: passed-clean\nCycles: 1 (initial)\nFindings resolved: none\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-366 -) 2>&1 >/dev/null); rc=$?
ck "  none resolved -> exit 0" 0 $rc
ck "  quiet" "no" "$(printf '%s' "$err" | grep -Eq 'origin class' && echo yes || echo no)"

echo "== 15. parentless-filing WARN (exit 0 — the BF-1189 shape)"
# filed with the (sub-issues of <PARENT>) suffix: compliant, quiet.
err=$(printf '# BF-377\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 1 (HIGH/impl: example)\nDeferred fixed in-session: none\nDeferred filed as issues: TT-40, TT-41 (sub-issues of TT-9)\nCollision edges: none owed\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-377 -) 2>&1 >/dev/null); rc=$?
ck "  suffixed filing -> exit 0" 0 $rc
ck "  quiet" "no" "$(printf '%s' "$err" | grep -q 'sub-issues of <PARENT>' && echo yes || echo no)"

# filed WITHOUT the suffix: three BF-1189 filings landed parentless this way (which also kept the
# collision-edge rule from firing) — warn, never refuse, since a genuinely parentless run is legal.
err=$(printf '# BF-388\n\nVerdict: passed-after-fixes\nCycles: 2 (initial + 1 re-review)\nFindings resolved: 1 (HIGH/impl: example)\nDeferred fixed in-session: none\nDeferred filed as issues: TT-40, TT-41\nCollision edges: none owed\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-388 -) 2>&1 >/dev/null); rc=$?
ck "  unsuffixed filing -> exit 0" 0 $rc
ck "  WARN fires" "yes" "$(printf '%s' "$err" | grep -q "without a '(sub-issues of <PARENT>)' suffix" && echo yes || echo no)"

# filed: none — nothing filed, nothing to link.
err=$(printf '# BF-399\n\nVerdict: passed-clean\nCycles: 1 (initial)\nFindings resolved: none\nDeferred fixed in-session: none\nDeferred filed as issues: none\nDeferred dropped: none\nOpen items: none\n' \
  | (cd "$wt" && "$SCRIPT" BF-399 -) 2>&1 >/dev/null); rc=$?
ck "  nothing filed -> exit 0" 0 $rc
ck "  quiet" "no" "$(printf '%s' "$err" | grep -q 'sub-issues of <PARENT>' && echo yes || echo no)"

echo
echo "$pass passed / $fail failed"
[ "$fail" -eq 0 ]
