#!/usr/bin/env bash
# Regression harness for full-continue.sh decide(). Sources the hook (its main body is guarded so
# sourcing only exposes the function) and replays synthetic transcripts, asserting the fire/pending/
# finishargs decision for the failure modes the window-boundary logic must get right.
#
# The load-bearing case is BF-391: a mid-run, recovered-from /start-terminal tag (BLOCKED-ON-REVIEW,
# MAIN-CHECKOUT-CONTAMINATION) must NOT close the /full window — treating it as a close is what silently
# disabled the handoff for the rest of that session. Run this after ANY change to decide().
#
# Fixtures are generated inline into a temp dir (not committed) — each case's transcript shape sits next
# to its assertion, which is easier to review and maintain than a directory of micro-files.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/full-continue.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Minimal record builders. decide() only reads assistant text/tool_use and user command text; everything
# else in a real transcript is noise it ignores, so the fixtures carry only what the logic keys off.
ucmd()   { printf '{"type":"user","message":{"content":"<command-name>%s</command-name>\\n<command-args>%s</command-args>"}}\n' "$1" "$2"; }
utext()  { printf '{"type":"user","message":{"content":%s}}\n'  "$(jq -Rn --arg s "$1" '$s')"; }
atext()  { printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$(jq -Rn --arg s "$1" '$s')"; }
askill() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s","args":"%s"}}]}}\n' "$1" "$2"; }
asidechain() { printf '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":%s}]}}\n' "$(jq -Rn --arg s "$1" '$s')"; }

pass=0
fail=0
# check <fixture> <jq-expr-on-decision> <expected> <label>
check() {
  TRANSCRIPT_PATH="$TMP/$1"
  local d got
  d=$(decide)
  got=$(jq -r "$2" <<<"$d" 2>/dev/null || echo '<jq-error>')
  if [[ "$got" == "$3" ]]; then
    printf 'PASS  %-14s %-11s = %s\n' "$1" "$4" "$3"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-14s %-11s expected %q got %q\n        decision: %s\n' "$1" "$4" "$3" "$got" "$d"
    fail=$((fail + 1))
  fi
}

# 1. Happy path: /full -> READY (clean). Baseline fire.
{ ucmd /full "PL-1"
  atext "Completion Summary.
READY-FOR-FINISH: PL-1 — done. Run /finish PL-1"; } > "$TMP/happy.jsonl"
check happy.jsonl .fire true fire

# 2. BF-391: /full -> mid-run BLOCKED-ON-REVIEW (recovered by the user) -> READY. Must still fire.
{ ucmd /full "wt BF-391"
  atext "Isolation check flagged a source change.
BLOCKED-ON-REVIEW: BF-391 — MAIN-CHECKOUT-CONTAMINATION: .claude/agents.sh vanished; manual verification required."
  utext "main is clean, continue"
  atext "Completion Summary.
READY-FOR-FINISH: BF-391 — consolidated verification, review passed. Run /finish BF-391 merge"; } > "$TMP/bf391.jsonl"
check bf391.jsonl .fire true fire
check bf391.jsonl .pending true pending
check bf391.jsonl .finishargs "BF-391 merge" finishargs

# 3. Stale window: /full ends, user types a NEW standalone /start that reaches READY. Must NOT fire.
{ ucmd /full "PL-1"
  atext "BLOCKED-ON-REVIEW: PL-1 — review failed; not shipping."
  ucmd /start "PL-2"
  atext "READY-FOR-FINISH: PL-2 — done. Run /finish PL-2"; } > "$TMP/stale.jsonl"
check stale.jsonl .fire false fire

# 4. Crashed, tagless /full, then standalone /start -> READY. Must NOT fire (new command supersedes).
{ ucmd /full "PL-1"
  atext "Working on PL-1..."
  ucmd /start "PL-2"
  atext "READY-FOR-FINISH: PL-2 — done."; } > "$TMP/crashed.jsonl"
check crashed.jsonl .fire false fire

# 5. /auto multi-issue: two Skill(full) dispatches, no user commands. Second issue's READY must fire.
{ askill full "auto wt PL-1"
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"
  askill finish "auto PL-1 merge"
  atext "SHIPPED-MERGE: PL-1 — merged, Ready For Release."
  askill full "auto wt PL-2"
  atext "READY-FOR-FINISH: PL-2 — done. Run /finish PL-2 merge"; } > "$TMP/auto.jsonl"
check auto.jsonl .fire true fire
check auto.jsonl .finishargs "auto PL-2 merge" finishargs

# 6. Post-ship re-emit: a completed cycle, then a spurious READY. Must NOT fire (double-finish guard).
{ ucmd /full "wt PL-1"
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"
  askill finish "PL-1 merge"
  atext "SHIPPED-MERGE: PL-1 — merged."
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"; } > "$TMP/postship.jsonl"
check postship.jsonl .fire false fire

# 7. Self-clear: /full -> READY -> /finish dispatched (no SHIPPED tag yet). Must NOT re-fire.
{ ucmd /full "PL-1"
  atext "READY-FOR-FINISH: PL-1 — done."
  askill finish "PL-1"; } > "$TMP/selfclear.jsonl"
check selfclear.jsonl .fire false fire

# 8. Plain stop: ordinary session, no /full. One-shot (pending:false), no fire.
{ utext "can you help me refactor this function"
  atext "Sure — here is what I would change."; } > "$TMP/plain.jsonl"
check plain.jsonl .fire false fire
check plain.jsonl .pending false pending

# 9. Unrelated user command between /full and READY: must still fire — only /start|/full close a window.
#    (The real BF-391 transcript carried a /remote-control line here; this locks $usercmds specificity.)
{ ucmd /full "wt BF-391"
  ucmd /remote-control "toggle"
  atext "READY-FOR-FINISH: BF-391 — done. Run /finish BF-391 merge"; } > "$TMP/unrelated-cmd.jsonl"
check unrelated-cmd.jsonl .fire true fire
check unrelated-cmd.jsonl .cmds_between 0 cmds_between

# 10. Sidechain READY must be excluded (the isSidechain filter is load-bearing): a subagent emitting a
#     READY-shaped line is not a main-conversation tag, so no fire (window still open -> pending stays true).
{ ucmd /full "PL-1"
  asidechain "READY-FOR-FINISH: PL-1 — subagent claims done"; } > "$TMP/sidechain.jsonl"
check sidechain.jsonl .fire false fire
check sidechain.jsonl .pending true pending

# 11-13. finishargs reconstruction across modes.
{ ucmd /full "wt pr PL-1"
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 pr"; } > "$TMP/args-pr.jsonl"
check args-pr.jsonl .finishargs "PL-1 pr" finishargs

{ ucmd /full "PL-1 no push"
  atext "READY-FOR-FINISH: PL-1 — done."; } > "$TMP/args-nopush.jsonl"
check args-nopush.jsonl .finishargs "PL-1 no push" finishargs

{ ucmd /full "PL-1 no-push"
  atext "READY-FOR-FINISH: PL-1 — done."; } > "$TMP/args-nopush-hyphen.jsonl"
check args-nopush-hyphen.jsonl .finishargs "PL-1 no push" finishargs

# 14. A non-object content element must not throw and black out decide() (the jq `type == "object"` guard):
#     /full -> a stray array-of-string content record -> READY must still fire, not silently no-op.
{ ucmd /full "PL-1"
  printf '{"type":"assistant","message":{"content":["bare string, not an object"]}}\n'
  atext "READY-FOR-FINISH: PL-1 — done."; } > "$TMP/nonobj.jsonl"
check nonobj.jsonl .fire true fire

echo "----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
