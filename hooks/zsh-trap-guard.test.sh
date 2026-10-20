#!/usr/bin/env bash
# Regression harness for zsh-trap-guard.sh: feeds Bash tool commands through the hook and asserts BLOCK/ALLOW.
#
# The ALLOW half matters as much as the BLOCK half: `git status`, `--status=` flags, `exit_status=`, `realpath`, a
# single-quoted grep pattern and a string handed to bash are everyday shapes that must never be refused.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PASS=0
FAIL=0

t() { # want desc command
  local want="$1" desc="$2" cmd="$3" out rc got
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | ./zsh-trap-guard.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

echo "zsh-trap-guard.sh —"
echo "  must BLOCK:"
t BLOCK "1 PIPESTATUS"                       'cmd | tee tmp/out.log; echo "EXIT=${PIPESTATUS[0]}"'
t BLOCK "2 status= after capture"            'out=$(git rev-parse HEAD); status=$?; echo $status'
t BLOCK "3 local status="                    'f() { local status=$?; }'
t BLOCK "4 for path in"                      'for path in a b; do echo "$path"; done'
t BLOCK "5 read … path"                      'while read -r label path pat; do echo "$path"; done < tmp/list'
t BLOCK "6 path= assignment"                 'path=/tmp/x; ls $path'
t BLOCK "7 lowercase \${var,,}"              'id=BF-123; f="tmp/x-${id,,}.md"; echo $f'
t BLOCK "8 uppercase \${var^^}"              'echo ${name^^}'
t BLOCK "9 unbraced \$rev:path (git)"        'git cat-file -e "$tag:apps/x" 2>/dev/null && echo present'
t BLOCK "10 unbraced \$dir:tools"            'echo $tag:tools/x'

echo "  must ALLOW:"
t ALLOW "11 git status"                      'git status --short'
t ALLOW "12 --status= flag"                  'gh pr list --status=open'
t ALLOW "13 exit_status= variable"           'exit_status=1; echo $exit_status'
t ALLOW "14 rc=\$?"                           'out=$(cmd); rc=$?; echo $rc'
t ALLOW "15 for p in"                        'for p in a b; do echo "$p"; done'
t ALLOW "16 single-quoted grep pattern"      "grep -rn 'PIPESTATUS' ~/.claude/standards"
t ALLOW "17 bash -c string"                  "bash -c 'echo \${PIPESTATUS[0]}'"
t ALLOW "18 bash script file"                'bash scripts/x.sh && echo ${PIPESTATUS[0]}'
t ALLOW "19 braced \${tag}:path"             'git cat-file -e "${tag}:apps/x"'
t ALLOW "20 PATH export"                     'export PATH=$PATH:/usr/local/bin'
t ALLOW "21 realpath / filepath"             'realpath foo; filepath=bar; --output-path=x'
t ALLOW "22 zsh case modifiers"              'echo ${var:l} ${var:u}'
t ALLOW "23 pipestatus lowercase"            'cmd | tee tmp/out.log; echo "EXIT=${pipestatus[1]}"'
t ALLOW "24 escaped \\\$ in a regex"         'grep -E "\$var:a" file'
t ALLOW "25 url with colon"                  'curl -s https://example.com/path:a'
t ALLOW "26 no trap tokens"                  'ls -la && pnpm check'

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
