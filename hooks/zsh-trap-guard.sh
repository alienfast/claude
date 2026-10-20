#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse the bash-only idioms that fail silently under the zsh tool shell.
#
# WHY: every Bash tool call runs zsh. `${PIPESTATUS[0]}` expands to nothing, `status=` dies on a read-only variable
# after the captured command already ran, `path=` / `for path in` replace the command search path, `${var,,}` aborts the
# call, and `$tag:apps/x` is a history modifier. Each prints a plausible result and exits 0, so the model reads a failure
# as a clean answer. standards/shell.md carries the mechanics; this hook makes the deterministic ones impossible to send.
#
# Skips: a string handed to bash (`bash -c …`, `bash file.sh`), where bash idioms are correct, and anything in single
# quotes, which zsh never expands. Fails OPEN if the analyzer cannot run.
#
# Run ./zsh-trap-guard.test.sh after ANY change.

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${COMMAND:-}" ]] && exit 0

# Cheap pre-filter: none of the trap tokens present → nothing to analyze.
grep -qE 'PIPESTATUS|status|path|,,\}|\^\^\}|\$[A-Za-z_][A-Za-z0-9_]*:[aAcehlPqQrstu]' <<<"$COMMAND" || exit 0

VERDICT=$(COMMAND="$COMMAND" python3 -c '
import os, re, sys

cmd = os.environ["COMMAND"]

# bash executes these strings and files itself, so bash idioms are correct inside them.
if re.search(r"(^|[;&|\s])bash\s+(-[A-Za-z]*\s+)*(-c\b|\S+\.sh\b)", cmd):
    sys.exit(0)

scan = re.sub(r"\x27[^\x27]*\x27", " ", cmd)  # single-quoted text is literal in zsh

ASSIGN = r"(^|[;&|(\s])(local\s+|typeset\s+|declare\s+|export\s+)?"
checks = (
    (r"(?<!\\)\$\{PIPESTATUS\b",
     "${PIPESTATUS[..]} is empty in zsh",
     "use ${pipestatus[1]} (lowercase, 1-indexed), set -o pipefail, or redirect to a file and echo \"EXIT=$?\""),
    (r"(?<!\\)\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?(,,|\^\^)\}",
     "${var,,} / ${var^^} is a bad substitution in zsh and aborts the whole call",
     "use ${var:l} / ${var:u}"),
    (ASSIGN + r"status\+?=",
     "status is a read-only synonym for $? in zsh; the assignment aborts the call AFTER the captured command ran",
     "use rc=$?"),
    (ASSIGN + r"(path|cdpath|fpath|manpath)\+?=",
     "path/cdpath/fpath/manpath are tied to PATH in zsh; assigning one replaces the command search path",
     "name the variable p, file or dir"),
    (r"\bfor\s+(path|cdpath|fpath|manpath)\s+in\b",
     "for path in … replaces PATH for the rest of the shell",
     "loop over p or file instead"),
    (r"\bread\s+(-[A-Za-z]+\s+)*([A-Za-z_][A-Za-z0-9_]*\s+)*(path|cdpath|fpath|manpath)(\s|$)",
     "read … path assigns PATH",
     "read into p or file instead"),
    (r"(?<![\\$])\$[A-Za-z_][A-Za-z0-9_]*:[aAcehlPqQrstu]",
     "$var: followed by a modifier letter is a zsh modifier, quoted or not (git rev:path is the usual victim)",
     "brace the name: ${var}:path"),
)
for pat, what, fix in checks:
    if re.search(pat, scan):
        print(f"{what}\n  fix: {fix}")
        sys.exit(1)
sys.exit(0)
' 2>/dev/null)
RC=$?

# Block ONLY on a non-zero exit that also produced a verdict: an analyzer that failed to start must fail OPEN.
if [[ $RC -ne 0 && -n "${VERDICT:-}" ]]; then
  cat >&2 <<EOF
🛑 BLOCKED: zsh trap — $VERDICT

Command: $COMMAND

The tool shell is zsh, and this idiom fails silently there: a wrong exit code or an empty value reads as success.
Mechanics for every trap: ~/.claude/standards/shell.md.
EOF
  exit 2
fi

exit 0
