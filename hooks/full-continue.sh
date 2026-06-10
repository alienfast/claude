#!/usr/bin/env bash
# Claude Stop hook: guarantee the /full macro's /start -> /finish handoff.
#
# WHY: /full runs /start then /finish in one turn. /start ends on a tagged line
# (READY-FOR-FINISH: ...) that reads like a terminal summary, so the model stops
# without dispatching /finish (recurred across PL-347/PL-349/PL-353/PL-351). Three
# layers of in-prose mitigation failed. This hook moves the reliability out of skill
# prose: when a stop happens inside an in-flight /full that reached READY-FOR-FINISH
# but has not yet dispatched Skill(finish), it blocks the stop and re-issues the
# dispatch. Self-clearing (stops firing once Skill(finish) appears) and hard-bounded
# (gives up after a few attempts, counted from the FIRST READY of the window so a
# model that merely re-emits the tag still advances toward give-up).
#
# FLUSH RACE (the bug this hook silently lost to before): a Stop hook can fire and read
# transcript_path BEFORE the model's just-emitted final assistant turn — the one carrying
# READY-FOR-FINISH — is durably flushed as a complete JSON line. The tag is then invisible,
# the decision is fire:false, and the hook exits with NO output. In prod this showed up as
# stop_hook_summary {hasOutput:false, preventedContinuation:false} on EVERY /full handoff
# (PL-401/PL-402/...): the decision logic was correct (replaying the same transcript prefix
# offline blocks correctly) but the single, immediate read lost the race to the writer. Fix:
# re-read in a bounded poll until the tag lands, gated on `pending` so ordinary stops pay for
# exactly one read. See decide() and the poll loop below.

set -uo pipefail

INPUT=$(cat)
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)

