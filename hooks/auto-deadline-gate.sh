#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse a /loop /auto PICK once the fleet deadline has passed.
#
# WHY: /fleet-launch's deadline is what lets an operator reclaim the machine — in-flight issues
# finish, no new ones are picked. The gate is a prose step in skills/auto/SKILL.md's preflight, and
# on the 2026-08-18 fleet it lost. Session 9c0e0a3b read tmp/fleet-deadline.json on all five of its
# earlier iterations (18:53, 20:08, 21:59, 00:04, 01:53 CDT) and then, at 07:51 — 62 minutes past
# the 06:49 deadline — went straight from its preflight text to next-candidates.sh without reading
# it, picked BF-997, and shipped at 10:09. That is 3h20m of unbudgeted burn (~$180 at that run's
# rate) plus a held stack slot and worktree, on a machine the operator had asked for back. Its two
# siblings read the file and drained correctly, and human_prompts was 0, so nothing excused it.
# Per fleet-retro doctrine a rule that already existed and lost gets a mechanical guard, not more
# prose (precedents: no-blind-sleep.sh, auto-heartbeat.sh, full-continue.sh,
# linear-create-state-guard.sh).
#
# NARROW BY CONSTRUCTION — four read-only skills call next-candidates.sh legitimately and must
# never be blocked: /next (the keeper asking what is next), /auto-prep (validating candidates),
# /fleet-status and /fleet-retro (remaining runway). None of them is distinguishable from /auto's
# pick by command string — /fleet-retro Step 3 runs a byte-identical `--label specified`. So the
# discriminator is the TRANSCRIPT: this hook fires only inside a session driven by `/loop /auto`,
# recognized by the /loop command-delivery record itself (command-name /loop with /auto in its
# args, or the raw agent-spawn prompt form), in USER records only. A looser test — the substrings
# "/loop" and "/auto" anywhere in one message — is not a discriminator at all: skill bodies land in
# user records too, and the fleet-retro and auto SKILL.md bodies both discuss /loop /auto, so that
# pair classified the real retro session (aeea872a) and a targeted /auto (6f28784f) as loops when
# run against the live 2026-08-18 transcripts — blocking exactly the callers this hook must allow.
# An interactively-typed /next or /fleet-retro has no /loop delivery and sails through.
#
# A human-typed one-shot `/auto BF-123` is excluded for the same reason and deliberately: targeted
# mode skips the pick entirely, and an operator naming an issue outranks the deadline.
#
# ASYMMETRIC BY DESIGN, opposite to auto-heartbeat.sh: a false BLOCK stalls one loop iteration that
# the operator wanted stopped anyway and prints its own recovery; a false ALLOW is another
# multi-hour overrun. Where the evidence is ambiguous, block. Everything the hook cannot determine —
# no deadline file, unparseable epoch, unreadable transcript, missing jq/python — fails OPEN.

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${COMMAND:-}" ]] && exit 0

# The overwhelmingly common case is a command with nothing to do with picking. Bail before any work.
grep -q 'next-candidates' <<<"$COMMAND" || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[[ -z "${CWD:-}" ]] && CWD=$PWD

