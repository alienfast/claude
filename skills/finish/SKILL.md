---
name: finish
description: Finish a Linear issue — check off requirements, add completion comment, commit/push, mark Ready For Release, suggest next issue. Use when the user says 'finish issue', 'done with this issue', 'complete PL-XX', or invokes /finish.
---

# Finish Issue

Automates the post-completion workflow for a Linear issue using the `linear` CLI.

## Workflow

### Step 1: Identify the Issue

Determine the issue identifier from:

1. **User input** — e.g., `/finish PL-12`
2. **Git branch name** — extract from branch (e.g., `kevinross/pl-12-scaffold-nextjs-16-app-in-monorepo` → `PL-12`)

```bash
# Get current branch name
git branch --show-current
```

If the identifier can't be determined, ask the user.

### Step 2: Get Issue Details

```bash
linear issues get PL-12 --format full
```

Read the description carefully. Note:

- Requirement checkboxes (`- [ ]` items)
- Success criteria checkboxes
- Any "Nice to Have" vs "Must Have" distinctions

### Step 3: Check Off Completed Checkboxes

Get the issue description and update checkboxes based on what was actually completed during this session.

```bash
# Get current description as JSON
linear issues get PL-12 --output json
```

For each `- [ ]` checkbox in the description:

- **If completed**: replace with `- [x]`
- **If not completed**: leave as `- [ ]` and note it in the completion comment

Update the description:

1. Use the `Write` tool to save the full updated description to `/tmp/linear-description.md`
2. Run:

```bash
linear issues update PL-12 --description - < /tmp/linear-description.md
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

### Step 4: Generate Completion Comment

Write a markdown comment summarizing the work. Structure:

```markdown
## Implementation Complete

Branch: `<branch>` | Commit: `<short-sha>`

### What was done
- Bullet points of key changes (files created/modified, features implemented)

### Design decisions
- Key technical choices and why they were made

### Verification
- What was verified (type checks, tests, dev server, etc.)

### Notes
- Any unchecked items with explanation of why
- Any follow-up work identified
```

Omit sections that have no content (e.g., skip "Notes" if everything was completed).

### Step 5: Add Comment to Issue

1. Use the `Write` tool to save the comment to `/tmp/linear-comment.md`
2. Run:

```bash
linear issues comment PL-12 --body - < /tmp/linear-comment.md
```

### Step 6: Git Commit & Push

Check the current git state and act accordingly:

```bash
git status
git log --oneline -1
```

- **Uncommitted changes**: Stage relevant files, commit with a descriptive message, then push
- **Committed but not pushed**: Push to remote
- **Already pushed**: Skip — confirm to user that code is already on remote

Always push to the current branch. Do not create PRs (that's a separate workflow).

### Step 7: Mark Issue as Ready For Release

```bash
linear issues update PL-12 --state "Ready For Release"
```

### Step 8: Suggest Next Issue

Find the most logical next issue to work on:

**First, check what's now unblocked:**

```bash
linear issues blocking PL-12
```

If there are issues that were blocked by this one, they're now candidates — prioritize by priority level.

**Then, check for siblings under the same parent:**

```bash
# Get parent ID from the issue details (from step 2)
linear issues get <parent-id> --format full
```

Look for child issues in Todo/Backlog/In Progress state. The next sibling in dependency order is the best candidate.

**Present the suggestion:**

> **Suggested next issue:** PL-13 — "Auth proxy and cookie session utilities"
> Priority: High | Estimate: 3 points
> **Why**: Was blocked by PL-12 (now unblocked), next in dependency chain under parent epic.

If no clear next issue exists, say so — don't force a suggestion.

## Error Handling

- If the issue is already Ready For Release or Done, warn the user and ask if they want to proceed (add comment only)
- If there are no uncommitted changes and code is already pushed, skip the git steps
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If the issue identifier can't be found, ask the user explicitly
