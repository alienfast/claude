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

2. **Detect worktree mode** by reading the source branch recorded by `/start wt`. The detection uses git's standard config lookup, which (when `extensions.worktreeConfig` is enabled as `/start wt` does) returns the per-worktree value only inside the worktree:

   ```bash
   SOURCE_BRANCH=$(git config --get start.source-branch || true)
   WORKTREE_BRANCH=$(git branch --show-current)
   WT_DIR=$(git rev-parse --show-toplevel)
   # Main repo root (parent of the common .git dir — different from $WT_DIR when in a linked worktree).
   REPO_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
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

5. Carry `$SOURCE_BRANCH`, `$WORKTREE_BRANCH`, `$WT_DIR`, `$REPO_ROOT`, and `$ACTION` forward; they drive Step 8 (state transition) and Step 9 (worktree finalization).

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
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-12.md issues update PL-12 --description -
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
~/.claude/scripts/linear-stdin.sh tmp/linear-comment-pl-12.md issues comment PL-12 --body -
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

- **Uncommitted changes**: Stage relevant files, commit with a descriptive message
- **Committed but not pushed**: Push to remote (unless `no push` was requested)
- **Already pushed**: Skip — confirm to user that code is already on remote

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

**Step 9 is the terminal step of this session.** After dispatching the subagent below (merge mode) or running the `gh pr create` (pr mode), do not run any further bash commands from this session — in merge mode the current cwd ceases to exist, and in pr mode the lifecycle now belongs to the PR. Report the subagent / `gh` output and end.

**If `$ACTION == "merge"`:**

The current session lives inside the worktree, so it cannot remove the directory it is running in. Delegate the merge and cleanup to a subagent running from the main repo checkout. The subagent runs explicit preconditions and on conflict aborts cleanly so the main checkout is never left in a half-merged state.

**Token substitution.** The prompt template below contains `__REPO_ROOT__`, `__WT_DIR__`, `__SOURCE_BRANCH__`, `__WORKTREE_BRANCH__`. Before calling the Agent tool, replace **every occurrence** with the bash-evaluated value — this is a global text-replace, not a structural replace. Tokens appear inside bash commands, inside `echo` recovery instructions, and inside the merge commit message; all must be substituted. **The dispatched prompt must contain zero such tokens** — verify by scanning the constructed prompt with the regex `/__(WT_ABS|ISSUE_ID|REPO_ROOT|WT_DIR|SOURCE_BRANCH|WORKTREE_BRANCH)__/`; if any match, do not dispatch. Any remaining token results in literal bash like `cd __REPO_ROOT__` or end-user-visible echo lines like `Worktree at __WT_DIR__ is intact`, both of which fail after the orchestrator session has already terminated.

```text
Agent({
  subagent_type: "claude",
  prompt: "
    cd __REPO_ROOT__

    # Precondition 1: source branch still exists locally.
    if ! git rev-parse --verify '__SOURCE_BRANCH__' >/dev/null 2>&1; then
      echo 'ERROR: source branch __SOURCE_BRANCH__ no longer exists locally. Cannot merge.'
      echo 'Recovery: fetch or re-create the branch, then re-run /finish merge.'
      exit 1
    fi

    # Precondition 2: worktree still exists. A concurrent session may have
    # removed it; surface a clear error rather than a misleading downstream one.
    if [ ! -d '__WT_DIR__' ]; then
      echo 'ERROR: worktree at __WT_DIR__ no longer exists. A concurrent session may have removed it.'
      exit 1
    fi

    # Precondition 3: worktree has no uncommitted *tracked* changes. Untracked
    # files (editor swap, tmp/ artifacts) do not block a merge — exclude them.
    # Also block when the worktree is mid-merge/rebase/cherry-pick.
    if ! git -C '__WT_DIR__' diff --quiet || ! git -C '__WT_DIR__' diff --cached --quiet; then
      echo 'ERROR: worktree at __WT_DIR__ has uncommitted tracked changes. Commit or stash before merging.'
      exit 1
    fi
    # Use --absolute-git-dir (git ≥2.13) so the result is unambiguous regardless
    # of cwd or git version — without --absolute, --git-dir can return a relative
    # path that resolves against the wrong cwd here. Fail loudly on git <2.13
    # rather than silently passing the mid-merge gate. Capture stderr so the
    # underlying git diagnostic surfaces to the user.
    rp_err=$(mktemp) || { echo 'ERROR: mktemp failed; cannot capture rev-parse stderr.'; exit 1; }
    wt_git_dir=$(git -C '__WT_DIR__' rev-parse --absolute-git-dir 2>\"$rp_err\")
    if [ -z \"$wt_git_dir\" ]; then
      echo 'ERROR: git rev-parse --absolute-git-dir failed (requires git >= 2.13):'
      cat \"$rp_err\" >&2
      rm -f \"$rp_err\"
      exit 1
    fi
    rm -f \"$rp_err\"
    if [ -e \"$wt_git_dir/MERGE_HEAD\" ] || [ -e \"$wt_git_dir/CHERRY_PICK_HEAD\" ] \\
       || [ -d \"$wt_git_dir/rebase-merge\" ] || [ -d \"$wt_git_dir/rebase-apply\" ]; then
      echo 'ERROR: worktree at __WT_DIR__ is mid-merge / mid-rebase / mid-cherry-pick. Finish or abort it before /finish merge.'
      exit 1
    fi

    # Precondition 4: main checkout is clean. `git checkout SOURCE_BRANCH` will
    # either silently carry local changes across or refuse, both of which leave
    # the main checkout in an ambiguous state during a multi-session workflow.
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo 'ERROR: main checkout has uncommitted changes. Commit, stash, or revert before running /finish merge.'
      echo 'Worktree at __WT_DIR__ is untouched.'
      exit 1
    fi

    git fetch --quiet || true
    if ! git checkout '__SOURCE_BRANCH__'; then
      echo 'ERROR: git checkout __SOURCE_BRANCH__ failed. Aborting before merge to avoid merging into the wrong branch.'
      exit 1
    fi

    if git merge --no-ff '__WORKTREE_BRANCH__' \\
         -m 'Merge __WORKTREE_BRANCH__ into __SOURCE_BRANCH__'; then
      # Gate the branch delete on worktree removal succeeding. If remove fails
      # (file lock, permission), we want a dangling worktree dir + intact branch
      # — recoverable. The reverse (deleted branch + stale dir) is worse.
      if git worktree remove '__WT_DIR__'; then
        git branch -d '__WORKTREE_BRANCH__'   # safe delete; refuses if unmerged
        echo 'Merged successfully. Worktree and branch removed.'
      else
        echo 'Merged successfully, but git worktree remove failed for __WT_DIR__.'
        echo 'Branch __WORKTREE_BRANCH__ left intact. Investigate and remove manually:'
        echo '  git worktree remove __WT_DIR__'
        echo '  git branch -d __WORKTREE_BRANCH__'
      fi
      git --no-pager log --oneline -1
    else
      # Conflict path: abort the merge so the main checkout returns to a clean state.
      # The worktree stays intact so the user can resolve from there.
      git merge --abort
      echo 'CONFLICT: merge of __WORKTREE_BRANCH__ into __SOURCE_BRANCH__ produced conflicts.'
      echo 'Main checkout has been aborted to a clean state.'
      echo 'Worktree at __WT_DIR__ is intact. To resolve manually:'
      echo '  cd __REPO_ROOT__'
      echo '  git checkout __SOURCE_BRANCH__'
      echo '  git merge --no-ff __WORKTREE_BRANCH__'
      echo '  # resolve conflicts, then:'
      echo '  git commit'
      echo '  git worktree remove __WT_DIR__'
      echo '  git branch -d __WORKTREE_BRANCH__'
      exit 1
    fi

    Report back: HEAD of source branch after merge, or the conflict-recovery instructions if the merge failed.
  "
})
```

If the subagent reports conflicts: surface them to the user and stop. The main checkout has been restored to a clean state and the worktree is intact for manual resolution.

**If `$ACTION == "pr"`:**

The branch was pushed in Step 7 (the `no push` + `pr` combination was rejected in Step 0). Open a PR with the recorded source branch as base.

**Why PR mode re-derives and merge mode does not.** Merge mode dispatches a single `Agent` call with values substituted into the prompt at orchestrator time (one shot, one shell). PR mode runs `gh pr create` directly from the orchestrator's Bash tool — each Bash invocation is a fresh shell, and Step 0's variables don't persist. The re-derive block below brings them back.

**Re-derive Step 0's values.** Each Bash tool call is a fresh shell — the `$SOURCE_BRANCH`, `$WORKTREE_BRANCH`, `$REPO_ROOT`, `$WT_DIR` vars set in Step 0 do **not** persist into Step 9's shell. Re-derive them at the top of Step 9's bash (run this from inside the worktree, exactly as Step 0 did — `|| true` matches Step 0's idiom even though `$SOURCE_BRANCH` must already exist to reach PR mode):

```bash
SOURCE_BRANCH=$(git config --get start.source-branch || true)
WORKTREE_BRANCH=$(git branch --show-current)
WT_DIR=$(git rev-parse --show-toplevel)
REPO_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
```

**Token substitution.** The commands below contain `__SOURCE_BRANCH__`, `__WORKTREE_BRANCH__`, `__REPO_ROOT__`, `__WT_DIR__`. Substitute each with the values just re-derived. Scan the constructed command with `/__(WT_ABS|ISSUE_ID|REPO_ROOT|WT_DIR|SOURCE_BRANCH|WORKTREE_BRANCH)__/`; if any match, do not run.

```bash
gh pr create --base '__SOURCE_BRANCH__' --head '__WORKTREE_BRANCH__' --fill
```

Leave the worktree in place — the PR is the lifecycle boundary. After the PR merges, the user removes the worktree manually:

```bash
cd '__REPO_ROOT__'
git worktree remove '__WT_DIR__'
```

## Error Handling

- If the issue is already Ready For Release or Done, warn the user and ask if they want to proceed (add comment only)
- If there are no uncommitted changes and code is already pushed, skip the git steps
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If the issue identifier can't be found, ask the user explicitly
