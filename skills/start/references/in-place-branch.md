# Step 5 in place: branch selection and the fetch before the baseline

Read from `/start` Step 5 when no worktree is involved — Step 0 did not fire and the `start.source-branch` probe
returned nothing. The checkout is shared with every other session on this machine, so nothing here moves HEAD without
the user's say-so.

## Branch selection

```bash
git branch --show-current
```

- **Already on a non-`main` branch** → stay on it and return to Step 5's Baseline check. **Do NOT create a new branch**,
  even when the current branch looks wrong for this issue (unrelated name, far ahead of `main`, or a "cleaner" dedicated
  branch would be nicer): in a shared in-place checkout, `git checkout -b` moves the shared working tree's HEAD and can
  drag or strand a concurrent session's uncommitted work ([standards/git.md](../../../standards/git.md) § Branch
  operations mutate the SHARED working tree). If the branch genuinely seems wrong, STOP and ASK which branch to use —
  never decide unilaterally.
- **On `main`** → switch to the issue's existing branch if one exists, else create one:

  ```bash
  git branch --list "*pl-13*"            # existing branch for this issue?
  git checkout <existing-branch>         # if found
  gh api user --jq .login                # if not: the username prefix, then
  git checkout -b <username>/pl-13-short-kebab-title
  ```

Branch naming: your GitHub username as prefix (`gh api user --jq .login`), the issue key lowercased (`pl-13`), then a
kebab-case title truncated to keep the name reasonable.

## Fetch before baselining

A baseline taken on a stale branch is worthless, and so is the plan built on it: on a long-lived shared branch the tree
can be far behind origin, and every artifact from here on is anchored to it — the `pnpm check` result, an out-of-band
suite's example count, the files Step 6's exploration reads, the plan composed from them. Nothing on this path fetches
otherwise, so nothing reports it:

```bash
git fetch origin
git rev-list --left-right --count HEAD...origin/<current-branch>   # output: "<ahead>\t<behind>"
```

Substitute the literal branch name printed above rather than a `$(…)` substitution — this step is reachable with
`IS_WT` armed, where the isolation guard refuses command substitution. A branch with no origin counterpart makes that
command error; compare against `origin/main` instead, which is what catches a branch just cut from a stale local `main`.

Behind by anything non-trivial → **STOP and ask before pulling.** A pull advances the shared checkout's HEAD and rewrites
files under a concurrent session's uncommitted edits — the same hazard as the no-new-branch rule above. On approval,
`git pull` (a merge; never rebase a shared branch), then baseline. A stale tree has cost a full redo before: the pull
brought a rewrite of a file the approved plan targeted, plus migrations that made the suite baseline fail at load.

`/start wt` does not cover this either: nothing in its path fetches, a fresh create forks off the main checkout's
unfetched HEAD, and `start-wt-create.sh`'s behind/ahead `NOTE:` fires only on the reuse path and only against the
*local* source ref.

Then return to Step 5's **Baseline check**.
