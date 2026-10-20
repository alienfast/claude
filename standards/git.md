# Git Standards

Commits and pushes need an explicit grant; destructive commands are hook-blocked and unrecoverable. Worktree-isolated
sessions (the shell-shape guard, the merge protocol, the worktree lifecycle): [git-worktrees.md](git-worktrees.md).
Windows Git Bash: [git-windows.md](git-windows.md).

## Commit Messages and PR Descriptions

### `[skip ci]` / `[ci skip]`

CI skips a build when the **HEAD commit of a push** carries the token anywhere in its subject or body, so the token on
the top commit un-tests every commit beneath it.

- **A docs-only push carries the token by default**, at the end of the subject. Docs-only is decided by path over the
  whole push range, never by reading the diff: every path in `git diff --name-only --cached origin/<branch>` must end
  in `.md` or `.mdx` (spell the branch out; `$(…)` is refused in worktree-isolated sessions). A branch with no `origin/`
  counterpart dies with `unknown revision` and gets no token. The token is inert where there is no CI.
- **Only Markdown qualifies.** Comments in code files are often directives to the tools a skipped run would exercise,
  and CI or tooling config (`.circleci/`, `.github/`, a lockfile, `package.json`) is what CI most needs to run on.
- **Never let it head a push to the default branch.** Merge commits are the convention, so a branch commit's message
  never becomes main's HEAD; the hazards are committing directly to main and fast-forwarding a branch onto it. Only
  release automation's own version-bump and changelog commits carry the token to main.
- Where a GitHub Actions check is **required** for merge, a skipped run leaves it pending and blocks the PR, so the push
  that will be merged must not carry the token, docs-only or not.
- The token matches in the body too: write it literally only when you mean it.

### Commit Message Guidelines

- `<scope>: <summary>`: `keeper: <ID> — <summary>`, `docs(config): <summary> (via /reflect)`, `checkpoint: <summary> [<ID>]`.
  Roughly 72 characters where it fits; a noun phrase naming what changed beats a truncated imperative. Blank line before
  the body; what and why, not how.
- **One concern per commit; a subject that cannot represent the commit is the tell.** A subject that must name two things
  or go vague (`chore: updates`) means split the commit: work the subject does not name is work nobody finds in
  `git log --oneline` or `git blame`. The unit is the concern, not the file or the finding: one honest subject covering
  thirty files is one commit, and splitting per file or per finding makes a revert a multi-commit operation.
- **The bundling trap is a blocked commit.** A hook refuses the commit, you fix the blocker, and both are now staged
  together with the blocker most likely to win the subject. Commit the unblocking fix by itself first.

### Linear auto-close keywords

**Only the issue being shipped may sit behind a close keyword; every other issue ID in a commit message, PR title or PR
description is referenced bare.** Linear's GitHub integration scans all three surfaces for `<keyword> <ISSUE-ID>` and,
on merge, moves that issue to the team's merge state. The match is positional, not grammatical: a close verb adjacent to
an ID fires whatever the sentence means (`the fix <ID> shipped`, a forward reference to what a future issue will close),
and nothing in the PR flow warns. Keywords: `close/closes/closed/closing`, `fix/fixes/fixed/fixing`,
`resolve/resolves/resolved/resolving`, `complete/completes/completed/completing`,
`implement/implements/implemented/implementing`. Safe forms: a **bare ID**; a **non-closing keyword** (`ref`, `refs`,
`references`, `part of`, `related to`, `relates to`, `contributes to`, `toward`), which links without the state change;
`skip <ID>` / `ignore <ID>`, which suppresses linking.

### PR Guidelines

Summarize the overall change rather than the commits, lead with the business value and technical impact, and give the
PR a title that explains its purpose.

## Working Tree Protection

Multiple Claude sessions work in one repository at once, and the user may have uncommitted work in progress. `git
restore <files>`, `git checkout <file>`, `git reset --hard` and `git clean -f` lose that work permanently: reflog does
not track working-tree files, and `git fsck --lost-found` cannot recover discarded working-tree changes.

### Forbidden Commands

| Command | Rule |
|---|---|
| `git reset` in any mode but `--soft` | bare `git reset` and `git reset HEAD~1` are `--mixed`; `--soft` moves HEAD only |
| `git restore <files>` | `--staged` is allowed |
| `git checkout` / `git switch` with an operand | a `<file>` destroys the file, a `<branch>` moves the shared tree. Allowed only as a plain switch with nothing to lose: an existing branch, a clean tracked tree, a resolvable directory (the payload `cwd` or a literal `-C`), no fleet running out of the checkout. `-B` and `switch -C` are blocked outright; `--detach`, `-b`, `-c` are allowed |
| `--ours` / `--theirs` | only on files git lists as unmerged in a merge in progress; elsewhere it overwrites from the index. Interactive only: an unattended `/finish` resolves conflicts with the Edit tool |
| `git clean -f` / `-fd` | `-n` / `--dry-run` is the sanctioned preview |
| `git stash` mutating forms | `drop`, `clear`, `branch` always; bare, `push`, `pop`, `apply` whenever a second party can be on the stack (a linked worktree, a running fleet). `list` / `show` always allowed |
| force in any spelling | `--force`, `--force-with-lease`, short `-f` (bundled too) on `push`/`branch`/`checkout`/`switch`/`clean`/`worktree`/`tag`/`gc`, a `+refspec` push |

