---
name: finish
description: Finish a Linear issue — check off requirements, add completion comment, commit/push, mark Ready For Release. Use when the user says 'finish issue', 'done with this issue', 'complete PL-XX', or invokes /finish.
---

# Finish Issue

Automates the post-completion workflow for a Linear issue using the `linear` CLI.

## Arguments

- Issue identifier (e.g., `PL-12`) — optional, auto-detected from branch/commit
- `no push` / `don't push` / `skip push` — optional, skips the git push step (commit still happens)
- `merge` — only meaningful inside a `/start wt` worktree. Merge the worktree branch back into its recorded source branch, then remove the worktree.
- `pr` — only meaningful inside a `/start wt` worktree. Open a pull request with `base = source branch` and leave the worktree in place.

Examples: `/finish`, `/finish PL-12`, `/finish no push`, `/finish PL-12 no push`, `/finish merge`, `/finish pr PL-12`

## Invariant

**`pnpm check` must pass before committing or pushing code.** Check failures are always CRITICAL — never "pre-existing", never "out of scope", never deferred. Fix them before proceeding. Turborepo caching makes repeated runs cheap.

## Workflow

### Step 0: Parse Worktree-Mode Arguments

1. **Scan args for `merge` and `pr` tokens** (case-insensitive, position-agnostic). If exactly one is present, record it as `$ACTION`. If both are present, stop and ask the user which one — the choice is mutually exclusive.

2. **Detect worktree mode** by reading the source branch recorded by `/start wt`. Read at per-worktree scope (`--worktree --get`) so a manual `start.source-branch` at common scope can't false-trigger worktree mode from outside a `/start wt` worktree. **Echo the values** so they appear in the tool output — Step 9 will need them, and each Bash tool call is a fresh shell so the variables themselves do not persist:

   ```bash
   SOURCE_BRANCH=$(git config --worktree --get start.source-branch 2>/dev/null || true)
   WORKTREE_BRANCH=$(git branch --show-current)
   WT_DIR=$(git rev-parse --show-toplevel)
   # Main repo root (parent of the common .git dir — different from $WT_DIR when in a linked worktree).
   REPO_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
   printf 'SOURCE_BRANCH=%s\nWORKTREE_BRANCH=%s\nWT_DIR=%s\nREPO_ROOT=%s\n' \
     "$SOURCE_BRANCH" "$WORKTREE_BRANCH" "$WT_DIR" "$REPO_ROOT"
   ```

3. **Branch on detection result:**

   - **`$SOURCE_BRANCH` empty AND `$ACTION` set** (`merge` or `pr` outside a worktree): the user's intent is ambiguous — `merge`/`pr` mean nothing here. Stop and warn:

     ```text
     ERROR: `merge` / `pr` is only valid inside a `/start wt` worktree.
     Current branch is `<WORKTREE_BRANCH>` but no `start.source-branch` is recorded.
     For the standard push-to-current flow, run `/finish` without `merge` / `pr`.
     ```

   - **`$SOURCE_BRANCH` empty AND `$ACTION` unset**: standard `/finish` — proceed to Step 1 with today's flow.

   - **`$SOURCE_BRANCH` set AND `$ACTION` unset**: prompt via `AskUserQuestion`:
     - Question: `Finalize ${WORKTREE_BRANCH}?`
     - Options:
       - `merge` (Recommended) — Merge into `${SOURCE_BRANCH}` and remove the worktree.
       - `pr` — Open a pull request with base=`${SOURCE_BRANCH}`; keep the worktree.

     Note: in agent-view background sessions, the prompt surfaces as "Needs input" — the session blocks until the user resolves it. This is intentional: the merge-vs-PR choice has lasting consequences for the parent branch and shouldn't time out to a default.

4. **Validate incompatible argument combinations.** If `$ACTION == "pr"` and `no push` / `don't push` / `skip push` is also present, stop and surface the conflict — opening a PR requires a pushed remote head:

   ```text
   ERROR: `/finish pr` requires pushing the branch. Remove `no push` or use `/finish merge`.
   ```

