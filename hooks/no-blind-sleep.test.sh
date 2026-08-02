#!/usr/bin/env bash
# Regression harness for no-blind-sleep.sh. Feeds real and synthetic Bash commands through the hook
# and asserts BLOCK/ALLOW.
#
# Cases 1-2 are verbatim from the 2026-08-01 BF fleet run, where two sessions burned 7.5 hours in
# this shape. Case 1 is the load-bearing one and the reason the hook strips quoted literals before
# looking for an exit condition: its trailing `echo "wait window elapsed"` contains the `wait`
# builtin as prose, which made the single worst offender in the run read as condition-bounded and
# sail straight through the first version of this guard.
#
# The ALLOW half matters as much as the BLOCK half. Marker polling is the SANCTIONED way to wait on
# a detached rspec run (basefund CLAUDE.md), and a guard that blocks it would push agents back toward
# foreground runs that get SIGKILLed mid-suite. Every ALLOW case here is a pattern that must survive.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PASS=0
FAIL=0

t() { # want desc command
  local want="$1" desc="$2" cmd="$3" out rc got
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | ./no-blind-sleep.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

echo "no-blind-sleep.sh —"
echo "  must BLOCK:"
t BLOCK "1 real: blind seq loop ending in echo \"wait ...\"" 'cd /w/bf-751; for i in $(seq 1 22); do sleep 25; done; echo "wait window elapsed"'
t BLOCK "2 real: blind seq loop + git status"                'cd /w/bf-659; for i in $(seq 1 22); do sleep 25; done; echo done; git status --short'
t BLOCK "3 bare long sleep"                                  'sleep 600'
t BLOCK "4 while true spin"                                  'while true; do sleep 30; done'
t BLOCK "5 while : spin"                                     'while :; do sleep 45; done'
t BLOCK "6 c-style for loop"                                 'for ((i=0;i<40;i++)); do sleep 20; done'
t BLOCK "7 explicit word list"                               'for i in 1 2 3 4 5 6; do sleep 30; done'
t BLOCK "8 seq with start and end"                           'for i in $(seq 5 25); do sleep 15; done'
t BLOCK "9 exit-word only inside a single-quoted string"     "for i in \$(seq 1 20); do sleep 30; done; echo 'if it is done then break'"

echo "  must ALLOW:"
t ALLOW "10 marker poll (CLAUDE.md detached-rspec pattern)" 'n=0; until [ -f tmp/run.done ] || [ $n -ge 60 ]; do sleep 10; n=$((n+1)); done'
t ALLOW "11 real: 95180db1 marker poll with break"          'cd /w/bf-491/apps/api; for i in $(seq 1 24); do if [ -f tmp/rspec-base.done ]; then break; fi; sleep 25; done'
t ALLOW "12 short settle"                                   'sleep 2 && cat tmp/out.log'
t ALLOW "13 exactly under the 120s floor"                   'sleep 60; echo ok'
t ALLOW "14 grep -q poll"                                   'for i in $(seq 1 30); do grep -q DONE tmp/x && break; sleep 20; done'
t ALLOW "15 pgrep-guarded wait"                             'for i in $(seq 1 30); do pgrep -f rspec || break; sleep 25; done'
t ALLOW "16 shell wait builtin on a real job"               'my_job & wait; sleep 300'
t ALLOW "17 no sleep at all"                                'git status --short'
t ALLOW "18 sleep as a substring of another word"           'grep -rn "sleep 300" docs/'
t ALLOW "19 timeout caps the wait below the floor"          'timeout 3 bash -c "sleep 300"'
t ALLOW "20 timeout with -k still caps"                     'timeout -k 5 10 bash -c "sleep 600"'
t BLOCK "21 timeout too long to rescue it"                  'timeout 900 bash -c "sleep 600"'
t ALLOW "22 timeout in minutes"                             'timeout 1m bash -c "sleep 300"'
t BLOCK "23 quotes are not a bypass under bash -c"          'bash -c "for i in $(seq 1 22); do sleep 25; done"'
t ALLOW "24 marker poll inside bash -c still allowed"       'bash -c "until [ -f tmp/run.done ]; do sleep 20; done"'

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
