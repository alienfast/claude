# Verdict overrides at the Step 8 gate

Step 8 of [`/finish`](../SKILL.md) reads this file when `VERDICT` from Step 1.5 is anything other than a fresh pass
(`passed-clean` / `passed-after-fixes` with `VERDICT_STALE=0`). Every branch here refuses by default and offers the same
three replies: `yes` (override), `re-run` (invoke `/quality-review`), `abort`. Auto mode never reaches this file —
SKILL.md Step 8 resolves every branch to `abort` unattended.

Every `<...>` token below is a substitution site: replace it with the resolved value before emitting, and never write a
literal placeholder to chat or to Linear.

## Who performs the transition

- Standard flow (`ACTION` empty): `yes` runs `linear-cli issues update <ISSUE-ID> --state "Ready For Release"` here —
  SKILL.md Step 8's state-update failure recovery applies — and ends on `RELEASED:`.
- `ACTION=merge` or `ACTION=pr`: `yes` changes no Linear state. The gate passed; Step 9 transitions after the merge lands
  or the PR opens and ends the flow with its own tag. The override comment still posts now, but it must record
  **authorization**, not a completed transition: replace `marked Ready For Release` in every comment body below with
  `authorized Ready For Release (the merge applies it when it lands)` — for `pr`, `(applied when the PR opens)`.
  Otherwise the comment asserts a release state while the code is unmerged and the issue is still In Progress.

## `re-run` dispatches the review — it is never a stop

The reply means the user asked this session to run the review, not to be told to run it themselves. On `re-run`:

1. Invoke `/quality-review <ISSUE-ID>` via the Skill tool and let it run to completion.
2. Resume at Step 1.5 — run `finish-read-verdict.sh` again and carry the fresh `VERDICT` / `VERDICT_STALE` /
   `SUB_ISSUES` forward. Do not repeat Steps 2–5: the description update and completion comment already posted.
3. Re-run Steps 6–7 — the review's fix loop may have left uncommitted edits (`/quality-review` holds no commit grant);
   `finish-commit.sh` no-ops when the tree is already synced, and the same `--push` gate applies (only under `PUSH=1`).
   Reading the verdict before committing the fix delta mirrors the normal Step 1.5 → Step 7 order, so the carried
   `VERDICT_STALE=0` stays honest.
4. Post a short comment with the fresh verdict via `~/.claude/scripts/linear-post.sh`, in the shape of Step 4's
   Adversarial-review section — the completion comment's verdict line is stale, or absent on the `none-found` path.
5. Re-enter the gate on the fresh values. `re-run` has no terminator of its own: the resumed gate, or Step 9, ends the
   flow, and a still-non-passing fresh verdict simply prompts again.

## Stale pass (`passed-*` with `VERDICT_STALE=1`)

The verdict was produced before the latest commits, so it may not describe current code. Prompt:

> Quality-review verdict is `<VERDICT>` but is **stale**: `<VERDICT_STALE_REASON>`. Additional commits landed after `/quality-review` ran, so the verdict may not reflect current code.
>
> Mark `Ready For Release` anyway? Reply `yes` to override (the prior verdict was passing and you've verified the new commits don't introduce findings), `re-run` to invoke `/quality-review` and produce a fresh verdict for current HEAD, or `abort` to stop here.

- `yes` → proceed per § Who performs the transition and post:
  `Override: marked Ready For Release on stale verdict <VERDICT> (additional commits since /quality-review ran). User-acknowledged.`
- `re-run` → § `re-run` above.
- `abort` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — stale verdict, user aborted at /finish gate. No state change.`

## `terminated-with-open-items` / `escalated-to-architect`

The implementation has known unresolved findings. `Read` the file at `VERDICT_FILE` and extract the `Open items:` line
plus any indented continuation bullets; substitute that text. If `VERDICT_STALE=1`, prepend the staleness note so the
user knows recent commits may have resolved some items. Prompt (single message, wait):

> Quality-review verdict is `<VERDICT>` with open items:
>
> `<text extracted from VERDICT_FILE's Open items: section>`
>
> [If `VERDICT_STALE=1`: `Note: the verdict is stale — <VERDICT_STALE_REASON>. The open items above may have already been resolved by the more recent commits.`]
>
> Mark `Ready For Release` anyway? Reply `yes` to override, `re-run` to invoke `/quality-review` and try to converge, or `abort` to stop here.

- `yes` → proceed and post via `~/.claude/scripts/linear-post.sh`:
  `Override: marked Ready For Release despite verdict <VERDICT>. Open items at override time: <list>. User-acknowledged.`
  When `VERDICT_STALE=1`, append: ` Verdict was stale; user explicitly accepted the risk of overriding without a fresh /quality-review.`
- `re-run` → § `re-run` above; change no state now.
- `abort` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — verdict <VERDICT>, user aborted at /finish gate. No state change.`

## `malformed`

The file at `VERDICT_FILE` exists but has no recognized verdict value (no `Verdict:` line, the pipe-separated schema
example, or a value outside the four enums). The user ran `/quality-review`, but the handoff is broken; passing the
gate silently would defeat it. Same prompt shape, with this preamble in place of the open-items list:

> Quality-review verdict file exists at `<VERDICT_FILE>` but is malformed (no recognized verdict value). The user clearly ran /quality-review, but the handoff is broken — silently marking Ready For Release would defeat the safety check.
>
> Mark `Ready For Release` anyway? Reply `yes` to override (consider inspecting the file first), `re-run` to invoke `/quality-review` and produce a fresh artifact, or `abort` to stop here.

- `yes` → post `Override: marked Ready For Release despite malformed /quality-review verdict file. User-acknowledged.`
  Never include `VERDICT_FILE`'s absolute path in the comment: Linear comments are not necessarily private, and the
  path leaks the user's home directory and project layout.
- `re-run` → § `re-run` above.
- `abort` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — malformed verdict, user aborted at /finish gate. No state change.`

Any value the script did not normalize (defense in depth) is handled exactly as `malformed`.

## `none-found`

No verdict file at the worktree's or the main checkout's `tmp/`: `/quality-review` never ran for this issue, or ran
from a different repo. An issue finished before this gate existed is the legitimate `yes` case. Preamble:

> No /quality-review artifact found for `<ISSUE-ID>` — the implementation has not been adversarially reviewed.
>
> Mark `Ready For Release` anyway? Reply `yes` to override and ship unreviewed, `re-run` to invoke `/quality-review` and produce a verdict, or `abort` to stop here.

- `yes` → post `Override: marked Ready For Release with no /quality-review artifact — shipped unreviewed. User-acknowledged.`
- `re-run` → § `re-run` above.
- `abort` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — no /quality-review artifact, user aborted at /finish gate. No state change.`
