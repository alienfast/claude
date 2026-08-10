---
name: keeper
description: The keeper's interactive pickup for config work autonomous runs cannot ship — adjudicate both review queues in one pass, the uncommitted local changes in ~/.claude (typically /reflect's auto-applied edits left for review) and every `keeper`-labeled Linear issue workspace-wide (the batches /reflect files because /auto cannot ship cross-repo config work). Judges each fix on its merits, applies the accepted ones, returns recommendations for the rest, and commits and pushes what it applied — invoking /keeper IS the commit/push grant for that adjudicated set (standards/git.md § Named exceptions). Interactive-only; never runs unattended. Use when the user says 'keeper', 'process the keeper queue', 'review the keeper batches', 'what's waiting on me', or invokes /keeper.
---

# Keeper

The interactive half of the `/reflect` pipeline. `/reflect` produces two queues that deliberately wait for a human: user-level `~/.claude` edits it auto-applies but leaves **uncommitted** for review, and `keeper`-labeled Linear issues it files for config work `/auto` can never ship. This skill drains both in one pass: adjudicate every item, apply what holds up, recommend on what doesn't, commit and push the accepted set.

## Step 0: Preconditions

- **Interactive-only.** If this is an `/auto`, fleet, or otherwise unattended session: STOP and say so. The queue exists precisely because these changes need human-gated judgment — an unattended run would launder proposals into shared config past the gate they were filed to get.
- **Not from a worktree-isolated session.** The isolation guard refuses git operations at `~/.claude` from a `/start wt` session; run from a normal session.
- Read [standards/git.md](../../standards/git.md) (any git operation) and [skills/linear/SKILL.md](../linear/SKILL.md) (before any Linear command — the obvious commands silently miss comments).
- Preflight sync: `git -C ~/.claude fetch`, and if behind, `git -C ~/.claude pull --ff-only`. If local changes to upstream-touched files block it, continue without pulling and note it — the push step reconciles.

## Step 1: Gather both queues

**Local**: `git -C ~/.claude status --porcelain`, then the full content — `git -C ~/.claude diff` plus every untracked file read whole. These are *usually* `/reflect` apply-now edits, but never assume: a concurrent session's in-flight WIP leaves the identical signature (`standards/git.md` § Multi-Session Awareness). The tell is shape, not mtime — a reflect edit reads as a complete, self-contained config change with its evidence in the prose; mid-edit WIP has dangling sentences, half-applied renames, or references to work not present. **When in doubt, defer the file**: adjudicate nothing you can't read as finished, leave it untouched, and name it in the report.

**Linear**: the `keeper` label is workspace-level (linear gotcha #7), so sweep all teams with the raw hatch — `issues list` is team-scoped and `search issues` can't filter by label:

```bash
linear-cli api query -o json 'query { issues(filter:{labels:{name:{eq:"keeper"}}, state:{type:{nin:["completed","canceled"]}}}, first:100) { nodes { identifier team { key } title } pageInfo { hasNextPage } } }'
```

Read through the `.data.` prefix (gotcha #6), check for an `errors` key before trusting emptiness (gotcha #13's loud/silent split), and paginate if `hasNextPage` is true — a one-shot read that silently drops the overflow reports a smaller queue than exists. For each hit, get the full picture with `~/.claude/scripts/linear-context.sh <ID>` — anchored comments are invisible to the obvious commands (gotcha #1), and comments routinely carry the evidence, corrections, or supersessions that change a verdict.

Both queues empty → report that in one line and stop.

## Step 2: Adjudicate — one standard for both queues

The unit is an **item**: one file-scoped concern in the local diff, or one proposal inside a keeper issue (reflect files batches — split them). For each item:

1. **Evidence.** Does it rest on a measured or observed event, and is the claim scoped to what the evidence covers ([rules/comments.md](../../rules/comments.md): empirical claims are measured; a family claim is falsified by the member the change skipped)? Verify the cheap claims before accepting — the file, flag, or command a proposal names may have moved since it was filed.
2. **Placement.** Right layer per CLAUDE.md's routing (user-level `~/.claude` vs project config vs memory) and right file (rule vs standard vs skill). An edit that adds path-scoped guidance must land in `paths:` frontmatter coverage, not just prose.
3. **Non-contradiction.** Grep the config for the subject. A duplicate is a rejection with a pointer to the existing text; a contradiction is a needs-you, not a coin flip.
4. **Proportion and wording.** House style holds (comments/markdown rules): sized to the reader, generalizes beyond the session that filed it, imperative and testable where possible.
5. **Blast radius.** Anything that changes what unattended `/auto` fleets do gets a higher bar — a bad rule multiplies across every fleet session. Prefer needs-you over guessing.

Three verdicts: **apply**, **reject** (with the recommendation that would make it acceptable, or why it never will be), **needs-you** (a genuine trade-off — surface the question, don't resolve it by taste).

A keeper item targeting a **project repo** is never edited from here — flag it with a routing recommendation (a project issue, or `/reflect`'s wt flow, which commits project edits on the issue branch) and leave it for the user.

## Step 3: Apply the accepted set

- Local items: the working tree already carries the edit — acceptance means staging it in Step 4. Rejected and deferred files stay exactly as they are: **never revert, never stash** (`standards/git.md` — recovery is not available); the report tells the user what to undo by hand and why.
- Linear items: implement directly in `~/.claude` (Read before Edit, always).
- Gates before any commit: a touched `scripts/<name>.(sh|py)` with a sibling `<name>.test.sh` runs it green; touched markdown runs `npx markdownlint-cli2 <files>` from `~/.claude`. A red gate un-accepts the item — report it, don't ship it.

## Step 4: Commit and push — the skill-scoped grant

Invoking `/keeper` is the explicit grant to commit and push **exactly the adjudicated-accepted set** (`standards/git.md` § Named exceptions). Bounded: stage by name only, never `-A`; no force-pushes; no history rewrites; deferred and rejected files are never swept in.

- One commit per keeper issue — `keeper: <ID> — <summary>`, body carrying per-item outcomes.
- One commit for accepted pre-existing local edits — `keeper: accept local apply-now edits — <areas>`.
- Push once at the end. On a non-fast-forward rejection, `git -C ~/.claude pull --no-rebase` and push again; a merge conflict stops the run with commits local — report, never force.

## Step 5: Linear bookkeeping

Per keeper issue, post a per-item verdict comment via `~/.claude/scripts/linear-post.sh comment <ID> <body-file>` (gotcha #18 — the raw comment commands mis-handle stdin): applied items name the commit SHA, rejections carry their recommendation, needs-you items the question. Then:

- Every item applied or rejected-with-rationale → `linear-cli issues update <ID> --state Done`, re-reading the state to confirm the write took (gotcha #8).
- Any needs-you item remaining → leave the issue open; the comment marks what waits on the user.

The `keeper` label stays either way — state, not label, is what removes it from the queue.

## Report

Lead with the disposition: local files applied/recommended-back/deferred, issues resolved/left-open, commits pushed with SHAs. Then the recommendations, each as *item → why not → what would make it acceptable*. Then the needs-you items as direct questions the user can answer inline. Deferred local files (possible concurrent-session WIP) named last with the shape that made you defer.

## Error handling

- Linear fetch fails → adjudicate the local queue anyway, and say plainly the Linear half did not run — a failed fetch is never reported as an empty queue.
- Push conflict unresolved → commits stay local; report the state and stop.
- A gate failure on one item never blocks the rest of the accepted set — drop the item, ship the remainder, report the drop.
