---
name: auto-prep
description: Prepare a team's certified backlog for a fleet of parallel /loop /auto sessions — audit `specified` labels for unattended-shippability (mark human-dependent issues `needs decision` and fleet-hostile ones `solo`, flag decision-gated ones), consolidate same-defect-family point fixes into class-scoped sweep issues, wire `blocks` edges between file-colliding candidates, validate through next-candidates.sh, audit fleet-drain blockers (certified candidates stranded behind needs-decision/human/solo/stalled, Backlog/Triage, or uncertified blockers — the daytime attention list before a night fleet), and recommend a parallel-session count. Use when the user says 'auto-prep', 'fleet prep', 'prep the backlog for auto', or before launching multiple /loop /auto sessions.
argument-hint: "[team:KEY | KEY]"
model: opus
effort: xhigh
---

# Auto-Prep — Certified-Pool Review Before a Parallel /auto Fleet

`/next` observes exactly one dependency signal — Linear `blocks` relations — and `/auto` ships whatever carries the `specified` label. Before running many `/loop /auto` sessions in parallel, both signals must be honest: every certified issue genuinely unattended-shippable, and every same-file pair serialized so two sessions never collide in the same components. This skill audits and repairs both, then sizes the fleet.

Read [skills/linear/SKILL.md](../linear/SKILL.md) first (gotchas: relations direction, label add/remove helpers, state-update verification). Interactive by design — the flags it raises are decisions for the user; never run it unattended.

After the fleet finishes, [`/fleet-retro`](../fleet-retro/SKILL.md) is the bookend — it measures where the run's capacity went and audits what it filed, which is where this skill's next inputs come from.

**Writes it may make** (all reversible, all reported): add/remove issue labels, add `blocks`/`duplicate` relations, post explanatory comments, adjust priority. It issues **no unconditional state write** — the `duplicate` relations it wires (Step 2's duplicate-filing cleanup, Step 3's family consolidation) land the absorbed issue in the team's duplicate-type state on their own, and the only state writes it may make are Step 3's read-back fallback for when that did not happen and Step 4's user-approved Backlog-blocker promotion (stage-inversion check); it never touches states otherwise, and never assignees.

## Step 1: Resolve scope and fetch the pool

Team scope: a `team:KEY` (or bare key) argument, else `$LINEAR_TEAM`, else error — fleet prep is a deliberate per-team act, never workspace-guessed. Multi-team fleets: run once per team.

One GraphQL call for everything (descriptions, labels, parents, relations both directions) across the team's unstarted workable states (Backlog/Planned/Todo — match `/next`'s `WORKABLE_STATES`):

```bash
linear-cli api query 'query { issues(filter: {team: {key: {eq: "<KEY>"}}, state: {name: {in: ["Backlog","Planned","Todo"]}}}, first: 250) { nodes { identifier title description priority labels { nodes { name } } parent { identifier state { name } } relations { nodes { type relatedIssue { identifier state { name } } } } inverseRelations { nodes { type issue { identifier state { name } } } } } } }' -o json
```

Split into the certified set (`specified` label) and the rest. Read every certified issue's description in full — the audit and the collision analysis both depend on body content, not titles.

## Step 2: Certification honesty audit

`specified` means "an unattended agent may pick this up and ship it" ([standards/issue-spec.md](../../standards/issue-spec.md)). Test every certified issue against that sentence and sort failures into four dispositions:

