---
name: auto-prep
description: Prepare a team's certified backlog for a fleet of parallel /loop /auto sessions — audit `specified` labels for unattended-shippability (de-label or flag decision-gated, human-dependent, and run-solo issues), consolidate same-defect-family point fixes into class-scoped sweep issues, wire `blocks` edges between file-colliding candidates, validate through next-candidates.sh, and recommend a parallel-session count. Use when the user says 'auto-prep', 'fleet prep', 'prep the backlog for auto', or before launching multiple /loop /auto sessions.
argument-hint: "[team:KEY | KEY]"
---

# Auto-Prep — Certified-Pool Review Before a Parallel /auto Fleet

`/next` observes exactly one dependency signal — Linear `blocks` relations — and `/auto` ships whatever carries the `specified` label. Before running many `/loop /auto` sessions in parallel, both signals must be honest: every certified issue genuinely unattended-shippable, and every same-file pair serialized so two sessions never collide in the same components. This skill audits and repairs both, then sizes the fleet.

Read [skills/linear/SKILL.md](../linear/SKILL.md) first (gotchas: relations direction, label add/remove helpers, state-update verification). Interactive by design — the flags it raises are decisions for the user; never run it unattended.

**Writes it may make** (all reversible, all reported): add/remove issue labels, add `blocks`/`duplicate` relations, post explanatory comments, adjust priority. It issues **no unconditional state write** — the `duplicate` relations it wires (Step 2's duplicate-filing cleanup, Step 3's family consolidation) land the absorbed issue in the team's duplicate-type state on their own, and the only state write it may make is Step 3's read-back fallback for when that did not happen; it never touches states otherwise, and never assignees.

## Step 1: Resolve scope and fetch the pool

Team scope: a `team:KEY` (or bare key) argument, else `$LINEAR_TEAM`, else error — fleet prep is a deliberate per-team act, never workspace-guessed. Multi-team fleets: run once per team.

One GraphQL call for everything (descriptions, labels, parents, relations both directions) across the team's unstarted workable states (Backlog/Planned/Todo — match `/next`'s `WORKABLE_STATES`):

```bash
linear-cli api query 'query { issues(filter: {team: {key: {eq: "<KEY>"}}, state: {name: {in: ["Backlog","Planned","Todo"]}}}, first: 250) { nodes { identifier title description priority labels { nodes { name } } parent { identifier state { name } } relations { nodes { type relatedIssue { identifier state { name } } } } inverseRelations { nodes { type issue { identifier state { name } } } } } } }' -o json
```

Split into the certified set (`specified` label) and the rest. Read every certified issue's description in full — the audit and the collision analysis both depend on body content, not titles.

## Step 2: Certification honesty audit

`specified` means "an unattended agent may pick this up and ship it" ([standards/issue-spec.md](../../standards/issue-spec.md)). Test every certified issue against that sentence and sort failures into four dispositions:

1. **De-label** — the body itself contradicts unattended shipping. Two tests, both mechanical:
   - The text says so: "must not ship from an unattended run", "needs dedicated review", or equivalent present-tense claims about *this* issue's work. (Past-tense "was deferred from BF-X because too big for that unattended run" does NOT count — being its own issue with its own review cycle is exactly the remedy.)
   - It requires capabilities no agent has: contacting a vendor/support rep, credentials or console access, a product/design decision with **no** testable success criteria (an "## Ask" body with no checkboxes).

   Remove the label (`~/.claude/scripts/linear-remove-label.sh <ID> specified`) and post a comment stating why and what would re-certify it.
2. **Flag: decision-gated** — the first success criterion is a product/design decision but a conservative implementable path exists (e.g. "apply the same filter the sibling uses"). Keep the label, list it in the report: the user either decides now (best) or accepts that an agent will pick the conservative option and record it.
3. **Flag: run attended/solo** — implementable unattended but with fleet-hostile blast radius: schema/codegen regeneration, repo-wide audits, changes touching what every other candidate touches. Recommend a targeted `/full <ID>` while the fleet is quiet (first or last), never mid-fleet.
4. **Pipeline label repair** — `/reflect` filings ("Auto-filed by /reflect…") certify by provenance: ensure `specified` + `reflection`, plus `keeper` when the proposal edits the shared `~/.claude` repo. Duplicate filings (same proposal from different sessions): keep one canonical, `linear-cli relations add <dup> <canonical> -r duplicate`, cross-comment both.

While reading bodies, also catch cheap ranking wins: a flake fix or check-stabilizer that other sessions' quality gates depend on deserves a priority bump (it sorts within-tier by priority); `bug`/`security` labels missing from issues that plainly are one feed the class rank.

## Step 3: Consolidate families, then wire collision edges

From the descriptions' named files/components, build overlap groups. For each group, consolidation is the first disposition; serialization is the fallback.

