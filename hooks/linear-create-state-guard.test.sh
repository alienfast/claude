#!/usr/bin/env bash
# Regression harness for linear-create-state-guard.sh. Feeds real and synthetic Bash commands
# through the hook and asserts BLOCK/ALLOW.
#
# Case 1 is verbatim the 2026-08-16 fleet shape that stranded BF-1194/95/96 in Triage — the filing
# that proved the prose rule (live since 2026-08-15) loses without a mechanical guard.
#
# The ALLOW half matters as much as the BLOCK half: the sanctioned helper invocation, quoted
# mentions of the command in greps and docs edits, and explicit-state creates must all survive.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PASS=0
FAIL=0

t() { # want desc command
  local want="$1" desc="$2" cmd="$3" out rc got
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | ./linear-create-state-guard.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

echo "linear-create-state-guard.sh —"
echo "  must BLOCK:"
t BLOCK "1 real 2026-08-16 shape: create --team -d - with no state" 'linear-cli issues create --team BF -d - "Sweep: unlocked Access reads" < tmp/body.md'
t BLOCK "2 title-first form, no state"                              'linear-cli issues create "Fix the thing" --team BF -d -'
t BLOCK "3 issues alias i, no state"                                'linear-cli i create "Fix the thing" --team BF'
t BLOCK "4 quotes are not a bypass under bash -c"                   'bash -c "linear-cli issues create --team BF -d - \"T\""'
t BLOCK "5 --state only inside the quoted title"                    'linear-cli issues create "add --state flag to helper" --team BF -d -'
t BLOCK "6 chained after another command"                           'cat tmp/body.md | linear-cli issues create "T" --team BF -d - && echo filed'

echo "  must ALLOW:"
t ALLOW "7 explicit --state"                                        'linear-cli issues create --team BF --state Backlog -d - "T"'
t ALLOW "8 explicit --state=X"                                      'linear-cli issues create --team BF --state=Backlog "T"'
t ALLOW "9 short -s flag"                                           'linear-cli issues create "T" --team BF -s Backlog -d -'
t ALLOW "10 sanctioned helper (create is inside the script)"        '~/.claude/scripts/linear-create-child.sh - BF - "T" tmp/body.md specified 2'
t ALLOW "11 grep for the command is data, not an invocation"        'grep -rn "linear-cli issues create" ~/.claude/skills/'
t ALLOW "12 issues update is not a create"                          'linear-cli issues update BF-1 --team BF'
t ALLOW "13 projects create is not an issues create"                'linear-cli projects create "Q3 roadmap" --team BF'
t ALLOW "14 search mentioning create in the query"                  'linear-cli search issues "create state" -o json'
t ALLOW "15 no linear-cli at all"                                   'git status --short'
t ALLOW "16 docs edit quoting the bare-create anti-pattern"         "echo 'never a raw linear-cli issues create' >> tmp/notes.md"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
