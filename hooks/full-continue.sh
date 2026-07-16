#!/usr/bin/env bash
# Claude Stop hook: guarantee the /full macro's /start -> /finish handoff.
#
# WHY: /full runs /start then /finish in one turn. /start ends on a tagged line
# (READY-FOR-FINISH: ...) that reads like a terminal summary, so the model stops
# without dispatching /finish (recurred across PL-347/PL-349/PL-353/PL-351). Three
# layers of in-prose mitigation failed. This hook moves the reliability out of skill
# prose: when a stop happens inside an in-flight /full that reached READY-FOR-FINISH
# but has not yet dispatched Skill(finish), it blocks the stop and re-issues the
# dispatch. It ALSO fires one step UPSTREAM of READY — at a passing /quality-review
# verdict inside /start, before Step 10 emits the tag (BF-392, the $upstream_fire
# branch) — the same stop-and-re-drive, keyed off the verdict instead of the tag.
# Self-clearing (stops firing once Skill(finish) appears) and hard-bounded (gives up
# after a few attempts).
#
# FLUSH RACE (a bug this hook lost to before): a Stop hook can fire and read
# transcript_path BEFORE the model's just-emitted final assistant turn — the one carrying
# READY-FOR-FINISH — is durably flushed as a complete JSON line. The tag is then invisible,
# the decision is fire:false, and the hook exits with NO output. In prod this showed up as
# stop_hook_summary {hasOutput:false, preventedContinuation:false} on EVERY /full handoff
# (PL-401/PL-402/...): the decision logic was correct (replaying the same transcript prefix
# offline blocks correctly) but the single, immediate read lost the race to the writer. Fix:
# re-read in a bounded poll until the tag lands, gated on `pending` so ordinary stops pay for
# exactly one read. See decide() and the poll loop below.
#
# WHAT CLOSES A /full WINDOW: exactly two things — (a) a /finish-completion tag (SHIPPED-MERGE/
# SHIPPED-PR/RELEASED/DEFERRED-MERGE), which stops a re-emitted READY from re-firing /finish after a
# cycle already completed; or (b) a NEW user-typed macro command (<command-name>/start|/full</command-name>)
# that supersedes the tracked /full — this also covers a crashed, tagless /full with no close tag to key
# off. A /start-TERMINAL tag (BLOCKED-ON-REVIEW, CANCELED, ABANDONED, SKIPPED-BLOCKED, INTERACTIVE-READY)
# must NEVER close the window: a recoverable stop (a contamination false-alarm, a blocker the user overrides
# with "continue") leaves that tag as a historical line once the run resumes while the /full is still in
# flight — treat it as a close and `pending` wrongly goes false, so the poll bails in one read and the later
# READY handoff is missed (the tell: stop-hook durations collapsing from ~1.6s to <100ms mid-session). This
# is the BF-391 regression. Skill-tool /start dispatches (what /full and /auto emit internally) are NOT user
# commands and never count as a boundary. Any change to decide() must keep ./full-continue.test.sh green.

set -uo pipefail