**Family consolidation (one decision per group, interactive like every flag here).** When a group's issues are the same defect *class* with the same fix *shape* — the bodies name one root cause across N sites (N header-scoped policy predicates, N unscoped finds, N copies of a missing guard) — N point-fix issues cost N worktrees, roughly 2N reviewer dispatches, and N serialized merges for what one class-scoped sweep fixes in a fraction. Adversarial review generates exactly this shape when it pulls a defect-family thread: a fleet night can file point fixes *and* its own sweep issues (BF-623, BF-642) for the same families in different sessions. Propose the merge: absorb the point issues into the existing sweep/audit issue when one exists, else promote the most complete point issue to canonical and widen its scope to the class. On approval for a group: append each absorbed issue's Problem + Success Criteria as a checklist block on the canonical (comment via `~/.claude/scripts/linear-post.sh`), wire `linear-cli relations add <absorbed> <canonical> -r duplicate`, and remove `specified` from the absorbed issues — the absorbed criteria live on in the canonical, so nothing is lost. **Adding the `duplicate` relation moves the first argument — the absorbed issue — into the team's duplicate-type state on its own**, leaving the canonical untouched (verified on BF: `Backlog` → `Duplicate` from the relation alone, with no state write and no `fromState`/`toState` history entry, so issue history will not show it). Read the state back and issue an explicit update only if it did not land there — the target is the team's duplicate-*type* state, whose name is team-configurable (`Duplicate` in BF and PL) and which a team may not have at all. A canonical that is not itself certified (a Triage-filed sweep, say) takes the absorbed work out of the fleet pool until it is groomed — flag it for `/spec` in the report rather than certifying it here (widened-scope certification is an interview-grade judgment, not label repair). Declined groups fall through to serialization. The test is same *fix shape*, never same *file*: two different defects in one file are a serialization case below, and merging them would build exactly the run-attended blast radius Step 2 flag 3 exists to keep out of fleets — when a proposed merge would cross that line, leave the group unconsolidated.

Then wire **minimal chains** with `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` (blocker ships first):

- **Same file → serialize.** Adjacent pairs only (A→B, B→C — never a redundant A→C; `/next` requires all blockers terminal, so transitivity is free).
- **Semantic order → direct the edge**: mechanism before consumers, client display fixes before the server withholds the data they render, code before the docs that describe it, small surgical fixes before the sweep that enumerates the area.
- **Disjoint-overlap diamonds stay parallel**: if A and C are disjoint but both overlap B, wire A→B and C→B and leave A ∥ C.
- **Never chain through a Step 2-flagged issue** — a de-labeled or decision-gated blocker never ships unattended, so anything wired behind it is stranded. Flagged issues sit at chain *tails* only.

Fleet safety rails that already exist and need no wiring: Linear is the claim registry (In Progress is invisible to `/next`), worktree creation is repo-locked, `/finish` merges serialize, and `/quality-review` wires same-batch filing collisions itself (BF-581). This step covers what those can't see: overlap across *previously filed* siblings.

## Step 4: Validate through the real ranking

```bash
~/.claude/scripts/next-candidates.sh --team <KEY> --label specified --limit 30
```

Confirm: tier-0 reflection filings lead; every Step 3 dependent is absent (blocked); de-labeled issues are gone; delegated epics annotated. If a blocker already in the team's ship state still reads as unresolved, suspect a state-name mismatch against the script's `TERMINAL_STATES` before suspecting the wiring.

## Step 5: Fleet size and launch checklist

Count **lanes**: the immediately-workable candidates minus flagged ones, grouped by cluster (chain heads count once; independent standalones count individually). Recommend `min(lanes, 8)` parallel sessions — beyond ~8, pick races and merge-queue serialization eat the gains; below 4 lanes, recommend the lane count and note when chains will release more work (each blocker's ship unblocks its dependent automatically).

Launch checklist for the report:

- `export LINEAR_TEAM=<KEY>` in every fleet session (else `/next` roams the workspace).
- Project main checkout clean and parked off the integration branch (`git checkout --detach`) — keeps every merge on the ref-only path.
- Run the Step 2 "attended/solo" issues via targeted `/full <ID>` before or after the fleet, not during.
- The decisions (Step 2 flags, de-labeled issues) that would refill the pool once made.

## Report

Lead with the recommended session count. Then: changes made (consolidations as absorbed→canonical with the class named, edges as blocker→blocked with one-line rationale, label ops, priority bumps), the flag lists by disposition (de-labeled / decision-gated / run-solo), and the validated top of the ranked pool. Every write is reversible — say so once.

## Error Handling

- No team resolvable → ask for one; never scan the workspace.
- Zero certified candidates → report it and point at `/spec` (certify backlog) rather than inventing prep work.
- A label/relation write failing mid-run leaves prior writes in place — report what landed and what didn't; all operations are idempotent to re-run.
