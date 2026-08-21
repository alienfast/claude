---
name: keeper
description: Interactive pickup for the config work autonomous runs cannot ship, with a mode per machine. On the keeper's machine (git -C ~/.claude config reflect.keeper prints true) it adjudicates three queues in one pass — uncommitted local changes in ~/.claude (typically /reflect's apply-now edits left for review), every `keeper`-labeled Linear issue workspace-wide, and open contributor proposal PRs on alienfast/claude — applying what holds up, merging accepted PRs, and committing and pushing the accepted set: invoking /keeper IS the commit/push grant for that adjudicated set (standards/git.md § Named exceptions). On any other machine it runs contributor mode instead — gathers the user's OWN keeper-labeled filings, adjudicates them for global value, builds the accepted set on a proposal branch in a linked worktree (the live checkout never leaves main), opens a PR to alienfast/claude, and closes the filed issues (Done with the PR link when included, Canceled when withdrawn); the grant is proposal-branch-only there, never main. Interactive-only; never runs unattended. Use when the user says 'keeper', 'process the keeper queue', 'review the keeper batches', 'what's waiting on me', 'propose my improvements', 'send my config changes upstream', or invokes /keeper.
---

# Keeper

The interactive half of the `/reflect` pipeline. `/reflect` produces queues that deliberately wait for a human: user-level `~/.claude` edits auto-applied but left **uncommitted** for review (keeper machines only), and `keeper`-labeled Linear issues filed from any machine for config work `/auto` can never ship. Which flow drains them depends on whose machine this is — the probe `git -C ~/.claude config --get reflect.keeper` decides. `true` → **keeper mode**: adjudicate everything, commit to main, push. Anything else (unset, or the probe errors) → **contributor mode**: adjudicate your *own* filings into a proposal PR; main is never touched. The mode switch is the guard — neither outcome is a hard stop.

## Step 0: Preconditions (both modes)

- **Interactive-only.** If this is an `/auto`, fleet, or otherwise unattended session: STOP and say so. The queue exists precisely because these changes need human-gated judgment — an unattended run would launder proposals into shared config past the gate they were filed to get.
- **Not from a worktree-isolated session.** The isolation guard refuses git operations at `~/.claude` from a `/start wt` session; run from a normal session.
- Read [standards/git.md](../../standards/git.md) (any git operation) and [skills/linear/SKILL.md](../linear/SKILL.md) (before any Linear command — the obvious commands silently miss comments).
- **Mode probe**: `git -C ~/.claude config --get reflect.keeper`. Prints `true` → keeper mode, but only after confirming the access that mode assumes: `gh api repos/alienfast/claude --jq .permissions.push` must print `true` too. The flag is machine-local and unaudited — PR #6 came from a machine with the flag set but no push access, whose keeper-mode runs adjudicated the whole queue and stranded commits on local main. Flag without permission → run contributor mode and tell the user to unset the flag (`git -C ~/.claude config --unset reflect.keeper`); it also skews `/next`'s keeper gate. Anything else → contributor mode. Never instruct a non-keeper to set the flag — it is the keeper's one-time setup, not a preference.
- Preflight sync: `git -C ~/.claude fetch`, and if behind, `git -C ~/.claude pull --ff-only`. If local changes to upstream-touched files block it, continue without pulling and note it — keeper mode's push step reconciles, and contributor mode branches from `origin/main` regardless.

## Keeper mode

### Step 1: Gather the queues

**Local**: `git -C ~/.claude status --porcelain`, then the full content — `git -C ~/.claude diff` plus every untracked file read whole. These are *usually* `/reflect` apply-now edits, but never assume: a concurrent session's in-flight WIP leaves the identical signature (`standards/git.md` § Multi-Session Awareness). The tell is shape, not mtime — a reflect edit reads as a complete, self-contained config change with its evidence in the prose; mid-edit WIP has dangling sentences, half-applied renames, or references to work not present. **When in doubt, defer the file**: adjudicate nothing you can't read as finished, leave it untouched, and name it in the report.

