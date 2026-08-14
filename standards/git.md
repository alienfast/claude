# Git Standards

## Commit Messages and PR Descriptions

### `[skip ci]` / `[ci skip]`

CI providers skip a build when the **HEAD commit of a push** carries the token — CircleCI matches it anywhere in that commit's subject or body; earlier commits in the same push trigger nothing. Two consequences:

- **Allowed and useful on working branches**: a docs-only or config-only commit that tops a branch push skips a CI run that would verify nothing.
- **Never let it head a push to the default branch.** Merge commits are the convention (squash+merge is retired), so a branch commit's message never becomes main's HEAD and branch-commit `[skip ci]` cannot suppress main CI. The residual hazards are committing directly to main and fast-forwarding a branch onto main — both put the token-bearing commit at main's HEAD and silently skip its CI.

Because the token matches in the body too, write it literally only when you mean it — prose like "originally committed with [skip ci]" arms the skip.

(The previous absolute ban here dated from the squash+merge era, when PR titles and descriptions became the main-branch commit message. Squash+merge is retired, so that path is gone.)

### Commit Message Guidelines

- Use imperative mood ("Add feature" not "Added feature")
- Keep first line under 50 characters
- Separate subject from body with blank line
- Focus on what and why, not how

### PR Guidelines

- Summarize the overall change, not individual commit details
- Focus on the business value and technical impact
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
| `git stash` (any mutating form: bare, `push`, `pop`, `apply`, `drop`, `clear`) | Applies or drops entries on the repo's ONE worktree-shared stash stack | A concurrent push between your push and pop makes `pop` apply their diff and delete their entry; `stash list`/`show` stay allowed |
| Any `--force` flag | Overrides safety checks, can cause data loss or destructive remote changes | Bypass of git's protective mechanisms |

### The hook only sees the Bash tool's command string

`git-permissions.sh` matches the string the Bash tool was given, and only when `git` is its leading word. A destructive git command run from **inside a script file** (`python3 sweep.py`, `bash revert.sh`) is invisible to it and executes unguarded — and the script runners are themselves pre-approved, so no permission prompt fires either. Any other form that displaces `git` from command position bypasses it the same way: `bash -c "git restore f"`, `cd x && git restore f`, `env git restore f`. The hook is a backstop for direct top-level invocation, not a guarantee.

**To undo a temporary edit — a mutation test, a spike, a bisect probe — copy the file aside and copy it back. Never revert with git, and never park it with `git stash` either.** A `/start wt` worktree's change is typically uncommitted and partly untracked, so `git checkout -- <file>` / `git restore <file>` destroys it with no recovery. `stash` *preserves* the edit, so it reads as compliant with "never revert" — but the stash stack is shared across every worktree of the repo, and a concurrent session's push can make your `pop` apply their work and drop their entry (mechanism under Safe Commands below).

### Multi-Session Awareness

**Fundamental principle**: Multiple Claude Code sessions can work simultaneously on the same repository.

**Never assume changes are mistakes.** Modified files outside your task's scope are evidence of a
concurrent session, not of an error to tidy up. Name the unexpected paths, say they look like other
work, and ask whether to include them or leave them — do not discard them on your own read of what
"should" be modified.

**Timing is not attribution.** A file's mtime falling inside your own subagents' run window is
correlation — a concurrent session or an editor autosave leaves the identical signature, and a
mechanism you invented to explain it ("the tool must have rewritten this") is not evidence. Treat
anything you did not positively write as another session's.