5. `$ACTION` informs the downstream branching (Step 8 skips when `pr`; Step 9 picks merge vs PR mode). The four shell variables (`$SOURCE_BRANCH`, `$WORKTREE_BRANCH`, `$WT_DIR`, `$REPO_ROOT`) do **not** persist across Bash tool calls — Step 9 re-derives them from the same git probes when it needs them. The printf above is informational only.

### Step 1: Identify the Issue

Determine the issue identifier from (in priority order):

1. **User input** — e.g., `/finish PL-12`
2. **Git branch name** — extract from branch (e.g., `pl-12-scaffold-nextjs-16-app-in-monorepo` → `PL-12`)
3. **Latest commit message** — extract issue key from the most recent commit (only reliable if there are no unstaged changes; if the working tree is dirty, the latest commit may not relate to the current work)

```bash
# Get current branch name
git branch --show-current

# Get latest commit message
git log --oneline -1
```

If the identifier can't be determined from any of the above, ask the user.

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

1. Use the `Write` tool to save the full updated description to `tmp/linear-description-<issue-id>.md` (e.g., `tmp/linear-description-pl-12.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh description PL-12 tmp/linear-description-pl-12.md
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

1. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id>.md` (e.g., `tmp/linear-comment-pl-12.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh comment PL-12 tmp/linear-comment-pl-12.md
```

### Step 6: Verify Check Passes

Run `pnpm check` as a hard gate before committing:

```bash
pnpm check
```

If it **fails**: this is CRITICAL. Do not commit or push. Fix the failures first, then re-run until it passes.

If it **passes**: proceed to commit.

### Step 7: Git Commit & Push

Check the current git state and act accordingly:

```bash
git status
git log --oneline -1
```

- **Uncommitted changes**: Stage relevant files, commit with a descriptive message.
- **Committed but not pushed**: Push to remote (unless `no push` was requested).
- **Already pushed**: Skip — confirm to user that code is already on remote.

**Commit-message requirement.** The issue ID resolved in Step 1 (e.g., `PL-13`) **must** appear in the commit message. Linear auto-links commits referencing an issue ID, so this is how the issue's "Linked branches/commits" panel populates. Prefer a leading-reference convention:

```text
PL-13: <short imperative summary>

<optional body explaining the why>
```

If the issue ID could not be resolved in Step 1 (no input, no branch hint, no commit hint) and the user did not supply one, ask before committing — do not silently commit without the reference.

If the user requested **no push** (e.g., `/finish no push`, `/finish don't push`), skip pushing after commit. Inform the user: "Skipping push as requested. Push manually when ready: `git push`"

Otherwise, always push to the current branch. Do not create PRs (that's a separate workflow).

### Step 8: Mark Issue as Ready For Release

**Skip when `$ACTION == "pr"`.** In PR mode, the work is not yet shipped — review and merge are still pending. Leave the issue in `In Progress`; transition to `Ready For Release` happens after the PR merges (manually, or via a follow-up `/finish` once the worktree branch is merged into source).

In all other cases (no worktree, or `$ACTION == "merge"`):

```bash
linear issues update PL-12 --state "Ready For Release"
```

### Step 9: Worktree Finalization (only when `$SOURCE_BRANCH` is set)

Runs only if Step 0 detected a worktree. Skip entirely otherwise.

**Step 9 is the terminal step of this session** — for both modes. After the merge (or `gh pr create`) completes, present the closing message and stop. Don't run further bash commands.

**If `$ACTION == "merge"`: the merge runs in this session — no subagent.**

The merge produces a real `--no-ff` commit on the source branch. The commit's message must include the Linear issue ID (for auto-linking) and a meaningful summary + body — not the default `Merge <branch> into <source>` boilerplate.

1. **Write the merge-commit message** to `<WT_ABS>/tmp/git-merge-msg-pl-13.md` (use the actual absolute worktree path from Step 0 and the lowercased issue ID) via the `Write` tool. The `Write` tool requires an absolute path; using the absolute form here also guarantees the file lands where `MSG_FILE` (computed in sub-step 2) expects it, regardless of cwd. Shape — first line is the subject (≤72 chars), one blank line, then a body that summarizes what was done:

   ```text
   PL-13: <short imperative summary of what shipped>

   <2–5 lines describing what was implemented, key design choices, and any
   notable verification (e.g., "pnpm check green; 15/15 specs pass"). Mirror
   Step 4's completion-comment content — but tighter, for git history.>

   Merges kross/pl-13-<kebab> into <source-branch>.
   ```

2. **Run the merge in a single Bash tool call** — each Bash invocation is a fresh shell, so the re-derive, `cd`, and script call must share one shell (otherwise `$REPO_ROOT`/`$WT_DIR`/etc. are empty in the script-call shell and `finish-merge.sh` errors out):

   ```bash
   # Re-derive Step 0's values from the current worktree.
   SOURCE_BRANCH=$(git config --worktree --get start.source-branch 2>/dev/null || true)
   WORKTREE_BRANCH=$(git branch --show-current)
   WT_DIR=$(git rev-parse --show-toplevel)
   REPO_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
   MSG_FILE="$WT_DIR/tmp/git-merge-msg-pl-13.md"   # absolute path; survives cd
   printf 'SOURCE_BRANCH=%s\nWORKTREE_BRANCH=%s\nWT_DIR=%s\nREPO_ROOT=%s\nMSG_FILE=%s\n' \
     "$SOURCE_BRANCH" "$WORKTREE_BRANCH" "$WT_DIR" "$REPO_ROOT" "$MSG_FILE"

   # cd out of the worktree to the main checkout (the script removes the worktree
   # on success — cwd must not be inside it).
   cd "$REPO_ROOT"

   # Run the merge. Script handles preconditions, merge (--no-ff -F MSG_FILE),
   # conflict-abort, and cleanup.
   ~/.claude/scripts/finish-merge.sh "$WT_DIR" "$SOURCE_BRANCH" "$WORKTREE_BRANCH" "$MSG_FILE"
   ```

If the script returns 0, surface its output and present the closing message:

```text
✓ <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>. Worktree removed.
This agent-view session is done — close it and dispatch a new session for the next issue.
```

Do not run further bash commands.

If the script exits non-zero (precondition failure or merge conflict), surface its output verbatim and stop. The script's conflict-abort path has already restored the main checkout; the worktree is intact for manual resolution. Do not attempt automated recovery from this session.

**If `$ACTION == "pr"`:**

The branch was pushed in Step 7 (the `no push` + `pr` combination was rejected in Step 0). Open a PR with the recorded source branch as base. Each Bash tool call is a fresh shell, so re-derive the source/worktree values inline and use them in the `gh` command from the same shell.

**Run all three lines in a single Bash tool call** — splitting them across separate calls would leave `$SOURCE_BRANCH` empty in the second call and `gh pr create --base ''` would fail:

```bash
SOURCE_BRANCH=$(git config --worktree --get start.source-branch 2>/dev/null || true)
WORKTREE_BRANCH=$(git branch --show-current)
gh pr create --base "$SOURCE_BRANCH" --head "$WORKTREE_BRANCH" --fill
```

After the PR is created, present the closing message:

```text
✓ PR opened (base=<SOURCE_BRANCH>, head=<WORKTREE_BRANCH>).
This agent-view session is done — review/merge the PR, then `git worktree remove` from the main checkout when you're done.
```

Leave the worktree in place — the PR is the lifecycle boundary. After the PR merges, the user removes the worktree manually from the main repo checkout:

```bash
# cd to the main repo checkout (parent of .claude/worktrees/), then:
git worktree remove .claude/worktrees/<issue-id-lowercased>
```

## Error Handling

- If the issue is already Ready For Release or Done, warn the user and ask if they want to proceed (add comment only)
- If there are no uncommitted changes and code is already pushed, skip the git steps
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If the issue identifier can't be found, ask the user explicitly
