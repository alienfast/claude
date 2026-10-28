# Git in Worktree-Isolated Sessions

A session registered on a worktree via `EnterWorktree` (every `/start wt`, and so every `/auto` and every fleet
session) runs its Bash commands through a static containment guard, and subagents inherit it. This file owns that
guard, where a delegate's writes must land, the merge protocol `/finish merge` runs between worktrees, and the worktree
lifecycle: fork point, re-pointing, throwaway worktrees, the hourly reaper. The general git rules are in
[git.md](git.md).

## Worktree-isolated sessions: no loops, no `$(…)`, no `git -C` at the shared checkout

Four shapes are refused, each with its own message:

- **Any loop construct, `$(…)` command substitution, or `<(…)` / `>(…)` process substitution** → *"this command is too
  complex to verify that it stays inside the worktree; break it into plain, separate commands."* Shape-based, not
  git-based: a git-free `for` over `linear-cli`, an `until` marker poll and `echo "$(echo hi)"` are all refused, while
  statement count is irrelevant (`echo one; echo two` runs). A bounded fan over a known list unrolls into one `;`
  sequence in a single call (`>|` on the first write, `>>` after). An unbounded loop, the sanctioned marker poll, cannot
  be unrolled: `Write` it to `tmp/<name>.sh` and run `zsh tmp/<name>.sh`. `diff <(a) <(b)` has no single-command
  equivalent: write each stream to its own `tmp/` file in separate commands, then `diff` the files.
- **`eval` as a word, anywhere in the command, quoting ignored** → *"this command runs a string through eval, which
  can't be verified to stay inside the worktree; run the command directly instead."* `grep "eval" …` is refused (grep
  for `ev[a]l` instead) and so is `agent-browser eval`; the any-script exemption below covers both.
- **`git -C <path outside the worktree>`** (likewise `--git-dir`, `GIT_DIR`, `GIT_WORK_TREE`) → *"this command redirects
  git to the shared checkout via -C."* Decided by target, not shape: the guard resolves a same-command variable
  assignment, so `M=/path/to/main; git -C "$M" status` is refused while the identical shape pointing inside the
  worktree runs.
- **A `-C` target the guard cannot resolve statically** (`git -C ~/.claude …`) → *"this command points git at a
  directory computed at runtime."* Fails closed.

These run: a plain top-level `git` command, a git command with a pipe or an `&&` tail, a plain `;` sequence of simple
commands, `git -C <path inside this worktree>` (literal, or a variable that resolves there), and **any script**. Only
the Bash tool's own command string is analyzed, so `~/.claude/scripts/finish-merge.sh` runs `git -C` against the main
checkout internally without issue.

