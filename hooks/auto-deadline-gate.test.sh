#!/usr/bin/env bash
# Regression harness for auto-deadline-gate.sh. Builds a throwaway checkout with a real-shaped
# tmp/fleet-deadline.json and real-shaped transcripts, then asserts BLOCK/ALLOW.
#
# EVERY FIXTURE IS SNAPSHOTTED FROM A LIVE FEED, not written from memory — the auto-stall-watch
# lesson (a hand-written agent-list fixture kept its suite green through 371 ticks of a watcher
# that matched zero live rows). Snapshotted 2026-08-19 from the basefund fleet:
#
#   /loop /auto delivery   session 9c0e0a3b — the session this hook exists because of
#   /fleet-retro delivery  session aeea872a — the retro that found it, which runs
#                          next-candidates.sh itself and MUST NOT be blocked
#   targeted /auto         session 6f28784f — human-typed `/auto BF-1266`
#   fleet-deadline.json    tmp/fleet-deadline.json as /fleet-launch writes it
#
# Command deliveries are {"type":"user","message":{"content":"<string>"}} — a plain STRING — while
# the SKILL BODY the invocation loads lands in the NEXT user record as a block array
# ([{"type":"text","text":...}]); both shapes are reproduced here, measured on all three sessions.
# The skill-body records are the load-bearing half of the ALLOW fixtures: fleet-retro's and auto's
# SKILL.md bodies both discuss `/loop /auto`, so a substring discriminator classified the real
# retro and targeted sessions as loops (the v1 bug — its fixtures had snapshotted only the
# command-delivery record). The bodies are read from ../skills/ at test time so the fixtures track
# the live text instead of freezing a copy that drifts.
#
# The ALLOW half matters more than the BLOCK half here: four read-only skills (/next, /auto-prep,
# /fleet-status, /fleet-retro) call next-candidates.sh with command strings byte-identical to
# /auto's pick, and blocking any of them would break a workflow to fix a compliance slip.
#
# GROW THIS SUITE, NEVER PRUNE IT — same contract as its hook siblings.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

TMPROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPROOT"' EXIT

CHECKOUT="$TMPROOT/basefund"
mkdir -p "$CHECKOUT/tmp" "$CHECKOUT/.claude/worktrees/bf-997" "$TMPROOT/transcripts"

PAST=$(( $(date +%s) - 3600 ))     # deadline an hour ago
FUTURE=$(( $(date +%s) + 3600 ))   # an hour of budget left

# Real shape, from /fleet-launch (count/launch_epoch carried verbatim from the 2026-08-18 run).
write_deadline() { # epoch
  cat > "$CHECKOUT/tmp/fleet-deadline.json" <<EOF
{
  "deadline_epoch": $1,
  "deadline": "2026-08-19 06:49 CDT",
  "count": 3,
  "launch_epoch": 1787096997
}
EOF
}

# --- transcript fixtures (real records, one JSON object per line) ------------------------------
skill_body_record() { # skill-name — the block-array user record a skill invocation appends
  python3 - "$1" <<'PY'
import json, pathlib, sys
name = sys.argv[1]
body = ("Base directory for this skill: ~/.claude/skills/" + name + "\n\n"
        + pathlib.Path("../skills/" + name + "/SKILL.md").read_text())
print(json.dumps({"type": "user",
                  "message": {"role": "user",
                              "content": [{"type": "text", "text": body}]}}))
PY
}

