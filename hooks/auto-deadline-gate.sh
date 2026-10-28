#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse a /loop /auto PICK once its fleet's deadline has passed.
#
# WHY: /fleet-launch's deadline is what lets an operator reclaim the machine — in-flight issues
# finish, no new ones are picked. The gate is a prose step in skills/auto/SKILL.md's preflight, and
# on the 2026-08-18 fleet it lost. Session 9c0e0a3b read the fleet marker on all five of its
# earlier iterations (18:53, 20:08, 21:59, 00:04, 01:53 CDT) and then, at 07:51 — 62 minutes past
# the 06:49 deadline — went straight from its preflight text to next-candidates.sh without reading
# it, picked BF-997, and shipped at 10:09. That is 3h20m of unbudgeted burn (~$180 at that run's
# rate) plus a held stack slot and worktree, on a machine the operator had asked for back. Its two
# siblings read the file and drained correctly, and human_prompts was 0, so nothing excused it.
# Per fleet-retro doctrine a rule that already existed and lost gets a mechanical guard, not more
# prose (precedents: no-blind-sleep.sh, auto-heartbeat.sh, full-continue.sh,
# linear-create-state-guard.sh).
#
# WHICH FLEET: several fleets run side by side in one checkout, each with its own marker
# <main-checkout>/tmp/fleet-deadline-<slug>.json (lib/fleet-markers.sh — the slug is the lowercased
# epic id of an epic-scoped fleet, `team` for a team-wide one). A session belongs to the fleet its
# own /loop /auto arguments name — `epic:<ID>` or none — so the slug is read from the same delivery
# record that identifies the session as a loop, and only that fleet's marker gates it. A team
# fleet's deadline never ends an epic fleet's session, and an archived marker
# (fleet-deadline-<slug>.<epoch>.json, an ended run a later launch displaced) gates nobody.
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
# no marker for the session's fleet, unparseable epoch, unreadable transcript, missing jq/python —
# fails OPEN.

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

# --- 2. Is any fleet marker in play? ------------------------------------------------------------
# /auto picks from the main checkout, but a resumed session's cwd can sit in a worktree, so walk up
# to the checkout whose tmp/ holds a live marker. None → no fleet here, nothing to gate.
CHECKOUT=""
probe=$CWD
for _ in 1 2 3 4 5 6 7 8; do
  [[ -z "$probe" || "$probe" == "/" ]] && break
  for f in "$probe"/tmp/fleet-deadline-*.json; do
    if [[ -f "$f" ]]; then CHECKOUT=$probe; break; fi
  done
  [[ -n "$CHECKOUT" ]] && break
  probe=$(dirname "$probe")
done
[[ -z "$CHECKOUT" ]] && exit 0

# --- 3. Is this an autonomous /loop /auto session, and of which fleet? ---------------------------
# The discriminator that keeps /next, /auto-prep, /fleet-status and /fleet-retro unblocked, and the
# slug of the fleet this session belongs to. Prints the slug (`team`, or the lowercased epic id the
# delivery's `epic:<ID>` names), or nothing when the transcript is not a loop's.
[[ -z "${TRANSCRIPT:-}" || ! -r "$TRANSCRIPT" ]] && exit 0