[[ -z "${TRANSCRIPT_PATH:-}" ]] && exit 0
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
[[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

# Single pass over the JSONL (array index = chronological order). `fromjson?` is
# line-tolerant: a single malformed or half-flushed line is skipped, not fatal. Emits both
# `fire` (block this stop now) and `pending` (we are plausibly mid-/full awaiting the handoff,
# so the caller should keep re-reading through the flush-race window).
decide() {
  jq -nR -c '
    [inputs | fromjson?] as $L

    | def lastline($s): ($s | split("\n") | map(rtrimstr("\r")) | map(select(length > 0)) | last // "");
      def utext($c):
        (if ($c | type) == "string" then $c
         else ([$c[]? | select(.type == "text") | .text] | join("\n")) end);

      ($L | to_entries) as $E

    # Lifecycle tag lines: main-conversation assistant text whose LAST non-empty line is an
    # anchored tag. Anchoring on the last line (not a substring) excludes prose mentions and
    # any leading summary paragraph the skill may prepend.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "assistant" and ($v.isSidechain != true))
        | ($v.message.content // [])[]
        | select(.type == "text")
        | lastline(.text) as $ll
        | select($ll | test("^(READY-FOR-FINISH|BLOCKED-ON-REVIEW|CANCELED|ABANDONED|RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE):"))
        | {i: $i, line: $ll} ] as $tags

    # /full slash-command invocations (string-content user messages); capture their args.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.type == "user" and ($v.isSidechain != true))
        | utext($v.message.content) as $u
        | select($u | test("<command-name>/full</command-name>"))
        | {i: $i, args: ($u | (capture("<command-args>(?<a>[^<]*)</command-args>") // {a: ""}) | .a)} ] as $fulls

    # All /finish dispatches by ANY form (Skill tool_use OR slash command), non-sidechain. Built once and
    # reused for both the post-tag self-clear and the pending gate. The block-reason this hook emits mentions
    # "/finish" in prose but never wraps it in <command-name>/finish</command-name>, so it cannot false-match.
    | [ $E[]
        | .key as $i | .value as $v
        | select($v.isSidechain != true)
        | { i: $i,
            fin: ( (($v.type == "assistant")
                     and (([ ($v.message.content // [])[] | select(.type == "tool_use" and .name == "Skill" and (.input.skill == "finish")) ] | length) > 0))
                   or (utext($v.message.content // []) | test("<command-name>/finish</command-name>")) ) }
        | select(.fin) ] as $finishes

    # pending = plausibly mid-/full awaiting the /finish handoff: a /full invocation exists with NO /finish
    # dispatch and NO macro-closing tag after it. Deliberately computed WITHOUT requiring a tag to be visible,
    # so it stays true during the flush-race window before READY-FOR-FINISH lands — exactly when we must keep
    # polling. A normal (non-/full) stop has pending:false, and the caller bails after a single read.
    | ([ $tags[] | select(.line | test("^(RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE|BLOCKED-ON-REVIEW):")) ] | last) as $anyclose
    | ($fulls | last) as $lastfull
    | (if $lastfull == null then false
       else (([ $finishes[] | select(.i > $lastfull.i) ] | length) == 0)
            and (($anyclose == null) or ($anyclose.i <= $lastfull.i))
       end) as $pending

    | (if ($tags | length) == 0 then {fire: false}
       else
         ($tags | last) as $t
         | $t.line as $tagline

         # Most recent macro-closing tag strictly before the current tag.
         | ([ $tags[]
              | select(.i < $t.i)
              | select(.line | test("^(RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE|BLOCKED-ON-REVIEW):")) ] | last) as $lastclose
         | ([ $fulls[] | select(.i < $t.i) ] | last) as $openfull
         # An open /full = a /full command before the tag, more recent than any close (so a stale, already-
         # completed earlier /full does not count).
         | ($openfull != null and ($lastclose == null or $openfull.i > $lastclose.i)) as $open_full

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

         # Reconstruct /finish args from the original /full invocation — mirrors /full Step 3:
         #   in-place -> "<id>"; wt -> "<id> merge"; wt+pr -> "<id> pr"; append " no push" when requested.
         # The tag line alone is insufficient (it always reads "merge" in wt mode and never knows about
         # pr/no-push). Space-padded token tests avoid matching an issue-id prefix such as "PR-123".
         | (" " + (($openfull.args // "") | ascii_downcase) + " ") as $fa
         | ($fa | test(" wt ")) as $is_wt
         | ($fa | test(" pr ")) as $is_pr
         | ($fa | test("no push|don.t push|skip push")) as $is_nopush
         | ($issue
            + (if $is_pr then " pr" elif $is_wt then " merge" else "" end)
            + (if ($is_nopush and ($is_pr | not)) then " no push" else "" end)) as $finishargs

         | { is_ready:     ($tagline | test("^READY-FOR-FINISH:")),
             open_full:    $open_full,
             finish_after: ($finish_after > 0),
             attempts:     $attempts,
             issue:        $issue,
             finishargs:   $finishargs }
         | . + { fire: (.is_ready and .open_full and (.finish_after | not)) }
       end)
    | . + { pending: $pending }
  ' "$TRANSCRIPT_PATH" 2>/dev/null
}

# Bounded re-read poll to defeat the transcript-flush race documented in the header. Break immediately once
# the decision says fire (the tag has landed); otherwise keep re-reading ONLY while pending (an in-flight
# /full awaiting its handoff), so ordinary stops pay for exactly one read and zero sleeps. The ceiling is
# ~POLL_MAX x 0.2s of waiting; a genuine mid-/full stop that is NOT a READY (e.g. an error) simply polls to
# the ceiling and then exits without blocking — never a false block, since fire still requires is_ready.
DECISION='{"fire":false}'
POLL_MAX=8
for ((attempt = 1; attempt <= POLL_MAX; attempt++)); do
  D=$(decide) || D=''
  [[ -z "$D" ]] && D='{"fire":false}'
  DECISION="$D"
  [[ "$(jq -r '.fire // false' <<<"$D" 2>/dev/null || echo false)" == "true" ]] && break
  [[ "$(jq -r '.pending // false' <<<"$D" 2>/dev/null || echo false)" == "true" ]] || break
  [[ "$attempt" -lt "$POLL_MAX" ]] && sleep 0.2
done

FIRE=$(jq -r '.fire // false' <<<"$DECISION" 2>/dev/null || true)
[[ "$FIRE" != "true" ]] && exit 0

ATTEMPTS=$(jq -r '.attempts // 0' <<<"$DECISION")
ISSUE=$(jq -r '.issue // empty' <<<"$DECISION")
FINISHARGS=$(jq -r '.finishargs // empty' <<<"$DECISION")
[[ -z "$FINISHARGS" ]] && FINISHARGS="$ISSUE"

# Hard bound on continuations within one READY window. $ATTEMPTS is measured from the
# window's FIRST READY tag, so it climbs even if the model keeps re-emitting the tag.
# stop_hook_active (the harness's own re-entry flag) tightens the ceiling as a backstop:
# at most ~2 nudges once we're already continuing from a prior block, ~3 otherwise.
if [[ "${ATTEMPTS:-0}" -ge 3 || ( "$STOP_ACTIVE" == "true" && "${ATTEMPTS:-0}" -ge 2 ) ]]; then
  echo "[full-continue] auto-continue gave up after ${ATTEMPTS} attempt(s). Run: /finish ${FINISHARGS}" >&2
  exit 0
fi

REASON="You are executing the /full macro. /start has finished and emitted READY-FOR-FINISH for ${ISSUE}. \
Do NOT stop. Continue /full Step 3 now: dispatch /finish exactly once. Preferred — call the Skill tool: \
Skill(skill: \"finish\", args: \"${FINISHARGS}\"). Running the slash command /finish ${FINISHARGS} is equally \
acceptable; either form clears this hook. Do not re-emit the READY-FOR-FINISH line as text, do not summarize \
what /start did, do not ask the user for confirmation. Dispatch /finish immediately and nothing else."

jq -n -c --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
