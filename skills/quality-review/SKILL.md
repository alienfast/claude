---
name: quality-review
description: Adversarial implementation review with a triage-and-fix loop — gate on `pnpm check`, quality-reviewer discovery, fixes by lane, fix-delta re-verification on quality-verifier until convergence, then deferred-item triage into Linear. Accepts the `auto` and `simple` tokens. Use when the user says 'review my work', 'check this implementation', 'adversarial review', 'quality review', or invokes /quality-review.
model: opus
effort: xhigh
---

# Quality Review

Run an adversarial review of the current implementation, then triage and fix findings until the implementation passes
cleanly. Used mid-development, before `/finish` — standalone, or delegated from `/start` Step 9.

## Invariant

**Working Application Contract** — `skills/start/SKILL.md` § Working Application Contract. The application was working
before the changes under review; `pnpm check` proves it still is, for the suites it runs (a suite outside it is the
contract's rule 1). A check failure after our changes is never "pre-existing" or "out of scope" — it is our breakage,
fixed before review proceeds. Turbo caching keeps repeated runs on an unchanged tree cheap.

## Arguments

- **Issue identifier** (e.g. `PL-13`) — optional; auto-detected from branch/commit when omitted. With none resolvable
  the skill runs without requirements-conformance context.
- **Positional file paths** — optional override of the auto-detected scope.
- **`auto`** (case-insensitive, position-agnostic) — autonomous mode: every prompt resolves to its documented default
  (`skills/full/SKILL.md` § Auto mode). This skill has two prompts: Step 5's soft-ceiling prompt resolves by the trend
  gate, lane drain, and provenance resolution in `references/soft-ceiling.md`; Step 6 sub-step 6's filing prompt
  resolves to `suggested`, and its state-name fallback files into the team default state, noted in the verdict block.
  Nothing else changes. Passed through by `/start auto` for the `/auto` loop.
- **`simple`** (case-insensitive, position-agnostic) — the simple review tier for a risk-low change
  (`standards/issue-spec.md` § The `simple` label): one `quality-verifier` scoped review in place of `quality-reviewer`
  discovery, at most two review cycles, four guards escalating fail-closed to the full tier. `/start` passes it when
  typed or when the issue carries the `simple` label; a typed token is a request, never an exemption from the guards.
  Compatible with `auto`. Read `references/simple-tier.md` at Step 3.

Examples: `/quality-review`, `/quality-review PL-13`, `/quality-review auto PL-13`, `/quality-review simple PL-13`,
`/quality-review src/foo.ts src/bar.ts`, `/quality-review PL-13 packages/api/`.

Reject any bare argument that is neither an issue ID (`[A-Z]+-[0-9]+`), the `auto` or `simple` token, nor a path that
exists on disk. `merge`, `pr`, `push`, `no push`, `don't push`, `skip push` are `/finish` arguments — error with
`Argument 'X' is a /finish argument, not a /quality-review argument` rather than treating one as a missing path, which
would produce an empty scope and warn about nothing to review.

## Workflow

### Preflight: Exit Plan Mode If Active

Standalone in plan mode, call `ExitPlanMode` before anything else (Steps 1+ need Bash, Agent, Write); detect by the
harness indicator or a plan-mode block on `detect-issue-id.sh`, never speculatively, and pass a one-line plan naming the
change set (a typed ID inlined only when it matches `^[A-Z]+-[0-9]+$`, uppercased). Approved → Step 1. Rejected → stop
with `/quality-review aborted at preflight: user rejected plan-mode exit. No review ran; no verdict persisted.` (no
lifecycle tag; `/finish` later sees `VERDICT=none-found`). Tool error → surface it verbatim, then stop with
`/quality-review aborted at preflight: ExitPlanMode failed (<first line>). No review ran; no verdict persisted.` From
`/start` Step 9 plan mode is never active and this is a no-op.

### Step 1: Resolve Scope

**Issue ID** — the shared script `/start` and `/finish` use; pass `--input` only when the user typed an ID:

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

It tries `--input` → current branch → latest commit subject. On exit 1, proceed without issue context (the
requirements-conformance line in the reviewer prompt is omitted).

**Scope-mismatch guard.** When the ID was auto-detected and the resolved scope is clearly not that issue's
implementation (side work on a branch named for an unrelated issue), proceed WITHOUT issue context and say so in chat.
It fires on auto-detected scope as readily as on positional paths — the commit-subject fallback resolves any HEAD whose
tip names a merged issue whenever the branch name carries no ID. Decide on the diff, not the issue's state; a deliberate
re-review of a shipped issue's own branch keeps its context. Never persist a verdict keyed to an issue whose
implementation the diff is not: it overwrites that issue's real verdict with a fresher mtime and misleads `/finish`
Step 8's gate. A user-typed ID is an instruction, not a detection — the guard does not apply.

**Changed files**: explicit positional args; otherwise the union of the merge-base diff and the working tree:

```bash
git merge-base HEAD origin/main   # run alone; substitute the literal SHA below — `$(…)` is refused in wt sessions
```

```bash
git diff --name-only <merge-base-sha>...HEAD
git status --porcelain -z --untracked-files=all --no-renames | tr '\0' '\n' | cut -c4-
```

(`-z` avoids C-quoting under `core.quotePath`; `cut -c4-` strips the status prefix; `--no-renames` keeps one field per
record.) Before defaulting to `origin/main`, check for a `/start wt` source branch — `git rev-parse --show-toplevel`
alone, then `git -C <WT_ABS> config --worktree --get start.source-branch` — and use it as the merge-base target when
set: `origin/main` is rarely a worktree's real parent, and diffing against it can return a feature branch's whole
history. An empty union → warn and exit — unless the issue names targets outside this repo (a `keeper`-labeled issue's
deliverable is in `~/.claude`, so this repo's union is empty by construction, and exiting persists no verdict for
`/finish`): resolve scope from the issue body's `- [ ] **<target file>** — …` lines intersected with
`git -C ~/.claude status --porcelain`, review exactly that and never the rest of that repo's dirt (other sessions' work,
which would key this verdict to it), exit if the intersection is empty, and run Step 2's `pnpm check` in that repo too —
leaving alone the out-of-scope `.md` files its `markdownlint-cli2 --fix` reformats. Run the same check for any mixed
filing, or its user-level half goes unreviewed.

