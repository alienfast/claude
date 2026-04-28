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

### Step 1: Get Issue Details

```bash
linear issues get PL-13 --format full
```

Read the description carefully. Note:

- Requirement checkboxes (`- [ ]` items)
- Success criteria checkboxes
- Any "Nice to Have" vs "Must Have" distinctions
- Parent issue (if any)
- Current state and assignee

### Step 2: Check for Blockers

```bash
linear search --blocks PL-13
```

If unresolved blocking issues exist:

- List them with their state and assignee
- Ask the user whether to proceed anyway or address blockers first
- Do not silently skip blockers

### Step 3: Gather Full Context

**Visualize the dependency graph** to understand the full picture:

```bash
linear deps PL-13
```

**Traverse the parent chain** — issues can be nested (issue → parent → grandparent → epic). Read each ancestor for goals, constraints, and sibling context:

```bash
# Get parent ID from issue details (Step 1 output)
linear issues get <parent-id> --format full

# If that parent also has a parent, keep climbing
linear issues get <grandparent-id> --format full
# Continue until there is no parent
```

Collect context from every level — higher-level issues often contain architectural decisions and scope boundaries that inform implementation.

**Get project description** — if the issue belongs to a project, read the project for roadmap context:

```bash
linear search "<project-name>" --type projects
```

**Read existing comments** for prior discussion, decisions, or partial work:

```bash
linear issues list-comments PL-13
```

**Download any images** from the description. `uploads.linear.app` URLs require authentication — do NOT use `WebFetch` or `curl`:

```bash
linear attachments download "https://uploads.linear.app/..." --output tmp/
# → tmp/linear-img-<hash>.png
```

Then `Read` the downloaded file path to view the image.

### Step 4: Assign & Move to In Progress

```bash
linear issues update PL-13 --assignee me --state "In Progress"
```

### Step 5: Ensure Correct Git Branch

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

Switch to plan mode to design the implementation:

1. Use the issue description, checkboxes, and parent context as requirements
2. Explore the codebase to understand relevant files, patterns, and dependencies
3. Design a step-by-step implementation plan
4. Identify which tasks are independent (parallelizable) vs dependent (sequential)
5. Present the plan and get user feedback before proceeding

Do not start implementation until the user approves the plan. After approval, proceed **immediately** to Step 7 — do not read files, grep, or do any implementation research until the plan is posted to Linear.

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

3. Run:

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
3. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-13.md issues update PL-13 --description -
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

**Do NOT change the issue state** during implementation. The issue stays "In Progress" throughout this entire skill. Moving to "Ready For Release" is handled exclusively by the `/finish` skill after commit and push. Even if all checkboxes are checked, do not transition the state.

**Progress Checkpoints** — As implementation progresses, add brief comments on significant design decisions or unexpected blockers:

1. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id>.md` (e.g., `tmp/linear-comment-pl-13.md`)
3. Run:

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
4. **Adversarial review**: Confirm the adversarial quality review ran, and include their summary:
   - Number of review cycles (initial + re-reviews)
   - Critical/High/Medium findings found and resolved
   - Any issues created for deferred findings (with issue IDs)
   - Final review verdict (passed clean / passed after fixes / terminated with open items)
5. **Checks**: Confirm `pnpm check` passes
6. **Next steps**: Suggest running `/finish` to commit, push, and mark Ready For Release

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it
- If there are unresolved blockers, list them and ask the user how to proceed
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If a git branch for this issue already exists, switch to it instead of creating a new one
