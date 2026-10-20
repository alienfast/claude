---
name: keeper
description: Interactive pickup of config work /auto cannot ship. Keeper machine (git config `reflect.keeper` true) — adjudicate uncommitted ~/.claude edits, `keeper`-labeled Linear issues and proposal PRs, then commit and push the accepted set (invoking it is that grant). Other machines — contributor mode, your own filings into a proposal PR. Use when the user says 'keeper', 'process the keeper queue', 'what's waiting on me', or invokes /keeper.
---

# Keeper

The interactive half of the `/reflect` pipeline. `/reflect` produces queues that deliberately wait for a human:
user-level `~/.claude` edits auto-applied but left **uncommitted** for review (keeper machines only), and
`keeper`-labeled Linear issues filed from any machine for config work `/auto` can never ship. Which flow drains them
depends on whose machine this is — the probe `git -C ~/.claude config --get reflect.keeper` decides. `true` → **keeper
mode**: adjudicate everything, commit to main, push. Anything else → **contributor mode**
([references/contributor-mode.md](references/contributor-mode.md)): adjudicate your *own* filings into a proposal PR;
main is never touched. The mode switch is the guard — neither outcome is a hard stop.

## Step 0: Preconditions (both modes)

- **Interactive-only.** In an `/auto`, fleet, or otherwise unattended session: STOP and say so. The queue exists because
  these changes need human-gated judgment — an unattended run would launder proposals into shared config past the gate
  they were filed to get.
- **Not from a worktree-isolated session.** The isolation guard refuses git operations at `~/.claude` from a `/start wt`
  session; run from a normal session.
- Read [standards/git.md](../../standards/git.md) (any git operation) and [skills/linear/SKILL.md](../linear/SKILL.md)
  (before any Linear command — the obvious commands silently miss comments).
- **Mode probe**: `git -C ~/.claude config --get reflect.keeper`. Prints `true` → keeper mode, but only after confirming
  the access that mode assumes: `gh api repos/alienfast/claude --jq .permissions.push` must print `true` too. The flag
  is machine-local and unaudited; a flag without push access adjudicates the whole queue and strands commits on local
  main. Flag without permission → run contributor mode and tell the user to unset the flag (`git -C ~/.claude config
  --unset reflect.keeper`); it also skews `/next`'s keeper gate. Anything else → contributor mode. Never instruct a
  non-keeper to set the flag — it is the keeper's one-time setup, not a preference.
- Preflight sync: `git -C ~/.claude fetch`, and if behind, `git -C ~/.claude pull --ff-only`. If local changes to
  upstream-touched files block it, continue without pulling and note it — keeper mode's push step reconciles, and
  contributor mode branches from `origin/main` regardless.

## Keeper mode

### Step 1: Gather the queues

**Local**: `git -C ~/.claude status --porcelain`, then the full content — `git -C ~/.claude diff` plus every untracked
file read whole. These are *usually* `/reflect` apply-now edits, but never assume: a concurrent session's in-flight WIP
leaves the identical signature (`standards/git.md` § Multi-Session Awareness). The tell is shape, not mtime — a reflect
edit reads as a complete, self-contained config change with its evidence in the prose; mid-edit WIP has dangling
sentences, half-applied renames, or references to work not present. **When in doubt, defer the file**: adjudicate
nothing you can't read as finished, leave it untouched, and name it in the report.

