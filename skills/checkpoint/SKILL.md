---
name: checkpoint
description: Save progress checkpoint — git commit WIP and update Linear issue with progress comment. Use when the user says 'checkpoint', 'save progress', 'wip commit', or invokes /checkpoint.
---

# Checkpoint

Lightweight mid-task save: commit work-in-progress to git and post a progress update to the Linear issue.

## Arguments

- Issue identifier (e.g., `PL-12`) — optional, auto-detected from branch name or latest commit
- `no push` / `don't push` / `skip push` — optional, skips the git push step (commit still happens)

Examples: `/checkpoint`, `/checkpoint PL-12`, `/checkpoint no push`, `/checkpoint PL-12 no push`

## Workflow

### Step 1: Identify the Issue

Determine the issue identifier from (in priority order):

1. **User input** — e.g., `/checkpoint PL-12`
2. **Git branch name** — extract from branch (e.g., `kross/pl-42-auth-middleware` → `PL-42`)
3. **Latest commit message** — extract issue key (only reliable if there are no unstaged changes; if the working tree is dirty, the latest commit may not relate to the current work)

```bash
# Get current branch name
git branch --show-current

# Get latest commit message
git log --oneline -1
```

If the identifier can't be determined from any of the above, ask the user.

### Step 2: Branch Safety

Verify we're NOT on `main` or `master`. Checkpoint is for feature branches only — refuse and explain if on a protected branch.

### Step 3: Verify Changes Exist

```bash
git status
```

If there are no staged or unstaged changes (working tree is clean), warn the user that there's nothing to checkpoint and exit. A checkpoint without code changes isn't a checkpoint.

### Step 4: Get Issue Details

```bash
linear issues get PL-42 --format full
```

Read the description. Note:

- Title (for commit message)
- Requirement checkboxes (`- [ ]` items)

### Step 5: Update Completed Checkboxes

If any `- [ ]` checkboxes have been completed, update them now.

```bash
# Get current description as JSON
linear issues get PL-42 --output json
```

For each `- [ ]` checkbox in the description:

- **If completed**: replace with `- [x]`
- **If not completed**: leave as `- [ ]`

If any checkboxes changed, update the description:

1. Use the `Write` tool to save the full updated description to `tmp/linear-description-<issue-id>.md`
2. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-42.md issues update PL-42 --description -
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat.

Skip this step entirely if no checkboxes changed.

### Step 6: Check Status (non-blocking)

```bash
pnpm check
```

Record whether checks pass or fail. Do NOT gate on this — it's WIP. If checks fail, note which checks failed for the Linear comment. Continue regardless.

### Step 7: Git Commit & Push

Stage relevant changed files by name (never `git add .` or `git add -A`).

Commit message format: `checkpoint: <brief summary> [<ISSUE-ID>]`

- Imperative mood, lowercase after prefix
- Include issue key in brackets for traceability
- Example: `checkpoint: add auth middleware and route guards [PL-42]`

```bash
git add <specific-files>
git commit -m "checkpoint: <summary> [PL-42]"
```

Then push to remote (unless `no push` was requested):

```bash
git push
```

If the user requested **no push**, skip and inform: "Skipping push as requested. Push manually when ready: `git push`"

### Step 8: Post Linear Comment

Write a checkpoint comment summarizing progress. Structure:

```markdown
## Checkpoint

### Completed
- [bullet points of what's done so far]

### In Progress
- [what's partially done]

### Remaining
- [what's left to do]

### Check Status
✅ All checks pass / ⚠️ Failures: [list failing checks]

### Commit
`<short-sha>` on branch `<branch-name>`
```

Omit empty sections. Keep it concise — this is a status update, not a report.

1. Use the `Write` tool to save the comment to `tmp/linear-checkpoint-<issue-id>.md`
2. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-checkpoint-pl-42.md issues comment PL-42 --body -
```

## Key Differences from /finish

| Aspect | /checkpoint | /finish |
|--------|-------------|---------|
| `pnpm check` | Non-blocking (report only) | Hard gate |
| Issue state | No change (stays In Progress) | Moves to Ready For Release |
| Checkboxes | Update completed ones | Update all completed ones |
| Git push | Default on, `no push` flag | Default on, `no push` flag |
| Linear comment | Progress snapshot | Completion summary |
| Scope | Quick save | Full completion workflow |

## Error Handling

- **On main/master**: Refuse — "Checkpoint is for feature branches. Switch to a feature branch first."
- **No changes**: Warn — "Nothing to checkpoint. Working tree is clean." Exit.
- **No issue found**: Ask the user for the issue identifier.
- **`linear` CLI not authenticated**: Prompt `linear auth login`.
- **Push fails**: Warn but don't fail — the commit is saved locally. User can push later.
