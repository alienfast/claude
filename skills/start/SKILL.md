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
5. **Every subagent inherits this contract.** When delegating to developer, debugger, quality-reviewer, or architect, include this contract in the delegation. They operate under the same rule.

Violating this contract — by shipping broken code, by claiming failures were pre-existing, by deferring breakage to a follow-up ticket — is the single worst outcome of this workflow. A partially-implemented feature on a working application is infinitely better than a "complete" feature on a broken one.

## Workflow

### Step 0: Worktree Mode (only when `wt` in args)

**Argument parsing.** Tokens are case-insensitive (`wt`, `WT`, `Wt` all match) and position-agnostic (`/start wt PL-123` and `/start PL-123 wt` both work). After stripping `wt`, the remaining must be exactly one non-token argument matching `^[A-Z]+-\d+$` (case-normalized to upper) — a Linear issue ID. If zero or multiple candidate IDs are found (e.g., `/start wt PL-123 PL-456` or `/start wt PL-123 wt`), error and stop.

If the args contain the token `wt`:

1. **Parse and validate args.** Strip the `wt` token; uppercase the remainder; verify it matches the issue-ID regex.

2. **Enable per-worktree git config (idempotent).** Required so the source-branch setting we write in step 7 is scoped to the new worktree, not shared across the whole repo. Without this, `git config start.source-branch ...` writes to `.git/config` (common) and every other checkout of the repo sees the value:

   ```bash
   git config extensions.worktreeConfig true
   ```

   **Foot-gun warning.** Do not manually set `start.source-branch` at common (`--global` / non-`--worktree`) scope. The Step 5 short-circuit (further down) treats *any* value as evidence of a `/start wt` worktree, so a stray manual config would silently bypass branch creation in a regular `/start` session.

3. **Capture the source branch.** This is the branch the worktree will be merged back into by `/finish merge` (or used as PR base by `/finish pr`):

   ```bash
   SOURCE_BRANCH=$(git branch --show-current)
   ```

4. **Fetch the issue title and compose the branch name.**

   **Token substitution.** The block below contains `__ISSUE_ID__`. Before running it, replace that token with the actual parsed-and-uppercased issue ID from sub-step 1. **The executed bash must contain zero such tokens** — scan with the regex `/__(WT_ABS|ISSUE_ID|REPO_ROOT|WT_DIR|SOURCE_BRANCH|WORKTREE_BRANCH)__/`; if any match, do not execute.

   ```bash
   ISSUE_ID="__ISSUE_ID__"
   ISSUE_LOWER=$(printf '%s' "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')
   ISSUE_TITLE=$(linear issues get "$ISSUE_ID" --output json | jq -r .title)
   GH_USER=$(gh api user --jq .login)
   # Kebab-case the title: lowercase, replace non-alphanum with `-`, collapse runs, trim.
   KEBAB=$(printf '%s' "$ISSUE_TITLE" \
     | tr '[:upper:]' '[:lower:]' \
     | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
     | cut -c1-40 | sed -E 's/-+$//')
   # If KEBAB is empty (title was all-punctuation/emoji), omit the trailing
   # dash so we get user/pl-123 instead of user/pl-123-.
   BRANCH="${GH_USER}/${ISSUE_LOWER}${KEBAB:+-$KEBAB}"
   ```

5. **Compute the worktree path.** Convention: `.claude/worktrees/${ISSUE_LOWER}` (e.g., `.claude/worktrees/pl-123`). Local to the project, gitignored per Claude Code's bgIsolation convention:

   ```bash
   WT_DIR=".claude/worktrees/${ISSUE_LOWER}"
   ```

