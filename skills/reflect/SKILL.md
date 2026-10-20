---
name: reflect
description: Turn a session's friction into shared-config improvements — verify each lesson adversarially, auto-apply small additive edits, propose the rest, file proposals as a Linear issue when unattended. Modes are `session` (default), `sweep <project>` (audit config against the codebase) and `fleet` (post-fleet batch, via /fleet-retro). Use when the user says 'reflect', 'what did we learn', 'reflect sweep', 'reflect fleet', or invokes /reflect.
---

# Reflect

Turn a session's friction into durable improvements to **shared, team-visible config** (`CLAUDE.md` / `rules/` /
`standards/` / skills) — and reconcile config that has drifted from reality. Reuses `/quality-review`'s triage
discipline (`apply-now` / `propose` / `drop`), pointed at the config layer instead of the code.

Two directions:

- **Add** — a generalizable friction (thrashing, a missing convention) → a new or updated rule/note that would have
  shortcut it.
- **Reconcile** — existing config now *contradicts* what actually happened → fix the stale instruction. A contradiction
  is concrete and verifiable, so reconcile is higher-value and lower-noise than add.

## Arguments

- (none) or `session` → **session mode**: reflect on the conversation in context (this file).
- `sweep [project-path]` → **sweep mode**: audit a project's config against its codebase plus cross-file dedup. Read
  [references/sweep-mode.md](references/sweep-mode.md).
- `fleet [checkout-path]` → **fleet mode**: batched reflection over a just-finished fleet run's evidence, invoked by
  `/fleet-retro`. Read [references/fleet-mode.md](references/fleet-mode.md).

Examples: `/reflect`, `/reflect sweep`, `/reflect sweep ~/projects/<repo>`, `/reflect fleet`.

## Invariant — the noise guard is the whole point

A reflection step that drips low-value "lessons" into `CLAUDE.md`/rules **actively degrades every future session**. So:

- **The bar is high and self-checking.** A candidate survives only if it is *genuinely generalizable* (will recur),
  *not already covered*, and *would actually have shortcut the friction*. Default to dropping.
- **Surfacing zero improvements is a success.** Most clean sessions should produce `No improvements identified.` Do not
  manufacture findings.
- **Commits are narrow and scoped; pushes never.** Auto-applied edits land in the working tree only — the user's
  explicit commit is the review gate — with one exception: project-scoped `apply-now` edits are committed by Step 5
  (by name, a dedicated commit, check-gated) inside a `/start wt` worktree so they ride the issue merge, or on the main
  checkout's source branch once that worktree is gone. This skill never runs `git push`, never commits user-level
  `~/.claude` edits, and never commits anything it did not itself just edit.
- **Auto-apply is additive/clarifying only.** Anything that *removes* or *restructures* existing guidance is `propose`.
- **The Step 3 bar-check is not skippable, and a skipped check is not a disclaimer.** A batch whose candidates did not
  pass the bar-check is surfaced only, never filed — a "verification disabled" note in the body does not license the
  filing.

## Routing — where a lesson goes

Per `~/.claude/CLAUDE.md` § Knowledge routing. Target **shared config**; memory is not a destination — a
generalizable lesson is team-worthy, so it belongs in committed config, and a non-generalizable note is `drop`.

| Lesson shape | Destination |
| --- | --- |
| File-type-scoped rule ("always X in `.ts`") | `~/.claude/rules/<type>.md` (with `paths:` frontmatter) or `<project>/.claude/rules/<topic>.md` |
| Universal cross-project rule or doctrine | `~/.claude/CLAUDE.md` or a `~/.claude/standards/<topic>.md` |
| Project-specific convention / stale project fact | `<project>/CLAUDE.md` or `<project>/.claude/rules/<topic>.md` |
| Broken skill behavior | fix the skill's `SKILL.md` directly; code/script changes → `propose` |
| Truly personal / transient | `drop` — say it in the reply if it matters now |

Unsure between two destinations → the **most specific** scope that still reaches everyone who needs it, routed to
`propose` so the user picks placement.

## Triage gates (adapted from `/quality-review` Step 6)

Classify each verified candidate as exactly one:

