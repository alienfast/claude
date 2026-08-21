#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse `finish-detect-mode.sh pr` in an UNATTENDED run whose
# originating invocation never carried a `pr` token.
#
# WHY: `/auto`'s worktree default is merge, and `pr` is opt-in. Three times a session added `pr`
# on its own judgment — JA-390 (2026-08-19, `/full auto wt pr` from a bare `/loop /auto`), JA-367
# (2026-08-20, dispatched `auto JA-367 merge` then ran mode detection with `pr`), and JA-415
# (2026-08-20, `/auto ja-415` -> `Skill(full,"auto wt pr JA-415")`). Each cited the same false
# evidence: "every recent issue shipped via PR." That history is a product of the INTERACTIVE
# convention, so the reasoning is circular — the run reads its own prior output back as proof.
#
# The cost is not cosmetic: in pr mode the source branch does not advance until the PR merges, so
# the next issue forks without its predecessor's code; `In Review` is a `started`-type state, so
# `blocks` edges never release and dependents stay invisible to /next and /auto; and SHIPPED-PR
# leaves the worktree behind.
#
# Prose already lost here once — jarvis CLAUDE.md 448ad05 stated the rule and JA-415 drifted hours
# later, because a worktree session reads a CLAUDE.md snapshot predating the fix, keys a separate
# memory namespace, and carries its own PR precedent through compaction. Per fleet-retro doctrine,
# a rule that already existed and lost gets a mechanical guard, not more prose (precedents:
# linear-create-state-guard.sh, no-blind-sleep.sh, auto-heartbeat.sh, full-continue.sh).
#
# SCOPE — interactive flows are deliberately untouched. The guard fires only when an `auto` token
# is in the dispatch chain, so a hand-typed `/finish pr`, and a bare `/finish` that means pr by a
# project's own convention, both pass. `/loop /auto pr` passes too: the user typed the token.

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${COMMAND:-}" ]] && exit 0

# The overwhelming majority of Bash calls are not mode detection — bail before any parsing work.
grep -q 'finish-detect-mode' <<<"$COMMAND" || exit 0

TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

VERDICT=$(COMMAND="$COMMAND" TRANSCRIPT="${TRANSCRIPT_PATH:-}" python3 -c '
import json, os, re, sys

cmd = os.environ["COMMAND"]

# Quoted text is normally DATA and must not be read as an invocation, so a `grep
# "finish-detect-mode.sh pr" skills/` never trips this guard. But under an executor the quoted text
# IS the code, and stripping it would be a trivial bypass. Same rule as linear-create-state-guard.sh.
EXECUTOR = r"\b(?:ba|z|k)?sh\s+-[A-Za-z]*c\b|\beval\b|\bxargs\b"
scan = cmd if re.search(EXECUTOR, cmd) else re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", " ", cmd)

# Only a real invocation carrying a pr argument. Stop the arg capture at a statement boundary so a
# later `; echo pr` cannot manufacture a match.
m = re.search(r"finish-detect-mode\.sh([^;&|\n]*)", scan)
if not m:
    sys.exit(0)

# Token boundaries must treat a QUOTE as a delimiter: under `bash -c "... pr"` the argument ends
# at the closing quote, and a whitespace-anchored match would sail straight past it. Excluding
# only [\w-] keeps `pr-deploy` and `autocompact` from counting as the bare tokens.
PR = re.compile(r"(?<![\w-])pr(?![\w-])", re.I)
AUTO = re.compile(r"(?<![\w-])auto(?![\w-])", re.I)

if not PR.search(m.group(1)):
    sys.exit(0)

tp = os.environ.get("TRANSCRIPT", "")
if not tp or not os.path.isfile(tp):
    sys.exit(0)                      # fail OPEN: cannot read intent

try:
    data = open(tp, "rb").read()
except Exception:
    sys.exit(0)                      # fail OPEN
if len(data) > 64 * 1024 * 1024:
    data = data[-64 * 1024 * 1024:]
lines = data.split(b"\n")

CMDNAME = re.compile(rb"<command-name>/?([A-Za-z-]+)</command-name>")
CMDARGS = re.compile(rb"<command-args>(.*?)</command-args>", re.S)
WANT = ("auto", "full", "finish", "loop")

# Walk backwards to the most recent GENUINE slash-command invocation. A real one is a user entry
# whose message content is a plain STRING opening with <command-message>; a tool_result that merely
# echoes transcript text (this hook has been developed in exactly such a session) carries a LIST
# content and is skipped, so transcript-analysis work cannot spoof intent.
idx, name, args = -1, None, ""
for i in range(len(lines) - 1, -1, -1):
    mm = CMDNAME.search(lines[i])
    if not mm or mm.group(1).decode().lower() not in WANT:
        continue
    try:
        d = json.loads(lines[i])
    except Exception:
        continue
    if d.get("type") != "user":
        continue
    content = (d.get("message") or {}).get("content")
    if not isinstance(content, str) or not content.lstrip().startswith("<command-message>"):
        continue
    idx = i
    name = mm.group(1).decode().lower()
    am = CMDARGS.search(lines[i])
    args = am.group(1).decode("utf-8", "replace") if am else ""
    break

if idx < 0:
    sys.exit(0)                      # fail OPEN: no invocation found (compaction, odd shape)

user_pr = bool(PR.search(args))

# Unattended when the invocation itself is /auto, names auto among its args, or is a /loop wrapping
# one; failing those, when any skill dispatched SINCE that invocation carried an auto token.
chain_auto = name == "auto" or bool(AUTO.search(args)) or (name == "loop" and "auto" in args.lower())
if not chain_auto:
    SKILLARGS = re.compile(rb"\"name\"\s*:\s*\"Skill\".*?\"args\"\s*:\s*\"([^\"]*)\"", re.S)
    for ln in lines[idx + 1:]:
        if any(AUTO.search(g.decode("utf-8", "replace")) for g in SKILLARGS.findall(ln)):
            chain_auto = True
            break

if chain_auto and not user_pr:
    print("/%s %s" % (name, args.strip()))
    sys.exit(1)
sys.exit(0)
' 2>/dev/null)
RC=$?

# Block ONLY on a non-zero exit that also produced a verdict — any breakage in the analyzer above
# (python missing, regex error, unreadable transcript) exits non-zero with empty stdout and must
# fail OPEN. A false ALLOW costs one PR to close; a false BLOCK breaks a real ship mid-flight.
if [[ $RC -ne 0 && -n "${VERDICT:-}" ]]; then
  cat >&2 <<EOF
🛑 BLOCKED: \`pr\` was injected into an unattended run

Command:    $COMMAND
Invocation: $VERDICT

This run is unattended (an \`auto\` token is in the dispatch chain) and its invocation carried no
\`pr\` token, so the flow is MERGE. Passing \`pr\` here is a flow the user never asked for.

If you were about to justify pr with "every recent issue shipped via PR" — that history is a
product of the INTERACTIVE convention and is not evidence about this run. Three issues drifted on
exactly that reasoning (JA-390, JA-367, JA-415).

Do instead:
  - Run \`finish-detect-mode.sh merge\` (or with no action token — it defaults to merge inside a
    /start wt worktree).
  - If a PR genuinely is wanted, the user asks for it: /auto pr <ISSUE-ID>, or /loop /auto pr.
EOF
  exit 2
fi

exit 0
