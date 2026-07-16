#!/usr/bin/env bash
# Regression harness for full-continue.sh decide(). Sources the hook (its main body is guarded so
# sourcing only exposes the function) and replays synthetic transcripts, asserting the fire/pending/
# finishargs decision for the failure modes the window-boundary logic must get right.
#
# The load-bearing case is BF-391: a mid-run, recovered-from /start-terminal tag (BLOCKED-ON-REVIEW,
# MAIN-CHECKOUT-CONTAMINATION) must NOT close the /full window — treating it as a close is what silently
# disabled the handoff for the rest of that session. Run this after ANY change to decide().
#
# GROW THIS SUITE, NEVER PRUNE IT. This hook has failed in a NEW way repeatedly (READY-as-summary across
# PL-347/349/351/353; the transcript-flush race PL-401/402; the BF-391 recovered-terminal-tag close; BF-379's
# fenced tag; BF-321's upstream verdict stop). The durable fix is not any single patch — it is that every
# newly-observed real-world /full stop failure becomes a captured fixture HERE, added WITH its fix, so each mode
# is fixed and STAYS fixed. When you discover a new stop mode, reproduce its transcript shape as a new numbered
# case below before/with the decide() change that catches it. The suite grows monotonically; it is the gate for
# every decide() edit. Do not delete cases to "clean up" — an old mode with no live guard is a mode that regresses.
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
# The hook's own block-reason record, as the harness persists it (type:user, isMeta:true, string content). The
# upstream attempts counter counts these by the shared REASON marker "executing the /full macro" (see the hook).
ublock() { printf '{"type":"user","isMeta":true,"message":{"content":%s}}\n' "$(jq -Rn --arg s "You are executing the /full macro. $1" '$s')"; }

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

# 15. BF-393: a READY-FOR-FINISH wrapped in a ```text fence still fires (the fence-resilient lastline strips the
#     trailing closing ``` so the anchor matches). ANSI-C quoting ($'...') keeps the triple-backticks literal —
#     a plain double-quoted arg would trigger bash command substitution and corrupt the fixture.
{ ucmd /full "PL-1"
  atext $'Completion Summary.\n```text\nREADY-FOR-FINISH: PL-1 — done. Run /finish PL-1\n```'; } > "$TMP/fenced.jsonl"
check fenced.jsonl .fire true fire
check fenced.jsonl .finishargs "PL-1" finishargs