**Issue requirements** (only with an issue): `linear-cli issues get PL-13`. Cache it for the whole run.

**Worktree mode.** Derive `WT_ABS` (`git rev-parse --show-toplevel`) and `MAIN_CHECKOUT` (parent of
`git rev-parse --path-format=absolute --git-common-dir`), each its own Bash call, and carry the literal paths.
`WT_ABS != MAIN_CHECKOUT` means `wt` mode is on: every delegation carries the READ-SCOPING block, every write-capable
one the WRITE-PLACEMENT block and the post-dispatch path probe — `standards/git-worktrees.md` § Delegation placement,
templated in `/start` Step 8. Read `references/worktree-hygiene.md` when `wt` mode is on: the probe-cleanup clause
every read-only dispatch carries, and the two-direction dirty-set comparison and expected-dirty hash check after every
delegation.

**Dispatch.** Every delegation here produces a result the very next step consumes, so dispatch each with
`run_in_background: false` (`standards/agent-coordination.md` § Background-agent completion reports); parallelism
comes from several dispatches in one message, never from backgrounding. Three tiers, fixed by role: the **initial
review (Step 3) runs on `quality-reviewer`** (opus/xhigh per its frontmatter — discovery depth is the one place the
heavy configuration pays for itself); **every re-review and fix confirmation runs on `quality-verifier`** (sonnet-tier,
built for verifying a fix delta under the same findings contract — Step 5 item 4's re-reviews, item 5's
`Targeted fix confirmation`, Step 6 sub-step 5's re-reviews, the Error Handling corrective re-spawn of any of those,
and the simple tier's scoped review); **every fix dispatch runs on `developer` with `model: sonnet`** on the Agent call
(Step 2's gate fix, Step 5's fix batches, Step 6 sub-step 5's above-bound fix-now items and corrective pass), with the
verifier-tier re-review as the correctness backstop. The smallest fixes dispatch nowhere: mechanical-lane, prose-lane,
and gate-clearing fix-now items are **applied directly in-session** by the orchestrator — their lane gates (single file,
~<15 lines, no contract change) are the "handful of tool calls" boundary below which a dispatch buys only overhead —
with the lanes' confirmation and check gates as the independent verification.

**Carry forward filed and routed items into every later reviewer prompt.** Once a finding is filed as a Linear issue,
or routed to a deferred filing not yet executed, every subsequent `quality-reviewer`/`quality-verifier` prompt this run
names it — ID or planned disposition plus a one-line summary — with the instruction not to re-flag it; each prompt is
composed fresh from its own template and the agent has no memory of prior cycles. One carve-out, stated beside every
suppression: a later fix delta that made a tracked item *worse* is a new fix regression, reported at its real severity.

### Step 2: Working Application Gate

```bash
pnpm check
```

**Fails** → we broke a working application. Do not review, do not rationalize: delegate to `developer` (sonnet-tier)
with "The application was working before our changes. It is now broken. Fix it.", re-run, repeat until green.
**Passes** → the contract holds; proceed.

### Step 3: Delegate Adversarial Review

```md
Task for quality-reviewer: Adversarial implementation review for PL-13
Context: Implementation of [issue title or one-line summary of the change] is complete. Your job is to try to break it.
Issue requirements: [Paste requirement checkboxes from the issue — omit this line entirely if no issue was resolved in Step 1]
Files: [List every file in the resolved scope from Step 1]
Requirements:
- Verify every issue requirement is actually satisfied, not just approximately
- Find edge cases with concrete triggering scenarios
- Trace error paths for completeness (including partial failure)
- Check implicit assumptions about inputs, state, and ordering
- Identify concurrency/timing issues under load
- Assess security surface beyond obvious vulnerabilities
- Check integration boundaries with existing code
- Verify conformance against user-level and project-level conventions
- Report every issue you find, including ones you are uncertain about or judge low-severity. Your job at this stage is coverage, not filtering: Step 6 triage ranks and disposes of findings, so it is better to surface something that later gets filtered out than to silently drop a real bug. Put your severity estimate in the section you file it under — Nice-to-Have is a real lane that gets fixed, not a discard pile.
- Read as widely as the review requires — callers, integration boundaries, conventions — but ingest incrementally, file by file as questions arise. Do NOT diff against long-lived branches: the issue's own delta (merge-base..HEAD) is the widest diff you may run. Generated artifacts (e.g. src/generated/*, schema dumps, lockfiles) are grep-only — grep them for the symbols you need, never read them wholesale. Everything you read is live context that compaction cannot shed; one bulk ingestion ends your review before it starts.
Acceptance: Produce a categorized findings report following the Required findings format below — markdown sections with `## Review Findings` heading and the five `### <severity>` subheadings, in that order. Do NOT emit JSON arrays of findings, tables, "Verification summary" sections, "Categorization" tallies, or any alternative structure. The format is parsed by Step 6 sub-step 1; deviations break the consolidation step and surface raw output to the user.
```

**Simple tier** (`simple` token) — read `references/simple-tier.md` now. One `quality-verifier` scoped review replaces
the template above, capped at two cycles; four guards escalate fail-closed to the full tier by dispatching this template
as the next cycle: the reviewability ceiling (~8 files / ~300 lines of non-generated diff, untracked files counted
whole), a forbidden co-label (`security`, `human`, `needs decision`, `epic`), the verifier's `ESCALATE:` answer, and a
Critical/High finding on the change at any cycle (any fix regression at cycle 2).

**Large or multi-domain changes** — read `references/parallel-review.md`: domain-scoped reviewers in one message, each
sized to its context budget, each with its own probe path and the shared-tree warning, write license split for mutation
testing. Consolidate findings before Step 4.

**Required findings format** — the parsed contract; `quality-reviewer`'s system prompt specifies the same, and both
must agree:

```markdown
## Review Findings

### Critical (must fix before done)
- [Finding]: [File:line] — [concrete scenario that triggers it]

### High (should fix)
- [Finding]: [File:line] — [concrete scenario that triggers it]

### Medium (real risk, lower probability)
- [Finding]: [File:line] — [scenario and likelihood assessment]

### Nice-to-Have (auto-fix lane)
- [Finding]: [file:line] — [the concrete fix — queued for /quality-review Step 6 triage]

### Approved
- [What survived adversarial review and why]
```

**Mid-run surfacing.** When findings reach the user before Step 6, state the Nice-to-Have lane's disposition — queued
for Step 6 triage: auto-fixed when safe or recorded under `Deferred dropped` (the lane never files), or routed to
`Open items` on early termination — never silently ignored. **Persist the lane as each dispatch returns**: append the
verbatim `### Nice-to-Have` section to `tmp/quality-review-nth-<issue-lower>.md`, prefixed with its cycle label (a plain
append). Step 6 sub-step 1 consolidates from this file; a mid-run compaction destroys the lane from context, and nothing
downstream reveals the loss.

### Step 4: Evaluate Verdict

No Critical, High, or Medium findings → the review passes; proceed to Step 6 with `passed-clean` (cycle 1) or
`passed-after-fixes` (later cycles). Any → Step 5. Nice-to-Have findings never affect the verdict; Step 6 handles them.

### Step 5: Triage & Fix Loop

**1. Fix every Critical/High/Medium finding in scope, pre-existing ones in touched files included.** Leave code better
than you found it; at this severity nothing is deferrable (this governs the **initial** review's findings — a
re-review's are routed by item 5). Classify each finding prose-only / mechanical / substantive as item 5 defines the
lanes: prose and mechanical findings are direct-applied and verified by their lanes' own machinery, substantive ones go
to item 2 — the lanes change how a fix is applied and verified, never whether. **A Nice-to-Have on the lines a fix must
rewrite is fixed in that batch**: when the fix would propagate the flagged defect (a third copy of a duplicated block, a
new call site missing the named guard) or author the very lines the Nice-to-Have governs (a new spec arm whose missing
assertion is the finding), name it in the dispatch's `Findings` and record it under `Deferred fixed in-session`,
excluded from Step 6 sub-step 1. The trigger is propagation, not proximity — a Nice-to-Have merely nearby still defers
to Step 6 — and a fix needing a new abstraction or cross-file move is what the escape hatch excludes: the batch avoids
propagating, and where it cannot without restructuring the delegate stop-and-reports.

**2. Fix all Critical/High/Medium items** — `developer` (sonnet-tier), parallel agents in one message for independent
files, with the template in `references/fix-dispatch.md` — read it when composing the first fix dispatch of a run. It
carries the completion bullets (every enum variant, every sibling within the named files, every `return` on an
exit-path finding, every input class of a new guard), the scope escape hatch, the no-provenance-decoration bullet, and
the orchestrator's bounds on applying a remedy: route a stop-and-report yourself, never re-dispatching "just do the
restructure"; complete a class-shaped finding through one of four bounded paths; enumerate a group member by member
before authorizing its deletion; open any external artifact a remedy cites and confirm it covers the claim; give a
wording finding a wording fix only; and sweep the batch for the dispatch's own finding labels before item 3.

**Snapshot first — the re-review needs the fix delta as a diff.** Before any fix of the cycle lands, in any lane:
`rm -rf tmp/qr-fix-base-<issue-lower|no-issue>-<cycle>`, then copy every path in the derived dirty set
(`git status --porcelain --untracked-files=all -- ':!tmp' | cut -c4-`) under it. After fixes and check, re-derive the
dirty set, `diff -u` each file against its snapshot, and concatenate; a file with no snapshot falls back to
`git diff -- <file>`, labeled as possibly carrying pre-fix hunks. Derive both sets, never hand-write them; issue-scope
and clear the directory every time (a stale base disarms the fallback); never replay a concatenated delta through
`patch` (it reverse-applies sections 2..N and exits 0). Inline the delta in every verifier prompt up to 200 lines; above
that, write it with `>|` to `tmp/qr-fix-delta-<issue>-<cycle>.diff`, pass the absolute path with the STOP-on-missing
instruction, and populate `Changed files:` from the fixes' own footprint, never from the file. Read
`references/fix-delta.md` before the first snapshot of a run, and whenever a delta goes by path.

After fixes land, continue through items 3→4→5. Do not stop after fixing.

**3. Verify check passes** — re-run `pnpm check`; if it fails, delegate further fixes before proceeding.

**4. Re-review — mandatory whenever the cycle applied a substantive fix.** One exemption: when a cycle's entire batch —
the initial review's included — is prose-lane and mechanical-lane fixes, their own verification (isolated prose checks,
the targeted confirmation) is the completion gate and no re-review is spawned. Spawn `quality-verifier` scoped to
verification of the fix delta — not a fresh review of the whole change — with the template in `references/re-review.md`
(read it on the first re-review of a run): in scope, each fix resolves its finding, each closure by argument is sound,
the delta's blast radius is regression-free; out of scope, modalities the initial review did not run and re-litigating
unchanged code (a real issue outside the delta is flagged `[out-of-delta]` and routed by disposition). The template
carries `Changed files`, the inline `Fix delta`, `Previous findings addressed`, `Accepted risks this cycle` (a residual
a fix accepted by argument, phrased as the measurement to make), and `Already tracked`. When a fixed finding was a
duplicated decision, add the class-shaped sweep — name the decision and the directory to search — and bound the
resulting fix (complete audit list; fix only what the change reaches plus any divergence the sweep introduces; report
the rest as deferred items), or the loop cannot converge.

**5. Route the re-review's findings; loop only on what deserves a cycle.** Split every new Critical/High/Medium
finding by lane, per finding — read `references/lanes.md` before the first prose-lane or mechanical-lane fix of a run:

- **Prose-only** (Step 6's definition, its three exclusions included; the reviewer's severity label does not matter):
  the orchestrator applies it **directly** as its own isolated edit confirmed by its own `pnpm check`, before the
  cycle's substantive fixes land — a failing check means the edit was not prose-only; treat it at its real severity.
  **Never loop fuel**: it neither mandates a re-review nor counts against convergence nor adds to `Cycles:` (the
  dispatch that surfaced it still counts). Same handling at every drain site. Three rules in `references/lanes.md`: a
  class-shaped prose defect completes across every sibling in the same pass, swept by token (the edited file included);
  a second attempt rewrites the paragraph, never a second qualifier; and when the change's **own deliverable is prose**
  (a recorded decision, an ADR, a doc/rule-only change), a false recorded claim is a defect of the change — still this
  lane, but the fix rides a `Targeted fix confirmation` wherever the lane drains with no re-review to follow, bounded to
  one corrective round, pure deletions exempt.
- **Mechanical**: fixed now, directly, verified by a **targeted fix confirmation** — not a cycle. A finding is
  *mechanical* when its fix requires no choice between valid alternatives AND is localized (single file, or a spec file
  plus its subject) AND changes no public API, schema, or contract AND is small (~<15 lines) AND is directly checkable
  by `pnpm check` plus a targeted test run — a missing import, one spec arm pinning existing behavior, a wrong string.
  Classify by the **fix**, not the severity; **doubt resolves to substantive** (runtime behavior the classifier cannot
  fully predict is not mechanical). Complete the class first (in-scope siblings in the same pass, beyond-scope ones
  routed out as severity-carrying deferred items; a class that blows the size bound was never mechanical), apply
  directly, run `pnpm check` plus the targeted specs, then dispatch one `Targeted fix confirmation` to
  `quality-verifier` (template in `references/lanes.md`). **A flagged confirmation does not close its finding**: the
  problem re-enters this lane split from the top; the original closes on the re-route's disposition; severity is
  inherited upward; the lane is a one-way door (a confirmation is never a review cycle); mixed-lane batches order prose
  → mechanical → substantive.
- **Substantive** — loop fuel: return to the top of this step. Membership narrows as cycles accrue, counted per
  `references/soft-ceiling.md` § Ground the count. **At any cycle**: fix regressions and unsound closures at every
  severity, and any new Critical or High defect of the change (including `[out-of-delta]` ones that are neither prose
  nor mechanical). **A new Medium of the change qualifies only when surfaced by cycle 2**; later it is routed out via
  the pre-existing bullet's machinery as a **severity-carrying deferred item**, the filing noting it is a defect of this
  change — by cycle 3 the change has had a discovery pass and a full-fuel verification pass, so a late Medium buys a
  filing, not a cycle.
- **Pre-existing beyond the change**: not fuel, not fixed here — routed out as a **severity-carrying deferred item**
  into Step 6 sub-step 6's "Suggested defer as issue" group (severity in the tag slot; certified `specified` once its
  body clears the quality bar, else rewritten or routed `needs decision`, never filed unlabeled), on sub-step 5's terms.
  Step 6 ingests these directly; on exits where Step 6 never runs they are rescued into `Open items`. The same applies
  to narrowed-fuel Mediums.
