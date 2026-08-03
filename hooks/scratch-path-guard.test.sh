#!/usr/bin/env bash
# Regression harness for scratch-path-guard.sh. Feeds both hook surfaces — Bash commands via
# .tool_input.command and file tools via .tool_input.file_path / .notebook_path — and asserts
# BLOCK/ALLOW.
#
# Case 25 is the reason this file exists: the rm/mv/cp patterns originally required an intervening
# argument (two spaces), so the bare form `rm /tmp/x` sailed through while `rm -f /tmp/x` blocked —
# found only while closing BF-807, years of runs after the hook shipped. The file-tool surface
# (cases 1-9) is BF-807 itself: a Write to /tmp/vis_test.rb landed unguarded, and the rm-block then
# stranded it as permanent litter.
#
# The ALLOW half matters as much as the BLOCK half. The harness session scratchpads
# (/tmp/claude-*, /private/tmp/claude-*) and the project-relative tmp/ are the SANCTIONED scratch
# destinations, and prose that merely mentions a /tmp path (a commit message, a posted comment, a
# heredoc body) must never trip the guard — a false positive here blocks legitimate work outright.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PASS=0
FAIL=0

run_case() { # want desc json
  local want="$1" desc="$2" json="$3" out rc got
  out=$(printf '%s' "$json" | ./scratch-path-guard.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}
tb() { run_case "$1" "$2" "$(jq -n --arg c "$3" '{tool_input:{command:$c}}')"; }        # Bash surface
tf() { run_case "$1" "$2" "$(jq -n --arg p "$3" '{tool_input:{file_path:$p}}')"; }      # Write/Edit surface
tn() { run_case "$1" "$2" "$(jq -n --arg p "$3" '{tool_input:{notebook_path:$p}}')"; }  # NotebookEdit surface

echo "scratch-path-guard.sh —"
echo "  file tools, must BLOCK:"
tf BLOCK "1 Write into system /tmp (the BF-807 shape)"      '/tmp/vis_test.rb'
tf BLOCK "2 Write into /private/tmp"                        '/private/tmp/x.log'
tf BLOCK "3 Write to a root-level file"                     '/rootfile.log'
tn BLOCK "4 NotebookEdit into system /tmp"                  '/tmp/nb.ipynb'

echo "  file tools, must ALLOW:"
tf ALLOW "5 harness scratchpad under /tmp/claude-*"         '/tmp/claude-501/s/ok.txt'
tf ALLOW "6 harness scratchpad under /private/tmp/claude-*" '/private/tmp/claude-501/s/ok.txt'
tf ALLOW "7 ordinary absolute path"                         '/Users/kross/ok.md'
tf ALLOW "8 project-relative tmp/"                          'tmp/ok.txt'
tf ALLOW "9 two-component system path outside /tmp"         '/opt/notes.md'

echo "  bash, must BLOCK:"
tb BLOCK "10 redirect into system /tmp"                     'echo hi > /tmp/x.log'
tb BLOCK "11 append into system /tmp"                       'echo hi >> /private/tmp/x.log'
tb BLOCK "12 tee into system /tmp"                          'run | tee /tmp/out.log'
tb BLOCK "13 tee -a into system /tmp"                       'run | tee -a /tmp/out.log'
tb BLOCK "14 rm -f under system /tmp"                       'rm -f /tmp/x.rb'
tb BLOCK "15 mv into system /tmp"                           'mv foo /tmp/bar'
tb BLOCK "16 cp into system /tmp"                           'cp foo /tmp/bar'
tb BLOCK "17 redirect to a root-level file"                 'pnpm check > /check_output.log 2>&1'
tb BLOCK "18 tee to a root-level single-component name"     'run | tee /tmp_check.log'
tb BLOCK "19 rm after a command separator"                  'ls; rm -f /tmp/x.rb'

echo "  bash, must ALLOW:"
tb ALLOW "20 redirect to project-relative tmp/"             'echo hi > tmp/x.log'
tb ALLOW "21 rm of project-relative tmp/ files"             'rm tmp/x.log'
tb ALLOW "22 rm -rf of an own tmp/ subdirectory"            'rm -rf tmp/screenshots'
tb ALLOW "23 scratchpad write"                              'echo hi > /tmp/claude-501/s/out.log'
tb ALLOW "24 scratchpad cleanup"                            'rm -rf /tmp/claude-501/s/work'

echo "  the bare no-flag form (the BF-807 regex gap) — must BLOCK:"
tb BLOCK "25 bare rm under system /tmp"                     'rm /tmp/x.rb'
tb BLOCK "26 bare rm of a root-level file"                  'rm /rootfile.log'

echo "  prose mentions are not writes — must ALLOW:"
tb ALLOW "27 double-quoted mention"                         'git commit -m "fix: rm /tmp/x stall"'
tb ALLOW "28 single-quoted mention"                         "echo 'see /tmp/foo.log for details'"
tb ALLOW "29 heredoc body mention"                          $'cat <<EOF > tmp/note.md\ndelete /tmp/evil.log by hand\nEOF'
tb ALLOW "30 /dev/null redirect (two components, not /tmp)" 'cmd > /dev/null 2>&1'
tb ALLOW "31 git rm (different command word)"               'git rm file.txt'
tb ALLOW "32 no paths at all"                               'ls -la'

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
