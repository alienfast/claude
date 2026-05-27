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

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

The script tries `--input` → current branch → latest commit subject, in that order. Pass `--input` only when the user typed an explicit ID (e.g., `/checkpoint PL-12`). On exit 1, ask the user for the identifier explicitly.

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
~/.claude/scripts/linear-post.sh description PL-42 tmp/linear-description-pl-42.md
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
~/.claude/scripts/linear-post.sh comment PL-42 tmp/linear-checkpoint-pl-42.md
```

### Step 9: Tagged Final Line

After Step 8 posts the Linear comment, emit the tagged final line per `standards/lifecycle-tags.md` as the last LLM-authored output. `/checkpoint` always ends with `IN-PROGRESS:` since the issue stays in `In Progress` and work is expected to resume.

**Step 8 succeeded** (`linear-post.sh` exited 0):

```text
IN-PROGRESS: <ISSUE-ID> — <one-line progress summary: e.g., "3 of 5 requirement checkboxes complete; paused mid-implementation.">
```

The summary should match what was just posted to Linear (so the agents-list and Linear stay in sync). For multi-section comments, distill the most recent `### Completed` count or the most-significant in-progress item — one line, not a paraphrase of the whole body.

**Step 8 failed** (`linear-post.sh` exited non-zero — auth dropped, network blip, Linear outage): do NOT silently emit a tag claiming success. Surface the staging-file path so the user can recover, then emit:

```text
IN-PROGRESS: <ISSUE-ID> — <one-line progress summary>. WARNING: Linear comment NOT posted (linear-post.sh failed; see error above). Staging file preserved at tmp/linear-checkpoint-<issue-id-lowercased>.md — re-post manually with: ~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/linear-checkpoint-<issue-id-lowercased>.md
```

The agents-list still shows `IN-PROGRESS:` (work IS in progress), but the inline WARNING makes the de-sync visible so the user doesn't assume Linear was updated.

Do not emit any trailing prose after the tagged line.

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
- **Linear post fails (Step 8 `linear-post.sh` exits non-zero)**: Surface the error to the user, preserve the staging file (`tmp/linear-checkpoint-<id>.md`), and proceed to Step 9 — which emits `IN-PROGRESS:` with an inline WARNING that Linear was NOT updated and a recovery command. Do not silently emit a clean `IN-PROGRESS:` (the agents-list would then claim success while Linear has no record of the checkpoint).
