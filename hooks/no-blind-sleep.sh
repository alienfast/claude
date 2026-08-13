#!/usr/bin/env bash
# Claude PreToolUse(Bash) hook: refuse a shell sleep that can only wait out the clock.
#
# WHY: waiting for delegated work by holding a turn open with `sleep` is pure wall-clock burn. The
# harness re-invokes you when a backgrounded Agent finishes, and a synchronous Agent call blocks on
# its own — so a timed sleep adds nothing and cannot end early. Measured on the 2026-08-01 BF fleet
# run by `scripts/fleet-metrics.py` (re-run it to reproduce these): two of four sessions spent
# **7.5 hours** in `for i in $(seq 1 22); do sleep 25; done` windows with no exit condition — 32% and
# 55% of their own wall-clock, and 54%/81% once marker-polling is counted too. The two sessions that
# dispatched their subagents synchronously (run_in_background: false) spent 0% on either. Same work,
# same skills, same day.
#
# THE DISTINCTION THIS HOOK DRAWS is not "sleep is bad" — it is whether the wait can END EARLY:
#   - `until [ -f tmp/rspec.done ]; do sleep 20; done`  -> ALLOWED. Polls a completion marker and
#     exits the moment it lands. This is the sanctioned pattern for a detached full-suite rspec run
#     (basefund CLAUDE.md, "Detach a full-suite run ... and poll for a completion marker").
#   - `for i in $(seq 1 22); do sleep 25; done`         -> BLOCKED. No condition anywhere; it burns
#     the full 9 minutes whether the thing it waits for finished in 10 seconds or never starts.
#
# NOT /auto-SPECIFIC. This fires in interactive sessions too, and it should: a human watching a
# session sleep through a 9-minute window it cannot exit early is the same waste, only more visible.
# The routing rule it enforces is in ~/.claude/CLAUDE.md ("Waiting on delegated work").
#
# THRESHOLD: only blind waits of >= 120s total. A short `sleep 2` to let a file settle, a retry
# backoff, a brief debounce — all untouched. The floor exists so this hook only ever argues with
# waits long enough to matter.

set -uo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "${COMMAND:-}" ]] && exit 0

# No sleep at all is the overwhelmingly common case — bail before doing any parsing work.
grep -qE '(^|[^[:alnum:]_-])sleep[[:space:]]+[0-9]' <<<"$COMMAND" || exit 0

