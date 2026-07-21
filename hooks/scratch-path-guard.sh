#!/bin/bash
# Scratch Path Guard Hook
#
# Enforces the CLAUDE.md scratch-file rule that prose alone failed to hold in long autonomous runs: scratch/intermediate
# files belong in the project-relative tmp/ (or the harness session scratchpad), never at the filesystem root or in
# system /tmp. A root-level log like /tmp_check_output.log sails through on write, then `rm` of it trips the harness's
# dangerous-path confirmation — stalling an unattended run on a prompt. Denying the WRITE here (exit 2 feeds stderr back
# to the model) converts that stall into an instant self-correction.
#
# Triggered: PreToolUse hook for Bash commands
# Blocks: redirections, tee, and rm/mv/cp targeting root-level files (/name) or system temp (/tmp, /private/tmp) —
#         except the harness session scratchpads (/tmp/claude-*, /private/tmp/claude-*), which stay fully allowed.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# Scan a copy with heredoc bodies and quoted strings stripped: prose inside them (a commit message describing an
# incident path, a posted comment) legitimately MENTIONS forbidden paths without writing to them. The resulting false
# negatives (a quoted redirect target) are acceptable — this is a guardrail, and the harness's own dangerous-path
# check still backstops deletes; a false positive here blocks legitimate work outright.
SCAN=""
heredoc_delim=""
while IFS= read -r line; do
  if [ -n "$heredoc_delim" ]; then
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ "$trimmed" = "$heredoc_delim" ] && heredoc_delim=""
    continue
  fi
  if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]]; then
    heredoc_delim="${BASH_REMATCH[1]}"
  fi
  line=$(printf '%s' "$line" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
  SCAN+="$line
"
done <<< "$COMMAND"

block() {
  cat >&2 <<EOF
🛑 BLOCKED: scratch write to a system path ($1)

Command: $COMMAND

Scratch and intermediate files (captured output, run logs, staging files) belong in the PROJECT-RELATIVE tmp/ directory
(mkdir -p tmp first) or the harness-assigned session scratchpad — never a bare root path like /check_output.log and
never system /tmp. Root/system-temp writes pollute the host and their cleanup trips the harness's dangerous-path
confirmation, stalling autonomous runs on a permission prompt.

Rerun the same command with the target under tmp/ (e.g. tmp/check_output.log). If a system path is genuinely required,
say so to the user and let them approve it explicitly.
EOF
  exit 2
}

# Zone 1: root-level single-component file (e.g. /tmp_check_output.log — note NOT /tmp/...; /dev/null etc. have two
# components and never match). Redirection, tee, or rm/mv/cp on such a path.
ROOT_FILE='/[A-Za-z0-9._+-]+'
if [[ "$SCAN" =~ (^|[^\<\>])\>{1,2}[[:space:]]*${ROOT_FILE}([[:space:]\;\&\|\)]|$) ]]; then
  block "redirection to a root-level file"
fi
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])tee[[:space:]]+(-[A-Za-z]+[[:space:]]+)*${ROOT_FILE}([[:space:]\;\&\|\)]|$) ]]; then
  block "tee to a root-level file"
fi
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])(rm|mv|cp)[[:space:]][^\;\&\|]*[[:space:]]${ROOT_FILE}([[:space:]\;\&\|\)]|$) ]]; then
  block "rm/mv/cp on a root-level file"
fi

# Zone 2: system temp (/tmp/..., /private/tmp/...) excluding the harness scratchpads (/tmp/claude-*, /private/tmp/claude-*).
SYSTMP='(/private)?/tmp/([^[:space:]"'\'']*)'
if [[ "$SCAN" =~ \>{1,2}[[:space:]]*${SYSTMP} ]] && [[ "${BASH_REMATCH[2]}" != claude-* ]]; then
  block "redirection into system /tmp"
fi
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])tee[[:space:]]+(-[A-Za-z]+[[:space:]]+)*${SYSTMP} ]] && [[ "${BASH_REMATCH[4]}" != claude-* ]]; then
  block "tee into system /tmp"
fi
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])(rm|mv|cp)[[:space:]][^\;\&\|]*[[:space:]]${SYSTMP} ]] && [[ "${BASH_REMATCH[4]}" != claude-* ]]; then
  block "rm/mv/cp in system /tmp"
fi

exit 0