# Single pass over the JSONL (array index = chronological order). `fromjson?` is
# line-tolerant: a single malformed or half-flushed line is skipped, not fatal. Emits both
# `fire` (block this stop now) and `pending` (we are plausibly mid-/full awaiting the handoff,
# so the caller should keep re-reading through the flush-race window). Reads the transcript from
# the global $TRANSCRIPT_PATH so the test harness can set it and call decide() in isolation.
#
# EDITING THE jq PROGRAM BELOW: it is one single-quoted bash string, so it must contain NO ' character
# anywhere — including in comments. An apostrophe (its, hook's, main()'s) closes the string mid-program
# and breaks the hook; reword to avoid it. `bash -n full-continue.sh` catches this instantly.
decide() {
  jq -nR -c '
    [inputs | fromjson? | select(type == "object")] as $L

    # Last non-empty line of $s, but FENCE-RESILIENT: if that line is a pure closing code-fence marker
    # (only 3+ backticks or tildes), drop it and take the line before it. WHY (BF-393/BF-379): the Step-9/
    # Step-10 emit docs SHOW the tagged line inside a ```text block for readability; a model that copies that
    # presentation emits the tag with a trailing closing fence, so the true last line of the transcript becomes
    # the fence, the tag anchor below misses, and the /full handoff silently stalls. Stripping the trailing RUN of
    # bare fence lines (until{} drops every trailing pure-marker line) restores the anchor regardless of how the tag
    # was formatted. An opening fence carries an info string (```text) so it never matches this bare-marker regex.
    | def lastline($s):
        ($s | split("\n") | map(rtrimstr("\r")) | map(select(length > 0))
         | until((length == 0) or (.[-1] | test("^\\s*(`{3,}|~{3,})\\s*$") | not); .[0:-1])
         | last // "");
      def utext($c):
        (if ($c | type) == "string" then $c
         else ([$c[]? | select((type == "object") and .type == "text") | .text] | join("\n")) end);
      # Reconstruct /finish args for $issue from the original /full invocation args — mirrors /full Step 3:
      #   in-place -> "<id>"; wt -> "<id> merge"; wt+pr -> "<id> pr"; append " no push" when requested; prefix
      #   "auto " when the /full ran autonomously (dropping it would swap the unattended /finish into interactive
      #   mode mid-flight). Space-padded token tests avoid matching an issue-id prefix like "PR-123"/"AUTO-12".
      #   Shared by the READY branch and the upstream-verdict branch so the two can never drift apart.
      def finargs($issue; $args):
        (" " + ($args | ascii_downcase) + " ") as $fa
        | (if ($fa | test(" auto ")) then "auto " else "" end)
          + $issue
          + (if ($fa | test(" pr ")) then " pr" elif ($fa | test(" wt ")) then " merge" else "" end)
          + (if (($fa | test("no[- ]?push|don.t push|skip push")) and (($fa | test(" pr ")) | not)) then " no push" else "" end);

      ($L | to_entries) as $E

    # Lifecycle tag lines: main-conversation assistant text whose LAST non-empty line is an
    # anchored tag. Anchoring on the last line (not a substring) excludes prose mentions and
    # any leading summary paragraph the skill may prepend. Only the tags decide() actually
    # consumes are recognized — READY-FOR-FINISH (fire target) and the /finish-completion close
    # set; /start-terminal tags are deliberately absent (see the header: they never close a window).
    # PLACEHOLDER GUARD: exclude ONLY a tag whose id position holds a `<...>` placeholder (`TAG: <ISSUE-ID> — ...`) —
    # a documentation example, which the fence-resilient lastline above would otherwise expose and fire on. Match
    # exactly the leading-`<` shape: NOT any `<UPPERCASE>` token (real summaries carry `Array<T>`/`<API>` prose), and
    # NOT "require an id" (that would drop off-convention closes like `SHIPPED-MERGE: merged, Ready For Release.`, and
    # $tags also feeds the close/boundary logic $anyclose/$lastclose — dropping a real close risks a double /finish).
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "assistant" and ($v.isSidechain != true))
        | ($v.message.content // [])[]?
        | select((type == "object") and .type == "text")
        | lastline(.text) as $ll
        | select($ll | test("^(READY-FOR-FINISH|RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE):"))
        | select($ll | test("^[A-Z-]+:\\s*<") | not)
        | {i: $i, line: $ll} ] as $tags

    # /full invocations by ANY form, mirroring $finishes below: a slash command in a user
    # message, OR an assistant Skill tool_use — /auto Step 3 dispatches /full only the
    # second way (the BF-390 unguarded hang), so both forms must match. Both sets merge
    # and re-sort chronologically; args capture from either form.
    | ([ $E[]
        | .key as $i | .value as $v
        | select($v.type == "user" and ($v.isSidechain != true))
        | utext($v.message.content) as $u
        | select($u | test("<command-name>/full</command-name>"))
        | {i: $i, args: ($u | (capture("<command-args>(?<a>[^<]*)</command-args>") // {a: ""}) | .a)} ]
       + [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "assistant" and ($v.isSidechain != true))
        | ($v.message.content // [])[]?
        | select((type == "object") and .type == "tool_use" and .name == "Skill" and (.input.skill == "full"))
        | {i: $i, args: ((.input.args // "") | tostring)} ]
       | sort_by(.i)) as $fulls

    # User-TYPED new-macro commands: a <command-name>/start</command-name> or /full slash command in a
    # user message. These are window boundaries — a new unit of work supersedes any earlier /full (the
    # stale-window defense, including a crashed tagless /full). Deliberately NOT the Skill tool_use form:
    # /full dispatches /start and /auto dispatches /full via Skill, and those internals must not count as
    # a boundary or the very handoff this hook exists to drive would close its own window.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "user" and ($v.isSidechain != true))
        | utext($v.message.content) as $u
        | select($u | test("<command-name>/(start|full)</command-name>"))
        | {i: $i} ] as $usercmds

    # All /finish dispatches by ANY form (Skill tool_use OR slash command), non-sidechain. Built once and
    # reused for both the post-tag self-clear and the pending gate. The block-reason this hook emits mentions
    # "/finish" in prose but never wraps it in <command-name>/finish</command-name>, so it cannot false-match.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.isSidechain != true)
        | { i: $i,
            fin: ( (($v.type == "assistant")
                     and (([ ($v.message.content // [])[]? | select((type == "object") and .type == "tool_use" and .name == "Skill" and (.input.skill == "finish")) ] | length) > 0))
                   or (utext($v.message.content // []) | test("<command-name>/finish</command-name>")) ) }
        | select(.fin) ] as $finishes

    # pending = plausibly mid-/full awaiting the /finish handoff: a /full invocation exists with NO /finish
    # dispatch, NO /finish-completion close tag, and NO new user macro command after it. Deliberately computed
    # WITHOUT requiring a tag to be visible, so it stays true during the flush-race window before READY-FOR-FINISH
    # lands — exactly when we must keep polling. A normal (non-/full) stop has pending:false, and the caller bails
    # after a single read. The close set here is ONLY the /finish-completion tags (a completed cycle); a new
    # user /start|/full command closes the window via $usercmds. /start-terminal tags do NOT close it (BF-391).
    | ([ $tags[] | select(.line | test("^(RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE):")) ] | last) as $anyclose
    | ($fulls | last) as $lastfull
    | (if $lastfull == null then false
       else (([ $finishes[] | select(.i > $lastfull.i) ] | length) == 0)
            and (($anyclose == null) or ($anyclose.i <= $lastfull.i))
            and (([ $usercmds[] | select(.i > $lastfull.i) ] | length) == 0)
       end) as $pending

    # $verdicts — non-sidechain main-conversation assistant TEXT blocks holding a PASSING /quality-review verdict
    # line. WHY (BF-392): /full -> /start Step 9 runs /quality-review inline; it emits `Verdict: passed-clean` /
    # `passed-after-fixes` as assistant text, then /start Step 10 is supposed to emit READY-FOR-FINISH. If the
    # model STOPS at that verdict block (before Step 10 emits the tag) there is NO tag, $tags is empty, the READY
    # branch never fires, and the run silently stalls In Progress with a clean-looking verdict — the BF-321 stop,
    # one step UPSTREAM of the READY trigger. The `Verdict:` line is NOT the last line of its block (Findings/
    # Cycles/Open items follow), so lastline anchoring cannot see it; and since jq `^` is whole-string-only, we
    # split each block into lines and test per line. Only the two PASSING enums match — a non-passing verdict must not
    # auto-drive to /finish. Keyed on the canonical persisted `Verdict:` Output line (quality-review SKILL Output
    # block) — NOT the interactive `Quality review verdict:` header spelling, which is a mid-run prompt, not a stop
    # point. Sidechain excluded: the quality-reviewer/developer delegations run as sidechains.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "assistant" and ($v.isSidechain != true))
        | ($v.message.content // [])[]?
        | select((type == "object") and .type == "text")
        | select(any(.text | split("\n")[] | rtrimstr("\r");
                     test("^Verdict:\\s*(passed-clean|passed-after-fixes)(?=\\s|$)")))
        | {i: $i} ] as $verdicts

    # A /quality-review dispatch (Skill tool_use skill=="quality-review", or the slash form) in the window. This
    # CORROBORATES that a passing verdict in the window is a REAL /start Step 9 review return, not a doc example of
    # a `Verdict:` line the model happened to emit as prose (a resolved example like `Verdict: passed-after-fixes`
    # carries no placeholder for the verdict scan to reject, so this dispatch check is its guard). /start Step 9
    # always dispatches /quality-review via the Skill tool, so a genuine upstream stall always has one.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.isSidechain != true)
        | select( (($v.type == "assistant")
                    and (([ ($v.message.content // [])[]? | select((type == "object") and .type == "tool_use" and .name == "Skill" and (.input.skill == "quality-review")) ] | length) > 0))
                  or (($v.type == "user") and (utext($v.message.content // []) | test("<command-name>/quality-review</command-name>"))) )
        | {i: $i} ] as $qrs

    # Upstream fire condition — the SAME open-/full window $pending tracks, stalled at a passing verdict with no
    # READY-FOR-FINISH yet. $pending already means "open /full, no /finish, no completion-close, no user macro
    # command after it", so we add: a passing verdict inside the window (index after the last /full), a corroborating
    # /quality-review dispatch inside the window, AND no READY tag in the window. If a READY exists, the tag branch
    # below owns the decision — the two branches are mutually exclusive by construction ($no_ready_in_window is
    # false exactly when the READY branch can fire). Computed at the TOP LEVEL, deliberately NOT gated on $tags being
    # empty: in /auto multi-issue, the SHIPPED-MERGE close of issue N leaves $tags non-empty while N+1 stalls at its
    # verdict, so an emptiness gate would silently skip /auto — the primary consumer this BF-392 fix targets.
    | ($lastfull.i // -1) as $winbase
    | ([ $verdicts[] | select(.i > $winbase) ] | first) as $winverdict
    | (([ $qrs[] | select(.i > $winbase) ] | length) > 0) as $qr_in_window
    | (([ $tags[] | select(.i > $winbase) | select(.line | test("^READY-FOR-FINISH:")) ] | length) == 0) as $no_ready_in_window
    | ($pending and ($winverdict != null) and $qr_in_window and $no_ready_in_window) as $upstream_fire

    | (if ($tags | length) == 0 then {fire: false}
       else
         ($tags | last) as $t
         | $t.line as $tagline

         # Most recent /finish-completion close tag strictly before the current tag (same set as $anyclose).
         | ([ $tags[]
              | select(.i < $t.i)
              | select(.line | test("^(RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE):")) ] | last) as $lastclose
         | ([ $fulls[] | select(.i < $t.i) ] | last) as $openfull
         # An open /full = a /full command before the tag, more recent than any completion-close (so a stale,
         # already-shipped earlier /full does not count).
         | ($openfull != null and ($lastclose == null or $openfull.i > $lastclose.i)) as $open_full
         # A new user macro command between the open /full and this tag means the tag belongs to that newer
         # unit, not the tracked /full — the window is superseded. (Zero for a genuine in-flight /full handoff.)
         | ([ $usercmds[] | select($openfull != null and .i > $openfull.i and .i < $t.i) ] | length) as $cmds_between

         # Has /finish STARTED after the tag (self-clear)? Scoped strictly after the tag so a /finish from a
         # prior issue — which precedes this tag — cannot clear this one. The instant finish begins by ANY
         # form, the hook stands down; otherwise it would thrash for the duration of a slash-invoked /finish.
         | ([ $finishes[] | select(.i > $t.i) ] | length) as $finish_after

         # Hard-bound counter: assistant turns since the FIRST READY tag of THIS /full window (not the most
         # recent tag). Counting from the first READY means a model that merely re-emits the READY line as
         # text still advances the counter — it cannot reset it and pin the hook in a re-emit<->block loop.
         | ($openfull.i // -1) as $winstart
         | ([ $tags[] | select(.i > $winstart) | select(.line | test("^READY-FOR-FINISH:")) ] | first) as $firstready
         | ($firstready.i // $t.i) as $countfrom
         | ([ $E[] | select(.key > $countfrom) | .value | select(.type == "assistant" and (.isSidechain != true)) ] | length) as $attempts

         # Issue id: prefer the tag line; fall back to the /full invocation args if the tag has no parseable id.
         | ($tagline | (capture("^[A-Z-]+:\\s*(?<id>[A-Z]+-[0-9]+)") // {id: ""}) | .id) as $tagid
         | (($openfull.args // "") | ascii_upcase | (capture("(?<id>[A-Z]+-[0-9]+)") // {id: ""}) | .id) as $fullid
         | (if ($tagid | length) > 0 then $tagid else $fullid end) as $issue

         # /finish args reconstructed from the /full invocation via the shared finargs helper (the tag line alone
         # is insufficient — it always reads "merge" in wt mode and never knows about auto/pr/no-push).
         | finargs($issue; ($openfull.args // "")) as $finishargs

         | { is_ready:     ($tagline | test("^READY-FOR-FINISH:")),
             open_full:    $open_full,
             cmds_between: $cmds_between,
             finish_after: ($finish_after > 0),
             attempts:     $attempts,
             issue:        $issue,
             finishargs:   $finishargs }
         | . + { fire: (.is_ready and .open_full and (.cmds_between == 0) and (.finish_after | not)) }
       end) as $d

    # Upstream-verdict override (BF-392): when the tag branch did NOT fire and we are stalled at a passing verdict
    # inside an open /full, synthesize a fire that drives /start Step 10 (emit READY-FOR-FINISH) then /finish.
    # `upstream:true` steers the main() block reason (READY not emitted yet, so the READY-worded nudge would be wrong).
    # issue/finishargs reconstruct from $lastfull.args — same helper as the READY branch, no tag id to read.
    #
    # ATTEMPTS counts prior HOOK NUDGES, not post-verdict turns: the READY branch can count turns-since-READY (READY
    # is the last emit before its stop), but the upstream stop sits AFTER the /quality-review /reflect tail, so a
    # turn-count would false-read 3+ on the FIRST stop and give up without firing. Each block appends a `type:"user"
    # isMeta:true` record carrying the REASON, so counting records with the shared marker "executing the /full macro"
    # (keep that phrase in BOTH main() variants) gives 0 on the first stop, climbing only on a real re-block.
    # `turns_since_verdict` is a format-independent backstop for a future harness that stores block reasons in a
    # shape the marker count cannot see; main() applies it only under stop_hook_active (see the give-up block there).
    | (if ($d.fire | not) and $upstream_fire
       then
         (($lastfull.args // "") | ascii_upcase | (capture("(?<id>[A-Z]+-[0-9]+)") // {id: ""}) | .id) as $issue
         | finargs($issue; ($lastfull.args // "")) as $finishargs
         | ([ $E[] | select(.key > $winbase) | .value
              | select((.type == "user") and (.isSidechain != true))
              | utext(.message.content // "") | select(test("executing the /full macro")) ] | length) as $attempts
         | ([ $E[] | select(.key > $winverdict.i) | .value | select(.type == "assistant" and (.isSidechain != true)) ] | length) as $turns_since_verdict
         | { is_ready: false, open_full: true, cmds_between: 0, finish_after: false,
             attempts: $attempts, turns_since_verdict: $turns_since_verdict, issue: $issue, finishargs: $finishargs, fire: true, upstream: true }
       else $d end)
    | . + { pending: $pending }
  ' "$TRANSCRIPT_PATH" 2>/dev/null
}

# main — only when executed directly. Sourcing this file (the test harness) exposes decide() without
# reading stdin or emitting a decision.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  INPUT=$(cat)
  TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
  STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)

  [[ -z "${TRANSCRIPT_PATH:-}" ]] && exit 0
  TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
  [[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

  # Bounded re-read poll to defeat the transcript-flush race documented in the header. Break immediately once
  # the decision says fire (the tag has landed); otherwise keep re-reading ONLY while pending (an in-flight
  # /full awaiting its handoff), so ordinary stops pay for exactly one read and zero sleeps. The ceiling is
  # ~POLL_MAX x 0.2s of waiting; a genuine mid-/full stop that is NOT a READY (e.g. an error) simply polls to
  # the ceiling and then exits without blocking — never a false block, since fire still requires is_ready.
  #
  # DO NOT add a transcript-size/growth "settled -> break early" shortcut to cheapen an abandoned /full: the
  # final assistant line is flushed ATOMICALLY (one append after an arbitrary delay), so a size that has not
  # changed does NOT mean "no tag is coming" — it means "not landed yet". Breaking on it silently drops the
  # handoff exactly when the flush is slow, which is the PL-401/402 class this poll exists to defeat. The full
  # ~POLL_MAX x 0.2s on a pending stop is the price of catching a delayed flush; it is the same cost the poll
  # always paid on a pending mid-/full stop (the BF-391 fix only made `pending` correctly STAY true after a
  # recovered-from /start-terminal tag, so that price now also covers the post-recovery window).
  # Break early ONLY on a READY fire (a landed tag). An UPSTREAM fire (BF-392) keys on the earlier verdict block,
  # which flushes BEFORE a later READY turn — so if the model has actually emitted READY and stopped with that turn
  # mid-flush, breaking on the upstream fire here would block with the wrong (pre-READY) reason. Instead let an
  # upstream fire ride the poll (it stays `pending`): a late-flushing READY then supersedes it via the READY branch,
  # and if none lands, the upstream decision from the final read still stands. Non-fire pending stops poll as before.
  DECISION='{"fire":false}'
  POLL_MAX=8
  for ((attempt = 1; attempt <= POLL_MAX; attempt++)); do
    D=$(decide) || D=''
    [[ -z "$D" ]] && D='{"fire":false}'
    DECISION="$D"
    [[ "$(jq -r '(.fire == true) and (.upstream != true)' <<<"$D" 2>/dev/null || echo false)" == "true" ]] && break
    [[ "$(jq -r '.pending // false' <<<"$D" 2>/dev/null || echo false)" == "true" ]] || break
    [[ "$attempt" -lt "$POLL_MAX" ]] && sleep 0.2
  done

  FIRE=$(jq -r '.fire // false' <<<"$DECISION" 2>/dev/null || true)
  [[ "$FIRE" != "true" ]] && exit 0

  ATTEMPTS=$(jq -r '.attempts // 0' <<<"$DECISION")
  ISSUE=$(jq -r '.issue // empty' <<<"$DECISION")
  FINISHARGS=$(jq -r '.finishargs // empty' <<<"$DECISION")
  UPSTREAM=$(jq -r '.upstream // false' <<<"$DECISION")
  TURNS_SINCE_VERDICT=$(jq -r '.turns_since_verdict // 0' <<<"$DECISION")
  [[ -z "$FINISHARGS" ]] && FINISHARGS="$ISSUE"

  # Hard bound on continuations within one window. $ATTEMPTS climbs with each real re-block, but is anchored
  # differently per branch (both correct for their shape): the READY branch counts assistant turns since the
  # window's FIRST READY tag (READY is the last thing before its stop, so a re-emit adds a turn); the upstream
  # branch counts prior hook nudges directly (its stop sits AFTER legitimate /reflect turns, so a turn-count
  # would false-inflate). stop_hook_active (the harness's own re-entry flag) tightens the ceiling as a backstop:
  # at most ~2 nudges once we're already continuing from a prior block, ~3 otherwise.
  # TURNS_SINCE_VERDICT (upstream only) is a format-independent runaway backstop for the case where the nudge count
  # above ever mis-reads 0 (a future harness changing how block reasons are stored). It is GATED ON stop_hook_active
  # so it can NEVER block the FIRST upstream stop: on the first stop stop_hook_active is false, so a long inline
  # /reflect tail (which counts toward turns_since_verdict) cannot trip it and the hook always fires — the exact
  # BF-392 case that must not stall. It only arms once we are already re-entering after a prior block, where a high
  # turn count genuinely means a runaway loop the (possibly broken) nudge counter failed to bound.
  if [[ "${ATTEMPTS:-0}" -ge 3 || ( "$STOP_ACTIVE" == "true" && ( "${ATTEMPTS:-0}" -ge 2 || "${TURNS_SINCE_VERDICT:-0}" -ge 12 ) ) ]]; then
    echo "[full-continue] auto-continue gave up after ${ATTEMPTS} attempt(s). Run: /finish ${FINISHARGS}" >&2
    exit 0
  fi

  # Two block-reason variants. The upstream variant (BF-392) fires one step earlier — at a passing /quality-review
  # verdict inside /start, BEFORE READY-FOR-FINISH — so it must NOT claim /start "emitted READY-FOR-FINISH"; it
  # drives /start Step 10 to render the summary + emit the tag, then hand off to /finish. Both self-clear once
  # /finish runs in any form. BOTH strings MUST keep the literal phrase "executing the /full macro" — decide()'s
  # upstream attempts counter keys on it to count prior nudges from the transcript.
  if [[ "$UPSTREAM" == "true" ]]; then
    REASON="You are executing the /full macro. /start Step 9 ran /quality-review, which returned a PASSING verdict \
for ${ISSUE}, but /start has NOT yet emitted READY-FOR-FINISH. Do NOT stop. Continue /start Step 10 now: render the \
completion summary and emit the READY-FOR-FINISH line, then continue /full Step 3 and dispatch /finish exactly once — \
call the Skill tool Skill(skill: \"finish\", args: \"${FINISHARGS}\") (or the slash command /finish ${FINISHARGS}); \
either form clears this hook. Do not ask the user for confirmation. Complete the handoff immediately."
  else
    REASON="You are executing the /full macro. /start has finished and emitted READY-FOR-FINISH for ${ISSUE}. \
Do NOT stop. Continue /full Step 3 now: dispatch /finish exactly once. Preferred — call the Skill tool: \
Skill(skill: \"finish\", args: \"${FINISHARGS}\"). Running the slash command /finish ${FINISHARGS} is equally \
acceptable; either form clears this hook. Do not re-emit the READY-FOR-FINISH line as text, do not summarize \
what /start did, do not ask the user for confirmation. Dispatch /finish immediately and nothing else."
  fi

  jq -n -c --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi
