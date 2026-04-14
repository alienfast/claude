#!/bin/bash
# Block Bash invocations of grep/rg/find/ls/cat in favor of built-in tools.
#
# Two distinct contexts are enforced:
#
# 1. New-command context (start of line, or after &&, ||, ;, $(, `)
#    — all five banned: they're reading files / listing dirs, which the
#    Grep / Glob / Read tools replace.
#
# 2. Pipeline downstream (after a single `|`)
#    — only find/ls/cat banned. `grep`/`rg` are legitimate stream filters
#    when the upstream isn't a file (e.g. `git log -p | grep foo` — the
#    Grep tool can't search command output).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Strip `cat <<EOF` / `cat <<-EOF` heredoc (multi-line string idiom,
# can't be replaced by the Read tool).
STRIPPED=$(echo "$COMMAND" | sed -E 's/cat[[:space:]]+<<-?/  /g')

# Regex 1: all five banned at new-command boundaries.
# Boundaries listed explicitly: start, &&, ||, ;, $(, backtick.
# Single `|` is NOT a boundary here (pipe handled separately below).
RE_NEWCMD='(^|&&|\|\||;|\$\(|`)[[:space:]]*(grep|rg|find|ls|cat)([[:space:]]|$)'

# Regex 2: only find/ls/cat downstream of a single pipe.
# `[^|]\|` matches a pipe NOT preceded by another pipe (to exclude `||`).
RE_PIPE='[^|]\|[[:space:]]*(find|ls|cat)([[:space:]]|$)'

BANNED=""
if [[ "$STRIPPED" =~ $RE_NEWCMD ]]; then
  BANNED="${BASH_REMATCH[2]}"
elif [[ "$STRIPPED" =~ $RE_PIPE ]]; then
  BANNED="${BASH_REMATCH[1]}"
fi

if [[ -n "$BANNED" ]]; then
  cat >&2 <<EOF
🛑 BLOCKED: Bash command invokes \`${BANNED}\` — use the built-in tool instead.

  grep, rg  →  Grep tool        (content search in files)
  find, ls  →  Glob tool        (file finding / directory listing)
  cat       →  Read tool        (reading file contents)

Pipeline filtering is allowed: \`some-cmd | grep foo\` or \`... | rg bar\`
is fine because the Grep tool can't search command output.

\`head\`, \`tail\`, \`touch\` remain allowed in pipelines when they're the
natural choice.

Command: ${COMMAND}
EOF
  exit 2
fi

exit 0
