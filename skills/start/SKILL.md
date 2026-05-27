---
name: start
description: Start working on a Linear issue — check blockers, assign, move to In Progress, create branch, plan implementation, execute with checkpoint updates, review and triage findings. Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
---

# Start Issue

Automates the full workflow for starting and implementing a Linear issue using the `linear` CLI.

## Working Application Contract

This is the non-negotiable rule that governs everything in this workflow:

**We are modifying a WORKING application. If the application stops working, that is OUR failure. Period.**

There is no such thing as a "pre-existing" failure during implementation. The baseline check in Step 5 establishes a clean starting point. From that moment forward, every failure in `pnpm check` is caused by our changes and is our responsibility to fix. If we go from a working application to a non-working application, we broke it — no excuses, no deflection, no deferral.

Rules that flow from this contract:

1. **`pnpm check` must pass at all times.** Turborepo caching makes repeated runs cheap. Run it early, run it often.
2. **Failures are never "pre-existing."** The baseline passed. Any failure after that is ours.
3. **Failures are never "out of scope."** If our changes cause a check to fail, fixing it IS our scope.
4. **Failures are never deferred.** We do not proceed with a broken application. We stop and fix.
5. **The contract is in effect from Step 5's baseline through Step 9's review.** Steps 1–4 gather context, Step 6 runs plan mode (read-only by definition), Step 7 posts the plan, Step 10 summarizes — none modify code. Steps 5, 8, and 9 are the ones that can break the application; they run in-session and must keep `pnpm check` green. Step 8's `developer` / `debugger` / `quality-reviewer` / `architect` delegations must include this contract verbatim in the delegation prompt.

Violating this contract — by shipping broken code, by claiming failures were pre-existing, by deferring breakage to a follow-up ticket — is the single worst outcome of this workflow. A partially-implemented feature on a working application is infinitely better than a "complete" feature on a broken one.

## Workflow

### Step 0: Worktree Mode (only when `wt` in args)

**Argument parsing.** Tokens are case-insensitive (`wt`, `WT`, `Wt`) and position-agnostic. After stripping `wt`, exactly one non-token argument must remain — pass it through `~/.claude/scripts/detect-issue-id.sh --validate-only --input <arg>` to normalize and validate (the script enforces `^[A-Z]+-[0-9]+$` and uppercases). Multiple IDs or duplicated `wt` tokens are errors.

If the args contain `wt`:

1. **Run the worktree setup script.** It encapsulates all the procedural setup that used to live inline here: argument validation, source-branch capture, per-worktree config enable, issue title fetch + branch name composition, worktree create/attach/reuse with branch-collision detection, source-branch recording, and digest pre-fetch into the worktree's `tmp/`.

   ```bash
   ~/.claude/scripts/start-wt-setup.sh PL-13
   ```

   **Read the tool output carefully.** Stdout contains five `KEY=value` lines you must carry forward into sub-step 2:

   ```text
   WT_ABS=<absolute worktree path>
   BRANCH=<the worktree branch name>
   SOURCE_BRANCH=<the branch the worktree forks from>
   ISSUE_ID=<normalized (uppercased) issue ID>
   DIGEST_FILE=<absolute path to pre-fetched digest, or empty if fetch failed>
   ```

   Stderr contains diagnostics (drift warnings, progress, errors). **If the script's exit code is non-zero, stop.** Do not proceed to sub-step 2 — the worktree is in an indeterminate state and the script has already cleaned up via its EXIT trap. Surface the script's stderr to the user.

   **Foot-gun warning.** Do not manually set `start.source-branch` at common (non-`--worktree`) scope. The Step 5 short-circuit treats any value as evidence of a `/start wt` worktree, so a stray manual config would silently bypass branch creation in a regular `/start` session. The setup script writes only at per-worktree scope.

2. **`cd` into the worktree.** The Bash tool's cwd persists across calls, so a single `cd` here scopes every subsequent bash command (Steps 1–10) to the worktree. Read `WT_ABS` from sub-step 1's stdout and substitute it; single-quote the path so spaces or shell metacharacters survive:

   ```bash
   cd '<value of WT_ABS from sub-step 1>'
   pwd   # confirm
   ```

