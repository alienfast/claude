---
name: start
description: Start working on a Linear issue — check blockers, assign, move to In Progress, create branch, plan implementation, execute with checkpoint updates. Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
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
mkdir -p tmp
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

1. Run `mkdir -p tmp` if not already created this session
2. Use the `Write` tool to save the full updated description to `tmp/linear-description-<issue-id>.md` (e.g., `tmp/linear-description-pl-13.md`)
3. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-13.md issues update PL-13 --description -
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

### Step 8: Checkpoint Updates

As implementation progresses:

- Check off `- [ ]` → `- [x]` in the issue description after completing each requirement
- Add brief comments on significant design decisions or unexpected blockers:

1. Run `mkdir -p tmp` if not already created this session
2. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id>.md` (e.g., `tmp/linear-comment-pl-13.md`)
3. Run:

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-comment-pl-13.md issues comment PL-13 --body -
```

This ensures progress is visible in Linear even if the session is interrupted, and enables picking up where we left off.

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it
- If there are unresolved blockers, list them and ask the user how to proceed
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If a git branch for this issue already exists, switch to it instead of creating a new one
