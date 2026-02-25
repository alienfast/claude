---
name: start
description: Start working on a Linear issue — check blockers, assign, move to In Progress, create branch, plan implementation, execute with checkpoint updates. Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
version: 1.0.0
---

# Start Issue

Automates the full workflow for starting and implementing a Linear issue using the `linear` CLI.

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

**Read parent issue** (if one exists) for epic-level goals and sibling context:

```bash
linear issues get <parent-id> --format full
```

**Read existing comments** for prior discussion, decisions, or partial work:

```bash
linear issues list-comments PL-13
```

**Download any images** from the description. `uploads.linear.app` URLs require authentication — do NOT use `WebFetch` or `curl`:

```bash
linear attachments download "https://uploads.linear.app/..."
# → /tmp/linear-img-<hash>.png
```

Then `Read` the downloaded file path to view the image.

### Step 4: Assign & Move to In Progress

```bash
linear issues update PL-13 --assignee me --state "In Progress"
```

### Step 5: Create or Switch to Git Branch

Generate a branch name from the issue key and title:

```
kevinross/pl-13-short-kebab-title
```

**Rules:**

- Prefix with `kevinross/`
- Issue key in lowercase (e.g., `pl-13`)
- Kebab-case title, truncated to keep the branch name reasonable
- Check if a branch for this issue already exists before creating one

```bash
# Check for existing branch
git branch --list "*pl-13*"

# If found, switch to it
git checkout <existing-branch>

# If not found, create from current branch
git checkout -b kevinross/pl-13-short-kebab-title
```

### Step 6: Enter Plan Mode

Switch to plan mode to design the implementation:

1. Use the issue description, checkboxes, and parent context as requirements
2. Explore the codebase to understand relevant files, patterns, and dependencies
3. Design a step-by-step implementation plan
4. Present the plan and get user feedback before proceeding

Do not start implementation until the user approves the plan.

### Step 7: Implement

Execute the approved plan. After completing each logical chunk of work:

1. Verify the change (type checks, tests, dev server — whatever is appropriate)
2. Check off the corresponding checkbox(es) in the issue description:

```bash
# Get current description
linear issues get PL-13 --output json
```

Update completed checkboxes (`- [ ]` → `- [x]`) and push the update:

```bash
cat <<'EOF' | linear issues update PL-13 --description -
<updated description with newly checked boxes>
EOF
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

### Step 8: Checkpoint Updates

As implementation progresses:

- Check off `- [ ]` → `- [x]` in the issue description after completing each requirement
- Add brief comments on significant design decisions or unexpected blockers:

```bash
cat <<'EOF' | linear issues comment PL-13 --body -
<checkpoint comment>
EOF
```

This ensures progress is visible in Linear even if the session is interrupted, and enables picking up where we left off.

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it
- If there are unresolved blockers, list them and ask the user how to proceed
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If a git branch for this issue already exists, switch to it instead of creating a new one
