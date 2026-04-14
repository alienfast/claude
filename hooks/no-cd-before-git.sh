#!/bin/bash
# Reject `cd <dir> && git ...` (or `;`, `||`) in Bash tool calls.
# These bypass the Bash(git:*) allowlist and trigger permission prompts.
# Use `git -C <dir> <subcommand>` instead.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Match: optional leading whitespace, `cd`, path, any separator (&&, ;, ||),
# then `git` as a word. `git-foo` / `gitk` will not match (word boundary).
if [[ "$COMMAND" =~ ^[[:space:]]*cd[[:space:]]+[^[:space:]]+[[:space:]]*(\&\&|\;|\|\|)[[:space:]]*git([[:space:]]|$) ]]; then
  cat >&2 <<'EOF'
🛑 BLOCKED: `cd` before a git command

NEVER `cd` before a git command — use `git -C <dir>` instead to avoid permission prompts.

Why: `git status`, `git log`, `git diff`, etc. are pre-approved via `Bash(git:*)` in settings.json.
Prefixing with `cd <dir> && ...` makes the command match `Bash(cd:*)` instead, which is not
pre-approved, so every invocation triggers a permission prompt.

Rewrite:
  BAD:  cd /path/to/repo && git status
  GOOD: git -C /path/to/repo status

  BAD:  cd /path/to/repo && git log --oneline -5
  GOOD: git -C /path/to/repo log --oneline -5
EOF
  exit 2
fi

exit 0