3. **Continue to Step 1 in this same session — no subagent.** The user is already in an isolated agent-view session; the worktree provides git-level isolation. Stacking subagent isolation on top would only hide plan-mode prompts and `/quality-review` output from the user. Steps 1–10 run unchanged:

   - Step 1 reads the pre-fetched digest at `tmp/linear-context-<issue-lower>.md`.
   - Step 5 short-circuits via the recorded per-worktree git config.
   - Step 6 (`EnterPlanMode`) surfaces the approval UI to the user.
   - Step 8 delegates implementation to `developer` subagents (those are appropriate — they're scoped tasks, not whole-workflow dispatch).
   - Step 9 (`/quality-review`) runs with visible findings, fix loop, and deferred-items triage.

If `wt` is **not** in args, proceed to Step 1 as today (in-place on the current branch).

### Step 1: Gather Issue Context

The issue digest is a markdown summary of the issue, parent chain, dependency graph, comments summary, and attachment URLs. Generate or read it:

```bash
mkdir -p tmp
DIGEST=tmp/linear-context-pl-13.md   # use the actual lowercased issue ID
# In `/start wt` mode, Step 0's setup script already cached the digest here.
# In plain `/start` mode (or if the pre-fetch failed), generate it now.
if [ -s "$DIGEST" ]; then
  cat "$DIGEST"
else
  ~/.claude/scripts/linear-context.sh PL-13 | tee "$DIGEST"
fi
```

Read the digest carefully. Note:

- **Description** — requirement checkboxes (`- [ ]` items), success criteria checkboxes, "Nice to Have" vs "Must Have" distinctions
- **Parent chain** — each ancestor's title and state; higher-level issues often contain architectural decisions and scope boundaries
- **Dependencies** — blockers with states; comments summary
- **Attachments** — `uploads.linear.app` URLs to inspect (download separately when needed)

### Step 2: Check for Blockers

The digest from Step 1 includes a **Blockers (issues blocking this)** section listing each blocker's state. Decide whether each blocker is resolved by checking its state against the team's terminal states (typically `Done`, `Canceled`, `Ready For Release`, plus any team-custom terminal states like `Released`, `Shipped`, `Won't Do`). When in doubt, treat the state as unresolved — false positives are recoverable; silently proceeding past a real blocker is not.

For each unresolved blocker:

- List it with its state
- Ask the user whether to proceed anyway or address the blocker first
- Do not silently skip

### Step 3: Deepen Context (only as needed)

The digest covers most context. Reach for these only when its summary is insufficient for the work at hand:

**Full comment bodies** (digest shows only first line of each comment):

```bash
linear i comments PL-13
```

**Project description** (digest does not include the project body; the digest's `**Project ID:**` line is the project UUID). Use the project ID directly from the Step 1 digest:

```bash
# Read the **Project ID:** value from the digest you printed in Step 1.
# If the digest had no Project ID line, the issue has no project — skip.
linear p get <project-uuid-from-digest>
```

**Inline images** — `uploads.linear.app` URLs from the digest's Attachments section require authentication; do NOT use `WebFetch` or `curl`:

```bash
linear attachments download "https://uploads.linear.app/..." --output tmp/
# → tmp/linear-img-<hash>.png
```

Then `Read` the downloaded path to view the image.

### Step 4: Assign & Move to In Progress

```bash
linear issues update PL-13 --assignee me --state "In Progress"
```

### Step 5: Ensure Correct Git Branch

**Worktree mode short-circuit.** Check at per-worktree scope (`--worktree`) so a manual `start.source-branch` at common scope can't false-trigger this from outside a `/start wt` worktree. If `git config --worktree --get start.source-branch` returns a value, the branch is already correct and the source branch is recorded for `/finish`. Skip the branch-selection logic below and jump directly to the **Baseline check** at the end of this step.

```bash
# Probe only — interpret the printed value, not the exit code. `|| true` is
# unnecessary here (unlike the capture-assignment sites in /finish) because
# this isn't being captured into a variable; a non-zero exit from the lookup
# is fine for the orchestrator to read as "no value set".
git config --worktree --get start.source-branch 2>/dev/null
```

```bash
git branch --show-current
```

- **If already on a non-`main` branch**: stay on it and skip to Step 6.
- **If on `main`**: create or switch to a feature branch:

```bash
# Check for existing branch
git branch --list "*pl-13*"

# If found, switch to it
git checkout <existing-branch>

# If not found, get GitHub username and create branch
gh api user --jq .login
git checkout -b <username>/pl-13-short-kebab-title
```

**Branch naming rules:**

- Prefix with your GitHub username (from `gh api user --jq .login`)
- Issue key in lowercase (e.g., `pl-13`)
- Kebab-case title, truncated to keep the branch name reasonable

**Baseline check — THIS ESTABLISHES THE CONTRACT.** Run `pnpm check` to prove the application works before we touch anything:

```bash
pnpm check
```

- If it **passes**: the Working Application Contract is now in effect. The application works. From this moment forward, any failure in `pnpm check` is caused by our implementation and is our responsibility to fix. No exceptions.
- If it **fails**: STOP. Do NOT proceed with planning. The application must be working before we begin. Investigate and fix the failures first — delegate to `developer` or `debugger` as needed. Re-run until the baseline is clean. The contract cannot be established on a broken baseline.

### Step 6: Enter Plan Mode

**Call the `EnterPlanMode` tool** to transition into plan mode. Do not write the plan inline in chat — plan mode has a dedicated tool flow that surfaces an approval UI (in VSCode: a side pane that supports annotation), and the inline-text path bypasses it.

While in plan mode:

1. Use the issue description, checkboxes, and parent context as requirements
2. Explore the codebase to understand relevant files, patterns, and dependencies
3. Design a step-by-step implementation plan
4. Identify which tasks are independent (parallelizable) vs dependent (sequential)
5. Write the plan to the plan file specified in the plan-mode system message

**When the plan is complete, call the `ExitPlanMode` tool.** This is what requests user approval and surfaces the annotation pane. If the user annotates or pushes back, incorporate the feedback, update the plan file, and call `ExitPlanMode` again — repeat until approved. Do NOT use `AskUserQuestion` to ask "is this plan okay?" — `ExitPlanMode` is the approval mechanism.

Do not start implementation until the user approves the plan via `ExitPlanMode`. After approval, proceed **immediately** to Step 7 — do not read files, grep, or do any implementation research until the plan is posted to Linear.

### Step 7: Post Approved Plan to Linear

**This step MUST complete before any implementation work begins — no exceptions.** No file reads, no grep, no dependency research. Post first, then stop.

Record the approved plan as a comment on the issue before starting work. This creates a permanent record so that if the session is interrupted, anyone (including a future session) can reconstruct intent from Linear.

1. Use the `Write` tool to save the plan as a structured comment to `tmp/linear-comment-<issue-id>.md`:

```markdown
## Implementation Plan

_Approved before implementation started._

### Approach
[1–3 sentence summary of the overall strategy]

### Steps
1. [Step — what will be done and why]
2. ...

### Key Files
- [File paths identified during planning]
```

2. Run:

```bash
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```


### Step 8: Implement via Delegation

**Your role is orchestrator only.** Do not read source files, write code, run grep, or make edits yourself. Every implementation action must be delegated to a subagent. You only:

- Dispatch tasks to subagents (via the Agent tool)
- Verify results by running `pnpm check`
- Update Linear (checkboxes, comments)
- Decide what to delegate next based on results

If you catch yourself reading a source file or editing code, stop — delegate it instead.

**Available agents:**

- `developer` — Implements code, writes tests, fixes bugs
- `quality-reviewer` — Reviews for security, performance, best practices
- `debugger` — Investigates errors, analyzes root causes
- `architect` — Designs solutions when implementation reveals architectural questions

**Parallel execution is the default, not the exception.** If two tasks don't depend on each other's output, launch them simultaneously in a single message with multiple Agent calls. This applies to implementation tasks, fix tasks, and review tasks equally. Sequential execution requires justification (e.g., task B needs task A's output). Refer to [Agent Coordination Standards](~/.claude/standards/agent-coordination.md) for the parallel vs sequential decision matrix.

**Delegation format:**

Every delegation MUST include the Working Application Contract. Subagents do not get to claim ignorance of it.

```md
Task for [agent]: [Specific, focused task]
Context: [Why this task matters, relevant issue context]
Files: [Exact paths and lines]

WORKING APPLICATION CONTRACT: We are modifying a working application. The baseline `pnpm check` passed before this work began. If your changes cause `pnpm check` to fail, that is your failure — not a pre-existing issue, not out of scope, not someone else's problem. You must leave the application in a working state. Run `pnpm check` before reporting your task as complete. If it fails, fix it.

Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
- Use dedicated tools: Read (not cat/head/tail), Glob (not find/ls), Grep (not grep/rg). Never use cat, ls, find, grep, or rg via Bash.
- Run `pnpm check` before reporting completion. If it fails, fix the failures. Do not report success with a failing check.
Acceptance: [How to verify success — MUST include "pnpm check passes"]
```

**After each delegation completes:**

1. Verify the result (type checks, tests, dev server — whatever is appropriate)
2. If validation fails: the subagent broke the working application. Delegate the fix back to `developer` or `debugger` with this framing: "The application was working before our changes. Your changes broke it. Fix it." Do not accept "pre-existing" as an explanation — the baseline passed.
3. Check off the corresponding checkbox(es) in the issue description:

```bash
# Get current description
linear issues get PL-13 --output json
```

Update completed checkboxes (`- [ ]` → `- [x]`) and push the update:

1. Use the `Write` tool to save the full updated description to `tmp/linear-description-<issue-id>.md` (e.g., `tmp/linear-description-pl-13.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

**Do NOT change the issue state** during implementation. The issue stays "In Progress" throughout this entire skill. Moving to "Ready For Release" is handled exclusively by the `/finish` skill after commit and push. Even if all checkboxes are checked, do not transition the state.

**Progress Checkpoints** — As implementation progresses, add brief comments on significant design decisions or unexpected blockers:

1. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id>.md` (e.g., `tmp/linear-comment-pl-13.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

This ensures progress is visible in Linear even if the session is interrupted, and enables picking up where we left off.

**Resumption.** `/start` is idempotent on the same issue: re-running `/start PL-13` after a `/checkpoint`-and-stop should detect the issue's existing `In Progress` state and the existing branch, skip the worktree-setup and assignment steps, and resume at the implementation phase. If Step 9 (review) had previously run, the existing `tmp/quality-review-verdict-<id>.md` file is still consulted by `/finish` Step 1.5 — the user can decide to re-run `/quality-review` to refresh it, or skip ahead to `/finish` if the prior verdict still applies.

**After all implementation tasks are complete, proceed to Step 9.** Implementation is not finished until the review passes.

### Step 9: Adversarial Review and Triage

Use the `/quality-review` skill to run the adversarial implementation review and triage/fix loop, passing the current issue ID as context. The `/quality-review` skill enforces the `pnpm check` gate, delegates to `quality-reviewer`, and loops up to 5 review/fix cycles before escalating. When it returns a passing verdict (`passed-clean` or `passed-after-fixes`), proceed to Step 10. If it returns `terminated-with-open-items`, print the verdict block (as composed by `/quality-review`) to chat as a single message — no `AskUserQuestion` prompt at this point. Step 10 will re-render the same block as part of the structured summary; the duplication is intentional (chat-visibility now, structured artifact later).

Invoke as: `/quality-review <ISSUE-ID>` (e.g., `/quality-review PL-13`), passing the issue ID positionally so `/quality-review` Step 1 doesn't fall back to branch parsing.

If `/quality-review` returns `escalated-to-architect`, surface the open items and the architect-agent recommendation in chat, then proceed to Step 10. Step 10 item 6's verdict-conditional Next-steps branch handles this verdict correctly (it emits the "architect recommendation supersedes — do NOT suggest /finish" line). Do not invent a separate exit path here — go through Step 10 like any other verdict.

**Step 10 ALWAYS fires** — even when `/quality-review` failed to produce a clean verdict. The user must always see Step 10's structured summary including the Next-steps line; silently ending the session at a broken `/quality-review` violates the "Next steps MUST be the final line" rule.

Two distinct failure modes route Step 10 differently:

- **`/quality-review` ran to completion and wrote a verdict file** — even with malformed reviewer output (Error Handling fallthrough writes `Verdict: terminated-with-open-items`) or unavailable agent (writes the same). In this case Step 10 item 4 reads the persisted verdict block normally and item 6 takes the `terminated-with-open-items` branch (`Re-run /quality-review to address open items, or open follow-up issues, before /finish`). This is the common failure path.

- **`/quality-review` crashed mid-flight without writing any verdict file** (orchestrator killed, OOM, network blip during the Output step, etc.) — narrow window. In this case Step 10 item 4 renders `Verdict: unavailable (see chat above for /quality-review failure details)` and item 6 takes the missing/unavailable branch (`Investigate /quality-review failure ... before /finish`).

Do not skip Step 10 to "save the user from noise" — the structured summary IS the contract.

### Step 10: Completion Summary

When implementation and review are complete, present a summary to the user that includes:

1. **Issue**: ID and title
2. **What was implemented**: Brief description of changes made
3. **Files changed**: List of created/modified files
4. **Adversarial review**: Confirm the adversarial quality review ran. Reproduce the verdict block from `/quality-review` verbatim — its field order is the canonical order:
   - Final review verdict (`passed-clean` / `passed-after-fixes` / `terminated-with-open-items` / `escalated-to-architect`)
   - Number of review cycles (initial + re-reviews)
   - Critical/High/Medium findings resolved
   - Deferred (Nice-to-Have) items fixed in-session
   - Deferred items filed as Linear issues (with issue IDs)
   - Deferred items dropped (user declined to fix and declined to file)
   - Open items (only on `terminated-with-open-items` or `escalated-to-architect`; includes any deferred items not handled above)
5. **Checks**: Confirm `pnpm check` passes. Four exception paths to handle explicitly, mutually exclusive by `/quality-review` termination point:
   - **Terminated at sub-step 5 regression-cap** (verdict = `terminated-with-open-items` from the deferred-items regression path) → `pnpm check` may be red. Surface that failure here rather than asserting passes.
   - **Terminated at Step 3+ Error Handling** (malformed reviewer output across two attempts, OR agent unavailable returned after Step 2's gate passed) → `pnpm check` is green as last observed at Step 2's gate. Report explicitly: `pnpm check passed at /quality-review Step 2 gate (review terminated at Error Handling after Step 2; fix loop did not run)`.
   - **Terminated at Step 2 itself** (`pnpm check` failed and Error Handling escalated to the user without proceeding) → `pnpm check` is red. Report the failing output and direct the user to fix before any further action.
   - **`/quality-review` never ran or crashed before reaching Step 2** (verdict = unavailable per the Step 9 always-fires fallback, no verdict file written) → report the most recent `pnpm check` state from the implementation phase, or note that the gate was not exercised.
6. **Next steps**: Branch on the verdict from Step 9:
   - `passed-clean` / `passed-after-fixes` → `Suggest running /finish to commit, push, and mark Ready For Release`
   - `terminated-with-open-items` → `Re-run /quality-review to address open items, or open follow-up issues, before /finish`
   - `escalated-to-architect` → `Architect-agent recommendation supersedes — review it before any further action. Do NOT suggest /finish.`
   - missing/unavailable verdict (subagent emitted malformed output, infrastructure error, etc.) → `Investigate /quality-review failure (likely malformed reviewer output or infrastructure error) before /finish. Do NOT suggest /finish until a clean verdict exists.`

**Ordering — Next steps MUST be the final line.** The "Next steps" line is the only actionable item in this summary; the user scans bottom-up when running parallel sessions. Do not emit a separate end-of-turn `result:` summary, a one-line recap, or any trailing prose after "Next steps:". The Step 10 block IS your end-of-turn summary — nothing follows it. (The harness may append its own `※ recap:` line, which you cannot suppress; the goal is that no LLM-authored text comes between "Next steps" and that harness line.)

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it
- If there are unresolved blockers, list them and ask the user how to proceed
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If a git branch for this issue already exists, switch to it instead of creating a new one
