# Git Standards

## Commit Messages and PR Descriptions

### CI Build Prevention

**CRITICAL**: Never include the phrase "skip ci" (or variations like `[skip ci]`, `[ci skip]`) in:

- Commit messages
- PR titles
- PR descriptions
- Any text that could be merged into the main branch

**Why**: When PRs are merged, commit messages become part of the main branch history. If any commit message contains "skip ci", it will prevent CI builds from running on the main branch.

### Safe Alternatives

Instead of mentioning CI skipping behavior, use these alternatives:

❌ **Don't write:**

- "Fixed linting issues (skip ci was used during development)"
- "Updated docs, originally committed with [skip ci]"
- "Minor changes that previously had ci skip"

✅ **Write instead:**

- "Fixed linting issues"
- "Updated documentation"
- "Minor formatting changes"

### Commit Message Guidelines

- Use imperative mood ("Add feature" not "Added feature")
- Keep first line under 50 characters
- Separate subject from body with blank line
- Focus on what and why, not how
- Avoid referencing CI behavior in commit messages

### PR Guidelines

- Summarize the overall change, not individual commit details
- Focus on the business value and technical impact
- Avoid mentioning development workflow details like CI skipping
- Use clear, descriptive titles that explain the change's purpose

## Branch Protection

These standards help ensure:

- Main branch always has functioning CI
- Clean, professional commit history
- No accidental CI bypasses in production code

## Working Tree Protection

**🛑 CRITICAL**: Destructive git commands can cause permanent, unrecoverable data loss. Multiple Claude sessions may be working simultaneously, and the user may have uncommitted work in progress.

### Forbidden Commands (Require Explicit Permission)

These commands are **BLOCKED** by the git-permissions hook (`~/.claude/hooks/git-permissions.sh`) and require explicit user approval:

| Command | Impact | Why Blocked |
|---------|--------|-------------|
| `git reset --hard` | **PERMANENT LOSS** of all uncommitted changes (working tree + staging) | Destroys work from other sessions and user's WIP |
| `git reset --mixed` | Unstages all changes (keeps working tree) | May interfere with other sessions' staged changes |
| `git restore <files>` | **PERMANENT LOSS** of working tree changes for specified files | No recovery possible - changes gone forever |
| `git checkout <files>` | **PERMANENT LOSS** of working tree changes (old syntax) | Same as `git restore`, use that instead |
| `git clean -f/-fd` | **PERMANENT LOSS** of all untracked files | May delete files created by other sessions |
| Any `--force` flag | Overrides safety checks, can cause data loss or destructive remote changes | Bypass of git's protective mechanisms |

### Multi-Session Awareness

**Fundamental principle**: Multiple Claude Code sessions can work simultaneously on the same repository.

**Never assume changes are mistakes:**

```bash
# ❌ CATASTROPHICALLY WRONG
$ git status
  modified: packages/api/config/cucumber.yml
  modified: doc/e2e/README.md

# Claude thinks: "I'm only working on docs, those API changes must be mistakes"
$ git restore packages/api/config/cucumber.yml  # 🛑 DESTROYS OTHER SESSION'S WORK

# ✅ CORRECT RESPONSE
"I notice changes to `packages/api/config/cucumber.yml` in git status.
I'm working on documentation, so this appears to be from other work.
Should I:
1. Include it in this commit?
2. Leave it unstaged for separate work?
3. Something else?"
```

#### `/finish merge` is self-serializing per parent repo

When multiple worktree sessions run `/finish merge` concurrently against the same parent repo, [scripts/finish-merge.sh](../scripts/finish-merge.sh) acquires an exclusive lock keyed by `REPO_ROOT` (via [scripts/with-repo-lock.py](../scripts/with-repo-lock.py)) before touching the main checkout's working tree. Other sessions block on stderr (`[finish-queue] waiting for <REPO_ROOT> ...`) and acquire in turn.

- Lockfile: `~/.claude/locks/repo-<sha1>.lock`. To inspect the current holder: `cat ~/.claude/locks/repo-*.lock`.
- Release: `fcntl.flock` is OS-managed; the lock is released on any process exit (including SIGKILL). No stale-lock cleanup is needed.
- Scope: only the merge step is locked. Worktree-branch pushes, Linear updates, and `gh pr create` (PR mode) run in parallel — they don't contend.
- Conflict-resolution edge case: a `finish-merge.sh` conflict exit releases the lock with `MERGE_HEAD` still present in the parent repo. The next session bails on precondition 5 with an explicit "another /finish session is mid-conflict-resolution" message rather than queueing behind a half-merged checkout.