# 16. BF-392: a stop at a PASSING /quality-review verdict inside an open /full, BEFORE any READY tag, fires — the
#     upstream branch. The /start Step 9 quality-review dispatch (askill) is what corroborates the verdict as a
#     real review return (the $qr_in_window gate). finishargs reconstruct from the /full args (wt -> " merge").
{ ucmd /full "wt PL-1"
  askill quality-review "PL-1"
  atext "Verdict: passed-clean
Cycles: 1 (initial + 0 re-reviews)
Findings resolved: none
Open items: none"; } > "$TMP/verdict-open.jsonl"
check verdict-open.jsonl .fire true fire
check verdict-open.jsonl .upstream true upstream
check verdict-open.jsonl .finishargs "PL-1 merge" finishargs
check verdict-open.jsonl .pending true pending

# 17. BF-392 + /auto multi-issue (the case a $tags-emptiness gate would MISS): issue N shipped (SHIPPED-MERGE
#     close, so $tags is NON-empty), then N+1's /full opens and stalls at a passing verdict. Must fire for N+1
#     with N+1's finishargs. This is the load-bearing new test for the top-level (not tag-emptiness) gating.
{ askill full "auto wt PL-1"
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"
  askill finish "auto PL-1 merge"
  atext "SHIPPED-MERGE: PL-1 — merged, Ready For Release."
  askill full "auto wt PL-2"
  askill quality-review "auto PL-2"
  atext "Verdict: passed-after-fixes
Cycles: 2 (initial + 1 re-review)
Findings resolved: 1
Open items: none"; } > "$TMP/verdict-auto.jsonl"
check verdict-auto.jsonl .fire true fire
check verdict-auto.jsonl .finishargs "auto PL-2 merge" finishargs

# 18. Standalone /quality-review (NOT inside /full): a passing verdict must NOT fire (no open /full), pending false.
{ ucmd /quality-review "PL-1"
  atext "Verdict: passed-clean
Cycles: 1
Findings resolved: none
Open items: none"; } > "$TMP/verdict-standalone.jsonl"
check verdict-standalone.jsonl .fire false fire
check verdict-standalone.jsonl .pending false pending

# 19. Non-passing verdict inside /full must NOT fire (only the two passing enums drive the handoff); window still
#     open so pending stays true. Includes the qr dispatch so the passing-enum filter is the ONLY thing blocking the
#     fire — DISCRIMINATING: broaden the filter to match terminated-with-open-items and this flips to fire=true
#     (a FAILED review must never auto-drive /finish).
{ ucmd /full "PL-1"
  askill quality-review "PL-1"
  atext "Verdict: terminated-with-open-items
Cycles: 5
Open items: HIGH: unresolved race in retry loop"; } > "$TMP/verdict-fail.jsonl"
check verdict-fail.jsonl .fire false fire
check verdict-fail.jsonl .pending true pending

# 20. Post-close spurious verdict: a completed cycle then a stray passing verdict must NOT fire. The /finish
#     dispatch makes pending false (double-finish guard); the SHIPPED-MERGE close reinforces it. Includes the qr
#     dispatch so the block is not merely an artifact of a missing $qr_in_window.
{ ucmd /full "wt PL-1"
  askill quality-review "PL-1"
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"
  askill finish "PL-1 merge"
  atext "SHIPPED-MERGE: PL-1 — merged."
  atext "Verdict: passed-clean
Cycles: 1
Open items: none"; } > "$TMP/verdict-postclose.jsonl"
check verdict-postclose.jsonl .fire false fire

# 21. Sidechain verdict must be excluded (mirrors the sidechain-READY guard #10): a subagent emitting a passing
#     verdict is not a main-conversation stop point, so no fire; window still open -> pending stays true. Includes
#     the qr dispatch so the isSidechain guard on $verdicts is the ONLY thing blocking the fire — DISCRIMINATING:
#     drop the isSidechain filter from the $verdicts builder and this flips to fire=true.
{ ucmd /full "PL-1"
  askill quality-review "PL-1"
  asidechain "Verdict: passed-clean
Open items: none"; } > "$TMP/verdict-sidechain.jsonl"
check verdict-sidechain.jsonl .fire false fire
check verdict-sidechain.jsonl .pending true pending

# 22. BF-392 PRODUCTION SHAPE and the LOAD-BEARING guard for the give-up fix (the case #16/#23 do not discriminate):
#     the mandatory /quality-review Step 7 /reflect tail emits several assistant turns BETWEEN the verdict and the
#     stop. The upstream give-up counter must NOT count those as prior nudges — on the FIRST stop, attempts is 0 and
#     the hook FIRES. Under the reverted turn-counter this reads 3+ and gives up without firing; only this fixture
#     (4 reflect turns, 0 nudge records) fails on that revert, so do not prune it.
{ ucmd /full "wt PL-1"
  askill quality-review "PL-1"
  atext "Verdict: passed-clean
Cycles: 1
Open items: none"
  atext "/reflect: scanning this session for improvements..."
  atext "/reflect: found 2 candidate config edits; auto-applying the safe one."
  atext "/reflect: filed the larger proposal as a certified issue. No blocking items."
  atext "Reflection complete. Nothing else to apply."; } > "$TMP/verdict-reflect.jsonl"
check verdict-reflect.jsonl .fire true fire
check verdict-reflect.jsonl .upstream true upstream
check verdict-reflect.jsonl .attempts 0 attempts
check verdict-reflect.jsonl .turns_since_verdict 4 turns_since_verdict
check verdict-reflect.jsonl .finishargs "PL-1 merge" finishargs

# 23. Upstream give-up bound: prior hook nudges (its own block-reason records) DO advance the counter, so a stuck
#     re-block loop still terminates. Two prior nudge records in-window -> attempts 2 (main() gives up at >=3, or >=2
#     when stop_hook_active). (Note: #22 is the fixture that discriminates the NUDGE counter from the reverted turn
#     counter — here both happen to yield 2; this one proves the counter still climbs on real re-blocks.)
{ ucmd /full "wt PL-1"
  askill quality-review "PL-1"
  atext "Verdict: passed-clean
Open items: none"
  ublock "verdict for PL-1 ... dispatch /finish PL-1 merge"
  atext "Verdict: passed-clean (re-emitted, still no READY)"
  ublock "verdict for PL-1 ... dispatch /finish PL-1 merge"
  atext "Verdict: passed-clean (re-emitted again)"; } > "$TMP/verdict-nudges.jsonl"
check verdict-nudges.jsonl .fire true fire
check verdict-nudges.jsonl .attempts 2 attempts

# 24. ID-POSITION guard must NOT false-exclude a REAL tag that carries bracketed prose (`Array<T>`, `<API>`): the
#     guard keys on the ID position (`TAG: PL-1`), not "any <UPPERCASE> token in the line", so this real READY still
#     FIRES. (An earlier over-broad guard excluded any bracket token and silently stalled such tags — this locks that
#     regression out.)
{ ucmd /full "PL-1"
  atext "READY-FOR-FINISH: PL-1 — added Array<T> and <API> support. Run /finish PL-1"; } > "$TMP/bracket-prose.jsonl"
check bracket-prose.jsonl .fire true fire
check bracket-prose.jsonl .finishargs "PL-1" finishargs

# 25. PLACEHOLDER guard DOES exclude a placeholder example (the shape a /full editing these very docs could emit): a
#     fenced `READY-FOR-FINISH: <ISSUE-ID>` has a `<` in the id position -> excluded -> no fire, pending stays true
#     (window still open, no real tag seen). Discriminating: remove the `^[A-Z-]+:\s*<` exclusion and it fires.
{ ucmd /full "PL-1"
  atext $'```text\nREADY-FOR-FINISH: <ISSUE-ID> — done. Run /finish <ISSUE-ID>\n```'; } > "$TMP/placeholder-ready.jsonl"
check placeholder-ready.jsonl .fire false fire
check placeholder-ready.jsonl .pending true pending

# 26. BF-393/M4: a READY followed by a RUN of trailing fence lines (2+) still fires — lastline strips the whole
#     trailing run of bare fence markers, not just one.
{ ucmd /full "PL-1"
  atext $'READY-FOR-FINISH: PL-1 — done. Run /finish PL-1\n```\n```'; } > "$TMP/multi-fence.jsonl"
check multi-fence.jsonl .fire true fire
check multi-fence.jsonl .finishargs "PL-1" finishargs

# 27. $qr_in_window guard for the upstream branch: a bare passing-verdict line emitted as PROSE inside an open /full
#     with NO /quality-review dispatch is a doc example (e.g. a /full editing quality-review docs), not a real review
#     return -> must NOT fire. Without the qr-dispatch corroboration this would drive a premature /finish. Discriminating:
#     add an `askill quality-review` before the verdict (as #16 has) and it fires.
{ ucmd /full "wt PL-1"
  atext "Copying the doc example here for reference:
Verdict: passed-after-fixes
Cycles: 3
Open items: none"; } > "$TMP/verdict-noqr.jsonl"
check verdict-noqr.jsonl .fire false fire
check verdict-noqr.jsonl .pending true pending

# 28. Placeholder guard must NOT swallow an OFF-CONVENTION close tag (regression guard for the round-2 id-requirement
#     bug): a /finish close lacking an id in the id position must still be recognized as a CLOSE so the window shuts —
#     otherwise a later re-emitted READY fires a SECOND /finish on an already-shipped issue. Here the id-less
#     SHIPPED-MERGE closes the window; the trailing bare READY re-emit must therefore NOT fire (double-finish guard).
{ ucmd /full "wt PL-1"
  askill finish "PL-1 merge"
  atext "SHIPPED-MERGE: merged into main, Ready For Release."
  atext "READY-FOR-FINISH: PL-1 — done. Run /finish PL-1 merge"; } > "$TMP/offconv-close.jsonl"
check offconv-close.jsonl .fire false fire

echo "----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