VERDICT=$(COMMAND="$COMMAND" python3 -c '
import os, re, sys

cmd = os.environ["COMMAND"]

# Quoted text is normally DATA, and must not be read as control flow: the real 95180db1 command
# ended `; echo "wait window elapsed"`, and since the bare `wait` builtin is an exit condition, that
# echo string alone made the worst offender in the whole run look condition-bounded.
#
# But under an executor — `bash -c "..."`, `sh -c`, `eval` — the quoted text IS the code, and
# stripping it would hide the whole command from this guard, turning the quotes into a trivial
# bypass. So strip only when nothing is going to execute the string.
EXECUTOR = r"\b(?:ba|z|k)?sh\s+-[A-Za-z]*c\b|\beval\b|\bxargs\b"
scan = cmd if re.search(EXECUTOR, cmd) else re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", " ", cmd)

# An early-exit construct anywhere in the command means the wait is condition-bounded, not blind.
# Deliberately generous: a false ALLOW costs one slow command, a false BLOCK costs a real workflow.
EARLY_EXIT = (
    r"until\s",            # until <cond>; do sleep
    r"\bbreak\b",          # explicit loop exit
    r"\bif\s",             # guarded body, typically `if [ -f marker ]; then break; fi`
    r"\[\s*-[efsdrz]\s",   # file/dir/size tests
    r"\btest\s+-[efsdrz]\b",
    r"grep\s+(-[A-Za-z]*\s+)*-[A-Za-z]*q",  # grep -q / grep -sq etc.
    r"\bpgrep\b",
    # `wait` only as a command word — anchored to a statement boundary so it cannot be matched by
    # the word appearing anywhere else that survived the quote strip.
    r"(^|[;&|\n]|\bdo\s|\bthen\s)\s*wait\b",
    r"\bcurl\b", r"\bnc\s", r"\bgh\s+run\s+watch\b",
)
for pat in EARLY_EXIT:
    if re.search(pat, scan):
        sys.exit(0)

# Every read below is against `scan`, not `cmd`: a sleep inside a string literal is text, not a
# command — `grep -rn "sleep 300" docs/` must not be read as a five-minute wait.
sleeps = [float(m) for m in re.findall(r"(?:^|[^A-Za-z0-9_-])sleep\s+([0-9]+(?:\.[0-9]+)?)", scan)]
if not sleeps:
    sys.exit(0)

# Unbounded spin: `while true`/`while :` around a sleep with no exit test (those were ruled out above).
if re.search(r"while\s+(true|:)\s*;?\s*do", scan):
    print("unbounded (while true) with no exit condition")
    sys.exit(1)

# Loop multiplier: `seq [a] b`, an explicit word list, or a C-style `for ((i=0;i<N;i++))`.
mult = 1
m = re.search(r"seq\s+(-?[0-9]+)(?:\s+(-?[0-9]+))?(?:\s+(-?[0-9]+))?", scan)
if m:
    nums = [int(g) for g in m.groups() if g is not None]
    if len(nums) == 1:
        mult = max(nums[0], 1)
    elif len(nums) == 2:
        mult = max(nums[1] - nums[0] + 1, 1)
    else:
        step = nums[1] if nums[1] else 1
        mult = max((nums[2] - nums[0]) // step + 1, 1)
else:
    m = re.search(r"for\s*\(\(\s*\w+\s*=\s*(-?[0-9]+)\s*;\s*\w+\s*<=?\s*(-?[0-9]+)", scan)
    if m:
        mult = max(int(m.group(2)) - int(m.group(1)) + 1, 1)
    else:
        m = re.search(r"for\s+\w+\s+in\s+([0-9]+(?:\s+[0-9]+)+)\s*;?\s*do", scan)
        if m:
            mult = len(m.group(1).split())

total = max(sleeps) * mult if mult > 1 else sum(sleeps)

# A `timeout N` wrapper is a real bound: the command cannot outlast it however the loop is written,
# so cap the computed wait at N rather than reading the inner sleep literally. Without this,
# `timeout 3 bash -c "sleep 300"` — a legitimate 3-second probe — reads as a 5-minute blind wait.
m = re.search(r"\btimeout\s+(?:-k\s+[0-9]+[smhd]?\s+)?(?:--?\S+\s+)*([0-9]+(?:\.[0-9]+)?)([smhd]?)\b", scan)
if m:
    cap = float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
    total = min(total, cap)

if total >= 120:
    print(f"{total:.0f}s of unconditional sleep ({mult} x {max(sleeps):.0f}s)" if mult > 1
          else f"{total:.0f}s of unconditional sleep")
    sys.exit(1)
sys.exit(0)
' 2>/dev/null)
RC=$?

# Block ONLY on a non-zero exit that also produced a verdict. A python that failed to start, or any
# future breakage in the analyzer above, exits non-zero with empty stdout — and must fail OPEN. A
# guard that blocks every Bash call containing the word sleep because its own interpreter broke is a
# far worse outcome than the waste it was written to prevent.
if [[ $RC -ne 0 && -n "${VERDICT:-}" ]]; then
  cat >&2 <<EOF
🛑 BLOCKED: blind sleep — $VERDICT

Command: $COMMAND

This wait has no exit condition, so it burns its full duration no matter when the thing it is waiting for
finishes. Measured on a real fleet run: 7.5 hours lost to exactly this shape in two sessions
(scripts/fleet-metrics.py reproduces it).

Use whichever of these fits:
  - Need a subagent's result before you can continue? If your Agent tool exposes run_in_background, dispatch
    with false — the call blocks and returns the result, no waiting to write at all. If it does not, the
    dispatch backgrounds regardless and the next bullet is your answer, not this one.
  - Dispatched work in the BACKGROUND? End your turn. The harness re-invokes you when it completes;
    sleeping to stay alive is what this hook exists to stop.
  - Genuinely polling something the harness cannot see (a detached test run, CI, a remote queue)? Poll a
    completion MARKER so the wait can end early:
        n=0; until [ -f tmp/run.done ] || [ \$n -ge 60 ]; do sleep 10; n=\$((n+1)); done
  - Pacing a self-paced /loop? That is ScheduleWakeup's job, not sleep's.
EOF
  exit 2
fi

exit 0
