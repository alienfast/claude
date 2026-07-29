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

### The hook only sees the Bash tool's command string

`git-permissions.sh` matches the string the Bash tool was given, and only when `git` is its leading word. A destructive git command run from **inside a script file** (`python3 sweep.py`, `bash revert.sh`) is invisible to it and executes unguarded — and the script runners are themselves pre-approved, so no permission prompt fires either. Any other form that displaces `git` from command position bypasses it the same way: `bash -c "git restore f"`, `cd x && git restore f`, `env git restore f`. The hook is a backstop for direct top-level invocation, not a guarantee.

**To undo a temporary edit — a mutation test, a spike, a bisect probe — copy the file aside and copy it back. Never revert with git.** A `/start wt` worktree's change is typically uncommitted and partly untracked, so `git checkout -- <file>` / `git restore <file>` destroys it with no recovery.

### Multi-Session Awareness

**Fundamental principle**: Multiple Claude Code sessions can work simultaneously on the same repository.

**Never assume changes are mistakes.** Modified files outside your task's scope are evidence of a
concurrent session, not of an error to tidy up. Name the unexpected paths, say they look like other
work, and ask whether to include them or leave them — do not discard them on your own read of what
"should" be modified.

#### Branch operations mutate the SHARED working tree — never reach for them unasked

The rules above cover file-level destruction (`restore`/`reset`/`clean`), and the hook blocks those. Branch operations are the other multi-session hazard — and the hook does NOT catch them: `git branch` is hook-allowed, and `git checkout`/`git switch` only trip it in the `--`-separated file-restore form, so `git checkout -b` / `git switch -c` / `git branch -D` all run unguarded. In a checkout shared by concurrent sessions they mutate state every session in that directory sees.

- **`git checkout` / `checkout -b` moves the shared working tree.** Switching branches carries the *current* uncommitted changes — including another session's WIP — onto the target branch. A concurrent session that then commits, commits onto **whatever branch you switched to**, not the one it thinks it's on.
- **A branch you "just created" can accrue other sessions' commits.** Between your `checkout -b` and a later `git branch -D`, a concurrent session can land a commit on your branch. The delete then de-references *their* commit — destructive despite you having committed nothing, and the hook won't stop it.
- **Uncommitted changes you didn't create = an active concurrent session. Do not run ANY branch/checkout/switch operation.** Leave the branch and working tree exactly as-is — the same STOP that governs `restore`/`reset`, extended to branch state.

Concrete rules:

1. **Never create, switch, or delete a branch in a checkout you don't exclusively own without an explicit user instruction.** "The current branch looks wrong for this issue" (unrelated name, far ahead of `main`) is a reason to **STOP and ASK**, never to re-branch on your own judgment. (A `/start wt` worktree session exclusively owns its own worktree — creating/deleting its branch there is fine; this is about the shared main checkout.)
2. **Before `git branch -D <b>`, verify `<b>` still points where you left it** (`git rev-parse <b>` == the SHA at creation). If it moved, a concurrent session committed onto it — do not delete; investigate and surface.
3. **Never rebase or otherwise rewrite a `/start wt` branch in an unattended run** — the `/auto` grant excludes history rewrites; merge from source instead. Interactively, a deliberate rewrite must be followed immediately by `~/.claude/scripts/wt-restamp.sh <wt_dir>` (owner-gated; refuses if any commit since the last stamp would be lost), otherwise the rewrite detaches the stamped baseline and `/finish` refuses the merge as a suspected hijack (exit 4).

(Scoped `git add <path>` staging — never `git add -A` in a shared checkout — is already covered under "Proper File Staging" below.)

#### `/finish merge` is self-serializing per parent repo

When multiple worktree sessions run `/finish merge` concurrently against the same parent repo, [scripts/finish-merge.sh](../scripts/finish-merge.sh) acquires an exclusive lock keyed by the repo's common git dir (via [scripts/with-repo-lock.py](../scripts/with-repo-lock.py)) before advancing source — one key per parent repo, shared across all its worktrees. Other sessions block on stderr (`[finish-queue] waiting for <common-git-dir> ...`) and acquire in turn.

The merge is structured so the source branch is only ever advanced cleanly: the worktree branch is first brought up to source's tip **inside the worktree** (private to the session, lock-free, and editable even from a background session), and any conflicts are resolved there — never in the main checkout. Source is then advanced by `git merge --ff-only` (when the main checkout is on source) or an atomic `git update-ref` compare-and-swap (when it is on another branch). The main checkout is therefore never left mid-merge and its HEAD is never switched, so a concurrent session can never merge into an unclean directory.