- **Ambiguity resolves to regression** — for both deferred exits. A finding leaves the loop only when this loop's own
  fix deltas are cleanly exonerated: pre-existing means plainly true before the loop began; a narrowed-fuel Medium must
  be plainly a defect of the change, not of any fix. Otherwise it is substantive. Mis-calling a regression ships a
  break; mis-calling the other way costs a cycle. The classifier is the party that wants to converge and owes the
  mechanical lane's conservatism; the ceiling is not a safety net that re-classifies what it defers.

**Termination.** The loop terminates by **convergence** — a re-review surfaces no new **substantive** findings, or the
initial review surfaced none and its all-prose/mechanical batch drained clean (a run that never needs a re-review
converges at cycle 1). Prose-only, mechanical, and deferred-routed findings do not block convergence. On convergence,
run the lane drain `references/soft-ceiling.md` prescribes, then exit with `passed-after-fixes` to Step 6 — only once
every prose fix's check is clean and every mechanical confirmation has returned clean. A dirty drain withdraws the
declaration: a failed prose check or a flagged confirmation re-enters the lane split, and a substantive landing re-arms
the loop. Exiting `passed-after-fixes` on a red `pnpm check` violates the Working Application Contract.

**Simple tier cap.** The scoped review is cycle 1 and item 4's re-review is cycle 2; a Critical/High on the change at
either cycle, or any fix regression or unsound closure at cycle 2, escalates to the full tier by
`references/simple-tier.md`'s recipe; everything else at cycle 2 takes item 5's routes, a new Medium of the change
filing as a severity-carrying deferred item.

