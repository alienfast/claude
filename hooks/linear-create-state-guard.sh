#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse a raw `linear-cli issues create` that carries no --state.
#
# WHY: an omitted state lands the issue in the team's DEFAULT state — Triage on a triage-enabled
# team — where next-candidates.sh's WORKABLE_STATES (Backlog/Planned/Todo) cannot see it, so the
# filing is invisible to /next and /auto permanently with no warning anywhere. The prose rule
# (linear skill gotcha #21; quality-review SKILL.md's every-filing-through-the-helper rule) went
# live 2026-08-15 after three fleet filings stranded this way in one run — and the very next fleet
# (2026-08-16, rules live at launch) stranded three more (BF-1194/95/96) via the exact shape this
# hook now denies. Per fleet-retro doctrine, a rule that already existed and lost gets a mechanical
# guard, not more prose (precedents: no-blind-sleep.sh, auto-heartbeat.sh, full-continue.sh).
#
# The sanctioned path is structurally unblocked: ~/.claude/scripts/linear-create-child.sh runs its
# create inside the script, so the Bash command string this hook sees is the script invocation, not
# a `linear-cli issues create`.

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${COMMAND:-}" ]] && exit 0

# No linear-cli create at all is the overwhelmingly common case — bail before any parsing work.
grep -q 'linear-cli' <<<"$COMMAND" || exit 0
grep -q 'create' <<<"$COMMAND" || exit 0

VERDICT=$(COMMAND="$COMMAND" python3 -c '
import os, re, sys

cmd = os.environ["COMMAND"]

# Quoted text is normally DATA, and must not be read as an invocation: a
# `grep "linear-cli issues create" skills/` search must never trip this guard. But under an
# executor — `bash -c "..."`, `sh -c`, `eval`, `xargs` — the quoted text IS the code, and
# stripping it would turn the quotes into a trivial bypass. Same rule as no-blind-sleep.sh.
EXECUTOR = r"\b(?:ba|z|k)?sh\s+-[A-Za-z]*c\b|\beval\b|\bxargs\b"
scan = cmd if re.search(EXECUTOR, cmd) else re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", " ", cmd)

# `issues` has the alias `i`; both reach the same create.
if not re.search(r"\blinear-cli\s+(?:issues|i)\s+create\b", scan):
    sys.exit(0)

# Any explicit state satisfies the guard. Deliberately generous — one --state/-s anywhere in the
# command allows a multi-statement chain through: a false ALLOW costs one stranded filing caught
# at retro, a false BLOCK costs a real workflow.
if re.search(r"(^|\s)--state(\s|=)", scan) or re.search(r"(^|\s)-s(\s|=)", scan):
    sys.exit(0)

print("no --state on a raw issues create")
sys.exit(1)
' 2>/dev/null)
RC=$?

# Block ONLY on a non-zero exit that also produced a verdict — any breakage in the analyzer above
# (python missing, regex error) exits non-zero with empty stdout and must fail OPEN.
if [[ $RC -ne 0 && -n "${VERDICT:-}" ]]; then
  cat >&2 <<EOF
🛑 BLOCKED: raw \`linear-cli issues create\` with no --state

Command: $COMMAND

An omitted state lands the issue in the team's DEFAULT state — Triage on a triage-enabled team —
invisible to /next and /auto permanently with no warning anywhere (linear skill gotcha #21;
measured on two consecutive fleets, 2026-08-15 and 2026-08-16, three stranded filings each).

Use one of:
  - ~/.claude/scripts/linear-create-child.sh (parent '-' for a standalone issue) — resolves a
    Backlog-preferring state and VERIFIES every write. This is the required path for every
    skill-driven filing.
  - An explicit --state on the create. Unattended filings use --state Backlog — the human curates
    Planned (keeper ruling 2026-08-15).
EOF
  exit 2
fi

exit 0