**A heredoc body is part of the analyzed string.** A token sequence inside the body that parses as a redirection is
refused with the first bullet's message even though the command is a plain `cmd <<'EOF'`: `<->` is refused while
`` ` ``, `<JsxTag />`, the word `for`, `<`, `<>`, `<-` and `->` run. It bites where generated prose is piped into a
script (a verdict body, a commit message, a PR body), and the same command shape succeeding on the previous issue makes
the refusal look random; it is deterministic and content-dependent. Reword the token (`<->` → `to/from`), or `Write` the
body to the worktree's `tmp/` and pass that path as an argument. The same refusal fires on a command whose own redirect
is zsh's `>>|` (`>|` and `>>` run): `>>|` is a bash syntax error, so a bash-grammar check cannot read it as a redirect
([shell.md](shell.md) § Redirects).

So `git -C /path/to/main-checkout` is right everywhere except from inside a worktree, where there is no flag to override
the refusal. Derive paths with plain probes, each its own Bash call: `git rev-parse --show-toplevel` is the worktree
root, and `git rev-parse --path-format=absolute --git-common-dir` is `<main-checkout>/.git`, whose parent is the main
checkout. Then substitute the **literal absolute paths** into later commands; shell state does not survive between Bash
calls anyway.

## Delegation placement: a delegate's success report is not evidence its writes landed in the right tree

`EnterWorktree` registration is meant to bind every subagent's Write tool to the worktree root, and it is best-effort:
parallel delegates have written into the main checkout while reporting success. So every delegation a worktree-isolated
session dispatches carries, in its prompt:

- **Read scoping**, on every delegation whatever the agent type, since even a read-only search can leak another
  session's uncommitted content into its output: the worktree root as a literal absolute path (the tree is nested under
  the main checkout, so a bare relative path can resolve in either), absolute paths for every Read/Edit/Write/Glob/Grep,
  and a ban on reading or writing anything under the main checkout outside the worktree.
- **Write placement**, on every write-capable delegation: list every changed file as bare repo-relative paths, built from
  the delegate's own record of its Edit/Write calls, never from `git status`; an empty list is legitimate only when no
  Edit/Write call was made, and a deliberate no-op or revert is named beside its path. The delegate probes neither tree
  and attempts no recovery.

After each write-capable delegation the orchestrator probes every reported path with
`git -C <WT_ABS> status --porcelain --untracked-files=all -- <path>` (an in-worktree `-C` target runs under the guard
normally). Empty output for a path not marked no-op means the writes were lost or misrouted; a green check is no
evidence either, since a worktree missing a delegate's changes still type-checks. Treat it as a failed delegation, not a
halt: re-confirm the `EnterWorktree` registration (cwd is the worktree, entered from the main checkout rather than via a
shell `cd`), re-dispatch scoped to exactly the missing paths with the same blocks, and stop and surface if the
re-dispatch misses too, noting that the writes may have landed in the main checkout for a human to check there. Never
go looking for the writes in the main checkout (it is shared, and nothing there is this session's to take or clean up),
never take over the implementation, and never weaken isolation (`worktree.bgIsolation: "none"`, a `settings.json` edit)
to get past a blocked write; a blocked write is a hard stop. A write-capable delegation that returns no path list is a
protocol failure, not "changed nothing": check the worktree's whole dirty set against its named scope. The main checkout
itself is never measured; other sessions dirty it routinely, and the one moment it matters is the merge, which is
`/finish`'s to handle.

## `/finish merge` between worktrees

### Self-serializing per parent repo

Concurrent `/finish merge` runs against one parent repo serialize through `scripts/finish-merge.sh`, which takes an
exclusive lock keyed by the repo's common git dir (`scripts/with-repo-lock.py`; lockfile
`~/.claude/locks/repo-<sha256-prefix>.lock`; `fcntl.flock`, released on any process exit, so no stale-lock cleanup)
before advancing source. Other sessions wait on stderr (`[finish-queue] waiting for <common-git-dir> …`). The worktree
branch is first brought up to source's tip **inside the worktree**, lock-free, and conflicts are resolved there, never
in the main checkout; source is then advanced by `git merge --ff-only` when the main checkout is on source, or an atomic
`git update-ref` compare-and-swap when it is on another branch, so the main checkout is never left mid-merge and its
HEAD is never switched. Only that finalize is locked; pushes, Linear updates and `gh pr create` run in parallel. On a
conflict the script exits 2 and releases the lock. The finalize re-verifies under the lock that the worktree branch still
descends from source's current tip and re-merges any new delta, looping until it converges, so it never fast-forwards a
stale branch.

### Transient blocks are deferred, never forced

A merge blocked by a condition that clears on its own exits 3 (distinct from 1, hard failure, and 2, conflict),
self-enqueues under `<repo>/.claude/merge-queue/`, and leaves the worktree intact: the main checkout on the source
branch with another session's uncommitted edits to files the merge changes, source checked out in another worktree, the
main checkout mid-operation, source under continuous contention. The dirty-tree check blocks only when the main checkout
is actually on source, since otherwise source advances by a ref-only `git update-ref`. A launchd drainer
(`scripts/drain-merge-queue.sh` → `scripts/merge-queue.sh drain`) retries about every 15 minutes until the merge lands.
The merge owns the `Ready For Release` transition (`scripts/mark-ready-for-release.sh`): a queued issue stays **In
Progress** until the merge lands, because in `merge` mode the landed merge *is* the ship — no PR exists and the worktree
branch is deleted on landing, so until then there is nothing for a release state to name. That is the merge queue's
rule, not a rule about PRs: `Ready For Release` is the state of a ship waiting for its release, an open PR awaiting
merge included — `/finish pr` marks it the moment the PR opens ([linear-workflow.md](linear-workflow.md) § Terminal
States). Inspect with `/merge-queue`.
The drainer never resolves conflicts unattended (it flags them for a human), and nobody stashes, commits or reverts
another session's WIP to unblock a merge.

### Posture for high-concurrency runs

Keep the main checkout parked on a quiet branch (its own worktree for in-place work, or the default branch) rather than
on the shared integration branch: every merge then advances source by a ref-only `git update-ref` that never reads the
tree, and the queue rarely engages. When the checkout must sit on the branch a fleet merges into, each merge
fast-forwards it with `git merge --ff-only`, which carries your uncommitted edits to files the merge leaves alone and
defers the merge to the queue when it would change a file you have edited. So commit every edit you make there in the
same turn (`git add <file> && git commit`); a commit is what clears the block, not a push.

## A worktree forks from where you are working — verify the base, and correct without `--force`

`EnterWorktree` takes no source ref: its base comes from the `worktree.baseRef` setting, and the `fresh` default forks
from `origin/<default-branch>`, not from the branch the checkout is on, which on a long-running branch silently hands you
the default branch's tree. This machine sets `worktree.baseRef: "head"` (settings.json) so `EnterWorktree`,
`--worktree` and agent isolation fork from the current HEAD; keep it that way. On a machine without the setting, verify
the fork point before trusting the tree: `git log --oneline -1` against the intended source, or
`git merge-base --is-ancestor <source> HEAD`.

Correct a mis-sourced worktree with the tool that made it: `ExitWorktree(action: "remove")`, which refuses to delete
uncommitted files or unmerged commits unless `discard_changes: true` is passed after confirming with the user. Never
`git worktree remove --force`: hook-blocked, it destroys the contents unexamined, and run from inside the worktree it
deletes the session's own cwd. Rebuilding by hand: verify the source ref exists (`git rev-parse --verify <ref>`; a
long-running branch often has no `origin/` twin), fork a **new** branch since the checkout's own branch cannot be checked
out twice (`git worktree add -b <work-branch> <path> <source-branch>`), then `EnterWorktree({path})`.

## Re-pointing a `/start wt` worktree at another merge target

The merge target is `git config --worktree start.source-branch <branch>`, which `finish-detect-mode.sh` reads; the
identity gate flags only a wiped value, never a changed one. The two identity sidecars
(`.claude/worktree-identity/wt-identity-<id>.env` in the repo and `wt-identity-<id>.env` under
`~/.claude/jobs/<session>/`) carry the branch too, and a config-only change makes every later probe load the identity
from a sidecar with a dissent WARN. Change `WT_IDENTITY_SOURCE_BRANCH=` in both sidecars to match, or the re-point reads
as tampering from then on. `wt_identity_stamp` is not the tool (the auto-mode classifier blocks it as a bypass), and
neither is deleting and recreating a worktree that already carries work.

## A throwaway worktree tests HEAD, not your working tree

`git worktree add --detach <path> HEAD` checks out **committed** content, so against a change that is still uncommitted
it runs the pre-change code and nothing says so. The failure biases toward a false pass: pre-change code exercised
against a new guard reproduces the old permissive behavior, which reads as "ran fine". Run it before and after carrying
the change in; the first run is the negative control, and only the difference is evidence. Carry the change in as a
patch, since one hand-copied file forgotten reproduces the same silent pass:

```bash
git -C <repo> diff HEAD >| tmp/wt.diff && git -C <wt> apply tmp/wt.diff   # all tracked modifications
cp <repo>/<new-file> <wt>/<new-file>                                     # untracked additions
```

Undo it before `git worktree remove`, which refuses on modified or untracked files and whose `--force` is hook-blocked:
restore tracked files with `git show HEAD:<path> >| <wt>/<path>` (`>|`, since the target exists and an imported
`NO_CLOBBER` would refuse the restore), never `git restore` / `git checkout` / `git stash`, and delete any file you
added.

## The hourly reaper reclaims `/start wt` worktrees it can prove finished — pin one you mean to keep

`reap-worktrees.sh` runs hourly under launchd and removes a worktree, deleting its branch, once the branch is merged into
its source branch or the repo default, the tree is clean, the index has sat idle past the 60-minute grace, and no live
Claude session has its cwd inside it. That encodes the `/start wt` lifecycle: one issue, one branch, merged once. It keys
on provenance: a worktree without the `/start wt` identity stamp (hand-made under `.claude/worktrees/`, or made by
`EnterWorktree`) is reported `KEEP — unmanaged` and never touched, because "merged, clean, idle" is its resting state
between rounds. Two per-worktree keys adjust that; they need `extensions.worktreeConfig`, which `start-wt-setup.sh`
enables in every repo it touches, and a repo without it refuses the write with a `fatal:` naming the extension.

```bash
git -C <wt> config --worktree reap.keep true       # pin: never auto-reaped, stamped or not (KEEP — pinned)
git -C <wt> config --worktree --unset reap.keep    # release the pin
git -C <wt> config --worktree reap.managed true    # opt a hand-made worktree INTO the /start wt rules
```

A worktree with a live Claude session inside it is never reaped, whatever the evidence. Pin a `/start interactive`
worktree you drive from outside it or will return to after the session ends: it is stamped, so once merged and idle with
no session inside it is otherwise eligible. A queued merge outranks the pin: the drainer removes that worktree when its
merge lands. Each pass also removes identity sidecars whose worktree is gone and whose file is older than the grace.

A session that drives a worktree from the main checkout is the one a reap hurts most: `cd <wt>; cmd` against a vanished
worktree reports the failed `cd` on stderr and runs `cmd` anyway, in the main checkout. Address the worktree without
changing directory (`git -C <wt> …`, absolute paths), or chain with `&&` so a failed `cd` stops the line. The reaper's
process sweep kills only processes whose cwd is inside a worktree that is already gone; a session parked in the main
checkout is never in that set.