SLUG=$(TRANSCRIPT="$TRANSCRIPT" python3 -c '
import json, os, re, sys

path = os.environ["TRANSCRIPT"]
slug = ""

def slug_of(args):
    m = re.search(r"epic:([A-Za-z][A-Za-z0-9]*-[0-9]+)", args or "")
    return m.group(1).lower() if m else "team"

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
                if "<command-name>/loop</command-name>" in t:
                    m = re.search(r"<command-args>([^<]*/auto[^<]*)</command-args>", t)
                    if m:
                        slug = slug_of(m.group(1))
                        break
                if t.lstrip().startswith("/loop /auto"):
                    slug = slug_of(t)
                    break
            if slug:
                break
except Exception:
    sys.exit(0)   # unreadable transcript -> prints nothing -> fail OPEN
print(slug)
' 2>/dev/null) || SLUG=""
[[ -z "${SLUG:-}" ]] && exit 0

# Only this session's own fleet gates it. No marker for that slug (another fleet's marker was what
# step 2 found) is no budget at all.
DEADLINE_FILE="$CHECKOUT/tmp/fleet-deadline-$SLUG.json"
[[ -f "$DEADLINE_FILE" ]] || exit 0

NOW=$(date +%s)
DEADLINE_EPOCH=$(jq -r '.deadline_epoch // empty' "$DEADLINE_FILE" 2>/dev/null)
PAST_DEADLINE=0
if [[ "$DEADLINE_EPOCH" =~ ^[0-9]+$ ]] && (( NOW >= DEADLINE_EPOCH )); then PAST_DEADLINE=1; fi

# A session the launch marked `retiring` (carried out of a wound-down marker by a relaunch) treats the deadline as passed whatever
# deadline_epoch says — the relaunch moved it for everyone. Its run key is the first 8 characters of the session id (the ledger
# key); a key that cannot be determined fails OPEN.
RETIRING=0
RUN_KEY=""
RETIRING_KEYS=$(jq -r '(.retiring // [])[]' "$DEADLINE_FILE" 2>/dev/null || true)
if [[ -n "$RETIRING_KEYS" ]]; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  [[ -z "${SESSION_ID:-}" && -n "${TRANSCRIPT:-}" ]] && SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
  RUN_KEY=${SESSION_ID:0:8}
  if [[ "$RUN_KEY" =~ ^[0-9a-f]{8}$ ]] && grep -qxF -- "$RUN_KEY" <<<"$RETIRING_KEYS"; then RETIRING=1; fi
fi

# Still inside the budget and not retiring (or no budget at all): this is exactly the pick the fleet was launched to make.
(( PAST_DEADLINE == 0 && RETIRING == 0 )) && exit 0

MARKER_NAME="tmp/$(basename "$DEADLINE_FILE")"
if (( PAST_DEADLINE )); then
  OVERRUN=$(( (NOW - DEADLINE_EPOCH) / 60 ))
  HUMAN=$(date -r "$DEADLINE_EPOCH" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "epoch $DEADLINE_EPOCH")
  HEADLINE="the fleet deadline passed ${OVERRUN} minute(s) ago"
  DEADLINE_LINE="Deadline: $HUMAN   ($DEADLINE_FILE)"
  RETIRING_NOTE=""
else
  HEADLINE="this session ($RUN_KEY) is retiring"
  DEADLINE_LINE="Retiring: $RUN_KEY is in the retiring list of $DEADLINE_FILE"
  RETIRING_NOTE="A relaunch carried this session out of a wound-down fleet; the relaunch's later deadline is not its budget.
"
fi

cat >&2 <<EOF
🛑 BLOCKED: ${HEADLINE} — no new pick.

$DEADLINE_LINE
Command:  $COMMAND

The deadline gates PICKING, not finishing: an issue picked before it runs to completion past it by
design. But this session is under \`/loop /auto\` (fleet $SLUG), the budget is spent, and ranking
candidates is the first step of taking new work.
${RETIRING_NOTE}
On the 2026-08-18 fleet this exact step ran 62 minutes past the deadline and cost 3h20m of
unbudgeted burn on a machine the operator had asked back. Two sibling sessions read the deadline
file and drained correctly; this gate is what makes that outcome not depend on remembering to.

Push first, if the project grants it — the wind-down half of /auto Step 2's lazy push:
  0. Run ~/.claude/scripts/auto-push-main.sh from the main checkout. Under AUTO_PUSH_MAIN=lazy (the
     project's .claude/settings.json) it pushes main fast-forward only and prints one line; elsewhere
     the line is DISABLED and nothing moves. Either way origin then does not lag Linear overnight —
     on the 2026-09-18 BFP fleet, 16 unpushed merges gated the one pickable issue for the whole run.

Drain instead — /auto Step 4:
  1. Record the outcome in tmp/auto-state-<runKey>.json:
       status "drained", reason "fleet deadline <time> passed; no further pick eligible"
       (retiring: reason "retired by a relaunch over a wound-down fleet; no further pick eligible")
  2. End the loop: ScheduleWakeup(stop: true)
  3. Report what shipped this run.

To run again, the operator clears the budget — delete $MARKER_NAME, or re-run /fleet-launch for
this fleet with a new one (a retiring session also needs its tmp/auto-state-<runKey>.json deleted
and a fresh /loop /auto). Do not work around this by picking an issue by hand.
EOF
exit 2
