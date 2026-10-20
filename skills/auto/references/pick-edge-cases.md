# Pick-time edge cases

Read from `/auto` Step 2 when `/next` returns an epic-scoped verdict, or when the top candidate waits on a deploy.

## Epic-scoped holds and drains

- Once only *need the keeper* members remain in the scope and no member is in flight, `/next` returns the drained
  headline with an `_EPIC-DRAINED: …_` note. It is a verdict, not a hold: take Step 2's No candidates path, including
  the double-run confirmation. The tag carries the note verbatim —
  `NO-CANDIDATES: epic BF-1826 — <the EPIC-DRAINED note verbatim> <shipped>/<canceled>/<skipped>/<failed> this run.`
  — and the state file's `reason` is `epic <ID>: only keeper-gated members remain, nothing in flight`.
- While a member is still in flight the `PLANNED-HOLD` note ends `N in flight — <IDs>; the run ends once every
  in-flight member lands…`: wait **600s**; a sibling's landing is the wake signal.
- The `AUTO-CONTINUE: no pick — …` tag prefixes the note with `epic <ID>: `, since the note's counts are the epic's.

## A deploy-gated candidate is a push-then-wait, never a hold for the keeper

The shape: the spec's blocker line says the blocker must be live in production, not merely merged (the contract half
of an expand/contract migration waiting on its expand's deploy), and `/next` ranks the issue because the blocker is
`Ready For Release`. Production deploys from origin, and `/finish`'s merge mode never pushes.

1. `next-candidates.sh` withholds an issue carrying the `deploy-gated` label until its blockers reach the project's
   `$LINEAR_DEPLOYED_STATES` (`standards/issue-spec.md` § The `deploy-gated` label), counting it as the keeper's so the
   Backlog fallback opens instead of the whole fleet holding on it. A candidate of this shape that IS offered was filed
   without the label: add it — `~/.claude/scripts/linear-add-label.sh <ID> deploy-gated`, plus the `blocks` edge from
   the release issue if missing — so the next pick reads the hold from the ranking.
2. Run `~/.claude/scripts/auto-push-main.sh` from the main checkout.
   - `PUSHED` or `NOTHING-TO-PUSH` → origin carries the blocker's merge. Confirm the deploy the project's way (its
     `CLAUDE.md` names the check; a project with no check treats the push itself as the gate). Until it answers yes,
     treat the pick as a `BLOCKED-HOLD`: no pick, no `status` change, an `AUTO-CONTINUE` no-pick naming the blocker,
     the sha and the push line, and under self-paced `/loop` a **600s** `ScheduleWakeup` (`noop: true`). Once it
     answers yes, take the candidate.
   - `DISABLED` → the project has not granted the push (`AUTO_PUSH_MAIN` unset): hold, naming the push the keeper must
     make.
   - `DIVERGED` → hold and name it; a human reconciles origin.
   - `FETCH-FAILED`/`PUSH-FAILED` → transient infrastructure: the `retrying in ~15m` variant (`api-failures.md`).
3. The push is lazy: main batches, because every push is a CI build, and this pick and the deadline wind-down are the
   only two moments a session pushes — never after a merge.