6. **Create, attach, or reuse the worktree.** Handle three cases — fresh creation, existing branch without worktree (prior aborted session), and full reuse (true resume):

   ```bash
   mkdir -p .claude/worktrees
   if [ -d "$WT_DIR" ]; then
     # Reuse. Verify it's a worktree on the expected branch — otherwise stop.
     CURRENT_WT_BRANCH=$(git -C "$WT_DIR" branch --show-current 2>/dev/null || true)
     if [ "$CURRENT_WT_BRANCH" != "$BRANCH" ]; then
       echo "ERROR: $WT_DIR exists but is on '$CURRENT_WT_BRANCH' (expected '$BRANCH'). Investigate manually."
       exit 1
     fi
     # Warn about base drift since the worktree was created. Compare against the LOCAL source branch.
     BEHIND=$(git -C "$WT_DIR" rev-list --count "$BRANCH..$SOURCE_BRANCH" 2>/dev/null || echo "?")
     AHEAD=$(git -C "$WT_DIR" rev-list --count "$SOURCE_BRANCH..$BRANCH" 2>/dev/null || echo "?")
     if [ "$BEHIND" != "0" ] && [ "$BEHIND" != "?" ]; then
       if [ "$AHEAD" != "0" ] && [ "$AHEAD" != "?" ]; then
         echo "NOTE: worktree branch has DIVERGED from $SOURCE_BRANCH: $AHEAD ahead, $BEHIND behind."
       else
         echo "NOTE: worktree branch is $BEHIND commit(s) behind $SOURCE_BRANCH."
       fi
       echo "  Consider: git -C \"$WT_DIR\" rebase $SOURCE_BRANCH"
     fi
     echo "Resuming worktree: $WT_DIR"
   elif git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
     # Branch exists but no worktree directory. Could be: (a) prior aborted
     # session left a dangling branch; (b) branch is checked out in main or
     # another worktree. Case (b) is fatal — `git worktree add` refuses.
     EXISTING_WT=$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
       /^worktree / { sub(/^worktree /, ""); wt = $0 }
       /^branch / && $2 == b { print wt; exit }
     ')
     if [ -n "$EXISTING_WT" ]; then
       echo "ERROR: branch '$BRANCH' is already checked out at '$EXISTING_WT'."
       echo "Either work from that location, or rename / remove that checkout first:"
       echo "  git worktree remove '$EXISTING_WT'      # if it's a worktree we no longer need"
       echo "  git -C '$EXISTING_WT' switch <other>    # if main checkout, switch off the branch"
       exit 1
     fi
     # Dangling branch — safe to attach.
     git worktree add "$WT_DIR" "$BRANCH"
   else
     # Fresh: create both worktree dir and branch off current HEAD.
     git worktree add "$WT_DIR" -b "$BRANCH" HEAD
   fi
   ```

   If `git worktree add` fails because a concurrent session won the race (directory or branch was just created by another process), the explicit `[ -d "$WT_DIR" ]` / `git rev-parse --verify "$BRANCH"` checks on retry will pick up the new state and route to the reuse / attach paths. Do not proceed past this step until the worktree is successfully prepared.

7. **Record the source branch inside the worktree** at per-worktree scope so `/finish` can locate it without leaking the value into the shared repo config:

   ```bash
   git -C "$WT_DIR" config --worktree start.source-branch "$SOURCE_BRANCH"
   ```

8. **Compute the absolute path** for the subagent's `cd`:

   ```bash
   WT_ABS=$(cd "$WT_DIR" && pwd)
   ```

9. **Delegate the rest of the workflow** to a subagent running inside the worktree. Do **not** pass the harness `isolation` parameter — we have already created the worktree manually and naming/source-branch control is the entire point.

   **Token substitution.** The prompt template below contains `__WT_ABS__` and `__ISSUE_ID__`. Before calling the Agent tool, replace each token with the bash-evaluated value of the corresponding variable. **The dispatched prompt must contain zero such tokens** — verify by scanning the constructed prompt with the regex `/__(WT_ABS|ISSUE_ID|REPO_ROOT|WT_DIR|SOURCE_BRANCH|WORKTREE_BRANCH)__/`; if any match, do not dispatch.

   ```text
   Agent({
     subagent_type: "claude",
     prompt: "
       First cd into the worktree:
         cd __WT_ABS__
       Then invoke /start __ISSUE_ID__ end-to-end (without the wt arg).
       The worktree and branch are already set up — Step 5 will short-circuit
       via the recorded per-worktree git config. On completion, report the
       worktree path and the final branch name.
     "
   })
   ```

