# The in-place path through Steps 1–5

Read from `/start` Step 5 when Step 0 did not fire — no `wt` (or `interactive`) token and no existing worktree for the
issue. Steps 1–4 have no in-place-only remainder: their bodies in `SKILL.md` serve both modes (Step 0 sub-step 3 decides
from Step 2's and Step 3's rules before running its script, and Step 6 reaches back for Step 4's commands), so only
Step 5's in-place body lives here.

## Step 5: Ensure Correct Git Branch

When Step 0 did not run (or a Step 2/3 decision routed to its prompts before the script ran), probe
`git config --worktree --get start.source-branch 2>/dev/null` — per-worktree scope, so a manual common-scope value cannot
false-trigger; read the printed value, not the exit code. A value means the branch is already correct and recorded for
`/finish`: skip branch selection and go to the **Baseline check**. It is also the second `IS_WT` trigger; when it is the
one that arms `IS_WT`, derive `WT_ABS` per `resumption.md` § Step 5 arms `IS_WT` before any delegation.

**In place (no worktree):** read `in-place-branch.md` for branch selection, naming, and the fetch that must precede the
baseline — a baseline on a stale branch is worthless, and so is the plan built on it. Then:

**Baseline check — THIS ESTABLISHES THE CONTRACT.** Run `pnpm check`, and **dispatch Step 6's exploration agents in the
SAME message** (read-only, the digest in hand; a red baseline stops the workflow regardless — waiting would serialize the
two longest pre-plan waits for nothing).

- **Passes** → the contract is in effect: every later `pnpm check` failure is ours. Per contract rule 1, also *start*
  the baseline for any outside suite this change will touch (cache lookup, detached launch, joined at Step 8's first
  edit).
- **Fails** → Step 5's **Baseline fails** paragraph in `SKILL.md`.