**Soft ceiling.** After 5 review cycles (initial + 4 re-reviews, counted from the dispatch headers — `Targeted fix
confirmation` dispatches never count), read `references/soft-ceiling.md`: in auto mode a decreasing recent trend extends
the ceiling once by 3; both modes then drain the mechanical and prose lanes (one corrective round for a flagged drain
confirmation); interactively the prompt offers continue / accept (`terminated-with-open-items`) / architect
(`escalated-to-architect`), and auto mode resolves post-drain survivors by provenance — any Critical/High or regression
terminates with open items, an all-Medium pre-existing residue converges and files them as severity-carrying deferred
items.

### Step 6: Deferred Items Triage

Runs once, after the loop terminates with `passed-clean` or `passed-after-fixes`. On `terminated-with-open-items` it is
skipped, but sub-step 1's consolidated list **and** every severity-carrying deferred item Step 5's deferred routes sent
out of the loop are appended to the verdict block under `Open items`. Two inputs: the consolidated Nice-to-Have lane,
and every Critical/High/Medium finding routed out of the loop as a severity-carrying deferred item — the latter is never
consolidated or auto-fixed; each takes sub-step 6's reachability test and lands in "Suggested defer as issue" or in
`Deferred dropped` with a re-open trigger, so a run whose entire deferred output is one routed High still reaches
sub-step 6. Read `references/deferred-triage.md` when either input is non-empty: it carries each sub-step's full rules,
the templates, and the verdict population on early termination. Sub-step 6 is the step's only prompt (a malformed reply
is re-prompted once, then falls back to `all`); sub-step 5's regression cap and sub-step 6's create-failure rule can
downgrade a passing verdict to `terminated-with-open-items`.