- Lockfile: `~/.claude/locks/repo-<sha256-prefix>.lock`. To inspect the current holder: `cat ~/.claude/locks/repo-*.lock`.
- Release: `fcntl.flock` is OS-managed; the lock is released on any process exit (including SIGKILL). No stale-lock cleanup is needed.
- Scope: only the fast-forward finalize (and a fast, conflict-free worktree pre-merge) is locked. Worktree-branch pushes, Linear updates, and `gh pr create` (PR mode) run in parallel — they don't contend. On a conflict the script exits 2 and releases the lock; the slow conflict resolution runs lock-free in the private worktree with the main checkout clean and available to other sessions.
- Optimistic re-check: source can advance between a session's worktree pre-merge and its fast-forward (another `/finish merge`, or a local human/CI update). The finalize re-verifies under the lock that the worktree branch still descends from source's current tip and re-merges the new delta if not, looping until it converges — it does not fast-forward a stale branch.

#### Transient blocks are deferred, never forced

A `/finish merge` can be blocked by a condition that will clear on its own — most commonly the **main checkout sitting on the shared source branch with another session's uncommitted WIP** (the merge would have to fast-forward that working tree over edits that aren't ours, which multi-session safety forbids). These are **transient, not failures**: [scripts/finish-merge.sh](../scripts/finish-merge.sh) exits `3` (distinct from `1` hard failure / `2` conflict), self-enqueues the merge to a local queue under `<repo>/.claude/merge-queue/`, and leaves the worktree intact. A local launchd drainer ([scripts/drain-merge-queue.sh](../scripts/drain-merge-queue.sh) → [scripts/merge-queue.sh](../scripts/merge-queue.sh) `drain`) retries every ~15 min until the merge lands. Crucially, the **merge owns the `Ready For Release` transition** ([scripts/mark-ready-for-release.sh](../scripts/mark-ready-for-release.sh)): `/finish` does not mark the issue ready in Step 8 for a `merge` flow — it transitions only after the merge actually lands (Step 9 on exit 0, or the drainer on an async landing). A queued issue therefore stays **In Progress**, so Linear never shows a release state for code that isn't merged. Inspect with `/merge-queue`. The drainer **never** resolves conflicts unattended (that would land unreviewed code on a shared branch) — it flags those for a human and notifies. We never stash, commit, or revert another session's WIP to unblock a merge.

Transient-block triggers reclassified to exit 3: main checkout on source + dirty; source checked out in another worktree; main checkout mid-operation; source under continuous contention. The dirty-tree check is also **relaxed** — it only blocks when the main checkout is actually *on* the source branch, since otherwise source advances by ref-only `git update-ref` that never touches the working tree.

#### Posture for high-concurrency runs (avoids the block entirely)

Running many issues at once, **keep the main checkout parked on a quiet branch** (its own worktree for in-place work, or the default branch) rather than on the shared integration branch. When the main checkout is never on the source branch, every merge advances source by a clean ref-only `git update-ref` — it never blocks on a dirty tree, so the queue rarely engages. The queue is the safety net; this posture is the cheap fix that prevents most deferrals in the first place.

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

Do not `restore` them, do not `reset` to "clean up", and do not sweep them in with `git add .`. Ask
whether to include them, leave them unstaged, or commit them separately.

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

### Running Git Outside the Current Directory

**Never `cd <dir> && git …`. Use `git -C <dir> …` instead.**

```bash
# ❌ FORBIDDEN — triggers a permission prompt every time
cd /path/to/repo && git status

# ✅ CORRECT
git -C /path/to/repo status
```

`Bash(git:*)` is pre-approved, but `cd:*` is not — prefixing with `cd` makes the command match `cd` rather than `git`, so every invocation prompts.

**This is not a git-specific rule — it applies to every pre-approved command.** A `cd <dir> && <allowlisted-cmd>` compound matches `cd`, so the allow rule for the real command never fires and the call falls through to a prompt (or, in auto mode, to the classifier). Prefer the tool's own directory flag whenever one exists — `git -C`, `pnpm --dir`, `make -C`, `rspec` run via a project wrapper script. When a runner genuinely requires its own working directory (Rails/rspec needs `apps/api`), the `cd` prefix is unavoidable and correct: the fix is a permission or `autoMode.allow` entry covering that shape, **not** a blanket `Bash(cd:*)` rule — that would greenlight anything beginning with `cd`, and a trailing-wildcard variant like `Bash(cd apps/api && rspec:*)` still admits an appended `; rm -rf ~`.