### What the hook enforces

Each row is matched by intent rather than one spelling (`hooks/git-permissions.test.sh` is the guard); the force and
destructive-branch checks run above the `status|log|diff|…` allowlist, so `git branch -D` cannot short-circuit past
them. Every `&&` / `||` / `;` / `|` / newline segment is evaluated after trimming whitespace, and the hook fails closed
on anything it cannot resolve (a quoted or `$VAR` `-C`, a `cd`, no `cwd`, missing `jq`). Nothing said in the
conversation unblocks it; a destructive command the user genuinely wants is run by the user in their own terminal.

### The hook only sees the Bash tool's command string

It matches only a command string whose leading word is `git`. A destructive command inside a script (`python3 sweep.py`)
or displaced from command position (`bash -c "git restore f"`, `cd x && git restore f`, `env git restore f`) runs
unguarded, and the runner is pre-approved so no prompt fires. The rules here bind whether or not the hook catches the
spelling you used.

### To undo a temporary edit, copy the file aside and copy it back

A mutation test, a spike, a bisect probe: never revert with git and never park it with `git stash`. A worktree's change
is typically uncommitted and partly untracked, so `git restore` destroys it with no recovery. The stash stack lives in
the common git dir and is shared by every worktree of the repo; `pop` takes `stash@{0}` and drops it, so a concurrent
session's push between your push and your pop makes your `pop` apply their diff and delete their entry.

### Multi-Session Awareness

- **Never assume changes are mistakes.** Modified files outside your task are evidence of a concurrent session. Name the
  paths, say they look like other work, and ask whether to include or leave them.
- **Timing is not attribution.** An mtime inside your subagents' run window is correlation; an editor autosave leaves the
  same signature. Treat anything you did not positively write as another session's.
- **Prefer the response that needs no attribution:** leave it in the tree and stage your commit by name. Excluding a
  file is free and reversible; reverting destroys work you may not own.

#### Branch operations mutate the SHARED working tree — never reach for them unasked

`git checkout -b` / `git switch -c` are flag-only and run unguarded. Switching carries the current uncommitted changes,
another session's WIP included, onto the target branch, and a concurrent session then commits onto whatever branch you
switched to; a branch you just created can accrue another session's commits before you delete it.

1. Never create, switch or delete a branch in a checkout you do not exclusively own without an explicit instruction. A
   branch that "looks wrong for this issue" is a reason to stop and ask. A `/start wt` worktree is exclusively owned.
2. Before `git branch -D <b>`, verify `git rev-parse <b>` still equals the SHA at creation; if it moved, another session
   committed onto it.
3. Never rebase or rewrite a `/start wt` branch in an unattended run; merge from source instead. An interactive rewrite
   is followed immediately by `~/.claude/scripts/wt-restamp.sh <wt_dir>`, or `/finish` refuses the merge as a hijack.
4. Verify `git branch --show-current` in the **same turn** as any commit or ref-moving command in a shared checkout:
   another session or the IDE can switch it between turns, and `git status --short` does not show the branch. If it is
   not the branch the work belongs on, stop and surface it; never commit "where we are".

### Proper File Staging

Stage only files you created or modified, by path: never `git add .`, `git add -A`, or a directory you did not wholly
touch. When you see unexpected changes, do not `restore`, `reset` or sweep them in; ask whether to include them, leave
them unstaged, or commit them separately.

### Safe Commands

These pass the hook without prompting. **Hook-safe is not authorization**: `add` / `commit` / `push` still need the grant
in § Commit and Push Authorization.

```bash
git status; git diff; git log; git reflog; git add <specific-path>; git commit
git restore --staged <path>                   # unstage without discarding
git stash list                                # read-only
git merge-tree --write-tree <base> <branch>   # dry-run merge: does this merge clean? Touches nothing
```

### Running Git Outside the Current Directory

Use `git -C <dir> …`, never `cd <dir> && git …`: `Bash(git:*)` is pre-approved and `cd:*` is not, so the compound
matches `cd` and prompts every time. The same holds for every pre-approved command: prefer the tool's own directory flag
(`pnpm --dir`, `make -C`), and where a runner genuinely needs its own cwd, a fixed-path wrapper with its own allow rule
(`~/.claude/scripts/wt-rspec.sh`, `wt-ci.sh`, `wt-bundle.sh`). Never a blanket `Bash(cd:*)` rule: even
`Bash(cd apps/api && rspec:*)` admits an appended `; rm -rf ~`. From inside a worktree-isolated session, `git -C` at the
shared checkout is refused ([git-worktrees.md](git-worktrees.md)).