1. **Consolidate** every Nice-to-Have from `tmp/quality-review-nth-<issue-lower>.md` (grep the transcript if it is
   missing — `references/verdict-recovery.md`); strip locationless `NOTE:` bullets with a chat note each (Nice-to-Have
   only — a NOTE-shaped C/H/M bullet is surfaced, never dropped); deduplicate by `file:line + text`, or by text alone
   for a locationless finding. Empty → sub-step 6.
2. **Classify** each item `fix-now` or `note-only`, first match wins: a comment-, doc-, or rule-text-only fix is
   `fix-now` (prose-only overrides every later gate; three exclusions — code+prose, prose wrong because the code is
   wrong, a meaning/policy change; one non-exclusion — a doc-string fix that forces artifact regeneration); a change
   that is obviously correct with no decision between alternatives, localized, contract-free, and small (~<30 lines, no
   new abstraction) is `fix-now` with a kind tag — the default home for trivial polish, non-gating but not optional, and
   dead code and duplication consolidated into an established home qualify under relaxed gates; everything else is
   `note-only`, recorded with its rationale and, for a refinement of this run's own fix, its re-open trigger. **The
   Nice-to-Have lane never files an issue** — a ticket-worthy nit is a severity question, not a filing question.
3. **Present** the `fix-now` list, numbered; omit when empty. `note-only` items are not rendered.
4. **Select** every `fix-now` item for auto-apply with no prompt; skip 4–5 when the group is empty; emit one chat line
   naming the items.