### Proper File Staging

**Only stage files you created or modified:**

```bash
# ✅ CORRECT - Specific files only
git add doc/e2e/01-playwright-best-practices.md
git add doc/e2e/README.md
git add doc/e2e/04-cucumber-migration.md

# ❌ FORBIDDEN - Stages everything
git add .
git add -A
git add doc/  # Even this is too broad if you didn't touch ALL doc files

# ❌ FORBIDDEN - Touches other work
git add packages/  # Unless you explicitly worked on ALL of packages/
```

### When You See Unexpected Changes

**STOP. DO NOT:**

- Run `git restore` on those files
- Run `git reset` to "clean up"
- Assume they are "unrelated" or "mistakes"
- Stage them with `git add .`

**INSTEAD, ASK:**

```text
"I see changes to <files> that I didn't modify. Should I:
1. Include them in my commit?
2. Leave them unstaged?
3. Create a separate commit for them?"
```

### Safe Commands (Always Allowed)

These commands are safe and do not require permission:

```bash
git status              # Check repository state
git diff                # See changes
git log                 # View history
git add <specific>      # Stage specific files
git commit              # Commit staged changes
git restore --staged    # Unstage (does not discard changes)
git stash               # Save work temporarily
git reflog              # View reference log
```

### Why This Matters: Real Incident

**October 2025 catastrophic failure:**

1. **Session A**: Working on API test configuration files (`packages/api/`)
2. **Session B**: Working on documentation cleanup (`doc/e2e/`)
3. Session B ran `git status`, saw API changes
4. Session B **assumed** API changes were "unrelated mistakes"
5. Session B ran `git restore packages/api/...` → **Destroyed Session A's hours of work**
6. Session B then ran `git reset --hard` → **Destroyed its own staged work**
7. **Total loss**: All uncommitted work from both sessions

**Recovery attempts**: All failed. Unstaged changes deleted by `git restore` are **gone forever**.

### Recovery Reality

| Command Used | Changes Lost | Recovery Possible? |
|--------------|--------------|-------------------|
| `git restore <files>` | Unstaged working tree changes | ❌ **NO** - Permanent loss |
| `git reset --hard` | All uncommitted changes | ⚠️ **Rarely** - Only if staged/committed before |
| `git clean -fd` | Untracked files | ❌ **NO** - Permanent loss |

- Git reflog **does not track** working tree files
- Dangling blobs **rarely help** for unstaged changes
- `git fsck --lost-found` **cannot recover** discarded working tree changes

### Enforcement

The git-permissions hook will **block** these commands with a clear error message. To override:

```bash
# User must explicitly say:
"Yes, run git reset --hard"
"Yes, run this git restore command"

# Only then will Claude be allowed to execute the command
```

### Internalize This

The hook provides enforcement, but you must **understand why**:

- **You are not alone** - Other sessions and user's work exists
- **Changes have reasons** - Never assume mistakes
- **Clean up is not worth data loss** - Leave working tree alone
- **When in doubt, ASK** - User decides what to keep/discard
- **Recovery is usually impossible** - Prevention is the only solution

## Commit and Push Authorization

Commits and pushes are **separate, explicit grants**. Neither is implied by implementation verbs.

### Authorization Rules

- "implement", "do it", "fix it", "make the change" → does NOT authorize a commit
- "commit" → applies only to current set of changes; NOT a standing grant for the session; does NOT include push
- "push" → applies only to currently-committed state; does NOT include future commits; does NOT imply commit
- "commit and push" / "commit, push, and create a PR" → explicit multi-action grant; honor as written

### Default Behavior

Stage nothing, commit nothing, push nothing. Make edits, run hooks/tests, report what changed, wait for explicit direction.

Pre-commit hooks (lint, typecheck) running automatically is fine — those aren't commits.

### When Unsure

Ask: "Want me to commit this, or leave it staged for review?" or "Want me to push, or leave the commit local?"

### Why

Review IS the workflow. Each commit is a recorded artifact the user wants to inspect before it's written to history. Each push is visible to others and triggers CI — both gates exist for the same reason: nothing leaves the user's control without explicit say-so.
