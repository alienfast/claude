# Contributor mode

Read this when `/keeper` Step 0's mode probe does not resolve to keeper mode: `git -C ~/.claude config --get
reflect.keeper` is unset, or it prints `true` on a machine without push access to `alienfast/claude`. Your filings,
your cleanup, the keeper's review via PR. The bar is **global value**: the shared repo carries only what generalizes to
every machine and teammate.

## Step C1: Gather your queue

**Linear** — your own open keeper filings, workspace-wide (the same hatch and gotchas as keeper Step 1, plus the creator
filter):

```bash
linear-cli api query -o json 'query { issues(filter:{labels:{name:{eq:"keeper"}}, creator:{isMe:{eq:true}}, state:{type:{nin:["completed","canceled"]}}}, first:100) { nodes { identifier team { key } title } pageInfo { hasNextPage } } }'
```

Full picture per hit via `~/.claude/scripts/linear-context.sh <ID>`. Other people's keeper issues are never gathered here
— adjudicating the rest of the queue is the keeper's job.

**Local drift** — `git -C ~/.claude status --porcelain`. On a non-keeper machine nothing legitimately commits from the
live checkout, so any dirty file is either a hand-edit worth proposing or clutter; each becomes an item in Step C2.

**Ahead commits** — `git -C ~/.claude log --oneline origin/main..HEAD`. Local commits on main can never be pushed from a
non-keeper machine (main is branch-protected), so they only accumulate conflicts against future pulls. Each commit's
content becomes an item in Step C2, and Step C4 is what returns main to a pure clone.

All three empty → report that in one line and stop.

## Step C2: Adjudicate — the same standard, plus the global-value gate

Apply keeper Step 2's five checks to each item, with one addition that binds hardest here: **does this generalize beyond
you?** Project-specific guidance → withdraw, with a comment routing it to that project's `.claude/` config. Machine- or
person-specific preference → withdraw, with a comment routing it to local settings (`settings.local.json`, local git
config); memory is not a destination. When in doubt whether the team wants it, that is a needs-keeper, not an include.

Three verdicts: **include** (goes into the PR), **withdraw** (your own filing that doesn't hold up — say why in a
comment and close it), **needs-keeper** (a genuine trade-off you can't settle — leave it for the keeper's queue with the
question spelled out).

## Step C3: Build the proposal branch — never on the live checkout

`~/.claude` is live config: checking out a branch there changes the active skills and hooks for every session on this
machine, and parks the clone off-main for as long as review takes. Build in a linked worktree instead:

```bash
git -C ~/.claude worktree add ~/.claude/tmp/proposal-<slug> -b proposal/<slug> origin/main
```

Implement the included items there (Read before Edit, always), under keeper Step 3's gates (sibling script tests green;
`npx markdownlint-cli2` on touched markdown; `pnpm check-anchors && pnpm test` once — all run from the worktree). One commit per issue — `keeper: <ID> — <summary>`,
body carrying per-item outcomes — so the shared history reads the same whoever shipped it.

**Folding local drift in**: copy the live edit into the worktree, commit it on the branch, and only after Step C4's push
confirm the branch copy contains everything the live copy had (`git -C ~/.claude diff proposal/<slug> -- <file>` empty,
or a diff you can read as fully superseded by consolidation). Then restore the live copy — `git -C ~/.claude checkout --
<file>` — which is safe here *because* the content survives on a pushed branch; without that push-and-containment check
the general never-revert rule stands. Drift you did not fold stays untouched: name it in the report with what to undo by
hand.

**Folding ahead commits in**: cherry-pick each onto the proposal branch (`git -C ~/.claude/tmp/proposal-<slug>
cherry-pick <sha>`), or re-implement just the part that passed Step C2 when a commit mixes global value with local-only
content. A commit whose content the user confirms is discardable (asked in this interactive session, shown the diff
first) is skipped rather than carried. A merge commit of `origin/main` carries nothing of its own — skip it without
asking.

## Step C4: Push and open the PR

Invoking `/keeper` in contributor mode is the grant to commit and push **the proposal branch only** — never main
(`standards/git.md` § Named exceptions).

```bash
git -C ~/.claude/tmp/proposal-<slug> push -u origin proposal/<slug>
gh pr create -R alienfast/claude --head proposal/<slug> --title "keeper: <summary>" --body-file <body>
```

The body carries per-issue provenance: each included issue's ID, its evidence in one or two sentences, and what the diff
does about it — the keeper adjudicates from this body plus the diff, so it is the review surface, not decoration. If the
push is denied (no write access): `gh repo fork alienfast/claude --clone=false`, `git -C ~/.claude remote add fork
<fork-url>`, push the branch to `fork`, and pass `--head <login>:proposal/<slug>` to `gh pr create`.

Once the PR exists, `git -C ~/.claude worktree remove ~/.claude/tmp/proposal-<slug>` — the content lives on the pushed
branch, and the live checkout has never left clean main.

**Restoring a pure clone** (only when Step C1 found ahead commits): after the push, and only when every ahead commit is
either carried on the pushed branch or user-confirmed discardable AND no unfolded dirty files remain (a hard reset would
destroy them — if any remain, skip this, report, and leave main as it is):

```bash
git -C ~/.claude branch rescue/main-<date> HEAD
git -C ~/.claude reset --hard origin/main
```

The rescue branch is one-line insurance making the reset fully recoverable; name it in the report so the user can delete
it once the PR merges. This is the sanctioned exception to the never-reset rule, and it is narrow: pushed-branch
containment plus explicit in-session consent for anything dropped.

## Step C5: Close out your issues

Per issue, post a per-item verdict comment (`~/.claude/scripts/linear-post.sh comment`, gotcha #18), then set the state
— re-reading it to confirm the write took (gotcha #8):

- **Any item included** → comment carries the PR URL and per-item verdicts → `--state Done`. The PR is now the pending
  artifact; the keeper's Step 1 PR sweep picks it up.
- **Fully withdrawn** → comment carries the rationale and where the idea belongs instead → `--state Canceled`.
- **Any needs-keeper item** → leave the issue open; the comment carries the question. It stays in the keeper's queue,
  boosted on their `/next`.

## Report and errors

Report: the PR URL first, then issues closed Done/Canceled/left-open and local drift folded/left-for-hand-undo; then the
recommendations and needs-keeper questions as in keeper mode.

`gh pr create` fails after a successful push → the branch is safely on origin; report the exact `gh pr create` command
for the user to run, and do NOT close any Linear issues — Step C5 runs only once the PR exists.
