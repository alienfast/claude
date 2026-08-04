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
printf '# Verdict — BF-999\n\nVerdict: passed-after-fixes\n' | (cd "$wt" && "$SCRIPT" BF-999 -) >/dev/null 2>&1
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
printf '# Staged BF-888\n\nVerdict: passed-clean\n' > "$wt/tmp/quality-review-verdict-bf-888.md"
(cd "$wt" && "$SCRIPT" BF-888) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  main-checkout copy published from staging" "$main/tmp/quality-review-verdict-bf-888.md" "# Staged BF-888"
ck_file "  staging file survives in place"            "$wt/tmp/quality-review-verdict-bf-888.md"   "# Staged BF-888"

echo "== 4. explicit body file (the pre-existing two-arg form) still works"
printf '# Explicit BF-777\n' > "$root/body.md"
(cd "$wt" && "$SCRIPT" BF-777 "$root/body.md") >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  published" "$main/tmp/quality-review-verdict-bf-777.md" "# Explicit BF-777"

echo "== 5. run from the main checkout writes once, does not error"
printf '# Main BF-666\n' | (cd "$main" && "$SCRIPT" BF-666 -) >/dev/null 2>&1
ck "  exit 0" 0 $?
ck_file "  written" "$main/tmp/quality-review-verdict-bf-666.md" "# Main BF-666"

echo "== 6. markdown bodies with code fences and backticks survive stdin verbatim"
printf '# Fenced BF-555\n\nVerdict: passed-clean\n\n```ruby\nputs `date`\n```\n' \
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
printf '# First\n'  | (cd "$wt" && "$SCRIPT" BF-111 -) >/dev/null 2>&1
printf '# Second\n' | (cd "$wt" && "$SCRIPT" BF-111 -) >/dev/null 2>&1
ck_file "  main copy carries the newer body" "$main/tmp/quality-review-verdict-bf-111.md" "# Second"

echo "== 11. published file is 0644, not mktemp's 0600"
perms=$(stat -f '%Lp' "$main/tmp/quality-review-verdict-bf-111.md" 2>/dev/null \
     || stat -c '%a'  "$main/tmp/quality-review-verdict-bf-111.md" 2>/dev/null)
ck "  mode 644" "644" "$perms"

echo "== 12. no stdin temp files leak into TMPDIR"
ck "  qr-verdict-stdin-* cleaned up" "0" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'qr-verdict-stdin-*' 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "$pass passed / $fail failed"
[ "$fail" -eq 0 ]
