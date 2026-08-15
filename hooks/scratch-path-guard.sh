#!/bin/bash
# Scratch Path Guard Hook
#
# Enforces the CLAUDE.md scratch-file rule that prose alone failed to hold in long autonomous runs: scratch/intermediate
# files belong in the project-relative tmp/ (or the harness session scratchpad), never at the filesystem root or in
# system /tmp. A root-level log like /tmp_check_output.log sails through on write, then `rm` of it trips the harness's
# dangerous-path confirmation — stalling an unattended run on a prompt. Denying the WRITE here (exit 2 feeds stderr back
# to the model) converts that stall into an instant self-correction.
#
# Triggered: PreToolUse hook for Bash commands AND the file tools (Write|Edit|NotebookEdit — see the matchers in
#            settings.json). Guarding only Bash left the file-tool surface open: a Write to /tmp/x.rb landed unguarded,
#            and the rm-block below then stranded it as permanent litter (BF-807).
# Blocks: Bash — redirections, tee, and rm/mv/cp on root-level files (/name); in system temp (/tmp, /private/tmp) an rm
#         anywhere in the command, but cp/mv only when /tmp is the DESTINATION (a /tmp source is a read);
#         file tools — file_path/notebook_path in those same zones. The harness session scratchpads
#         (/tmp/claude-*, /private/tmp/claude-*) stay fully allowed on both surfaces.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# File-tool surface: Write/Edit use file_path, NotebookEdit uses notebook_path. One absolute target, no parsing needed.
FILE_TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
if [ -n "$FILE_TARGET" ]; then
  case "$FILE_TARGET" in
    /tmp/claude-*|/private/tmp/claude-*) exit 0 ;;
    /tmp/*|/private/tmp/*)
      target_zone="file write into system /tmp" ;;
    /*/*) exit 0 ;;
    /*)
      target_zone="file write to a root-level file" ;;
    *) exit 0 ;;
  esac
  cat >&2 <<EOF
🛑 BLOCKED: scratch write to a system path ($target_zone)

Target: $FILE_TARGET

Scratch and intermediate files (captured output, run logs, staging files) belong in the PROJECT-RELATIVE tmp/ directory
(mkdir -p tmp first) or the harness-assigned session scratchpad — never a bare root path and never system /tmp. These
writes pollute the host, and cleanup is itself guarded — a stray file here becomes permanent litter.

Retry the same edit with the target under tmp/. If a system path is genuinely required, say so to the user and let them
approve it explicitly.
EOF
  exit 2
fi

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
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])(rm|mv|cp)[[:space:]]([^\;\&\|]*[[:space:]])?${ROOT_FILE}([[:space:]\;\&\|\)]|$) ]]; then
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
# The middle group is optional so the bare form (`rm /tmp/x`, no flags) matches too — with it, the path capture lands
# in BASH_REMATCH[4] here / [5] below. It excludes newlines so an `rm` on one line cannot reach across into a later
# line's path and misattribute a cp there as an rm — which would re-block the very source-position cp allowed below.
NL=$'\n'
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])rm[[:space:]]([^\;\&\|${NL}]*[[:blank:]])?${SYSTMP} ]] && [[ "${BASH_REMATCH[4]}" != claude-* ]]; then
  block "rm in system /tmp"
fi
# cp/mv fire only on a /tmp DESTINATION — the path must be the LAST argument (blanks, then a statement terminator,
# a newline, or end of scan). A /tmp SOURCE is a read, and repo conventions legitimately keep shared artifacts there
# (basefund's apps/api/local defaults its prod dump to /tmp/db_dump.sql), so blocking `cp /tmp/db_dump.sql tmp/x.sql`
# denied legitimate work with no actionable retry — its write target was already tmp/. The ${NL} in the terminator
# class is load-bearing: bash compiles the ERE without REG_NEWLINE, so `$` matches only the end of the WHOLE scan and
# a destination on any non-final line of a multi-line command would slip through. Two accepted false negatives, per
# the guardrail philosophy in the header: target-first `cp -t /tmp/dir src`, and a trailing redirect `cp x /tmp/y 2>&1`.
if [[ "$SCAN" =~ (^|[[:space:]\;\&\|])(mv|cp)[[:space:]]([^\;\&\|${NL}]*[[:blank:]])?${SYSTMP}[[:blank:]]*([\;\&\|\)${NL}]|$) ]] && [[ "${BASH_REMATCH[5]}" != claude-* ]]; then
  block "cp/mv into system /tmp"
fi

exit 0