**Prefer the response that needs no attribution: leave it in the working tree and stage your commit
by name.** Excluding a file is free and reversible; reverting destroys work you may not own — and
asking the user to approve a disposition premised on your guess just launders the guess through
them.

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
git stash list          # View the stash stack (read-only)
git reflog              # View reference log
```

**`git stash push`/`pop` are NOT on that list.** The stash stack lives in the **common** git dir (`<repo>/.git/refs/stash`), not per-worktree — every worktree of a repo pushes onto and pops off one shared stack, and `git stash list` from any worktree shows every other session's entries. `pop` takes `stash@{0}` and **drops** it, so a concurrent session pushing between your push and your pop makes your `pop` apply their diff into your tree *and* delete their entry. `git-permissions.sh` blocks every mutating form (bare `stash`, `push`, `pop`, `apply`, `drop`, `clear`), allowing only `stash list`/`stash show` — but the hook sees only top-level `git` commands (see above), so a stash run from inside a script executes unguarded. To undo a temporary edit, use the file-copy rule above.

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

### A path-filtered git command resolves its pathspec against the cwd, and three of them fail silently

`git diff -- <path>`, `git log -- <path>`, and `git show <ref> -- <path>` resolve a bare pathspec relative to the shell's cwd, not the repo root. Issued after a `cd` into a subdirectory — which the rule above notes is sometimes unavoidable, and whose effect persists across every later tool call in the session — a repo-root-relative pathspec silently doubles: `git diff -- apps/api/spec/foo_spec.rb` run from inside `apps/api` resolves to `apps/api/apps/api/spec/foo_spec.rb`, matches nothing, prints **nothing at all**, and exits **0**. That is indistinguishable from "this file has no changes" — a conclusion worth acting on.

`git status -- <path>` is the exception, and only partly: it also exits 0, but prints `warning: could not open directory '<doubled-path>'` to stderr, so it self-diagnoses where the other three do not. Measured on all four.

The tell is an unfiltered form contradicting a filtered one — `git diff --stat` listing a file that `git diff -- <that file>` calls unchanged. Anchor the call instead of trusting the prompt: `git -C <repo-root> …`, per the rule above.

### Worktree-isolated sessions: no loops, no `$(…)`, no `git -C` at the shared checkout

A session registered on a worktree via `EnterWorktree` — every `/start wt`, and so every `/auto` and every fleet session — runs its Bash commands through a static containment check (measured on harness 2.1.222, in foreground and background sessions alike), and subagents inherit the restriction. It refuses four shapes, each with its own message:

- **Any loop construct or `$(…)` command substitution** → *"this command is too complex to verify that it stays inside the worktree; break it into plain, separate commands."* Shape-based, not git-based: a git-free `for` loop over `linear-cli`, the sanctioned `until`-marker poll, and the git-free substitution `echo "$(echo hi)"` are all refused. Statement count is irrelevant in both directions — `echo one; echo two; echo three` runs, while the single simple command `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` is refused. For an UNBOUNDED loop — the sanctioned `until`-marker poll — "break it into separate commands" is unfollowable, since the loop is the construct: `Write` it to a script and run the script instead (the poll-loop form is spelled out in CLAUDE.md § Waiting on delegated work). A BOUNDED fan over a known list (five `diff -u` calls, three `git` probes) is followable as literally instructed — unroll it into one `;` sequence in a single Bash call, `>|` on the first write and `>>` after, and skip the script. **Process substitution is refused in both directions too**, with this same message: measured, `cat <(echo hi)` and `echo hi > >(cat)` are each refused, while bare `cat <file>`, `diff <file> <file>`, an `&&` chain, and a `>|` redirect all run — so the cause is the `<(`/`>(`, not the chaining or the redirect. The natural use, `diff <(…) <(…)` over two derived streams, likewise has no single-command equivalent: write each stream to its own `tmp/` file in separate commands, then `diff` the two files.
- **`eval` as a word, anywhere in the command** → *"this command runs a string through eval, which can't be verified to stay inside the worktree; run the command directly instead."* A word match that ignores quoting: `echo eval` and `echo "eval"` are refused while `evaluate` and `my_eval_helper` run. So it fires on a `grep "eval" …` whose only `eval` is the search pattern (grep for `ev[a]l` instead) and on `agent-browser eval` — that tool's only route for running JS in a page, and the load-bearing step of the Storybook play-function check (basefund's `.claude/rules/storybook.md` records the project-side half); the any-script exemption below covers both.
- **`git -C <path outside the worktree>`** (likewise `--git-dir`, `GIT_DIR`, `GIT_WORK_TREE`) → *"this command redirects git to the shared checkout via -C."* Decided by **target**, not shape: the guard resolves a same-command variable assignment, so `M=/path/to/main; git -C "$M" status` is refused while the identical shape pointing inside the worktree runs.
- **A `-C` target the guard cannot resolve statically** (`git -C ~/.claude …`) → *"this command points git at a directory computed at runtime."* Fails closed.

These still run: a plain top-level `git` command (`git rev-parse --show-toplevel`), a plain git command with a pipe or an `&&` tail (`git status --porcelain && echo DONE`), a plain `;` sequence of simple commands, `git -C <path inside this worktree>` (literal, or a variable that resolves there), and **any script** — only the Bash tool's own command string is analyzed, so `~/.claude/scripts/wt-baseline.sh` keeps working exactly as written even though it runs `git -C "$MAIN_CHECKOUT"` internally.

**A heredoc body is part of the analyzed command string, so prose can trip the first bullet's shape check.** A token sequence *inside the body* that parses as a redirection is refused with that bullet's message — *"too complex to verify that it stays inside the worktree"* — even though the command itself is a plain `cmd <<'EOF'`. This is deterministic and content-dependent, never flaky: measured here, bodies containing `` ` ``, `<JsxTag />`, the prose word `for`, `<`, `<>`, `<-`, or `->` all run, while a body containing `<->` is refused every time. It bites where a command pipes *generated prose* into a script — `quality-review-write-verdict.sh <ID> - <<'VERDICT_EOF'`, `/finish`'s commit-message heredoc, `/pr-update`'s `gh pr edit` body — because the text is composed long before anyone reads it as shell, and the same command shape succeeding on the previous issue makes the refusal look random. Do not conclude the guard is unpredictable and do not abandon the one-call form on the strength of one refusal: reword the offending token in the body (`<->` → `to/from`), or, when the body cannot change, `Write` it to the worktree's `tmp/` and pass that path as an argument instead.

The same refusal fires on a command whose **own** redirect uses zsh's `>>|`: `echo x >>| tmp/f` is refused while the identical call with `>>` or with `>|` runs. `>>|` is zsh-only and a hard bash syntax error, so a bash-grammar check cannot read it as a redirect at all; `>|` parses in both shells and is unaffected. CLAUDE.md's clobber bullet prescribes `>>|` by reflex, so this collides routinely — use one `>|` write, or a script.

So the `git -C /path/to/repo` form recommended above is right everywhere except at a shared checkout from inside a worktree, where it is hard-refused and there is no flag to override it. Derive paths with plain probes instead — from a worktree, `git rev-parse --show-toplevel` gives the worktree root and `git rev-parse --path-format=absolute --git-common-dir` gives `<main-checkout>/.git`, whose parent is the main checkout — then substitute the resulting **literal absolute paths** into subsequent commands. Shell variables cannot carry them between calls anyway: shell state does not survive across Bash tool calls.

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

## Verifying a git config value was registered

`git config --get <key>` reads **system, then global, then local** and returns the highest-precedence value it finds — local overrides global overrides system, and within a single file the last entry wins. It is therefore not a valid check that a setup step — a `prepare` script, an installer, a bootstrap command — registered the value in *this* clone: when the same key is also set in `~/.gitconfig` or `~/.config/git/config`, the command prints the expected value and exits 0 whether the setup step ran, failed, or was reverted. It reads green either way and pins nothing.

Scope the read to the level you are actually asserting about:

```bash
git config --local --get <key>              # this repository only; exits 1 when unset — that failure is the whole signal
git config --show-origin --get-all <key>    # every level, naming the file each value came from
```

For a from-scratch reproduction — fresh clone, setup step deliberately not yet run — neutralize the outer levels too:

```bash
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git config --get <key>
```

`--local` is per-**repository**, not per-worktree: inside a `/start wt` worktree it reads the main clone's shared `$GIT_DIR/config`, so a sibling worktree's setup step satisfies your check. Only `config.worktree` (gated on `extensions.worktreeConfig`) is worktree-scoped.

This is [negative control](problem-solving.md#a-verification-you-never-watched-fail-is-not-a-verification) applied to a one-line check: run the command against the pre-change state and confirm it reads *differently*. Do it especially when the check is going into a **success criterion** — nothing re-verifies a criterion at pickup, so an unfalsifiable one passes every time it is read.

## Commit and Push Authorization

Commits and pushes are **separate, explicit grants**. Neither is implied by implementation verbs.

### Authorization Rules

- "implement", "do it", "fix it", "make the change" → does NOT authorize a commit
- "commit" → applies only to current set of changes; NOT a standing grant for the session; does NOT include push
- "push" → applies only to currently-committed state; does NOT include future commits; does NOT imply commit
- "commit and push" / "commit, push, and create a PR" → explicit multi-action grant; honor as written

### Named exceptions: skill-scoped grants

Invoking `/finish` is an explicit grant to commit and push that one issue's change set — the documented contract of the skill IS the grant. Invoking `/auto` (or `/loop /auto`) is the single **run-scoped standing grant**: it authorizes the `/finish auto` commit+push of every issue that run ships, because unattended shipping is `/auto`'s entire documented purpose. The grant is bounded — no force-pushes, no history rewrites, no committing work unattributable to a Linear issue — and every shipped change is audited via the issue's plan and completion comments. Invoking `/keeper` is an explicit grant to commit and push, in the `~/.claude` repo only, the config changes that run adjudicates and accepts — bounded to files the skill edited or accepted (staged by name), no force-pushes, no history rewrites, and never files the adjudication rejected or deferred (concurrent-session WIP stays in the tree). No other skill or phrasing creates a standing grant.

### Default Behavior

Stage nothing, commit nothing, push nothing. Make edits, run hooks/tests, report what changed, wait for explicit direction.

Pre-commit hooks (lint, typecheck) running automatically is fine — those aren't commits.

### When Unsure

Ask: "Want me to commit this, or leave it staged for review?" or "Want me to push, or leave the commit local?"

### Why

Review IS the workflow. Each commit is a recorded artifact the user wants to inspect before it's written to history. Each push is visible to others and triggers CI — both gates exist for the same reason: nothing leaves the user's control without explicit say-so.

## A worktree forks from where you are working — verify the base, and correct without `--force`

`EnterWorktree` takes no source ref: its base comes from the `worktree.baseRef` setting, and the `fresh`
default forks from `origin/<default-branch>` — NOT from the branch the checkout is on. On a long-running
branch that silently hands you the default branch's tree (measured 2026-08-13: a debug worktree requested
while the checkout sat on `nextjs-descope-user` was cut from origin/main, and its tooling findings described
the wrong tree). This machine sets `worktree.baseRef: "head"` (settings.json), so `EnterWorktree`,
`--worktree`, and agent isolation all fork from the current local HEAD — keep it that way. On a machine
without the setting, VERIFY the fork point on entry before trusting anything in the tree:
`git log --oneline -1` against the intended source, or `git merge-base --is-ancestor <source> HEAD`.

A mis-sourced `EnterWorktree` worktree is corrected with the tool that made it: `ExitWorktree(action:
"remove")`, which refuses to delete uncommitted files or unmerged commits unless `discard_changes: true` is
passed after confirming with the user. Never `git worktree remove --force` — hook-blocked, it destroys the
worktree's contents unexamined, and run from inside the worktree it deletes this session's own cwd (measured
2026-08-13: the session that did was left with no worktree, no cwd, and no replacement). Rebuilding by hand:
verify the source ref exists first (`git rev-parse --verify <ref>`) — a long-running branch often has no
`origin/` twin — and remember the checkout's own branch cannot be checked out twice: fork a NEW branch
(`git worktree add -b <work-branch> <path> <source-branch>`), then re-enter with `EnterWorktree({path})`.

## A throwaway worktree tests HEAD, not your working tree

`git worktree add --detach <path> HEAD` checks out **committed** content — exactly right for capturing a HEAD baseline, and exactly wrong for exercising a change that is still uncommitted (the normal case mid-issue). The worktree runs the *pre-change* code and nothing says so. The failure is biased toward a false PASS: pre-change code exercised against a newly-added guard reproduces the old permissive behavior, which reads as "the command ran fine" rather than as an error, so a guard that never executed gets reported as verified. Run it before and after carrying the change in — the first run is the [negative control](problem-solving.md#a-verification-you-never-watched-fail-is-not-a-verification), and only the difference between the two is evidence.

Carry the change in as a patch rather than enumerating files by hand; one file you forget to copy reproduces the same silent pass:

```bash
git -C <repo> diff HEAD > tmp/wt.diff && git -C <wt> apply tmp/wt.diff   # all tracked modifications
cp <repo>/<new-file> <wt>/<new-file>                                     # untracked additions
```

Undo it before `git worktree remove`: removal refuses on **modified or untracked** files (`fatal: … contains modified or untracked files, use --force to delete it`), and `--force` is blocked by the git-permissions hook, so the flag git suggests is not available. Restore tracked files with `git show HEAD:<path> > <wt>/<path>` — not `git restore`/`git checkout` (hook-blocked), and not `git stash` (also hook-blocked; the stack is worktree-shared — Safe Commands above) — and delete any file you added.