**Linear**: the `keeper` label is workspace-level (linear gotcha #7), so sweep all teams with the raw hatch — `issues list` is team-scoped and `search issues` can't filter by label:

```bash
linear-cli api query -o json 'query { issues(filter:{labels:{name:{eq:"keeper"}}, state:{type:{nin:["completed","canceled"]}}}, first:100) { nodes { identifier team { key } title } pageInfo { hasNextPage } } }'
```

Read through the `.data.` prefix (gotcha #6), check for an `errors` key before trusting emptiness (gotcha #13's loud/silent split), and paginate if `hasNextPage` is true — a one-shot read that silently drops the overflow reports a smaller queue than exists. For each hit, get the full picture with `~/.claude/scripts/linear-context.sh <ID>` — anchored comments are invisible to the obvious commands (gotcha #1), and comments routinely carry the evidence, corrections, or supersessions that change a verdict.

**PRs**: `gh pr list -R alienfast/claude --state open` — contributor proposal PRs. Their underlying Linear issues were closed at submit time (contributor mode Step C5), so the PR is the only pending artifact and this sweep is what keeps it from waiting invisibly.

All three queues empty → report that in one line and stop.

### Step 2: Adjudicate — one standard for every queue

The unit is an **item**: one file-scoped concern in the local diff, one proposal inside a keeper issue (reflect files batches — split them), or one per-issue commit inside a proposal PR (adjudicated on the PR diff). For each item:

1. **Evidence.** Does it rest on a measured or observed event, and is the claim scoped to what the evidence covers ([rules/comments.md](../../rules/comments.md): empirical claims are measured; a family claim is falsified by the member the change skipped)? Verify the cheap claims before accepting — the file, flag, or command a proposal names may have moved since it was filed. A filing that declares its own verification was skipped forfeits spot-checking: re-verify every claim in it, not just the cheap ones.
2. **Placement.** Right layer per CLAUDE.md's routing (user-level `~/.claude` vs project config vs memory) and right file (rule vs standard vs skill). An edit that adds path-scoped guidance must land in `paths:` frontmatter coverage, not just prose.
3. **Non-contradiction.** Grep the config for the subject. A duplicate is a rejection with a pointer to the existing text; a contradiction is a needs-you, not a coin flip.
4. **Proportion and wording.** House style holds (comments/markdown rules): sized to the reader, generalizes beyond the session that filed it, imperative and testable where possible. A rule earns its place by contradicting what an unprompted agent actually does, not by being true — well-known doctrine agents already follow is over-prescription, and a measured tell buried in textbook framing compresses to the tell plus the measurement. Evidence in shared-config prose is self-contained — mechanism, date, magnitude — never a foreign-team issue ID: pointers must target a space the keeper curates, and a contributor's IDs belong in the commit message and PR body instead (rules/comments.md's provenance line). Test fixtures replaying real history are data, not decoration — exempt.
5. **Blast radius.** Anything that changes what unattended `/auto` fleets do gets a higher bar — a bad rule multiplies across every fleet session. Prefer needs-you over guessing.

Three verdicts: **apply**, **reject** (with the recommendation that would make it acceptable, or why it never will be), **needs-you** (a genuine trade-off — surface the question, don't resolve it by taste).

A keeper item targeting a **project repo** is never edited from here — flag it with a routing recommendation (a project issue, or `/reflect`'s wt flow, which commits project edits on the issue branch) and leave it for the user. The subtler form is an item that *edits shared config* but whose value is project-scoped — one team's workflow states, one stack's tooling, one repo's conventions dressed as a general rule: that is a **route-to-project**, not an accept, whatever file the diff touches. An item mixing a global principle with project-specific detail splits — the principle lands in shared config, the detail routes to the filer's project rules, and the verdict names which sentence is which.

### Step 3: Apply the accepted set

- Local items: the working tree already carries the edit — acceptance means staging it in Step 4. Rejected and deferred files stay exactly as they are: **never revert, never stash** (`standards/git.md` — recovery is not available); the report tells the user what to undo by hand and why.
- Linear items: implement directly in `~/.claude` (Read before Edit, always).
- PR items: nothing to apply locally — the merge in Step 4 is the apply. Review on GitHub (inline comments where a recommendation is line-scoped).
- Gates before any commit: a touched `scripts/<name>.(sh|py)` with a sibling `<name>.test.sh` runs it green; touched markdown runs `npx markdownlint-cli2 <files>` from `~/.claude`. A red gate un-accepts the item — report it, don't ship it.

### Step 4: Commit, merge, push — the skill-scoped grant

Invoking `/keeper` is the explicit grant to commit and push **exactly the adjudicated-accepted set** (`standards/git.md` § Named exceptions). Bounded: stage by name only, never `-A`; no force-pushes; no history rewrites; deferred and rejected files are never swept in.

- One commit per keeper issue — `keeper: <ID> — <summary>`, body carrying per-item outcomes.
- One commit for accepted pre-existing local edits — `keeper: accept local apply-now edits — <areas>`.
- Accepted PRs: `gh pr merge --rebase` (per-issue commits land as-is, history stays linear). Rejected items in a PR: request changes with the recommendation and leave it open. A PR rejected outright is closed unmerged with the rationale in a review comment — its body's per-issue provenance says which Linear issues to reopen if any item deserves another round; otherwise the closed PR's thread is the durable rationale.
- Push once at the end. On a non-fast-forward rejection, `git -C ~/.claude pull --no-rebase` and push again; a merge conflict stops the run with commits local — report, never force.

### Step 5: Linear bookkeeping

Per keeper issue, post a per-item verdict comment via `~/.claude/scripts/linear-post.sh comment <ID> <body-file>` (gotcha #18 — the raw comment commands mis-handle stdin): applied items name the commit SHA, rejections carry their recommendation, needs-you items the question. Then:

- Every item applied or rejected-with-rationale → `linear-cli issues update <ID> --state Done`, re-reading the state to confirm the write took (gotcha #8).
- Any needs-you item remaining → leave the issue open; the comment marks what waits on the user.

The `keeper` label stays either way — state, not label, is what removes it from the queue. Merged or closed PRs need no Linear writes — their issues were closed at submit time.

## Contributor mode

Your filings, your cleanup, the keeper's review via PR. The bar is **global value**: the shared repo carries only what generalizes to every machine and teammate.

### Step C1: Gather your queue

**Linear** — your own open keeper filings, workspace-wide (same hatch and gotchas as keeper Step 1, plus the creator filter):

```bash
linear-cli api query -o json 'query { issues(filter:{labels:{name:{eq:"keeper"}}, creator:{isMe:{eq:true}}, state:{type:{nin:["completed","canceled"]}}}, first:100) { nodes { identifier team { key } title } pageInfo { hasNextPage } } }'
```

Full picture per hit via `~/.claude/scripts/linear-context.sh <ID>`. Other people's keeper issues are never gathered here — adjudicating the rest of the queue is the keeper's job.

**Local drift** — `git -C ~/.claude status --porcelain`. On a non-keeper machine nothing legitimately commits from the live checkout, so any dirty file is either a hand-edit worth proposing or clutter; each becomes an item in Step C2.

**Ahead commits** — `git -C ~/.claude log --oneline origin/main..HEAD`. Local commits on main can never be pushed from a non-keeper machine (main is branch-protected), so they only accumulate conflicts against future pulls. Each commit's content becomes an item in Step C2, and Step C4 is what returns main to a pure clone.

All three empty → report that in one line and stop.

### Step C2: Adjudicate — the same standard, plus the global-value gate

Apply keeper Step 2's five checks to each item, with one addition that binds hardest here: **does this generalize beyond you?** Project-specific guidance → withdraw, with a comment routing it to that project's `.claude/` config. Machine- or person-specific preference → withdraw, with a comment routing it to local settings or memory. When in doubt whether the team wants it, that is a needs-keeper, not an include.

Three verdicts: **include** (goes into the PR), **withdraw** (your own filing that doesn't hold up — say why in a comment and close it), **needs-keeper** (a genuine trade-off you can't settle — leave it for the keeper's queue with the question spelled out).

### Step C3: Build the proposal branch — never on the live checkout

`~/.claude` is live config: checking out a branch there changes the active skills and hooks for every session on this machine, and parks the clone off-main for as long as review takes. Build in a linked worktree instead:

```bash
git -C ~/.claude worktree add ~/.claude/tmp/proposal-<slug> -b proposal/<slug> origin/main
```

Implement the included items there (Read before Edit, always), under keeper Step 3's gates (sibling script tests green; `npx markdownlint-cli2` on touched markdown — run from the worktree). One commit per issue — `keeper: <ID> — <summary>`, body carrying per-item outcomes — so the shared history reads the same whoever shipped it.

**Folding local drift in**: copy the live edit into the worktree, commit it on the branch, and only after Step C4's push confirm the branch copy contains everything the live copy had (`git -C ~/.claude diff proposal/<slug> -- <file>` empty, or a diff you can read as fully superseded by consolidation). Then restore the live copy — `git -C ~/.claude checkout -- <file>` — which is safe here *because* the content survives on a pushed branch; without that push-and-containment check the general never-revert rule stands. Drift you did not fold stays untouched: name it in the report with what to undo by hand.

**Folding ahead commits in**: cherry-pick each onto the proposal branch (`git -C ~/.claude/tmp/proposal-<slug> cherry-pick <sha>`), or re-implement just the part that passed Step C2 when a commit mixes global value with local-only content. A commit whose content the user confirms is discardable (asked in this interactive session, shown the diff first) is skipped rather than carried. A merge commit of `origin/main` (the get-current step users run before this skill) carries nothing of its own — skip it without asking.

### Step C4: Push and open the PR

Invoking `/keeper` in contributor mode is the grant to commit and push **the proposal branch only** — never main (`standards/git.md` § Named exceptions).

```bash
git -C ~/.claude/tmp/proposal-<slug> push -u origin proposal/<slug>
gh pr create -R alienfast/claude --head proposal/<slug> --title "keeper: <summary>" --body-file <body>
```

The body carries per-issue provenance: each included issue's ID, its evidence in one or two sentences, and what the diff does about it — the keeper adjudicates from this body plus the diff, so it is the review surface, not decoration. If the push is denied (no write access): `gh repo fork alienfast/claude --clone=false`, `git -C ~/.claude remote add fork <fork-url>`, push the branch to `fork`, and pass `--head <login>:proposal/<slug>` to `gh pr create`.

Once the PR exists, `git -C ~/.claude worktree remove ~/.claude/tmp/proposal-<slug>` — the content lives on the pushed branch, and the live checkout has never left clean main.

**Restoring a pure clone** (only when Step C1 found ahead commits): after the push, and only when every ahead commit is either carried on the pushed branch or user-confirmed discardable AND no unfolded dirty files remain (a hard reset would destroy them — if any remain, skip this, report, and leave main as it is):

```bash
git -C ~/.claude branch rescue/main-<date> HEAD
git -C ~/.claude reset --hard origin/main
```

The rescue branch is one-line insurance making the reset fully recoverable; name it in the report so the user can delete it once the PR merges. This is the sanctioned exception to the never-reset rule, and it is narrow: pushed-branch containment plus explicit in-session consent for anything dropped.

### Step C5: Close out your issues

Per issue, post a per-item verdict comment (`~/.claude/scripts/linear-post.sh comment`, gotcha #18), then set the state — re-reading it to confirm the write took (gotcha #8):

- **Any item included** → comment carries the PR URL and per-item verdicts → `--state Done`. The PR is now the pending artifact; the keeper's Step 1 PR sweep picks it up.
- **Fully withdrawn** → comment carries the rationale and where the idea belongs instead → `--state Canceled`.
- **Any needs-keeper item** → leave the issue open; the comment carries the question. It stays in the keeper's queue, boosted on their `/next`.

## Report

Lead with the disposition. Keeper mode: local files applied/recommended-back/deferred, issues resolved/left-open, PRs merged/changes-requested/closed, commits pushed with SHAs. Contributor mode: the PR URL first, then issues closed Done/Canceled/left-open and local drift folded/left-for-hand-undo. Then the recommendations, each as *item → why not → what would make it acceptable*. Then the needs-you/needs-keeper items as direct questions. Deferred local files (possible concurrent-session WIP) named last with the shape that made you defer.

## Error handling

- Linear fetch fails → adjudicate the local queue anyway, and say plainly the Linear half did not run — a failed fetch is never reported as an empty queue.
- Push conflict unresolved (keeper mode) → commits stay local; report the state and stop.
- `gh pr create` fails after a successful push (contributor mode) → the branch is safely on origin; report the exact `gh pr create` command for the user to run, and do NOT close any Linear issues — Step C5 runs only once the PR exists.
- A gate failure on one item never blocks the rest of the accepted set — drop the item, ship the remainder, report the drop.