5. **Fix** them: snapshot (cycle token `deferred`); prose-only and mechanical-lane items directly, the remainder to
   `developer`; `pnpm check` (one corrective delegation, then Error Handling); a `quality-verifier` re-review scoped to
   the touched files, exempt on item 4's terms when the orchestrator applied the whole batch (mechanical items then ride
   one `Targeted fix confirmation`). New Nice-to-Haves: prose-only applied directly, the rest `note-only`, never
   re-fixed. New C/H/M split by provenance (regression implicates this sub-step's delta; ambiguity resolves to
   regression): pre-existing ones never downgrade the verdict and route straight to sub-step 6's group; regressions get
   exactly one corrective pass and an optional confirmatory re-review that restores `passed-after-fixes` when nothing
   lands as a regression — otherwise Step 6 terminates with `terminated-with-open-items`, implicated fixes and unoffered
   fileable items in `Open items`.
6. **Offer Linear issues** for what remains fileable — skip when nothing is (the common case). Render the grouped list
   with sub-step 3's numbering preserved; the "Suggested defer as issue" group's membership is defined there, once:
   every severity-carrying deferred item that passes the reachability test (one sentence naming the actor, surface, and
   input that produce the consequence in production, with no coincidence of independent conditions) — never a
   Nice-to-Have, a prose-only finding, or a fixed item. Ask; `suggested` files the group, `all` is identical, `none`
   files nothing, a numeric list files those numbers (skipping fixed items). Auto mode renders and proceeds as
   `suggested`, filing into the team default state when the state-name fallback would need to ask.

**File every chosen item per [standards/linear-filing.md](../../standards/linear-filing.md)** — search before filing,
`linear-create-child.sh` under `<ISSUE-ID>` (`-` when Step 1 resolved none), class labels and the severity priority at
create, collision edges, `specified` last — one item at a time, in rendered order, in interactive and auto mode alike,
for the Step 6 batch and for any ad-hoc mid-run filing. This skill's inputs to that recipe:

- **Severity → priority and state.** Critical → 1, High → 2, Medium → 3; the severity tag belongs to the render above,
  never to the filed title. Priority 1–2 or a `security` class label files into `Planned` behind `--allow-planned`;
  everything else into `Backlog`. The `suggested` reply token is a reply, never a label.