### Windows Git Bash: `ref:path` Arguments

MSYS path conversion mangles some colon arguments: `git show origin/main:.gitignore` becomes `origin\main;.gitignore` (`fatal: ambiguous argument`).
It triggers when the ref contains `/` and the path starts with a dot (`origin/main:package.json` passes, `origin/main:.claude/settings.json` fails),
so it looks intermittent. Prefix any `ref:path` command with `MSYS_NO_PATHCONV=1` — harmless on macOS:

```bash
MSYS_NO_PATHCONV=1 git show origin/main:.gitignore
```

### Windows Git Bash: comparing paths

`pwd -P` is not canonical on MSYS — it normalizes differently depending on the input path format, so string-comparing two `pwd -P` outputs across differently-formatted inputs is unreliable. `cd C:/Users/…` and `cd /c/Users/…` are the same location but can resolve to different strings, and a path under a mount alias (`/tmp` → `AppData/Local/Temp`) resolves to `/tmp/…` from one entry form and `/c/Users/…/Temp/…` from another. Git compounds this: `git rev-parse --show-toplevel` (and `--absolute-git-dir`, `--git-common-dir`) emit Windows form (`C:/Users/…`) while surrounding shell code carries MSYS form (`/c/Users/…`).

Do not test path identity by string-comparing resolved paths, and be wary of deriving a value one script `pwd -P`-resolves that another script compares against (e.g. a per-repo lock key from `cd "$common_dir" && pwd -P`) — the two can diverge by input format alone. Prefer a structural signal independent of path format: e.g. to tell a registered linked worktree from an orphaned dir, test the shape of `git rev-parse --absolute-git-dir` (`*/worktrees/*`) plus the worktree's own `.git` pointer, not `--show-toplevel` vs the directory string.

### Recovery is not available

This is why the rules above are absolute rather than advisory. A session once read a concurrent
session's API changes as unrelated mistakes, ran `git restore` on them, then `git reset --hard` to
tidy up — destroying hours of work from both sessions. Every recovery attempt failed.

| Command | Changes lost | Recoverable? |
|---|---|---|
| `git restore <files>` | Unstaged working tree changes | **No** — permanent |
| `git reset --hard` | All uncommitted changes | Only if staged or committed first |
| `git clean -fd` | Untracked files | **No** — permanent |

Reflog does not track working tree files, dangling blobs rarely help for unstaged changes, and
`git fsck --lost-found` cannot recover discarded working tree changes.

The `git-permissions.sh` hook blocks these commands. It unblocks only on an explicit user
instruction naming the command — the hook is the floor, not the reasoning.

## Commit and Push Authorization

Commits and pushes are **separate, explicit grants**. Neither is implied by implementation verbs.

### Authorization Rules

- "implement", "do it", "fix it", "make the change" → does NOT authorize a commit
- "commit" → applies only to current set of changes; NOT a standing grant for the session; does NOT include push
- "push" → applies only to currently-committed state; does NOT include future commits; does NOT imply commit
- "commit and push" / "commit, push, and create a PR" → explicit multi-action grant; honor as written

### Named exceptions: skill-scoped grants

Invoking `/finish` is an explicit grant to commit and push that one issue's change set — the documented contract of the skill IS the grant. Invoking `/auto` (or `/loop /auto`) is the single **run-scoped standing grant**: it authorizes the `/finish auto` commit+push of every issue that run ships, because unattended shipping is `/auto`'s entire documented purpose. The grant is bounded — no force-pushes, no history rewrites, no committing work unattributable to a Linear issue — and every shipped change is audited via the issue's plan and completion comments. No other skill or phrasing creates a standing grant.

### Default Behavior

Stage nothing, commit nothing, push nothing. Make edits, run hooks/tests, report what changed, wait for explicit direction.

Pre-commit hooks (lint, typecheck) running automatically is fine — those aren't commits.

### When Unsure

Ask: "Want me to commit this, or leave it staged for review?" or "Want me to push, or leave the commit local?"

### Why

Review IS the workflow. Each commit is a recorded artifact the user wants to inspect before it's written to history. Each push is visible to others and triggers CI — both gates exist for the same reason: nothing leaves the user's control without explicit say-so.
