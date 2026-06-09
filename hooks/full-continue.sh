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

set -uo pipefail

INPUT=$(cat)
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)
STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)

[[ -z "${TRANSCRIPT_PATH:-}" ]] && exit 0
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
[[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

# Single pass over the JSONL (array index = chronological order). `fromjson?` is
# line-tolerant: a single malformed or half-flushed line is skipped, not fatal.
DECISION=$(jq -nR -c '
  [inputs | fromjson?] as $L

  | def lastline($s): ($s | split("\n") | map(rtrimstr("\r")) | map(select(length > 0)) | last // "");
    def utext($c):
      (if ($c | type) == "string" then $c
       else ([$c[]? | select(.type == "text") | .text] | join("\n")) end);

    ($L | to_entries) as $E

  # Lifecycle tag lines: main-conversation assistant text whose LAST non-empty line is
  # an anchored tag. Anchoring on the last line (not a substring) excludes prose mentions
  # and any leading summary paragraph the skill may prepend.
  | [ $E[]
      | .key as $i | .value as $v
      | select($v.type == "assistant" and ($v.isSidechain != true))
      | ($v.message.content // [])[]
      | select(.type == "text")
      | lastline(.text) as $ll
      | select($ll | test("^(READY-FOR-FINISH|BLOCKED-ON-REVIEW|CANCELED|ABANDONED|RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE):"))
      | {i: $i, line: $ll} ] as $tags

  | if ($tags | length) == 0 then {fire: false}
    else
      ($tags | last) as $t
      | $t.line as $tagline

      # /full slash-command invocations (string-content user messages); capture their args.
      | [ $E[]
          | .key as $i | .value as $v
          | select($v.type == "user" and ($v.isSidechain != true))
          | utext($v.message.content) as $u
          | select($u | test("<command-name>/full</command-name>"))
          | {i: $i, args: ($u | (capture("<command-args>(?<a>[^<]*)</command-args>") // {a: ""}) | .a)} ] as $fulls

      # Most recent macro-closing tag strictly before the current tag.
      | ([ $tags[]
           | select(.i < $t.i)
           | select(.line | test("^(RELEASED|SHIPPED-MERGE|SHIPPED-PR|DEFERRED-MERGE|BLOCKED-ON-REVIEW):")) ] | last) as $lastclose
      | ([ $fulls[] | select(.i < $t.i) ] | last) as $openfull
      # An open /full = a /full command before the tag, more recent than any close
      # (so a stale, already-completed earlier /full does not count).
      | ($openfull != null and ($lastclose == null or $openfull.i > $lastclose.i)) as $open_full

      # Has /finish STARTED after the tag, by ANY dispatch form? (self-clear). The hook must
      # stand down the instant finish begins, no matter how it was invoked — otherwise it
      # thrashes for the entire duration of a slash-invoked /finish and then falsely "gives up"
      # (the manual-recovery path in full/SKILL.md emits a slash /finish, which produces NO Skill
      # tool_use, so a Skill-only check never clears). Both checks are scoped to entries strictly
      # after the tag, so a /finish from a prior issue — which precedes this tag — cannot self-clear.
      # Same sidechain filter as $tags throughout: a subagent dispatch is not a main-loop one.
      # (No closing-tag check is needed here: a SHIPPED-*/RELEASED tag would become the last tag,
      # flipping is_ready false. A check for one with .i > $t.i would be unreachable — $t is last.)
      #   (a) Skill tool_use {skill:"finish"} — the /full Step 3 happy path.
      | ([ $E[]
           | select(.key > $t.i) | .value
           | select(.type == "assistant" and (.isSidechain != true))
           | (.message.content // [])[]
           | select(.type == "tool_use" and .name == "Skill" and (.input.skill == "finish")) ] | length) as $finish_skill
      #   (b) <command-name>/finish</command-name> slash invocation — manual/recovery dispatch.
      #       The harness adds this tag at invocation; it is absent from skill bodies and from the
      #       block reason this hook emits, so the literal match is exact and self-match-free.
      | ([ $E[]
           | select(.key > $t.i) | .value
           | select(.isSidechain != true)
           | utext(.message.content // [])
           | select(test("<command-name>/finish</command-name>")) ] | length) as $finish_slash
      | ($finish_skill + $finish_slash) as $finish_after

      # Hard-bound counter: assistant turns since the FIRST READY tag of THIS /full window
      # (not the most recent tag). Counting from the first READY means a model that merely
      # re-emits the READY line as text still advances the counter — it cannot reset it and
      # pin the hook in a re-emit<->block loop. Sidechain turns excluded.
      | ($openfull.i // -1) as $winstart
      | ([ $tags[] | select(.i > $winstart) | select(.line | test("^READY-FOR-FINISH:")) ] | first) as $firstready
      | ($firstready.i // $t.i) as $countfrom
      | ([ $E[] | select(.key > $countfrom) | .value | select(.type == "assistant" and (.isSidechain != true)) ] | length) as $attempts

      # Issue id: prefer the tag line; fall back to the /full invocation args if the tag
      # is malformed and has no parseable id.
      | ($tagline | (capture("^[A-Z-]+:\\s*(?<id>[A-Z]+-[0-9]+)") // {id: ""}) | .id) as $tagid
      | (($openfull.args // "") | ascii_upcase | (capture("(?<id>[A-Z]+-[0-9]+)") // {id: ""}) | .id) as $fullid
      | (if ($tagid | length) > 0 then $tagid else $fullid end) as $issue

      # Reconstruct /finish args from the original /full invocation — mirrors /full Step 3:
      #   in-place -> "<id>"; wt -> "<id> merge"; wt+pr -> "<id> pr"; append " no push" when requested.
      # The tag line alone is insufficient (it always reads "merge" in wt mode and never knows
      # about pr/no-push), so a tag-only parse would wrongly merge a pr run. Space-padded token
      # tests avoid matching an issue-id prefix such as "PR-123".
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
    end
' "$TRANSCRIPT_PATH" 2>/dev/null) || DECISION='{"fire":false}'
[[ -z "${DECISION:-}" ]] && DECISION='{"fire":false}'

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