### A path-filtered git command resolves its pathspec against the cwd

`git diff -- <path>`, `git log -- <path>` and `git show <ref> -- <path>` resolve a bare pathspec relative to the shell's
cwd. After a `cd` into a subdirectory (which persists across tool calls) a repo-root-relative path doubles, matches
nothing, prints nothing and exits 0, indistinguishable from "no changes"; only `git status -- <path>` warns. The tell is
an unfiltered form contradicting a filtered one; anchor the call with `git -C <repo-root>`.

### `git log -S` returns the commit that MADE the change

That sha is the wrong ref to read the before-state from: `git show <sha>:<path>` is the file **with** the change, and
the before-state is `git show <sha>^:<path>`. The mistake is silent and inverts the answer (the guard you are checking
for is present, which reads as proof the before-state claim is false), while a wrong *path* fails loudly. Prefer the
diff forms (`git show <sha>`, `git show <sha> -- <path>`) when the question is what changed. `^` is the first parent; on
a merge commit the other side is `<sha>^2` (`git rev-list --parents -n 1 <sha>` names both).

## Verifying a git config value was registered

`git config --get <key>` returns the highest-precedence value across system, global and local, so it says nothing about
whether a setup step registered the value in *this* clone when the key is also set in `~/.gitconfig`. Scope the read:

```bash
git config --local --get <key>              # this repository only; exit 1 when unset is the whole signal
git config --show-origin --get-all <key>    # every level, naming the file each value came from
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git config --get <key>   # fresh-clone reproduction
```

`--local` is per repository, not per worktree: inside a `/start wt` worktree it reads the main clone's shared config;
only `config.worktree` (gated on `extensions.worktreeConfig`) is worktree-scoped. Run the check against the pre-change
state and confirm it reads differently
([problem-solving.md](problem-solving.md#a-verification-you-never-watched-fail-is-not-a-verification)), especially for
a success criterion, which nothing re-verifies at pickup.

## Commit and Push Authorization

Commits and pushes are separate, explicit grants. Neither is implied by implementation verbs.

### Authorization Rules

- "implement", "do it", "fix it", "make the change" → no commit.
- "commit" → the current set of changes only; not a standing grant for the session; no push.
- "push" → the currently committed state only; no future commits; no commit.
- "commit and push" / "commit, push, and create a PR" → an explicit multi-action grant; honor as written.

### Named exceptions: skill-scoped grants

The documented contract of a skill is its grant. No other skill or phrasing creates a standing grant.

- `/finish` commits that one issue's change set; it pushes only under the `push` token or in `pr` mode.
- `/auto` (or `/loop /auto`) is the single **run-scoped standing grant**: the `/finish auto` commit and push of every
  issue the run ships. In worktree-merge mode the push half runs only through `scripts/auto-push-main.sh` (fast-forward
  only, at a deploy-gated pick and at deadline wind-down, only where the project sets `AUTO_PUSH_MAIN=lazy`); elsewhere
  the merge commit waits for a human's push. No force-pushes, no history rewrites, no committing work unattributable to
  a Linear issue.
- `/fleet-sequence` is the same run-scoped grant for the issues it lists, merging into the sequence's integration branch
  (or the launch branch under `merge`); the runner pushes that branch and opens its one PR.
- `/epic-pr` pushes one epic's integration branch by ref and opens its PR; it never merges the PR or moves the checkout.
- `/keeper` commits and pushes, in the `~/.claude` repo only, the config changes it accepts, staged by name, never files
  it rejected or deferred. On the keeper's machine (`reflect.keeper` = `true`) that targets main and covers merging
  accepted proposal PRs; in contributor mode the grant is proposal-branch-only.
- `/checkpoint` commits and pushes one WIP checkpoint of the named issue's change set, staged by name; `no push`
  suppresses the push.
- `/reflect` commits exactly once and never pushes: project-scoped config edits, check-gated and staged by name, with the
  branch verified in the same turn (§ Multi-Session Awareness, rule 4). User-level `~/.claude` edits are never committed
  by that skill.

### Default Behavior

Stage nothing, commit nothing, push nothing. Make edits, run hooks and tests, report what changed, wait for direction.
Pre-commit hooks running on their own are not commits. When unsure, ask: "Want me to commit this, or leave it staged
for review?" or "Want me to push, or leave the commit local?"

### Why

Review is the workflow: each commit is an artifact the user inspects before it enters history, and each push is visible
to others and triggers CI. Nothing leaves the user's control without explicit say-so.
