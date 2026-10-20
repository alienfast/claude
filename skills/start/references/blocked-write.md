# A delegate's Write blocked by the worktree isolation guard

Read from `/start` Step 8 item 1 when a delegate reports that its Write was blocked. It applies to every `IS_WT`
session, foreground or background, in any step that delegates (Step 5's baseline repair included).

Step 0 entered the worktree with `EnterWorktree(path=<WT_ABS>)`, which registers it as the session's isolation root and
is meant to bind every subagent's Write tool to it. That registration is best-effort, which is why every delegation
carries READ-SCOPING and every write-capable one WRITE-PLACEMENT, and why item 1 confirms writes landed
([standards/git-worktrees.md](../../../standards/git-worktrees.md) § Delegation placement).

**A blocked Write is a hard stop, not a license to weaken isolation.**

- Do **not** set `worktree.bgIsolation: "none"`.
- Do **not** edit `settings.json` / `settings.local.json` to change isolation — the auto-mode self-modification
  classifier is right to block that.
- Above all, do **not** take over the implementation yourself. Step 8's orchestrator-only rule is absolute and is never
  suspended by a delegation-mechanics failure.

## Procedure

1. Re-confirm Step 0's `EnterWorktree` registration took: cwd is the worktree, and it was entered from the main checkout
   with the tool, not via a shell `cd` (Step 0 sub-step 2).
2. If writes are still blocked, **STOP.** Compose the failure detail: which delegation, what it reported, and the
   registration re-confirmation result.
3. Record it where a human will find it:
   - **Interactive mode:** surface all of the above in chat before the tagged line.
   - **Auto mode:** post a Linear comment first — `Write` the body to
     `tmp/blocked-write-comment-<issue-id-lowercased>.md`, then
     `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/blocked-write-comment-<issue-id-lowercased>.md`. Without
     it the tagged line would be the only durable record; the comment gives a human something to act on.
4. Both modes then emit the tagged line, bare, and stop:

   ```text
   BLOCKED-ON-REVIEW: <ISSUE-ID> — delegate writes blocked by the worktree isolation guard; manual investigation required.
   ```

A stopped session never ends without a tag ([standards/lifecycle-tags.md](../../../standards/lifecycle-tags.md): every
session ends with exactly one). No Linear state changes; the worktree and branch are preserved.