- **Provenance.** The parent is the issue under review. The body's `## Problem` is the finding told as a story and its
  `## Evidence` carries the reviewer's verbatim text and `file:line`; a body whose criteria cite a measurement this run
  produced (a repro rate, a baseline count) ships the apparatus with it. Before filing a decision-shaped item, read the
  Decisions sections and `(decided: …)` markers on `<ISSUE-ID>` and every ancestor in its parent chain, per the recipe.
  The parent→child `blocks` edge is wired only while this run's verdict is still passing: a run already headed for
  `terminated-with-open-items` (Step 5's option 2 reaches this sub-step) ends with `/auto` abandoning the parent In
  Progress and `stalled`, the blocker-that-never-ships that strands a child.
- **Where each item lands in the verdict block.** Filed (a dedup's `<ID> (existing — evidence appended)` and every
  helper annotation included) → `Deferred filed as issues`, with the `(sub-issues of <PARENT>)` suffix. A **create
  failure** (the helper's `failed to create issue` family with no id on stdout) stops filing and **downgrades the run to
  `terminated-with-open-items`**, the same transition sub-step 5's regression cap uses, because the unfiled items have
  nowhere honest to go under a passing verdict: the filed prefix stays under `Deferred filed as issues` (the bare word
  `none` if the first create failed), the failed item goes to `Open items` as `create failed: <first line of helper
  stderr> — the issue may exist unlinked; check Linear, then re-file or link manually`, and every chosen-but-never-
  attempted item after it as `not attempted — filing stopped at the create failure above`. This holds in auto mode too:
  the failing verdict makes `/finish auto` abort and `/auto` surface the issue to a human. A verification wobble, a
  pre-flight refusal, a label that did not attach, or a nesting-cap peer edge never downgrades: annotate and continue,
  per the recipe. Every other field is unaffected.

Every fileable item rendered that the reply did not select goes to `Deferred dropped`, joined by every `note-only` item;
items that never reached the prompt because Step 6 terminated in sub-step 5, and chosen items a create failure left
unfiled, go to `Open items` instead.

## Output

Returning to the caller (or the user, standalone), present a structured verdict block — delegated from `/start`, it
becomes the completion summary's "Adversarial review" section verbatim:

```text
Verdict: <one of: passed-clean | passed-after-fixes | terminated-with-open-items | escalated-to-architect>
Cycles: N (initial + N-1 re-reviews)
Findings resolved: [list — every severity tag carries an origin class, SEVERITY/origin; or the bare word none if passed-clean]
Deferred fixed in-session: [list of items applied in-session, including auto-applied fix-now items even when sub-step 6 was skipped; or the bare word none]
Deferred filed as issues: [PL-XX, PL-YY (sub-issues of <PARENT>), or the bare word none]
Collision edges: [required whenever the line above names an issue: each edge wired across the filed batch and to open hits (PL-XX blocks PL-YY; PL-XX related PL-ZZ), or the phrase none owed — the writer script WARNs when it is missing and fleet-metrics.py flags it at retro]
Deferred dropped: [items intentionally not filed — note-only items auto-classified too minor to track, plus every fileable item rendered at sub-step 6's prompt that the chosen reply did not select for filing; list, or the bare word none]
Open items: [list, or the bare word none — populated only on terminated-with-open-items or escalated-to-architect; includes any deferred items not handled above]
```

**Process notes go after the schema fields, never inside one.** A delegate's leftover path, a vanished expected path, a
hash mismatch, and the simple tier's `Review tier:` line are a trailing paragraph below `Open items:` — after a blank
line, never directly beneath it, which `/finish` Step 8 may read as a continuation. Every consumer reads the block by
anchored per-line match (`quality-review-write-verdict.sh` validates the seven field lines, `finish-read-verdict.sh`
extracts `Verdict:` and `Cycles:`, `fleet-metrics.py`'s regexes are `re.M`-anchored), so a trailing note persists in
both verdict copies and is reproduced by `/start` Step 10 but never reaches `/finish`'s completion comment. Never fold
one into `Open items:`, which `/finish` Step 8 and `/start` Step 10 read as unresolved work.

**Every severity tag carries an origin class** — `SEVERITY/origin` (e.g. `HIGH/plan`) wherever a severity tag renders.
Origin names the stage that would have prevented the finding (`/fleet-retro` aggregates it to decide where to tune);
exactly one of `plan` (the posted plan was wrong or incomplete — a missed requirement, wrong scope, a missed sibling
issue, a reversed design choice), `impl` (the plan was right; the code diverged or carries a code-level defect), `spec`
(the issue's own description or success criteria were wrong or incomplete; no plan from that spec could have avoided
it), `test` (coverage-only gap — behavior correct but unpinned), `latent` (adjudicated pre-existing by sub-step 5's
provenance split or Step 5's pre-existing route — the codebase's latent pool, not any stage of this session).

**Substitute resolved values before rendering — never emit the schema verbatim.** `Verdict:` MUST carry exactly one
enum value, no `|`, no angle-bracket placeholders: `finish-read-verdict.sh` takes the first whitespace-separated token
after `Verdict:`, so the verbatim schema would read downstream as `passed-clean` — the most permissive value — and
bypass `/finish` Step 8's gate; the same extraction on `Cycles:` has no enum validation, so an unsubstituted line yields
a literal `CYCLES=N`. A concrete passing example:

```text
Verdict: passed-after-fixes
Cycles: 3 (initial + 2 re-reviews)
Findings resolved: 2 (CRIT/impl: null-pointer in handler; HIGH/plan: race in retry loop)
Deferred fixed in-session: 1 (dead-code in spec_helper.rb)
Deferred filed as issues: PL-299, PL-300 (sub-issues of PL-190)
Deferred dropped: none
Open items: none
```

**Compose `Findings resolved` from the run's recorded text, never from recollection** — a summarization keeps the
per-cycle counts and destroys the finding text, and no consumer validates the field. Read
`references/verdict-recovery.md` whenever the wording is not in context: it carries the transcript grep that recovers
it and the check that settles each `origin`. The `(sub-issues of <PARENT>)` suffix is required when issues were filed
and a parent was resolved in Step 1; omit it only when no parent was resolved. The writer script WARNs whenever issue
IDs render without it (advisory — it cannot tell the legitimate omission from a batch filed parentless): confirm no
parent was resolved, or re-link with `linear-cli relations parent <CHILD> <PARENT>` and re-run the publish. Inline
annotations: `PL-XX (specified label not attached — not /auto-eligible until labeled)` when the helper exited 2;
`PL-XX (parent link unverified — confirm in Linear or re-link manually)` for sub-step 6's verification-failed marker.

**Persist the verdict for `/finish`.** Skip only when no issue ID was resolved. In ONE call, pipe the resolved block —
every placeholder substituted, no `|`-separated schema lines — into the script on stdin; it publishes atomically to the
worktree's `tmp/` AND the main checkout's `tmp/`, which is what survives `/finish merge` deleting the worktree:

```bash
~/.claude/scripts/quality-review-write-verdict.sh <ISSUE-ID> - <<'VERDICT_EOF'
[the resolved verdict block, verbatim]
VERDICT_EOF
```

Quote the delimiter (`<<'VERDICT_EOF'`) so backticks and `$` in the body are not expanded — an empty body (what a
mangled heredoc degrades to) is rejected with exit 2. Exit **3** means the copies WERE written but a field line is
missing or unparseable (an unsubstituted `Cycles: N`, a pipe-carrying `Verdict:`, a field rendered as a heading): fix
the block and re-run the same call, which overwrites idempotently. **Never stage the body with `Write` under the
verdict's own basename** — the scratch-path-guard hook denies any `Write`/`Edit` to `quality-review-verdict-*.md` in
every directory, because a staged-but-unpublished file dies with the worktree and the audit trail with it. When the
isolation guard refuses the heredoc body (`standards/git-worktrees.md` § Worktree-isolated sessions), stage it under a
**different** basename and pass the path as the second argument (`… <ISSUE-ID> tmp/verdict-body-<issue>.md`). The
harness blocks a direct write to the main checkout's `tmp/` from a `/start wt` worktree; that guard is correct, and this
script is the sanctioned route across the boundary. The persisted file is the canonical `/quality-review` → `/finish`
handoff; `/finish` Step 1.5 parses `Verdict:` and `Open items:`.

## Error Handling

Read `references/error-handling.md` when any of these fires; its termination bodies are shapes, populated from what the
run actually did, and `Cycles:` there counts completed review-cycle dispatches only.

- `pnpm check` repeatedly fails at the Step 2 gate → surface the failing output; do not review.
- Sub-step 5's single corrective pass leaves the check red or regressions open → `terminated-with-open-items`, surface.
- No changed files → warn and exit.
- Issue ID given but `linear-cli` unauthenticated → prompt `linear-cli auth oauth`; auto mode continues without context.
- A reviewer dispatch cut off by a transient API error → resume it once via `SendMessage` before any re-spawn.
- A reviewer dispatch returns malformed findings → surface the raw output, one corrective re-spawn, then terminate.
- Reviewer agent unavailable → surface, terminate with open items.
- `quality-review-write-verdict.sh` fails (not exit 3) → surface stderr, print the persistence warning, continue in memory.

## References

- `references/simple-tier.md` — guards, scoped-review template, escalation recipe, Step 5 cap, tier note. Step 3, `simple`.
- `references/parallel-review.md` — domain split, context sizing, shared-tree warning, probe paths, write licenses. Step 3.
- `references/worktree-hygiene.md` — the two paths, probe-cleanup clause, dirty-set comparison, hash check. Step 1, `wt`.
- `references/fix-dispatch.md` — the `developer` fix template and the bounds on applying a remedy. Step 5 item 2.
- `references/fix-delta.md` — snapshot recipe, `patch` replay ban, a delta by path. Step 5 item 2; any delta over 200 lines.
- `references/re-review.md` — re-review template, verification not re-discovery, class sweep and bound. Step 5 item 4.
- `references/lanes.md` — prose carve-out, ping-pong, class completion, confirmation template and re-route. Step 5 item 5.
- `references/soft-ceiling.md` — count grounding, trend gate, lane drain, prompt, auto provenance resolution. Step 5 ceiling.
- `references/deferred-triage.md` — Step 6 in full: decision procedure, fix-now pass, filing prompt, membership. Step 6.
- `references/verdict-recovery.md` — recovering finding text from the transcript; settling `origin`. Output; Step 6 item 1.
- `references/error-handling.md` — each error branch's procedure and verdict body. Any Error Handling trigger.