1. **Mark `needs decision`** — the body itself contradicts unattended shipping. Two tests, both mechanical:
   - The text says so: "must not ship from an unattended run", "needs dedicated review", or equivalent present-tense claims about *this* issue's work. (Past-tense "was deferred from BF-X because too big for that unattended run" does NOT count — being its own issue with its own review cycle is exactly the remedy.)
   - It requires capabilities no agent has: contacting a vendor/support rep, credentials or console access, a product/design decision with **no** testable success criteria (an "## Ask" body with no checkboxes).

   Post a comment stating the specific decision or access needed, then apply the label: `~/.claude/scripts/linear-add-label.sh <ID> 'needs decision'`. The issue keeps `specified` — the spec is gated, not wrong (`standards/issue-spec.md`) — and `next-candidates.sh` hides it from every ranking until a human decides and clears the label (directly, or via `/spec <ID>`).

   **When the capabilities test fires because the work is *itself* human-performed** — outreach, vendor contact, production data remediation, sign-offs, a roll-up a person owns — apply `human` instead (`~/.claude/scripts/linear-add-label.sh <ID> human`): that gate is permanent and refuses targeted `/auto <ID>` too, while `needs decision` advertises a pending decision that would return the issue to agents (`standards/issue-spec.md`). A body that *bundles* an agent-shippable slice with human acts takes neither label as the fix — flag it for `/spec` to split at the handoff, exactly the BF-856 shape (a fully-specified schema fused to a confirmation pass the plan itself called human-in-the-loop).
2. **Flag: decision-gated** — the first success criterion is a product/design decision but a conservative implementable path exists (e.g. "apply the same filter the sibling uses"). Keep the label, list it in the report: the user either decides now (best) or accepts that an agent will pick the conservative option and record it. **A decision made now counts only once it is in the description** — route it through `/spec <ID>` so the answer lands in the body and the criterion is rewritten to prescribe it; a decision left in a comment does not unblock `/auto` ([standards/issue-spec.md](../../standards/issue-spec.md)).
3. **Mark `solo`** — implementable unattended but fleet-hostile. The constraint is concurrency, not attendance: worktrees isolate the working tree, so the remedy is sequencing, not a human. Apply the label (`~/.claude/scripts/linear-add-label.sh <ID> solo`; exit 2 → `linear-cli labels create "solo" -t issue`, then retry once) and recommend a targeted `/auto <ID>` (or `/full <ID>`) while the fleet is quiet, first or last, never mid-fleet. The label hides the issue from every ranking so no fleet session can pick it, while targeted runs still ship it normally ([standards/issue-spec.md](../../standards/issue-spec.md)). A report-only flag would not survive the session that read it — this is the one disposition where the old advice ("don't hand-pick these") was addressed to a human who wasn't going to be there.

   **This disposition over-triggers, and a false positive is expensive** — it pulls a workable issue out of the fleet pool and parks it on the one serial resource, the user. Qualify on exactly two grounds, and name which one in the comment:

   - **(a) It changes the rules other in-flight sessions are already playing by.** Merge-driver or `.gitattributes` registration, the `pnpm check` / turbo task graph, a package's `test` script going from stub to real, a shared CI gate, a dependency or lockfile change every other worktree's install predates. The test is whether a session that started *before* this merged would behave differently after it — not whether the file sounds important.
   - **(b) It collides so broadly that serialization does not scale.** A sweep across a directory where much of the certified pool lives. Make this quantitative: if wiring the Step 3 `blocks` edges would take more than a handful, one `solo` mark is the same guarantee for a fraction of the wiring — count the colliding issues and put the count in the comment. Below that threshold, wire the edges instead; that is what Step 3 is for.

   **Not solo, however it sounds:**

   - **Touching a generated artifact.** Regenerating codegen output is not a collision when the repo already resolves it — check `.gitattributes` for a `merge=ours` driver on those paths and CI for an unconditional regen before assuming otherwise. Under both, sibling sessions never conflict there and CI rebuilds the truth anyway. Changing the generation *pipeline or its gate* can still qualify under (a); emitting different *content* through an unchanged pipeline does not.
   - **A class-scoped sweep confined to one file or type.** That is Step 3's serialization case by the same "same file → serialize" rule, and often already wired. Scope, not the word "sweep" or "audit," decides.
   - **An ordinary schema or API change** whose only shared-file contact is the regenerated output above.
4. **Pipeline label repair** — `/reflect` filings ("Auto-filed by /reflect…") certify by provenance: ensure `specified` + `reflection`, plus `keeper` when the proposal edits the shared `~/.claude` repo. Duplicate filings (same proposal from different sessions): keep one canonical, `linear-cli relations add <dup> <canonical> -r duplicate`, cross-comment both.

