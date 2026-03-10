---
name: start
description: Start working on a Linear issue — check blockers, assign, move to In Progress, create branch, plan implementation, execute with checkpoint updates, review and triage findings. Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
---

# Start Issue

Automates the full workflow for starting and implementing a Linear issue using the `linear` CLI.

## Invariant

**`pnpm check` must pass at all times.** Check failures are always CRITICAL — never "pre-existing", never "out of scope", never deferred. Fix them before proceeding. Turborepo caching makes repeated runs cheap.

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

**Baseline check** — run `pnpm check` to establish a clean baseline before planning:

```bash
pnpm check
```

- If it **passes**: baseline is clean. Any post-implementation failure is unambiguously caused by the implementation.
- If it **fails**: note the failures. These are not exempt — factor them into the implementation plan in Step 6.

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

```md
Task for [agent]: [Specific, focused task]
Context: [Why this task matters, relevant issue context]
Files: [Exact paths and lines]
Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
- Use dedicated tools: Read (not cat/head/tail), Glob (not find/ls), Grep (not grep/rg). Never use cat, ls, find, grep, or rg via Bash.
Acceptance: [How to verify success]
```

**After each delegation completes:**

1. Verify the result (type checks, tests, dev server — whatever is appropriate)
2. If validation fails, delegate investigation to `debugger` or corrections to `developer`
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

### Step 9: Review Implementation (MANDATORY)

**Do NOT skip this step.** The issue is not complete until the review passes. After all implementation tasks from Step 8 are complete, run `pnpm check` as a hard gate before review:

```bash
pnpm check
```

If it **fails**: this is CRITICAL. Do not proceed to review. Delegate fixes to `developer` immediately, then re-run `pnpm check`. Repeat until it passes.

If it **passes**: proceed to the quality review below.

**Delegate the review:**

```md
Task for quality-reviewer: Full implementation review for PL-13
Context: Implementation of [issue title] is complete. Review all changes.
Files: [List every file created or modified during Step 8]
Requirements:
- Correctness: does the implementation satisfy all issue requirements?
- Code quality: naming, structure, readability, maintainability
- Security: injection, auth, data exposure, input validation
- Performance: unnecessary re-renders, N+1 queries, unindexed lookups
- Test coverage: are new paths tested?
Acceptance: Produce a categorized findings report.
```

For large issues spanning multiple domains, **always** spawn parallel reviewers scoped by domain in a single message (e.g., one for backend, one for frontend). The same parallelism principle applies here — reviews are independent and must run simultaneously. Consolidate findings before proceeding.

**Required findings format:**

```markdown
## Review Findings

### Critical (must fix before done)
- [Finding]: [File:line] — [explanation]

### High (should fix)
- [Finding]: [File:line] — [explanation]

### Nice-to-Have / Out-of-Scope
- [Finding]: [rationale for deferring]

### Approved
- [What looks good and why]
```

If **no findings at all** → review passes, implementation is done. If **any** findings exist (any severity, including pre-existing or out-of-scope notes) → proceed to Step 10.

### Step 10: Triage & Fix Loop

If Critical or High findings exist, triage, fix, and re-review until the implementation passes cleanly.

**1. Triage all non-implementation findings** — for any finding (any severity) that is **pre-existing** or **out of scope** for this issue, you **MUST** ask the user whether to create a new Linear issue. Do not silently defer these.

Present each such finding and ask:

- If large scope (new files, new abstractions, estimated >30 min) → **strongly recommend** creating a new Linear issue
- If small scope (one-line fix, trivial rename, missing guard) → suggest fixing now without a new issue, but still ask

For items where the user selects "create a new issue", create it **and** link it back to the current issue. Both steps are required — an unlinked issue is a failure:

```bash
linear issues create --title "<title>" --description "<one-line summary>" --team <team>
linear issues update <new-issue-id> --depends-on PL-13
```

**2. Fix Critical/High items caused by this implementation** — delegate to `developer`. If multiple findings are in independent files, launch parallel fix agents:

```md
Task for developer: Fix review findings for PL-13
Context: Quality reviewer identified the following issues.
Findings:
- [Finding 1]: [File:line] — [explanation]
- [Finding 2]: [File:line] — [explanation]
Requirements:
- Address each finding precisely — no unrelated changes
- Verify with type checks or tests as appropriate
Acceptance: All listed findings resolved, no regressions.
```

After fixes are applied, you MUST continue through items 3→4→5 below. Do not stop after fixing.

**3. Verify check passes** — after fixes, re-run `pnpm check`. If it fails, delegate further fixes before proceeding.

**4. Re-review (MANDATORY)** — fixes are not complete until re-reviewed. Spawn `quality-reviewer` scoped to only the changed files:

```md
Task for quality-reviewer: Re-review fixes for PL-13
Context: Previous review findings were addressed. Review only changed files for regressions and confirm fixes are correct.
Changed files: [list]
Previous findings addressed: [list]
Acceptance: Confirm findings resolved. Flag any new Critical or High issues.
```

**5. Loop** — if the re-review surfaces new Critical or High issues, return to the top of this step (triage → fix → check → re-review).

**Termination**: Maximum 3 review cycles total (initial review + up to 2 re-reviews). If Critical/High issues persist after 3 cycles, surface them to the user:

> The implementation has gone through 3 review cycles and still has unresolved findings:
> [list findings]
>
> Options:
> - Continue fixing (another round)
> - Accept current state and create follow-up issues
> - Revisit the approach with the architect agent

### Step 11: Completion Summary

When implementation and review are complete, present a summary to the user that includes:

1. **Issue**: ID and title
2. **What was implemented**: Brief description of changes made
3. **Files changed**: List of created/modified files
4. **Quality review**: Confirm the quality reviewer ran, and include their summary:
   - Number of review cycles (initial + re-reviews)
   - Critical/High findings found and resolved
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
