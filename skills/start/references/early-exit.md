# Step 8.5: the CANCELED and ABANDONED exits

Read from `/start` Step 8.5 when one of its triggers fires, and for ABANDONED's return-to-availability mechanics from
Step 5's auto-mode baseline failure and Step 6 item 4's auto-mode boundary stop. These are the only two places `/start`
changes the issue state; both bypass Steps 9 and 10 and end on a tagged final line
([standards/lifecycle-tags.md](../../../standards/lifecycle-tags.md)). Use them as written rather than improvising an
exit — they are documented contracts other sessions and the user can scan.

## CANCELED — the work is already done or not needed

Triggers: implementation discovery shows the requested change already shipped (under another issue, on the source
branch, or via a parallel session), the requirement was dropped (requirements changed, design pivot), or the issue
duplicates work in progress elsewhere.

1. **Post a Linear comment** summarizing what was found and why no code is shipping — name the issues or PRs that
   already cover the work, and any out-of-scope findings worth filing separately. `Write` it to
   `tmp/canceled-comment-<issue-id-lowercased>.md`, then
   `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/canceled-comment-<issue-id-lowercased>.md`.
2. **Move the issue to the team's canceled state.** Try the canonical name first:

   ```bash
   linear-cli issues update <ISSUE-ID> --state Canceled
   ```

   If rejected, derive the team key from the ID prefix (`PL-13` → `PL`), probe `linear-cli statuses list -t PL`, and
   pick the first state matching `/^(canceled|cancelled|won.?t.?do|abandoned)/i` (case-insensitive prefix). If none
   match, surface the available states and ask which to use — never fall through to the team default. **Auto mode:** do
   not ask — leave the state unchanged, name the intended state in the comment from step 1 (a human re-states it), and
   continue.

   After the transition succeeds, clear the assignee so the Step 3 claim does not linger on a terminal issue (the same
   unassign-on-terminal behavior as `mark-ready-for-release.sh`):

   ```bash
   linear-cli issues assign <ISSUE-ID>   # no user arg unassigns
   ```

3. **Surface the cleanup commands** — do NOT run them; the worktree may hold in-progress notes worth saving:

   ```bash
   git worktree remove .claude/worktrees/<issue-id-lowercased>
   git branch -D <worktree-branch-name>
   ```

4. **Release the ownership stamp** (worktree mode only): `~/.claude/scripts/wt-disown.sh .claude/worktrees/<issue-id-lowercased>`.
   The worktree stays on disk until someone runs the commands above, and an unreleased stamp keeps claiming it — while
   the session idles, and after the session is deleted (which removes its job dir) for as long as the shared daemon
   whose pid a fleet stamp carries keeps running, which can hold a `/pr-merge-deferred` wait after a fleet has drained.
   Best-effort: on failure, warn, continue, and note in the tag that ownership was not released.
5. **Emit the tagged final line** (bare) and stop — no Step 9, no Step 10:

   ```text
   CANCELED: <ISSUE-ID> — <one-line reason>. Run git worktree remove .claude/worktrees/<issue-id-lowercased> && git branch -D <worktree-branch-name>.
   ```

## ABANDONED — the user is halting before completion

Every trigger is user-initiated; a session never self-invokes this path. Triggers: the user asks to pause and return the
issue to the backlog ("move PL-322 back to Planned"); a blocker emerges that the user wants to defer (an external
decision, a dependency not ready); the user is parking the session for later resumption (another context, another
person). **The fleet deadline is never a trigger**: it gates picking new work only (`/auto`'s deadline gate;
`/fleet-stop`'s contract is that in-flight issues run to completion), and a mid-issue estimate that the remaining gates
overrun it is neither a blocker nor a park — finish the pipeline, gates uncut, and let the budgeted overrun happen.
Self-invoking here on a shipping-ready change trades minutes of overrun for a full re-entry cycle plus a human
intervention.

1. **Post a Linear comment** noting where things stand: done, not done, decisions made, where implementation left off.
   `Write` it to `tmp/abandoned-comment-<issue-id-lowercased>.md`, then
   `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/abandoned-comment-<issue-id-lowercased>.md`.
2. **Move the issue back to a ready-to-work state.** Try the canonical name first:

   ```bash
   linear-cli issues update <ISSUE-ID> --state Planned
   ```

   If rejected, derive the team key from the ID prefix, probe `linear-cli statuses list -t PL`, and pick the first state
   matching `/^(planned|backlog|to.?do)$/i` — an **exact** match on those names, NOT a prefix match — preferring
   `Planned`, which keeps the "we intend to do this" signal that `Backlog` weakens. `ready` is deliberately excluded: a
   prefix match would latch onto `Ready For Release` or `Ready For Review` and silently move an abandoned issue into a
   release or review state. If none match, surface the available states and ask — never fall through to the team
   default. **Auto mode:** do not ask — leave the state unchanged (the issue stays In Progress), name the intended state
   in the comment from step 1, and continue.
3. **Preserve the worktree.** Resumption is the whole point of ABANDONED versus CANCELED: do not run
   `git worktree remove` and do not delete the branch.
4. **Release the ownership stamp** (worktree mode only) so *any* session can resume, not just this one:
   `~/.claude/scripts/wt-disown.sh .claude/worktrees/<issue-id-lowercased>` (this session is the stamped owner, so no
   `--force`). Without it, "preserved for resumption" holds only for this harness — the stamp reads `alive` to every
   other session for as long as the shared harness process lives. Best-effort: on failure, warn, continue, and note in
   the tag that ownership was not released.
5. **Emit the tagged final line** (bare) and stop:

   ```text
   ABANDONED: <ISSUE-ID> — <one-line reason>. Worktree preserved at .claude/worktrees/<issue-id-lowercased> for resumption.
   ```

## Choosing between them

Work done or unneeded (by the user's say-so or implementation discovery) → `CANCELED`. Pausing with intent to resume →
`ABANDONED`. In doubt, ask the user once; never pick silently. **Auto mode:** do not ask — `CANCELED` only when the
evidence clearly shows the work shipped or is unneeded; `ABANDONED` in every other doubtful case, since it preserves all
state for a human to inspect.