10. **Stop.** The subagent owns the remainder of Steps 1–10. This session's role ends here — do not run further commands.

If `wt` is **not** in args, proceed to Step 1 as today.

### Step 1: Gather Issue Context

Run the context script — it collapses ~5–7 separate Linear CLI calls (issue details, dependency graph, parent chain, comments summary, attachment URLs) into one markdown digest:

```bash
~/.claude/scripts/linear-context.sh PL-13
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

**Project description** (digest does not include the project body; the digest's `**Project ID:**` line is the project UUID). Use the project ID directly from the Step 1 digest — no extra round-trip.

**Token substitution.** The block below uses `__PROJECT_ID__`. Replace it with the value of `**Project ID:**` from the Step 1 digest, or with an empty string if that line was absent (issue has no project). Scan with the regex `/__(WT_ABS|ISSUE_ID|REPO_ROOT|WT_DIR|SOURCE_BRANCH|WORKTREE_BRANCH|PROJECT_ID)__/`; if any match, do not run.

```bash
PROJECT_ID='__PROJECT_ID__'
if [ -n "$PROJECT_ID" ]; then
  linear p get "$PROJECT_ID"
else
  echo "(issue has no project)"
fi
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

**Worktree mode short-circuit.** If `git config --get start.source-branch` returns a value, you are inside a worktree set up by Step 0 — the branch is already correct and the source branch is recorded for `/finish`. Skip the branch-selection logic below and jump directly to the **Baseline check** at the end of this step.

```bash
git config --get start.source-branch
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
~/.claude/scripts/linear-stdin.sh tmp/linear-comment-pl-13.md issues comment PL-13 --body -
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
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-13.md issues update PL-13 --description -
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

**Do NOT change the issue state** during implementation. The issue stays "In Progress" throughout this entire skill. Moving to "Ready For Release" is handled exclusively by the `/finish` skill after commit and push. Even if all checkboxes are checked, do not transition the state.

**Progress Checkpoints** — As implementation progresses, add brief comments on significant design decisions or unexpected blockers:

1. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id>.md` (e.g., `tmp/linear-comment-pl-13.md`)
2. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-comment-pl-13.md issues comment PL-13 --body -
```

This ensures progress is visible in Linear even if the session is interrupted, and enables picking up where we left off.

**After all implementation tasks are complete, proceed to Step 9.** Implementation is not finished until the review passes.

### Step 9: Adversarial Review and Triage

Use the `/quality-review` skill to run the adversarial implementation review and triage/fix loop, passing the current issue ID as context. The `/quality-review` skill enforces the `pnpm check` gate, delegates to `quality-reviewer`, and loops up to 3 review/fix cycles before escalating. When it returns a passing verdict (`passed-clean` or `passed-after-fixes`), proceed to Step 10. If it returns `terminated-with-open-items`, surface the open items to the user before continuing.

### Step 10: Completion Summary

When implementation and review are complete, present a summary to the user that includes:

1. **Issue**: ID and title
2. **What was implemented**: Brief description of changes made
3. **Files changed**: List of created/modified files
4. **Adversarial review**: Confirm the adversarial quality review ran. Reproduce the verdict block from `/quality-review` verbatim — its field order is the canonical order:
   - Final review verdict (`passed-clean` / `passed-after-fixes` / `terminated-with-open-items`)
   - Number of review cycles (initial + re-reviews)
   - Critical/High/Medium findings resolved
   - Deferred (Nice-to-Have) items fixed in-session
   - Deferred items filed as Linear issues (with issue IDs)
   - Deferred items dropped (user declined to fix and declined to file)
   - Open items (only on `terminated-with-open-items`; includes any deferred items not handled above)
5. **Checks**: Confirm `pnpm check` passes
6. **Next steps**: Suggest running `/finish` to commit, push, and mark Ready For Release

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it
- If there are unresolved blockers, list them and ask the user how to proceed
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If a git branch for this issue already exists, switch to it instead of creating a new one