LOOP_AUTO="$TMPROOT/transcripts/loop-auto.jsonl"
python3 - "$LOOP_AUTO" <<'PY'
import json, sys
rows = [
  {"type":"user","message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/auto</command-args>"}},
  {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Main checkout clean. Picking the next certified issue."}]}},
]
with open(sys.argv[1], "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY
skill_body_record auto >> "$LOOP_AUTO"

# The record after the delivery is the fleet-retro SKILL.md body, which discusses /loop /auto —
# the exact text that made the v1 substring discriminator classify the real retro as a loop.
RETRO="$TMPROOT/transcripts/fleet-retro.jsonl"
python3 - "$RETRO" <<'PY'
import json, sys
rows = [
  {"type":"user","message":{"role":"user","content":"<command-message>fleet-retro</command-message>\n<command-name>/fleet-retro</command-name>"}},
]
with open(sys.argv[1], "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY
skill_body_record fleet-retro >> "$RETRO"
python3 - "$RETRO" <<'PY'
import json, sys
rows = [
  {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Step 3 - remaining certified pool."}]}},
]
with open(sys.argv[1], "a") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY

# A retro that quotes a /loop delivery verbatim as evidence, in ASSISTANT text — the delivery
# shape appears in the transcript without this session being a loop.
RETRO_QUOTING="$TMPROOT/transcripts/fleet-retro-quoting.jsonl"
cp "$RETRO" "$RETRO_QUOTING"
python3 - "$RETRO_QUOTING" <<'PY'
import json, sys
quote = ("Session 9c0e0a3b started with the delivery:\n"
         "<command-name>/loop</command-name>\n<command-args>/auto</command-args>\n"
         "and then skipped the deadline gate at 07:51.")
with open(sys.argv[1], "a") as fh:
    fh.write(json.dumps({"type":"assistant","message":{"role":"assistant",
             "content":[{"type":"text","text":quote}]}}) + "\n")
PY

TARGETED="$TMPROOT/transcripts/targeted-auto.jsonl"
python3 - "$TARGETED" <<'PY'
import json, sys
rows = [
  {"type":"user","message":{"role":"user","content":"<command-message>auto</command-message>\n<command-name>/auto</command-name>\n<command-args>BF-1266</command-args>"}},
]
with open(sys.argv[1], "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY
skill_body_record auto >> "$TARGETED"

# The raw agent-spawn prompt form: /loop /auto delivered as plain text, no command blocks.
RAW_SPAWN="$TMPROOT/transcripts/raw-spawn.jsonl"
python3 - "$RAW_SPAWN" <<'PY'
import json, sys
rows = [
  {"type":"user","message":{"role":"user","content":"/loop /auto"}},
]
with open(sys.argv[1], "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY

CORRUPT="$TMPROOT/transcripts/corrupt.jsonl"
printf 'not json at all\n{"type":"user"\n' > "$CORRUPT"

PASS=0
FAIL=0

t() { # want desc command transcript cwd
  local want="$1" desc="$2" cmd="$3" tr="$4" cwd="$5" out rc got
  out=$(jq -n --arg c "$cmd" --arg t "$tr" --arg w "$cwd" \
        '{tool_input:{command:$c}, transcript_path:$t, cwd:$w}' | ./auto-deadline-gate.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

echo "auto-deadline-gate.sh —"

write_deadline "$PAST"
echo "  must BLOCK (deadline passed, session under /loop /auto):"
# Case 1 is verbatim what 9c0e0a3b ran at 07:51 CDT, 62 min past the deadline.
t BLOCK "1 real 2026-08-18 overrun shape" \
  '~/.claude/scripts/next-candidates.sh --label specified 2>&1 | head -60' "$LOOP_AUTO" "$CHECKOUT"
t BLOCK "2 with an explicit --team" \
  '~/.claude/scripts/next-candidates.sh --team BF --label specified' "$LOOP_AUTO" "$CHECKOUT"
t BLOCK "3 bare relative invocation" \
  'next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"
t BLOCK "4 quotes are not a bypass under bash -c" \
  'bash -c "~/.claude/scripts/next-candidates.sh --label specified"' "$LOOP_AUTO" "$CHECKOUT"
t BLOCK "5 cwd inside a worktree still finds the checkout deadline" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT/.claude/worktrees/bf-997"
t BLOCK "6 raw agent-spawn prompt form, no command blocks" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$RAW_SPAWN" "$CHECKOUT"

echo "  must ALLOW (the four read-only callers, and every fail-open path):"
# Cases 7 and 9 carry the skill-body records whose /loop /auto prose broke the v1 discriminator.
t ALLOW "7 /fleet-retro Step 3 — byte-identical command, interactive session" \
  '~/.claude/scripts/next-candidates.sh --team BF --label specified' "$RETRO" "$CHECKOUT"
t ALLOW "8 /fleet-retro quoting a /loop delivery as evidence in assistant text" \
  '~/.claude/scripts/next-candidates.sh --team BF --label specified' "$RETRO_QUOTING" "$CHECKOUT"
t ALLOW "9 targeted /auto BF-1266 — operator named the issue" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$TARGETED" "$CHECKOUT"
t ALLOW "10 grep for the script is data, not an invocation" \
  'grep -rn "next-candidates.sh" ~/.claude/skills/' "$LOOP_AUTO" "$CHECKOUT"
t ALLOW "11 unrelated command mentioning nothing" \
  'git status --short' "$LOOP_AUTO" "$CHECKOUT"
t ALLOW "12 unreadable transcript fails OPEN" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$TMPROOT/does-not-exist.jsonl" "$CHECKOUT"
t ALLOW "13 corrupt transcript fails OPEN" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$CORRUPT" "$CHECKOUT"

echo "  must ALLOW (budget not spent):"
write_deadline "$FUTURE"
t ALLOW "14 in-budget pick is exactly what the fleet is for" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"

echo "  must ALLOW (no gate in play):"
rm -f "$CHECKOUT/tmp/fleet-deadline.json"
t ALLOW "15 no deadline file — untimed run" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"
echo '{"count":3}' > "$CHECKOUT/tmp/fleet-deadline.json"
t ALLOW "16 deadline file with no epoch fails OPEN" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"
echo '{"deadline_epoch":"soon"}' > "$CHECKOUT/tmp/fleet-deadline.json"
t ALLOW "17 non-numeric epoch fails OPEN" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"
printf 'not json\n' > "$CHECKOUT/tmp/fleet-deadline.json"
t ALLOW "18 unparseable deadline file fails OPEN" \
  '~/.claude/scripts/next-candidates.sh --label specified' "$LOOP_AUTO" "$CHECKOUT"

# --- retiring sessions (fleet-launch.sh marks sessions carried out of a wound-down marker) -------
# The marker is the key set of the live basefund tmp/fleet-deadline.json (2026-10-11), plus `retiring`; the hook input carries
# session_id, which is the ledger key's full form (b2bb1003 is the session whose leg-1 token outlived its fleet's deadline).
RETIRING_SID="b2bb1003-5683-4b0d-8b3d-b1201abbdc38"
SIBLING_SID="1cc250ad-ee0f-493c-b8d0-47b3acf10a52"
write_live_marker() { # <deadline-epoch | none> <retiring-json-array>
  jq -n --arg d "$1" --argjson r "$2" '{count: 3, launch_epoch: 1791601120,
      fleet_sessions: ["1492b0e1","1cc250ad","3b566c2a","8c16860d","b2bb1003"]}
    + (if $d == "none" then {} else {deadline_epoch: ($d | tonumber), deadline: "2026-10-11 06:09 CDT"} end)
    + (if ($r | length) > 0 then {retiring: $r} else {} end)' > "$CHECKOUT/tmp/fleet-deadline.json"
}
ts() { # want desc session-id transcript [message-needle]
  local want="$1" desc="$2" sid="$3" tr="$4" needle="${5:-}" out rc got
  out=$(jq -n --arg c '~/.claude/scripts/next-candidates.sh --label specified' --arg t "$tr" --arg w "$CHECKOUT" --arg s "$sid" \
        '{tool_input:{command:$c}, transcript_path:$t, cwd:$w} + (if $s == "" then {} else {session_id:$s} end)' | ./auto-deadline-gate.sh 2>&1)
  rc=$?
  got=$([[ $rc -eq 2 ]] && echo BLOCK || echo ALLOW)
  if [[ "$got" == "$want" ]] && { [[ -z "$needle" ]] || grep -qF -- "$needle" <<<"$out"; }; then
    PASS=$((PASS + 1)); printf '  ok   %-6s %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL want=%s got=%s  %s\n       %s\n' "$want" "$got" "$desc" "$(head -1 <<<"$out")"
  fi
}

echo "  must BLOCK (retiring session, whatever the deadline says):"
write_live_marker "$FUTURE" '["b2bb1003"]'
ts BLOCK "19 retiring key with the deadline still ahead" "$RETIRING_SID" "$LOOP_AUTO" "is retiring"
write_live_marker none '["b2bb1003"]'
ts BLOCK "20 retiring key under a marker with no deadline at all" "$RETIRING_SID" "$LOOP_AUTO" "retiring list"
write_live_marker "$FUTURE" '["8c16860d","b2bb1003"]'
ts BLOCK "21 retiring key among several" "$RETIRING_SID" "$LOOP_AUTO"
cp "$LOOP_AUTO" "$TMPROOT/transcripts/$RETIRING_SID.jsonl"
ts BLOCK "22 no session_id: the key comes from the transcript's file name" "" "$TMPROOT/transcripts/$RETIRING_SID.jsonl"
write_live_marker "$PAST" '["b2bb1003"]'
ts BLOCK "23 retiring AND past deadline reports the deadline" "$RETIRING_SID" "$LOOP_AUTO" "deadline passed"

echo "  must ALLOW (not retiring, or the key cannot be determined):"
write_live_marker "$FUTURE" '["b2bb1003"]'
ts ALLOW "24 a sibling not in the retiring list keeps picking" "$SIBLING_SID" "$LOOP_AUTO"
ts ALLOW "25 retiring key but the session is a /fleet-retro, not a /loop /auto" "$RETIRING_SID" "$RETRO"
ts ALLOW "26 retiring key but a targeted /auto — the operator named the issue" "$RETIRING_SID" "$TARGETED"
ts ALLOW "27 no session_id and a transcript name that is not a session id fails OPEN" "" "$LOOP_AUTO"
ts ALLOW "28 a session_id that is not hex fails OPEN" "not-a-session-id" "$LOOP_AUTO"
ts ALLOW "29 a session_id shorter than the key fails OPEN" "b2bb1" "$LOOP_AUTO"
write_live_marker "$FUTURE" '["loop-aut"]'
ts ALLOW "29b a key that is not a hex run key fails OPEN even when the marker names it" "" "$LOOP_AUTO"
write_live_marker "$FUTURE" '[]'
ts ALLOW "30 a marker with no retiring list gates nobody before the deadline" "$RETIRING_SID" "$LOOP_AUTO"
printf '{"retiring":"b2bb1003","deadline_epoch":%s}\n' "$FUTURE" > "$CHECKOUT/tmp/fleet-deadline.json"
ts ALLOW "31 a malformed retiring field (not an array) fails OPEN" "$RETIRING_SID" "$LOOP_AUTO"

echo
echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
