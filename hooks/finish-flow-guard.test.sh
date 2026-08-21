#!/usr/bin/env bash
# Regression harness for finish-flow-guard.sh. Builds synthetic transcripts, feeds them with a Bash
# command, and asserts BLOCK/ALLOW.
#
# Cases 1-3 are the three real drifts the hook exists to stop — JA-415, JA-367, JA-390 — each
# reconstructed from its actual transcript.
#
# The ALLOW half matters MORE than the BLOCK half: a false allow costs one PR to close, a false
# block breaks a real ship mid-flight. Every interactive shape, every user-typed `pr`, and every
# unreadable-intent case must survive.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

usercmd() { python3 -c '
import json, sys
n, a = sys.argv[1], sys.argv[2]
print(json.dumps({"type": "user", "message": {"content":
    "<command-message>%s</command-message>\n<command-name>/%s</command-name>\n<command-args>%s</command-args>" % (n, n, a)}}))
' "$1" "$2"; }

skill() { python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "message": {"content":
    [{"type": "tool_use", "name": "Skill", "input": {"skill": sys.argv[1], "args": sys.argv[2]}}]}}))
' "$1" "$2"; }

# A tool_result that ECHOES transcript text — list content, so it must never read as an invocation.
echoed() { python3 -c '
import json, sys
print(json.dumps({"type": "user", "message": {"content":
    [{"type": "tool_result", "content": sys.argv[1]}]}}))
' "$1"; }

t() { # want desc command [transcript]
  local want="$1" desc="$2" cmd="$3" tr="${4:-}" out rc got
  out=$(jq -n --arg c "$cmd" --arg t "$tr" '{tool_input:{command:$c},transcript_path:$t}' | ./finish-flow-guard.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

# --- transcripts -------------------------------------------------------------------------------
JA415="$TMP/ja415.jsonl"
{ usercmd auto "ja-415"; skill full "auto wt pr JA-415"; skill start "auto wt JA-415"; } >"$JA415"

JA367="$TMP/ja367.jsonl"
{ usercmd loop "/auto"; skill full "auto wt JA-367"; skill finish "auto JA-367 merge"; } >"$JA367"

JA390="$TMP/ja390.jsonl"
{ usercmd loop "/auto"; skill full "auto wt pr JA-390"; } >"$JA390"

FULLAUTO="$TMP/fullauto.jsonl"
{ usercmd full "auto wt JA-1"; skill start "auto wt JA-1"; } >"$FULLAUTO"

AUTOPR="$TMP/autopr.jsonl"
{ usercmd auto "pr JA-1"; skill full "auto wt pr JA-1"; } >"$AUTOPR"

LOOPPR="$TMP/looppr.jsonl"
{ usercmd loop "/auto pr"; skill full "auto wt pr JA-1"; } >"$LOOPPR"

BAREFIN="$TMP/barefin.jsonl"
{ usercmd finish ""; } >"$BAREFIN"

INTERPR="$TMP/interpr.jsonl"
{ usercmd finish "pr JA-1"; } >"$INTERPR"

NOCMD="$TMP/nocmd.jsonl"
{ skill full "auto wt pr JA-1"; } >"$NOCMD"

# Genuine `/auto ja-1`, then a tool_result echoing an interactive `/finish pr` invocation. If the
# echo were mistaken for intent the guard would wrongly ALLOW.
SPOOF="$TMP/spoof.jsonl"
{ usercmd auto "ja-1"
  skill full "auto wt pr JA-1"
  echoed '<command-message>finish</command-message>
<command-name>/finish</command-name>
<command-args>pr JA-1</command-args>'; } >"$SPOOF"

echo "finish-flow-guard.sh —"
echo "  must BLOCK:"
t BLOCK "1 JA-415: /auto ja-415 -> pr injected at /full"       '~/.claude/scripts/finish-detect-mode.sh pr 2>&1; echo "EXIT=$?"'                      "$JA415"
t BLOCK "2 JA-367: dispatched merge, ran pr"                   '~/.claude/scripts/finish-detect-mode.sh pr; echo "DETECT_EXIT=$?"'                    "$JA367"
t BLOCK "3 JA-390: pr injected, stderr redirect form"          '~/.claude/scripts/finish-detect-mode.sh pr 2>tmp/finish-detect-ja-390.err; echo "EXIT=$?"' "$JA390"
t BLOCK "4 /full auto wt with no pr token"                     '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$FULLAUTO"
t BLOCK "5 echoed invocation must not spoof intent"            '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$SPOOF"
t BLOCK "6 quotes are not a bypass under bash -c"              'bash -c "~/.claude/scripts/finish-detect-mode.sh pr"'                                 "$JA415"

echo "  must ALLOW:"
t ALLOW "7  user typed /auto pr"                               '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$AUTOPR"
t ALLOW "8  user typed /loop /auto pr"                         '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$LOOPPR"
t ALLOW "9  bare interactive /finish (no auto in chain)"       '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$BAREFIN"
t ALLOW "10 interactive /finish pr"                            '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$INTERPR"
t ALLOW "11 merge under an auto chain"                         '~/.claude/scripts/finish-detect-mode.sh merge; echo "EXIT=$?"'                        "$JA415"
t ALLOW "12 no action token under an auto chain"               '~/.claude/scripts/finish-detect-mode.sh'                                              "$JA415"
t ALLOW "13 missing transcript_path fails open"                '~/.claude/scripts/finish-detect-mode.sh pr'                                           ""
t ALLOW "14 nonexistent transcript fails open"                 '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$TMP/absent.jsonl"
t ALLOW "15 no invocation in transcript fails open"            '~/.claude/scripts/finish-detect-mode.sh pr'                                           "$NOCMD"
t ALLOW "16 grep for the command is data, not an invocation"   'grep -rn "finish-detect-mode.sh pr" ~/.claude/skills/'                                "$JA415"
t ALLOW "17 unrelated command"                                 'git status --short'                                                                   "$JA415"
t ALLOW "18 pr only after a statement boundary"                '~/.claude/scripts/finish-detect-mode.sh merge; echo pr'                               "$JA415"
t ALLOW "19 docs edit quoting the anti-pattern"                "echo 'never finish-detect-mode.sh pr in auto' >> tmp/notes.md"                        "$JA415"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
