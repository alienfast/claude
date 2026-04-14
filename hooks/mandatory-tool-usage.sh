#!/bin/bash
# Block Bash invocations of grep/rg/find/ls/cat in favor of built-in tools.
# Matches the command as actually invoked (start of command, or after a shell
# separator like | && || ; $( `), so it doesn't trip on file paths, flag
# values (e.g. `git log --grep=foo`), or names used as arguments.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Allow `cat <<EOF` / `cat <<-EOF` heredoc (standard shell idiom for
# multi-line strings — Read tool cannot replace it). Strip heredoc-cats out
# of the command before matching so only "real" cats remain.
STRIPPED=$(echo "$COMMAND" | sed -E 's/cat[[:space:]]+<<-?/  /g')

if [[ "$STRIPPED" =~ (^|[\;\&\|\`\(])[[:space:]]*(grep|rg|find|ls|cat)([[:space:]]|$) ]]; then
  BANNED="${BASH_REMATCH[2]}"
  cat >&2 <<EOF
🛑 BLOCKED: Bash command invokes \`${BANNED}\` — use the built-in tool instead.

  grep, rg  →  Grep tool        (content search)
  find, ls  →  Glob tool        (file finding / directory listing)
  cat       →  Read tool        (reading file contents)

\`head\`, \`tail\`, \`touch\` remain allowed in pipelines when they're the
natural choice.

Command: ${COMMAND}
EOF
  exit 2
fi

exit 0
