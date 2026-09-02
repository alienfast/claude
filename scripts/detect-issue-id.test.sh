#!/usr/bin/env bash
# Regression suite for detect-issue-id.sh.
#
# Team lists come from DETECT_ISSUE_ID_TEAMS so no case touches the network; the
# undiscoverable-list cases run with a failing linear-cli stub on PATH and both env sources
# unset. Git fixtures are throwaway repos in $TMP, one per branch/subject shape.

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect-issue-id.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
TEAMS="BF,PL"

mkrepo() { # <name> <branch> <subject> — echoes the repo dir
  local dir="$TMP/$1"
  git init -q -b "$2" "$dir"
  git -C "$dir" -c user.email=t@t.test -c user.name=t commit -q --allow-empty -m "$3"
  printf '%s' "$dir"
}

mkdir -p "$TMP/nobin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nobin/linear-cli"
chmod +x "$TMP/nobin/linear-cli"

t() { # <name> <want_rc> <want_stdout> <want_stderr_pattern|-> <cmd...>
  local name="$1" want_rc="$2" want_out="$3" want_err="$4"; shift 4
  local out rc err ok=1
  out=$("$@" 2>"$TMP/err"); rc=$?
  err=$(cat "$TMP/err")
  [ "$rc" = "$want_rc" ] || ok=0
  [ "$out" = "$want_out" ] || ok=0
  if [ "$want_err" = "-" ]; then
    [ -z "$err" ] || ok=0
  else
    printf '%s' "$err" | grep -q "$want_err" || ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=$want_rc out='$want_out' err~'$want_err'; got rc=$rc out='$out' err='$err'"; FAIL=$((FAIL+1))
  fi
}

in_repo() { # <dir> <cmd...>
  local dir="$1"; shift
  (cd "$dir" && "$@")
}

echo "detect-issue-id.sh"

# --input is authoritative and never team-validated: a prefix outside the team list still
# resolves, byte-identical to the pre-validation behavior.
t "--input normalizes, skips team validation" 0 "HOTFIXES-1" - \
  env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT" --input hotfixes-1
t "--input invalid shape refused"             1 "" "does not match" \
  env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT" --input "not an id"
t "--validate-only normalizes"                0 "PL-9" - \
  env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT" --validate-only --input pl-9
t "--validate-only without --input refused"   1 "" "requires --input" \
  "$SCRIPT" --validate-only

# Branch source, team list discoverable.
r=$(mkrepo r1 bf-123-fix-widget "no ids here")
t "branch with known team resolves"           0 "BF-123" - \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"
r=$(mkrepo r2 feature/pl-7-thing "no ids here")
t "slash-segmented branch resolves"           0 "PL-7" - \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"
r=$(mkrepo r3 hotfixes-1 "tidy docs")
t "word-number branch rejected"               1 "" "no issue ID found" \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"
r=$(mkrepo r4 hotfixes-1 "fix widget for BF-77")
t "rejected branch falls through to subject"  0 "BF-77" - \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"
r=$(mkrepo r5 bf-6-a "no ids here")
t "team match is case-insensitive"            0 "BF-6" - \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="bf" "$SCRIPT"

# Commit-subject source (branch fallback skipped on main), team list discoverable.
r=$(mkrepo r6 main "fix UTF-8 handling for BF-1705")
t "known team beats leftmost non-team match"  0 "BF-1705" - \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"
r=$(mkrepo r7 main "document SHA-256 and RFC-7231")
t "hyphenated tokens alone resolve nothing"   1 "" "no issue ID found" \
  in_repo "$r" env DETECT_ISSUE_ID_TEAMS="$TEAMS" "$SCRIPT"

# Undiscoverable team list (stub linear-cli fails, both env sources unset): fail open.
r=$(mkrepo r8 feature/bf-55-x "no ids here")
t "undiscoverable list: branch WARN-accepts"  0 "BF-55" "WARN.*BF-55" \
  in_repo "$r" env -u DETECT_ISSUE_ID_TEAMS -u LINEAR_TEAM PATH="$TMP/nobin:$PATH" "$SCRIPT"
r=$(mkrepo r9 main "ship BF-88 fix")
t "undiscoverable list: subject WARN-accepts" 0 "BF-88" "WARN.*BF-88" \
  in_repo "$r" env -u DETECT_ISSUE_ID_TEAMS -u LINEAR_TEAM PATH="$TMP/nobin:$PATH" "$SCRIPT"

# LINEAR_TEAM fallback: confirms members silently, cannot reject non-members.
r=$(mkrepo r10 bf-12-y "no ids here")
t "fallback member accepted without WARN"     0 "BF-12" - \
  in_repo "$r" env -u DETECT_ISSUE_ID_TEAMS LINEAR_TEAM=BF PATH="$TMP/nobin:$PATH" "$SCRIPT"
r=$(mkrepo r11 pl-31-z "no ids here")
t "fallback non-member WARN-accepts"          0 "PL-31" "WARN.*PL-31" \
  in_repo "$r" env -u DETECT_ISSUE_ID_TEAMS LINEAR_TEAM=BF PATH="$TMP/nobin:$PATH" "$SCRIPT"

# --help prints the whole header, however long it grows (the old sed range hardcoded it).
out=$("$SCRIPT" --help)
if printf '%s' "$out" | grep -q 'Usage:' \
  && printf '%s' "$out" | grep -q 'not found / invalid format / refused' \
  && ! printf '%s' "$out" | grep -q 'set -eo'; then
  echo "  PASS  --help spans the full header"; PASS=$((PASS+1))
else
  echo "  FAIL  --help spans the full header — got: $(printf '%s' "$out" | tail -3)"; FAIL=$((FAIL+1))
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