1. **`apply-now`** — *all* of:
   - Targets an **existing** shared file (no new file created automatically).
   - One localized, **additive or clarifying** edit (a bullet, a sentence, a small section, or a reconcile fix that
     *corrects* a stale line in place — a rewrite to current reality, **not** a deletion).
   - Removes or contradicts no other guidance.
   - Clearly generalizable and confirmed not already covered.
   - **User-level `~/.claude` targets: keeper machines only.** The `~/.claude` repo is shared and has one keeper who
     reviews and commits it; on any other machine an auto-applied edit sits uncommitted in a clone nobody inspects.
     Probe with a **literal absolute path, never a bare `git -C ~/.claude …`**: inside a `/start wt` worktree the
     isolation guard refuses a `git -C` target it cannot resolve statically, and `~/.claude` needs runtime expansion
     (`standards/git-worktrees.md` § Worktree-isolated sessions); that refusal reads like a probe error and would turn
     into a silent non-keeper downgrade on a keeper machine. Resolve first with a plain command (`echo ~/.claude`), then
     `git -C <resolved path> config --get reflect.keeper`. Never hardcode one machine's path. Prints `true` → apply-now
     permitted (the edit stays uncommitted for the keeper's review). Anything else — unset, or the probe errors —
     → downgrade to `propose`. One-time keeper setup per machine: `git -C ~/.claude config reflect.keeper true` (local
     git config — never committed or synced).
   - **Project-scoped targets inside a `/start wt` worktree: permitted, but MUST go through Step 5's check-then-commit
     path** (`WT_ABS != MAIN_CHECKOUT` is the worktree signal). Left uncommitted, the edit fails `finish-merge.sh`
     precondition 5 and blocks the merge, or is discarded to unblock it; committed on the issue branch it rides the
     `/finish … merge` to the source branch. **When that worktree is already gone** — the normal moment a post-issue
     `/reflect` runs — a project-scoped edit still applies: edit the **main checkout** while it is clean and on the
     source branch, and commit that one file by name through Step 5; a dirty checkout, or one parked on another branch,
     downgrades to `propose`. "No worktree" is not a reason to downgrade a one-sentence rule-doc correction and file it.
   - → apply to the working tree now, no prompt.
2. **`propose`** — *any* of: a new rule/standard/skill **file**; a structural `CLAUDE.md` change; a skill bug needing
   code/script work; cross-cutting; or the wording/placement needs a judgment call. → surface a ready-to-paste diff and
   capture it in the issue Step 6 files (auto-filed unattended; the user's call interactively).
3. **`drop`** — one-off, already covered, or not generalizable. → record a one-line reason; do not surface loudly.

When torn between `apply-now` and `drop` for a small, safe, generalizable edit, prefer `apply-now`. When torn between
`apply-now` and `propose`, prefer `propose` (let the user place a borderline edit).

## Session mode

### Step 1 — Detect friction signals

Scan the session **in context** (no transcript-file lookup — it also risks matching the wrong JSONL across concurrent
sessions). Look for:

- **Thrashing** — repeated failed attempts at one problem; multiple `pnpm check` fail→fix cycles; circling on one file;
  a long detour to discover a fact a doc would have handed over.
- **Silent skill/tool workaround** — a skill or tool errored or behaved wrong and was routed around **without being
  surfaced**. *Highest value:* a broken skill stays broken for the whole team until someone flags it.
- **Repeated user correction** — the same class of thing corrected more than once → a *candidate* missing convention.
  Frequency within one session is only a trigger to look, never proof; the lesson qualifies only as a standing
  principle that will recur across sessions. Step 3 tests this.
- **Workaround anti-pattern** — one of the seven in `standards/problem-solving.md` was used; justified-and-documented, or
  a smell pointing at a missing rule?
- **Stale-config contradiction (targeted reconcile)** — this session did something that contradicts existing config: a
  script that supersedes a documented manual step, or a `CLAUDE.md`/rule instruction that proved wrong. Scope the check
  to config that plausibly references the files this session touched.

**If no signal clears the bar → emit `No improvements identified.` and stop.** Keep it cheap.

### Step 2 — Draft candidates

For each surviving signal, draft:

```text
{ type: add | reconcile,
  observation: <what happened, with concrete evidence — file/command/quote from the session>,
  proposed change: <the rule/note/fix>,
  target file: <per the routing table>,
  draft: <exact text or diff to add/change> }
```

### Step 3 — Verify (adversarial bar-check + dedup)

Delegate each candidate to a verifier agent. The agent has none of the session context, so pass the full candidate; it
reads the target config file(s) and relevant code **from disk** and tries to **reject** it:

```md
Task for general-purpose (or quality-reviewer): Adversarially verify a config-improvement candidate.
Candidate:
- type: <add|reconcile>
- observation + evidence: <...>
- proposed change: <...>
- target file: <path>
- draft text/diff: <...>
Your job is to REJECT unless it clearly survives all of:
1. Generalizable — this states a standing principle that will recur across sessions/people. Single-session frequency is NOT evidence of recurrence on its own. (You cannot see other sessions — judge the plausibility that the principle is durable; do not reject a sound general principle merely for lack of cross-session proof.)
2. Not already covered — read <target file> and the related rules/standards/CLAUDE.md; quote anything that already says this. If covered, reject.
3. Would actually have helped — the change, present beforehand, would have shortcut the friction (for reconcile: the contradiction is real and the fix matches CURRENT reality — read the code/scripts to confirm).
4. Correct destination — per ~/.claude/CLAUDE.md § Knowledge routing.
5. Claims about other skills hold — when the draft asserts how another skill, standard, or rule behaves, or prescribes an action another skill owns, READ those files (skills included — gate 2's read set stops at rules/standards/CLAUDE.md) and confirm every assertion. Reject, or return a `corrected_draft`, when a claim misstates the referenced behavior or would conflict with what that skill does. A rule stating a false fact about the workflow is worse than no rule.
6. Quantified or enumerative claims about the codebase hold — a count, a universal, any characterization of a family. Verify by enumerating every member and checking each, never by sampling or trusting the draft's survey, and state the enumeration in your reason line. This gate and gate 7 are the only ones whose read set reaches application code, so for a type `add` candidate no other gate catches a false claim about the codebase. When the lesson survives but the claim does not, return a `corrected_draft` with the accurate enumeration rather than `drop` — this overrides the default-to-drop below, which governs doubt about the lesson, not a fixable claim.
7. Impossibility and universal-negative claims hold — "no hook can be written", "nothing can reach X", "the only answers are A or B". The failure this gate exists for: a draft measured ONE mechanism's absence correctly and generalized to the capability's absence, so re-reading the measurement never surfaces the error. Name the capability, list the mechanisms that could satisfy it, and check each (read set reaches library and application code). When the enumeration cannot be closed, return a `corrected_draft` scoped to what was measured ("`beforeSend` cannot see a replay event") in place of the unscoped claim ("no hook can") — the default action here. A rule that forecloses a mechanism talks the next reader out of the correct solution.
8. Prescribes against observed behavior, not general truth — the candidate names what an unprompted agent actually did (or demonstrably would do) wrong that this text prevents. Well-known doctrine agents already follow is over-prescription. A measured tell wrapped in textbook framing compresses to the tell plus the measurement; pure doctrine with no tell is a drop.
9. Exceptions update the sentences they falsify — when the draft adds an exception to an existing rule, grep the config for sentences citing that rule as absolute ("bans X altogether", "never Y"); every one the exception falsifies must be updated in the same proposal.

Return: { verdict: keep|drop, reason: <one line>, corrected_target?: <path>, corrected_draft?: <text> }.
Default to drop when uncertain.
```

Run verifiers in parallel when there are several, as one-shot `Agent` dispatches with `run_in_background: false` — the
next step consumes every verdict, so there is nothing to wait for (`standards/agent-coordination.md` § Background-agent
completion reports). Drop everything that comes back `drop`. This is the primary noise guard — be glad when it rejects.

### Step 4 — Triage

Apply the three gates to each kept candidate. **`apply-now` requires that Step 3 ran and returned `keep` for that
candidate** — the independent verify is what licenses an unattended edit to shared config. If verification could not run
at all, **no candidate may be `apply-now`**; every survivor downgrades to `propose`.

### Step 5 — Apply `apply-now` items

Edit the target files directly in the working tree (small markdown edits; delegate to `developer` only if several
independent files are involved). Re-read each target **immediately before editing** — a prior step, an auto-fixer, or a
concurrent session may have touched it (`~/.claude/CLAUDE.md` multi-session safety). **Do not commit** — except the one
scoped case below.

**Project-scoped edits — check, then commit (the Invariant's single exception).** Covers a `/start wt` worktree and the
main checkout once that worktree is gone (clean, on the source branch). User-level `~/.claude` edits are never committed
by this skill, in any mode. After applying:

1. Run `pnpm check`. On failure, reverse each just-applied project edit with the Edit tool (swap the edit's new/old
   strings back — never `git restore`, which is hook-blocked and could clobber others' work, and never `git stash`, whose
   stack is shared across every worktree: `standards/git.md` § Safe Commands), reclassify the candidate as `propose`
   with the check failure as the reason, and move on — a config edit that reddens the check must not ride the merge,
   and left uncommitted it would block it (`finish-merge.sh` precondition 5).
2. On a green check, stage ONLY those files by name and commit them as a dedicated commit — never amended into or mixed
   with issue commits. On the main checkout, confirm `git branch --show-current` prints the source branch **in the same
   turn** as the commit (`standards/git.md` § Multi-Session Awareness — the shared checkout can switch between turns):

   ```bash
   git add <target-file ...> && git commit -m "docs(config): <one-line summary> (via /reflect)"
   ```

   In a worktree it rides `/finish … merge` into the source branch; on the main checkout it lands on the source branch
   directly and waits for the human's next push. No push in either case.

Emit one visibility line, e.g.:

```text
Applied 2 config improvements: rules/typescript.md — prefer X over Y (uncommitted, keeper review); <project>/CLAUDE.md — test setup is now scripts/setup-tests.sh, not manual (committed on issue branch).
```

### Step 6 — Surface and file `propose` items

First, for each `propose` item, show its destination and a ready-to-paste diff. **Then split on who is present.** In an
**unattended** run (`/fleet-retro`'s `/reflect fleet`, or any `/auto` or fleet session that reaches this skill), capture
every `propose` item in **one** auto-filed Linear issue with **no prompt**, so the work survives the run — there is no
human to act on a surfaced diff. In an **interactive** invocation, do **not** auto-file: ask once, per batch — apply now
/ file / drop — and recommend apply for anything small. A one-sentence rule-doc correction the user can approve in one
line is never worth an issue, a pick, a worktree, and a review cycle.

For the items to file, read [references/filing.md](references/filing.md): team resolution (never guessed), the body
shape and its precondition line, dedup against open issues before creating, `linear-file-improvement.sh [--keeper]`
(the `--keeper` flag whenever any proposal targets `~/.claude`, which files uncertified with `keeper` instead of
`specified`), the exit-code branches for the `Filed:` line, and collision-edge wiring. Filing is best-effort: never
block the reflection or the enclosing `/full` on it, and never guess a team to force a file.

### Step 7 — Output

Emit the Reflection block below, and **emit no lifecycle tag** (this skill never owns one).

```text
Reflection:
- Applied: <N> — <file — one-line each, marked committed|uncommitted, or none>
- Proposed: <N> — <destination — one-line each, or none>
- Filed: <PL-XX (Backlog, specified — or "Backlog, keeper — uncertified" for a --keeper batch) — append `(label not attached)` on exit 2, and/or `(collision edge to PL-YY not wired — add manually)` on a wiring miss; or none — the user chose apply/drop interactively, or the reason it was skipped>
- Dropped: <N> (already-covered / one-off / not-generalizable)
```

## Error handling

- **Invoked by `/fleet-retro` with nothing to reflect on** → `No improvements identified.` and return.
- **Verifier agent unavailable** → do not auto-apply on faith. Downgrade every unverified candidate to `propose` and note
  that verification could not run.
- **Keeper probe unavailable** (`git -C <resolved literal path> config` errors — e.g. `~/.claude` is not a git clone
  here) → treat as non-keeper: user-level candidates downgrade to `propose`. Fail toward filing, never toward editing a
  shared repo blind. **A worktree-isolation guard refusal on the tilde form is NOT this case** — re-resolve `~/.claude`
  to a literal path and retry before concluding the probe is unavailable.
- **Step 5 commit fails** (rejected by a hook or precondition) → reverse the edits with the Edit tool exactly as in the
  red-check path, reclassify as `propose`, and surface the git error. Never leave a tracked project edit uncommitted in
  a merge-mode worktree, or dirty on the main checkout's source branch — there it defers to the queue every fleet merge
  that changes a file you edited
  (`standards/git-worktrees.md` § Posture for high-concurrency runs).
- **Auto-fixer/lint touched a config file you were about to edit** → re-read before editing (`rules/markdown.md`).
- **A proposed edit would remove or restructure existing guidance** → never `apply-now`, even if confident. (A reconcile
  fix that corrects a stale line's value in place removes nothing — that stays `apply-now`.)
- **No issue / no project context** (standalone in a non-project dir) → session mode still works; sweep mode requires a
  project. When `<project>` is unresolvable, any candidate whose correct home is a project-scoped file downgrades to
  `propose` (surface the suggested path) — never `apply-now` to a guessed or user-level fallback path.
- **Issue filing failed or no team resolved** → `references/filing.md` § 4: exit 1 or no team → surface the diffs and
  record `Filed: none — <reason>`; exit 2 is filed-but-unlabeled, not a failure.