# --- 1. Is this actually an invocation, or just text mentioning the script? -------------------
# Same rule as no-blind-sleep.sh and linear-create-state-guard.sh: quoted text is DATA (a grep, a
# docs edit) unless an executor makes it code, in which case stripping quotes would be a bypass.
IS_INVOCATION=$(COMMAND="$COMMAND" python3 -c '
import os, re, sys
cmd = os.environ["COMMAND"]
EXECUTOR = r"\b(?:ba|z|k)?sh\s+-[A-Za-z]*c\b|\beval\b|\bxargs\b"
scan = cmd if re.search(EXECUTOR, cmd) else re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", " ", cmd)
sys.exit(0 if re.search(r"next-candidates\.sh(\s|$)", scan) else 1)
' 2>/dev/null; echo $?)
[[ "$IS_INVOCATION" != "0" ]] && exit 0

# --- 2. Find the deadline file ----------------------------------------------------------------
# /auto picks from the main checkout, but a resumed session's cwd can sit in a worktree, so walk up.
DEADLINE_FILE=""
probe=$CWD
for _ in 1 2 3 4 5 6 7 8; do
  [[ -z "$probe" || "$probe" == "/" ]] && break
  if [[ -f "$probe/tmp/fleet-deadline.json" ]]; then DEADLINE_FILE="$probe/tmp/fleet-deadline.json"; break; fi
  probe=$(dirname "$probe")
done
# No timed fleet in play — nothing to gate.
[[ -z "$DEADLINE_FILE" ]] && exit 0

DEADLINE_EPOCH=$(jq -r '.deadline_epoch // empty' "$DEADLINE_FILE" 2>/dev/null)
[[ -z "${DEADLINE_EPOCH:-}" ]] && exit 0
[[ "$DEADLINE_EPOCH" =~ ^[0-9]+$ ]] || exit 0

NOW=$(date +%s)
# Still inside the budget: this is exactly the pick the fleet was launched to make.
(( NOW < DEADLINE_EPOCH )) && exit 0

# --- 3. Is this an autonomous /loop /auto session? ---------------------------------------------
# The discriminator that keeps /next, /auto-prep, /fleet-status and /fleet-retro unblocked.
[[ -z "${TRANSCRIPT:-}" || ! -r "$TRANSCRIPT" ]] && exit 0

IS_AUTO_LOOP=$(TRANSCRIPT="$TRANSCRIPT" python3 -c '
import json, os, re, sys

path = os.environ["TRANSCRIPT"]
found = False
try:
    with open(path, errors="ignore") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            # USER records only. Skill bodies arrive as user records too, but they are excluded by
            # the delivery-shape match below; assistant records are skipped so a retro QUOTING a
            # loop delivery as evidence does not classify itself as the loop it is reporting on.
            if not isinstance(rec, dict) or rec.get("type") != "user":
                continue
            msg = rec.get("message") or {}
            content = msg.get("content") if isinstance(msg, dict) else None
            if isinstance(content, str):
                texts = [content]
            elif isinstance(content, list):
                texts = [b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
            else:
                continue
            for t in texts:
                # The actual /loop delivery shape, measured on session 9c0e0a3b: the harness
                # command block whose args carry /auto. The raw startswith form covers an
                # agent-spawn prompt delivered without slash parsing. A bare substring pair
                # ("/loop" and "/auto" anywhere in one text) is NOT a valid discriminator — see
                # the header for the measured false-classification of the retro and targeted
                # sessions it produced.
                if ("<command-name>/loop</command-name>" in t
                        and re.search(r"<command-args>[^<]*/auto", t)):
                    found = True
                    break
                if t.lstrip().startswith("/loop /auto"):
                    found = True
                    break
            if found:
                break
except Exception:
    sys.exit(0)   # unreadable transcript -> fail OPEN
sys.exit(1 if found else 0)
' 2>/dev/null; echo $?)

# 1 == found an /auto loop delivery. Anything else (0, or a crashed analyzer) allows.
[[ "$IS_AUTO_LOOP" != "1" ]] && exit 0

OVERRUN=$(( (NOW - DEADLINE_EPOCH) / 60 ))
HUMAN=$(date -r "$DEADLINE_EPOCH" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "epoch $DEADLINE_EPOCH")

cat >&2 <<EOF
🛑 BLOCKED: the fleet deadline passed ${OVERRUN} minute(s) ago — no new pick.

Deadline: $HUMAN   ($DEADLINE_FILE)
Command:  $COMMAND

The deadline gates PICKING, not finishing: an issue picked before it runs to completion past it by
design. But this session is under \`/loop /auto\`, the budget is spent, and ranking candidates is
the first step of taking new work.

On the 2026-08-18 fleet this exact step ran 62 minutes past the deadline and cost 3h20m of
unbudgeted burn on a machine the operator had asked back. Two sibling sessions read the deadline
file and drained correctly; this gate is what makes that outcome not depend on remembering to.

Drain instead — /auto Step 4:
  1. Record the outcome in tmp/auto-state-<runKey>.json:
       status "drained", reason "fleet deadline <time> passed; no further pick eligible"
  2. End the loop: ScheduleWakeup(stop: true)
  3. Report what shipped this run.

To run again, the operator clears the budget — delete tmp/fleet-deadline.json, or re-run
/fleet-launch with a new one. Do not work around this by picking an issue by hand.
EOF
exit 2
