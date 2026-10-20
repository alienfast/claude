# The `interactive` token — set up the worktree, then hand off

Read from `/start` Step 0 sub-step 4 when the `interactive` token is present. `/start <ISSUE-ID> interactive` runs
Step 0 in full — worktree create/enter, identity stamp, claim + In Progress, green baseline — and then **STOPS before
Step 6**: no planning, no implementation, no review. It leaves the session cwd'd inside the isolated worktree so
interactive edits land there and the main checkout stays clean, which is the whole point: not interfering with
background `wt` agents' merges.

## Rules

- **`interactive` implies worktree mode.** It arms Step 0's worktree path even when `wt` is absent — interactive work
  in place on the main checkout would reintroduce the interference it exists to avoid — so `/start <ISSUE-ID>
  interactive` behaves as `/start wt <ISSUE-ID> interactive`, and the `IS_WT` derivation reads `wt` as present.
- **`interactive` + `auto` is a usage error** — unattended and user-driven are contradictory; reject the pair, never
  pick one.
- Otherwise it is position-agnostic and case-insensitive like the other tokens, and `simple` is inert under it (the
  path never reaches Step 9 — pass `simple` to the `/quality-review` you run by hand).
- **Sub-step 3 dispatches no exploration.** The run halts before Step 6, so exploration would have nothing to feed and
  would contradict the no-planning contract: run `start-wt-verify.sh` alone (its cwd confirm, claim, source-branch probe
  and green `pnpm check` baseline are all this mode needs).
- **Every guard before the halt still fires.** A blocker, an owned-by-someone-else issue, a terminal state, a red
  baseline, or any `FAILED-*` verdict routes to its normal Step 0/2/3/5 handling and stops with its own tag, never
  reaching this hand-off. The token changes only what happens after a `VERIFIED` sub-step 3.

## The hand-off (after `VERIFIED`)

Everything the setup needed is done: the worktree exists and is entered (cwd registered via `EnterWorktree`, so edits
made through this session land in the worktree), its identity is stamped, the issue is claimed (In Progress, assigned to
you), and the baseline `pnpm check` is green. It is a first-class `/start wt` worktree: the reaper never reaps it while
this session's cwd is inside it (its live-session guard) and keeps it while unstarted or unmerged otherwise, and
`/finish` merges and removes it later exactly as for any other, so no special cleanup applies. Pin it
(`git config --worktree reap.keep true`) only if you will drive it from outside this session or come back to it after
its issue is merged or Done.

1. **Open the worktree in its own editor window.** `EnterWorktree` moves only the session's cwd, not the VS Code file
   tree, which stays rooted on the main checkout. Do this yourself (never tell the user to run it), best-effort — guard
   on `code` being present and never fail the halt if it is absent or errors:

   ```bash
   command -v code >/dev/null 2>&1 && code -n "<WT_ABS>" || true   # -n opens a NEW window, so this session survives
   ```

2. **Emit the tagged final line and stop**, substituting `ISSUE_ID` and `BRANCH` from sub-step 1's stdout; the path is
   `.claude/worktrees/<issue-id-lowercased>`. Emit it **bare**, as the last non-empty line, with no fence around it
   ([standards/lifecycle-tags.md](../../../standards/lifecycle-tags.md)); the fence below is illustrative:

   ```text
   INTERACTIVE-READY: <ISSUE-ID> — worktree ready at .claude/worktrees/<issue-id-lowercased> (branch <BRANCH>), claimed In Progress, baseline green. Work here; when done run /quality-review <ISSUE-ID>, then /finish <ISSUE-ID> merge.
   ```

`INTERACTIVE-READY` is a genuine terminal state, not a `/checkpoint`-style `IN-PROGRESS` pause: `/start` has finished
its job and there is no further `/start` work to resume — the user continues in the live session. It is this session's
completion summary and its single lifecycle tag, so **do not run Step 10**: it keys off a `/quality-review` verdict that
never ran and would emit a second, contradictory `BLOCKED-ON-REVIEW` tag. Nothing after Step 0 runs — not Step 1 either.

**Resumption composes for free.** Re-running `/start <ISSUE-ID> interactive` later hits Step 0's existing-worktree gate,
reuses the same worktree, re-enters it, re-baselines, claims idempotently (`--no-claim`), and halts here again.