**Linear**: the `keeper` label is workspace-level (linear gotcha #7), so sweep all teams with the raw hatch —
`issues list` is team-scoped and `search issues` can't filter by label:

```bash
linear-cli api query -o json 'query { issues(filter:{labels:{name:{eq:"keeper"}}, state:{type:{nin:["completed","canceled"]}}}, first:100) { nodes { identifier team { key } title } pageInfo { hasNextPage } } }'
```

Read through the `.data.` prefix (gotcha #6), check for an `errors` key before trusting emptiness (gotcha #13), and
paginate if `hasNextPage` is true — a one-shot read that drops the overflow reports a smaller queue than exists. For
each hit, `~/.claude/scripts/linear-context.sh <ID>` — anchored comments are invisible to the obvious commands
(gotcha #1), and comments routinely carry the evidence, corrections, or supersessions that change a verdict.

**PRs**: `gh pr list -R alienfast/claude --state open` — contributor proposal PRs. Their Linear issues were closed at
submit time (contributor Step C5), so the PR is the only pending artifact and this sweep is what keeps it from waiting
invisibly.

All three queues empty → report that in one line and stop.

### Step 2: Adjudicate — one standard for every queue

The unit is an **item**: one file-scoped concern in the local diff, one proposal inside a keeper issue (reflect files
batches — split them), or one per-issue commit inside a proposal PR (adjudicated on the PR diff). For each item:

1. **Evidence.** Does it rest on a measured or observed event, and is the claim scoped to what the evidence covers
   ([rules/comments.md](../../rules/comments.md): empirical claims are measured; a family claim is falsified by the
   member the change skipped)? Verify the cheap claims before accepting — the file, flag, or command a proposal names may
   have moved since it was filed. A filing that declares its own verification was skipped forfeits spot-checking:
   re-verify every claim in it.
2. **Placement.** Right layer per CLAUDE.md's routing (user-level `~/.claude` vs project config — memory is not a
   layer) and right file (rule vs standard vs skill). Path-scoped guidance must land in `paths:` frontmatter coverage,
   not just prose.
3. **Non-contradiction.** Grep the config for the subject. A duplicate is a rejection with a pointer to the existing
   text; a contradiction is a needs-you, not a coin flip.
4. **Proportion and wording.** House style holds (comments/markdown rules): sized to the reader, generalizes beyond the
   session that filed it, imperative and testable where possible. A rule earns its place by contradicting what an
   unprompted agent actually does, not by being true — doctrine agents already follow is over-prescription, and a
   measured tell buried in textbook framing compresses to the tell plus the measurement. Evidence in shared-config prose
   is self-contained — mechanism, date, magnitude — never a foreign-team issue ID: pointers must target a space the
   keeper curates; a contributor's IDs belong in the commit message and PR body. Test fixtures replaying real history
   are data, not decoration — exempt.
5. **Blast radius.** Anything that changes what unattended `/auto` fleets do gets a higher bar — a bad rule multiplies
   across every fleet session. Prefer needs-you over guessing.

Three verdicts: **apply**, **reject** (with the recommendation that would make it acceptable, or why it never will be),
**needs-you** (a genuine trade-off — surface the question, don't resolve it by taste).

A keeper item targeting a **project repo** is never edited from here — flag it with a routing recommendation (a project
issue, or `/reflect`, which commits project edits on the issue branch inside a `/start wt` worktree or on the main
checkout's source branch once that worktree is gone) and leave it for the user. The subtler form is an item that *edits
shared config* but whose value is project-scoped — one team's workflow states, one stack's tooling, one repo's
conventions dressed as a general rule: that is a **route-to-project**, not an accept, whatever file the diff touches. An
item mixing a global principle with project-specific detail splits — the principle lands in shared config, the detail
routes to the filer's project rules, and the verdict names which sentence is which.

### Step 3: Apply the accepted set

- Local items: the working tree already carries the edit — acceptance means staging it in Step 4. Rejected and deferred
  files stay exactly as they are: **never revert, never stash** (`standards/git.md`); the report tells the user what to
  undo by hand and why.
- Linear items: implement directly in `~/.claude` (Read before Edit, always).
- PR items: nothing to apply locally — the merge in Step 4 is the apply. Review on GitHub (inline comments where a
  recommendation is line-scoped).
- Gates before any commit: a touched `scripts/<name>.(sh|py)` with a sibling `<name>.test.sh` runs it green; touched
  markdown runs `npx markdownlint-cli2 <files>` from `~/.claude`. A red gate un-accepts the item — report it, don't ship
  it.

### Step 4: Commit, merge, push — the skill-scoped grant

Invoking `/keeper` is the explicit grant to commit and push **exactly the adjudicated-accepted set** (`standards/git.md`
§ Named exceptions). Bounded: stage by name only, never `-A`; no force-pushes; no history rewrites; deferred and rejected
files are never swept in.

- One commit per keeper issue — `keeper: <ID> — <summary>`, body carrying per-item outcomes.
- One commit for accepted pre-existing local edits — `keeper: accept local apply-now edits — <areas>`.
- Accepted PRs: `gh pr merge --rebase` (per-issue commits land as-is, history stays linear). Rejected items in a PR:
  request changes with the recommendation and leave it open. A PR rejected outright is closed unmerged with the
  rationale in a review comment — its body's per-issue provenance says which Linear issues to reopen if any item
  deserves another round.
- **Adoption**: when a mixed PR's contributor cannot or will not revise, the accepted subset does not strand with the
  PR. Re-apply each accepted item from the PR diff with its conditions and rewording, as per-item
  `keeper: <ID> — <summary>` commits (cherry-pick only a commit needing no rework), then close the PR unmerged with a
  comment naming what landed and what was dropped. The contributor's Linear issues stay as they closed at submit.
- Push once at the end. On a non-fast-forward rejection, `git -C ~/.claude pull --no-rebase` and push again; a merge
  conflict stops the run with commits local — report, never force.

### Step 5: Linear bookkeeping

Per keeper issue, post a per-item verdict comment via `~/.claude/scripts/linear-post.sh comment <ID> <body-file>`
(gotcha #18 — the raw comment commands mis-handle stdin): applied items name the commit SHA, rejections carry their
recommendation, needs-you items the question. Then:

- Every item applied or rejected-with-rationale → `linear-cli issues update <ID> --state Done`, re-reading the state to
  confirm the write took (gotcha #8).
- Any needs-you item remaining → leave the issue open; the comment marks what waits on the user.

The `keeper` label stays either way — state, not label, removes it from the queue. Merged or closed PRs need no Linear
writes — their issues were closed at submit time.

## Report

Lead with the disposition: local files applied/recommended-back/deferred, issues resolved/left-open, PRs
merged/changes-requested/closed, commits pushed with SHAs. Then the recommendations, each as *item → why not → what
would make it acceptable*. Then the needs-you items as direct questions. Deferred local files (possible
concurrent-session WIP) named last with the shape that made you defer.

## Error handling

- Linear fetch fails → adjudicate the local queue anyway, and say plainly the Linear half did not run — a failed fetch is
  never reported as an empty queue.
- Push conflict unresolved → commits stay local; report the state and stop.
- A gate failure on one item never blocks the rest of the accepted set — drop the item, ship the remainder, report the
  drop.