While reading bodies, also catch cheap ranking wins: a flake fix or check-stabilizer that other sessions' quality gates depend on deserves a priority bump (it sorts within-tier by priority); `bug`/`security` labels missing from issues that plainly are one feed the class rank.

## Step 3: Consolidate families, then wire collision edges

From the descriptions' named files/components, build overlap groups. For each group, consolidation is the first disposition; serialization is the fallback.

**A named file is not necessarily an edited file — classify each mention before it becomes an edge.** Descriptions cite paths for three reasons that are not collisions: as **precedent** ("the sibling half of this flow already locks — `email_verification.rb:11`"), as **explanation** of blast radius ("`useQuery.tsx` rethrows to the error boundary, so one missing row kills the page"), and as a **pattern to follow** ("following `spec/lib/bullet_spec.rb`'s `around`-block pattern"). The discriminator is which *section* the mention sits in, never how precise it is: Success Criteria / Requirements checkboxes and In Scope entries are what the issue will edit (`/start` Step 6 takes the checkboxes as its requirements, and [standards/issue-spec.md](../../standards/issue-spec.md)'s quality bar bans implementation-planning file lists from specs altogether, so a path that survives certification inside a criterion is there because it names the work target), while prose in Problem, Notes, or a Boundaries rationale is a citation. **Line numbers prove the author read the code, not that they will change it** — `tenant.rb:72-77` quoted in a Problem to explain a symptom is a citation; a criterion naming a bare `debt_series/create.rb` is an edit. Keep a pair only where **both** sides edit; one-sided contact is not a collision, at most a `related` link when the mechanism is genuinely shared. The cost is asymmetric and silent: a false edge hides a workable issue from every ranking until its supposed blocker ships, and unlike the keeper / `needs decision` / `solo` gates there is no trailing note reporting it — a missed edge costs at most one merge conflict. On one BF run 5 of 27 computed edges were citation-only, including a three-issue N+1 cluster whose members all merely cited `config/application.rb` and `bullet_spec.rb` and so had no collision at all.

**Family consolidation (one decision per group, interactive like every flag here).** When a group's issues are the same defect *class* with the same fix *shape* — the bodies name one root cause across N sites (N header-scoped policy predicates, N unscoped finds, N copies of a missing guard) — N point-fix issues cost N worktrees, roughly 2N reviewer dispatches, and N serialized merges for what one class-scoped sweep fixes in a fraction. Adversarial review generates exactly this shape when it pulls a defect-family thread: a fleet night can file point fixes *and* its own sweep issues (BF-623, BF-642) for the same families in different sessions. Propose the merge: absorb the point issues into the existing sweep/audit issue when one exists, else promote the most complete point issue to canonical and widen its scope to the class. On approval for a group: append each absorbed issue's Problem + Success Criteria as a checklist block on the canonical (comment via `~/.claude/scripts/linear-post.sh`), wire `linear-cli relations add <absorbed> <canonical> -r duplicate`, and remove `specified` from the absorbed issues — but only once the scope test below passes. **Adding the `duplicate` relation moves the first argument — the absorbed issue — into the team's duplicate-type state on its own**, leaving the canonical untouched (verified on BF: `Backlog` → `Duplicate` from the relation alone, with no state write and no `fromState`/`toState` history entry, so issue history will not show it). Read the state back and issue an explicit update only if it did not land there — the target is the team's duplicate-*type* state, whose name is team-configurable (`Duplicate` in BF and PL) and which a team may not have at all. **Before absorbing into a *certified* canonical, test the canonical's stated scope against the absorbed issue's subject.** The selection test is same fix *shape*, deliberately not same *file* — so the canonical's `### In Scope` and success criteria routinely do not reach the file, class, or predicate the absorbed issue names, and there "the absorbed criteria live on in the canonical" does not hold. `/start` Step 6 does read absorbed criteria out of the comment (it names this protocol by name, after BF-627), but the **description** is what the rest of the pipeline consumes: `/quality-review` sources its "Issue requirements" from `linear-cli issues get <ID>`, which returns the description and no standalone comments, and `/finish` checks off *description* checkboxes — so a criterion living only in a comment is shipped at the planner's discretion, verified by no reviewer, and checked off by nobody, while the absorbed issue sits de-certified in the duplicate state tracking nothing. Two dispositions, and the test picks between them: **scope reaches the subject** → absorb as above; **it does not** → either leave the two separate, wired `related` with a cross-comment and `specified` intact on both, or absorb and **flag the canonical for `/spec`** to widen its Boundaries and criteria into the description before the fleet picks it up — the same interview-grade judgment the uncertified-canonical branch below defers, and the reason not to edit a certified description here. **Never strip `specified` from the absorbed issue on the strength of a comment alone** — do it only once the canonical's description names its subject. Worked case: BF-874 (High, `security`+`bug`, subject `apps/api/app/policies/secure_entity_policy.rb`) was absorbed into BF-849, whose In Scope names only `disbursement_of_funds_policy.rb` and `disbursement_of_funds.rb`'s `participant_emails` and whose six criteria are all written against `DisbursementOfFundsPolicy`; `specified` came off BF-874 eleven seconds after the absorption comment, and BF-866's review re-found the same unguarded predicate and could only file the scope gap back as another comment. A canonical that is not itself certified (a Triage-filed sweep, say) takes the absorbed work out of the fleet pool until it is groomed — flag it for `/spec` in the report rather than certifying it here (widened-scope certification is an interview-grade judgment, not label repair). Declined groups fall through to serialization. The test is same *fix shape*, never same *file*: two different defects in one file are a serialization case below, and merging them would build exactly the fleet-hostile blast radius Step 2's `solo` disposition exists to keep out of fleets — when a proposed merge would cross that line, leave the group unconsolidated.

Then wire **minimal chains** with `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` (blocker ships first):

- **Same file → serialize.** Adjacent pairs only (A→B, B→C — never a redundant A→C; `/next` requires all blockers terminal, so transitivity is free).
- **Order each group against the edges it already carries, then re-check every pair.** The pool arrives pre-wired — `/quality-review` files up to one dedup-adjacent edge per filed item (same-file sibling, both certified) plus intra-batch chains, and a prior prep adds more (one BF run started with 60) — and Step 1's `relations`/`inverseRelations` already carry them, so no extra fetch. Sort each group by existing reachability with your heuristic only as the tiebreak, or a fresh sort buries a chain head at the tail (a priority-first sort did exactly that to an issue already blocking two others). Then check every pair in the group: adjacent-pairs-only wiring plus an existing edge makes a group *look* serialized while a pair sits mutually unreachable — that pair is a live collision, and nothing downstream reports it, since Step 4 confirms the edges you wired and never the ones you missed.
- **Semantic order → direct the edge**: mechanism before consumers, client display fixes before the server withholds the data they render, code before the docs that describe it, small surgical fixes before the sweep that enumerates the area.
- **Disjoint-overlap diamonds stay parallel**: if A and C are disjoint but both overlap B, wire A→B and C→B and leave A ∥ C.
- **Never chain through a Step 2-flagged issue** — a `needs decision` or decision-gated blocker never ships unattended, so anything wired behind it is stranded. Flagged issues sit at chain *tails* only.
- **A `solo` blocker is a chain head or nothing.** Unlike the flags above it does ship — just outside the fleet window — and blocker resolution reads the blocker's *state*, never its labels, so a dependent behind it stays blocked for the whole fleet run. Wire one as a blocker only when you will run it in the pre-fleet solo pass; otherwise leave it at a tail and let its dependents run free.

Fleet safety rails that already exist and need no wiring: Linear is the claim registry (In Progress is invisible to `/next`), worktree creation is repo-locked, `/finish` merges serialize, and `/quality-review` wires same-batch filing collisions itself (BF-581), plus one dedup-adjacent edge per filed item against an open same-file sibling. This step covers what those can't see: the rest of the overlap across *previously filed* siblings.

## Step 4: Validate through the real ranking

```bash
~/.claude/scripts/next-candidates.sh --team <KEY> --label specified --limit 30
```

Confirm: tier-0 reflection filings lead; every Step 3 dependent is absent (blocked); de-labeled issues are gone; every issue marked `solo` is absent and accounted for by the trailing hidden-count note; delegated epics annotated. To reconcile that count against what Step 2 marked, re-list with **`--label solo --include-blocked`**. Two independent causes make the numbers disagree, neither a bug. The blocker filter is one: a bare `--label solo` ranking still hides an issue behind an open blocker, which `--include-blocked` restores. The larger one is usually **state span** — the fetch excludes only the `completed` and `canceled` state *types*, and the hidden-count notes run over that unfiltered list, so a labeled issue in any other state the fetch admits is counted as hidden even though it was never workable and the `--label solo` listing correctly omits it. That is not just the `started` states (`In Progress`, `In Review`) — `triage` and `duplicate` survive too, and Step 3's own `duplicate` wiring moves absorbed issues into one of them. The `needs decision`, `human`, and keeper notes span the same states. **Reconcile against the listing, not the note** — and read a note that exceeds the listing as parked, in-flight, or blocked siblings before suspecting a wiring fault. If a blocker already in the team's ship state still reads as unresolved, suspect a state-name mismatch against the script's `TERMINAL_STATES` before suspecting the wiring.

**Fleet-drain blocker audit — every certified candidate whose blocker nothing in the fleet will ship.** Step 3's wiring rules keep *new* chains from running through flagged issues, but the pool arrives pre-wired, and an inherited edge can strand a certified candidate for the whole run behind a blocker the fleet can never pick: one labeled `needs decision`, `human`, `solo`, or `stalled`; one sitting in Triage or Backlog (stage-first ranking sorts it below the entire Planned stage); or one that is simply **uncertified** — `/next specified` never offers it, so a Planned-but-unspecified blocker strands its dependent exactly as hard as a parked one. Run the tested implementation — do not re-derive the filter inline (a mistranscribed filter prints nothing at exit 0, which reads as "nothing blocks the fleet"). The first line is the verdict, `FLEET-BLOCKED: <n>`; branch on it, never on empty output. Each row names the reason(s) with the remedy:

```bash
~/.claude/scripts/fleet-blockers.sh --team <KEY>
```

Present the hits grouped by remedy — this is the daytime attention list that makes a night fleet drain: decisions to make now (`needs decision` — decide, comment, clear the label), human-performed blockers to do or re-scope (`human`), `solo` blockers for the pre-fleet quiet window, `stalled` in-flight blockers to resume or release, uncertified and Triage blockers to `/spec` (grooming is triage acceptance — never promote around it with a bare state write), and Backlog blockers to promote (`linear-cli issues update <BLOCKER> -s Planned`, user-approved, verified per linear skill gotcha #8 — paired with `/spec` when uncertified, since promotion alone still ships nothing). If the user declines a remedy, report the dependent as stranded for this run; if inspection shows the edge itself is stale, dropping the edge is the fix, not the promotion.

## Step 5: Fleet size and launch checklist

Count **lanes** from the Step 4 ranking, which already excludes both label gates: the immediately-workable candidates minus the decision-gated flags, grouped by cluster (chain heads count once; independent standalones count individually). Recommend `min(lanes, 8, quota)` parallel sessions — beyond ~8, pick races and merge-queue serialization eat the gains; below 4 lanes, recommend the lane count and note when chains will release more work (each blocker's ship unblocks its dependent automatically).

**`quota` is the third term because it is usually the binding one, and lanes cannot see it.** Lane math answers "how much independent work is there", which is the wrong question whenever the account runs out of allowance before the backlog does — and the fleet then stops mid-issue rather than at a clean boundary, leaving in-flight work to be finished by hand. Measured on the 2026-08-06 BF fleet: **3 sessions exhausted a weekly allowance in 11.5 hours**, all three stalling within 30 seconds of each other, 9 minutes short of their own deadline, with 63 certified candidates still in the pool and a lane-derived recommendation of 8.

### Quota is TWO windows with TWO different levers — size against both

The account meters a **5h burst window** and a **weekly window**, and they do not respond to the same knob. Collapsing them into one "quota" number is what produces a recommendation that saturates the burst window while nominally fitting the week:

- **The 5h window constrains CONCURRENCY.** Burn per window is `n x 5 x rate`. Duration does not appear — only `n` moves it. Saturating it throttles every session at once, which is *worse* than a smaller fleet: same wall-clock, less shipped, worktrees still held open.
- **The weekly constrains TOTAL SESSION-HOURS.** Burn is `n x duration x rate`. Either lever moves it.

So when the weekly permits more than the burst window does, **extend duration rather than adding sessions**. Worked case: 5 x 20h and 9 x 12h spend nearly the same fraction of a week (54% vs 59%), but the first sits at 2.5M per 5h window against the second's 4.5M.

```text
n_window = floor(peak_5h_observed x 0.8 / (5 x rate))   # never exceed proven burst burn
n_weekly = floor(weekly_available / (duration x rate))
n        = min(lanes, 8, n_window, n_weekly)
```

**Get `rate` and `peak_5h_observed` from the `windows` block, never from a mean.** `~/.claude/scripts/fleet-metrics.py --json | jq .windows` reports `peak_5h_output_tokens`, `peak_5h_concurrency`, and `output_tokens_per_session_hour_at_peak`. Use the **at_peak** rate: `output_tokens_per_session_hour_all_sessions` pools idle and interactive sessions with fleet ones and lands roughly half the truth (measured 55.9k vs 84.9k on the same BF data), which under-sizes every projection built on it. Scaling by proportion is equivalent and easier to sanity-check — at concurrency `n`, expect about `peak_5h x n / peak_5h_concurrency` per window.

**A peak is a floor only until a run gets cut off; then it is a ceiling.** A survived peak records what was *tolerated*, so the `x 0.8` above exists because the real limit sits somewhere above it and unknown. Once `/fleet-retro` reports a `windows.quota_stall_groups` entry, that run's peaks bound the limit from **above** instead, and the discount is no longer conservative — it is applied to a number that was already too high. Prefer the cutoff basis whenever one exists, per [`/fleet-launch`](../fleet-launch/SKILL.md)'s sizing section.

**Check `limit_kind` before you touch `n`.** The stall group names which allowance refused the run, read from the harness message rather than inferred. `n_window` is the answer only to a **5-hour** cutoff; a **`weekly`** one says duration was too long, not that the fleet was too wide, and a **`session`** one says nothing about fleet size at all. Both recent basefund cutoffs (2026-08-06, 2026-08-08) were `weekly` — so `n_weekly`, not `n_window`, is the term that has actually been binding, and no genuine 5h-burst fleet cutoff has been observed yet.

**Prefer the measured bracket to any of this arithmetic when the shape matches.** For a ~12h window on the BF backlog at opus/xhigh, n=3 is confirmed workable (2026-08-08: 20 issues shipped, cut off ~35 min before a 12h deadline, on 43% weekly remaining) and n=4 is confirmed too wide (2026-08-06: cut off at 4.9h). Recommend 3 there and spend the lane math on cases outside it — but scale the *duration* by the weekly reading, since the bracket was measured at one point in the week and does not carry across it.

**Ask the user for their current readings and record them.** Neither the scripts nor the transcripts can see remaining allowance — only the user can (`/usage`). Ask for **weekly % remaining** and **5h % remaining**, and convert with the measured peak-weekly total (`peak_168h_output_tokens`) as the 100% basis. Two traps, both hit on 2026-08-06:

1. **A run ending at zero measures nothing about the allowance's size.** It consumed whatever was *left*. Inferring "34.5 session-hours = one weekly allowance" from an exhausted fleet was wrong by ~5x — that fleet was only ~19% of its week's spend; 46 other sessions had already taken the rest. This is `planning.md`'s *measured, not reasoned* rule landing on the sizing math: derive the basis from `peak_168h_output_tokens`, or from bracketing readings, never from the fact that something ran out.
2. **Output tokens may not be what the limit meters, and no measurement has settled it.** Cache reads run ~1000x output volume in this workload. One tempting near-proof has already been retired: three cutoffs appeared to agree on trailing-5h total-billable to 0.08% while diverging 23% on output, until reading `limit_kind` showed two were **weekly** and one was a per-**session** limit — unrelated ceilings coinciding. Bracketing readings sidestep the question entirely: they calibrate against whatever the limit actually counts, with no need to know the formula. Keep asking for them.

State the binding term in the report — name which of the four it was. "8 lanes available, capped to 5 by the 5h burst window" tells the user their lever is `n`; "capped to 5 by weekly" tells them it is `duration`; a bare "5 sessions" reads as a thin backlog and invites the wrong fix.

**Persist the recommendation** so `/fleet-launch` can pick it up without re-deriving the lane math (a count-less `/fleet-launch` reads exactly this file):

```bash
jq -n --argjson sessions <N> --arg team <KEY> --argjson e "$(date +%s)" \
      --arg bound_by '<lanes|cap|window|weekly>' --argjson duration_h <D> \
      --argjson rate <TOK_PER_SESSION_HOUR> --argjson peak5h <PEAK_5H_OBSERVED> \
      --argjson weekly_pct <PCT> --argjson burst_pct <PCT> \
  '{sessions: $sessions, team: $team, generated_epoch: $e, generated: (now | todate),
    bound_by: $bound_by, duration_h: $duration_h,
    sizing: {rate_tok_per_session_hour: $rate, peak_5h_observed: $peak5h,
             weekly_pct_at_prep: $weekly_pct, burst_pct_at_prep: $burst_pct}}' \
  > tmp/fleet-recommendation.json
```

Written in the project's main checkout (where the fleet sessions will run), not `~/.claude`. `fleet-launch.sh` warns when the file is older than 24h — a re-run of this skill refreshes it. The `sizing` block is what makes the recommendation auditable after the fact: `/fleet-retro` compares realized burn against the `rate` assumed here, so a projection that missed by 2x is visible rather than silently repeated next run.

Launch checklist for the report:

- `export LINEAR_TEAM=<KEY>` in every fleet session (else `/next` roams the workspace).
- Project main checkout clean and parked off the integration branch (`git checkout --detach`) — keeps every merge on the ref-only path.
- Run the `solo` issues via targeted `/auto <ID>` (or `/full <ID>`) before or after the fleet, not during. Two invocations split the plan: bare `--label solo` is the **workable-now** set (its blocker filter hides the rest), and the `--include-blocked` diff is the **blocked** set — workable ones are the pre-fleet knock-out candidates; blocked ones wait on their blockers regardless of the quiet window.
- The decisions (Step 2 flags, `needs decision` issues) that would refill the pool once made.
- The Step 4 fleet-drain audit's remaining hits (`FLEET-BLOCKED` rows not remedied during prep) — each is a candidate the fleet will NOT reach tonight.

## Report

Lead with the recommended session count **and the duration**, how to launch it (`/fleet-launch [count] [duration]` — count defaults to this run's persisted recommendation; an explicit count is the user's quota throttle), and **which of the four terms bound it** (lanes / the 8 cap / the 5h burst window / weekly). Show the projected burn per 5h window beside the observed peak, so the user can see the margin they are running on rather than taking the count on faith. Then: changes made (consolidations as absorbed→canonical with the class named, edges as blocker→blocked with one-line rationale, label ops, priority bumps), the flag lists by disposition (needs-decision / decision-gated / solo), and the validated top of the ranked pool. Render the `solo` list in two groups, each in running order — it is a work plan for the quiet window, not a warning: **workable now** (bare `next-candidates.sh --label solo` — no open blockers; what the keeper can knock out before launching the fleet) and **blocked** (the `--include-blocked` remainder, each annotated with the blocker it waits on and whether that blocker is itself in the workable-now group). Every write is reversible — say so once.

## Error Handling

- No team resolvable → ask for one; never scan the workspace.
- Zero certified candidates → report it and point at `/spec` (certify backlog) rather than inventing prep work.
- A label/relation write failing mid-run leaves prior writes in place — report what landed and what didn't; all operations are idempotent to re-run.
