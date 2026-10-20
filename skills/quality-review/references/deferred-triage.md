# Deferred items triage — the full procedure

Step 6 reads this when its inputs are non-empty: a consolidated Nice-to-Have list, or any severity-carrying deferred
item routed out of the loop. The core carries the sub-step skeleton and the Linear filing inputs; this file carries each
sub-step's complete rules, the templates, and the verdict population on early termination.

## Inputs and conventions

**Severity-carrying deferred items are a second input.** Alongside sub-step 1's Nice-to-Have consolidation, Step 6
ingests every Critical/High/Medium finding routed out of the fix loop as a deferred item — by Step 5 item 5's
pre-existing lane and its narrowed-fuel Medium route, by the auto-mode ceiling resolution, and by sub-step 5's own
re-reviews (the mandatory one and the optional confirmatory one alike). Nothing about them needs consolidating or
auto-fixing; each takes the reachability test sub-step 6's membership definition sets, and the ones that pass land
directly in the "Suggested defer as issue" group — the ones that fail it are `Deferred dropped` with a re-open trigger,
never filed. Sub-step 1's empty-list short-circuit and sub-step 4's entry gate govern the Nice-to-Have lane only and
never discard them: a run whose entire deferred output is one routed pre-existing High still reaches sub-step 6 and is
offered for filing (auto mode's `suggested` default files it).

**Substitution token.** `<ISSUE-ID>` in the templates means the issue ID resolved in Step 1. With none, replace
`for <ISSUE-ID>` with `for the current change set` and skip the parent link in sub-step 6.

**Malformed user replies.** Sub-step 6 is the only prompt in this step. On a reply you cannot parse (`1-3`, `the first
three`, `sure`), re-prompt once with the exact accepted syntax — including the `suggested` shortcut — and a literal
example, re-rendering the full template. After a second malformed reply, fall back to the safe default `all` (filing
extra issues is recoverable; silently dropping findings is not). `suggested` is an accepted input, never a fallback.

**Verdict downgrade.** Step 6 can move a passing verdict to `terminated-with-open-items` — by sub-step 5's
regression-cap path, or by sub-step 6's create-failure rule when filing stops mid-run. The new verdict overrides Step 4's.

## 1. Consolidate

Collect every Nice-to-Have finding from `tmp/quality-review-nth-<issue-lower>.md` (written incrementally as each
dispatch returned) rather than from recollection; if the file is absent or predates a cycle, grep the session transcript
for each dispatch's `### Nice-to-Have` block (`verdict-recovery.md`). Strip any instructional or meta bullet — one whose
text begins `NOTE:` **and** carries no `file:line` — before consolidation: instruction-echo carries no location, while
every actionable finding carries one per the Required findings format, so the location requirement spares a finding
quoting an offending `NOTE:` comment but not a locationless `NOTE:`-prefixed one. A stripped bullet is reviewer
instruction-echo, not a finding: neither ingested, classified, nor rendered — emit a one-line chat note identifying it so
the drop stays visible. This strip applies only to Nice-to-Have ingestion — here and in sub-step 5's re-reviews — never
to Critical/High/Medium, where a NOTE-shaped bullet is surfaced for confirmation, not dropped: it either gates the
verdict or is forbidden echo. Deduplicate by `file:line + finding text`; a finding emitted without a `file:line` is
locationless, not malformed (no Error Handling criterion fires) — deduplicate it by finding text alone (trim, casefold,
collapse whitespace). If the consolidated list is empty, skip to sub-step 6, whose entry gate decides whether any
severity-carrying routed item remains to file.

## 2. Classify

Assign each item exactly one of two outcomes — `fix-now` or `note-only`. **The Nice-to-Have lane never files an
issue**: a reviewer Nice-to-Have carries the same target-of-opportunity semantics as the spec template's
`### Nice to Have` tier (`standards/issue-spec.md`) — fix it if it is easy, otherwise record it and drop it. Filing from
this lane is how a backlog's birth rate exceeds one issue filed per issue shipped. Real risks reach Linear exclusively
through the severity-carrying routes; if a Nice-to-Have seems to deserve a ticket, that is a severity question, not a
filing question — it either carried C/H/M and rides those routes, or it drops. `fix-now` items are **applied
automatically in-session with no approval prompt** (sub-steps 4–5) — gated to obviously-correct, localized,
no-API-change changes, so the user has opted into fixing them without per-item review. `note-only` items are neither
fixed nor filed — recorded in the verdict's `Deferred dropped` field, never surfaced as a decision.

### Decision procedure

Evaluate top-to-bottom; first match wins.

1. **Comment-, doc-, or rule-text-only fix** → `fix-now`. The prose-only rule below overrides every gate that follows.
2. **Clears all of these `fix-now` gates** → `fix-now`:
   - One obviously-correct change — no decision between valid alternatives. *Following an established codebase pattern
     is **not** an open design choice*: "I'd have to look at how it's done elsewhere" satisfies this sub-gate. It waives
     no other — a pattern applied across many files still fails localization, one that changes an exported contract
     still fails the contract sub-gate; either failure sends the item to gate 3.
   - Localized (single file or small contiguous region).
   - No change to public APIs, schemas, exported types, or contracts.
   - Small (~<30 lines diff, no new abstractions).
   - A pre-existing test arm's removal clears this gate only when the finding names the arm's home — the file that
     already pins the same matrix; it is then `fix-now` under the consolidation ruling below, applied in the fix batch
     with the consolidation ledger and the survivor's mutation proof. With no home named, coverage removal belongs to
     `/test-sweep`; it is `note-only`.
   - Attach a one-word kind tag: `[mechanical]`, `[naming-only]`, `[missing-guard]`, `[typo]`, `[dead-code]`,
     `[comment-fix]`, `[doc-fix]`, etc.

   This is the **default home for trivial polish**. When genuinely torn between `fix-now` and `note-only` for a small,
   safe change, prefer `fix-now` — the standing preference is to improve the code, not surface it. **The lane is
   non-gating, not optional**: every Nice-to-Have with a safe, concrete fix is `fix-now`, including rule/doc
   corrections, provably-inert cruft, and cosmetic regressions the change under review itself introduced.

   **Dead code and duplication consolidate under relaxed gates.** Dead-code deletion is always `fix-now` — except a
   pre-existing test arm with no named home, which the sub-gate above keeps `note-only` — deadness is provable (remove,
   run the suite; `rules/comments.md`'s discipline), and the reviewer grades substantial dead code Critical/High as a
   mandatory deletion, so it rarely reaches this lane. Consolidating duplicated code into an **established home** — a
   module every copy already includes, a support file that already hosts the pattern's siblings — is likewise `fix-now`
   even cross-file and even when it introduces a suite-wide name: the localization and no-new-abstraction sub-gates do
   not apply, because following the established home is not a design choice (gate 2's own pattern rule) and internal
   contract changes are embraced (`standards/technical-debt-prevention.md`). Exactly two escalations survive: a
   **deliberate divergence** among the copies — one copy intentionally differs — which is a genuine decision the
   consolidation must not flatten silently; and **sweep breadth** — copies beyond the change's resolved scope follow the
   mechanical lane's complete-in-scope/surface-beyond rule, never an unbounded sweep from here. A consolidation applied
   under this ruling preserves any deliberately-diverging sibling untouched and rides the normal fix-batch verification,
   never a blind direct apply; a pre-existing test arm removed under it additionally carries the consolidation ledger
   and the survivor's mutation proof — the gates `/test-sweep apply` runs — so the deletion is proven, not asserted.
3. **Otherwise** → `note-only`. Everything not safely fixable now is recorded and dropped — including items needing a
   design choice, cross-cutting scope, an API/contract change, or a broader test/perf/security strategy: under the
   opportunity semantics they are simply not opportune. The guard runs in the *other* direction unchanged: **"no visual
   harm," "cosmetic," "no-op," "not a regression," "harmless to the app," and "out of scope" are NOT grounds for
   `note-only`** when a safe, localized fix exists — those are `fix-now` (gate 2). A provably-inert no-op prop, a
   redundant token, or a cosmetic regression the change itself introduced all have a concrete fix. Record each
   `note-only` item (verbatim finding + `file:line` + one-line rationale — plus, for a non-defect refinement of this
   run's own fix, its **re-open trigger**: the observable signal, a Sentry event or a measured production occurrence,
   that would make it worth a session) for the `Deferred dropped` field; do not fix it, do not file it, do not prompt.

A `fix-now` candidate that fails a gate-2 safety check (a `[mechanical]` rename that also touches a public type) does
**not** auto-apply — it falls through to `note-only` with the failed gate in its rationale: a contract-touching nit is
dropped, not ticketed.

**A non-defect refinement of this run's own fix is `note-only` wherever it arises** — a Nice-to-Have finding, a
checkpoint's "carried forward" note, a mid-implementation deferral. Record it with its re-open trigger in the
completion-comment record, plus a durable code pointer at the site when regression-prone (`rules/comments.md`). And
distinguish the stronger-arm case first: a refinement that IS the issue's own preferred either/or outcome arm was
in-mandate to deliver in-session (`standards/issue-spec.md` § An either/or Desired Outcome is ordered) — reaching
classification cold means the cheap moment was already missed, which argues for the note and its trigger, never a filing.

**Prose-only fixes are always `fix-now` — never dropped and never fileable.** A *prose-only* fix edits only
non-executable text: a code comment, a doc-string, or a standalone documentation/rule file (`.claude/rules/*.md`,
`standards/*.md`, `CLAUDE.md`, and the like). When the prose is stale, incorrect, misleading, or self-contradictory and
the code/policy it describes is already correct, correcting it touches no behavior, API, schema, or contract — trivially
safe to apply in-session, and filing an issue to correct prose is pure overhead. This **overrides** gates 2–3 and any
"out of scope" reasoning — even when the prose lives in a file you would otherwise leave untouched (an already-run
migration whose comment is wrong, a rule doc pointing readers at the wrong file). It applies **wherever** a prose-only
finding surfaces, including ones first raised by sub-step 5's re-reviews. **Three exclusions:** a fix that edits *both*
code and prose is not prose-only — apply the standard criteria; prose that is wrong *because the code is wrong* is a
code defect — fix the code at its real severity, never paper over it by rewording; and a doc/rule edit that changes the
rule's *meaning or policy* (not merely correcting a stale, wrong, or contradictory fact) is a design decision — standard
criteria, which under the lane's two outcomes means `note-only` unless it is safely fix-now. **One non-exclusion: a
doc-string fix that forces regeneration of committed derived artifacts is STILL prose-only.** A GraphQL `description:`
change manifests exactly as a comment; the regenerated `schema.json`/client-file diff from a description-only change is
comments and metadata. Run the generator and commit its output as part of the fix; never scope around the regen, defer
the fix for it, or mark the work `solo`.

## 3. Present the fix-now list

Render the `fix-now` group with numbered items; omit the render entirely if the group is empty. **`note-only` items are
not rendered** — they are neither fixed nor filed, so listing them would surface exactly the minor items this
classification keeps out of view; they appear only in the verdict's `Deferred dropped` field. Nothing from this lane is
fileable — the "Suggested defer as issue" group renders in sub-step 6 and contains only severity-carrying items.

```text
Deferred items surfaced during review:

Auto-fixing now (no approval needed):
  1. [Finding] — [file:line] — [tag] — [rationale]
  2. [Finding] — [file:line] — [tag] — [rationale]
```

**Prompt mechanism (applies to sub-step 6).** Sub-step 6 is the only prompt in Step 6 — it asks about exactly one
action verb ("file as issue"); `fix-now` items are auto-applied with no prompt, so there is no second prompt to
disambiguate against. Render the unfixed-items list as **plain text above the question**; do not rewrite an item's label
to encode the verb — the [tag] communicates the recommendation, the label is the finding. The question MAY be an
`AskUserQuestion` multiSelect, in which case: every option label reads "file [finding]"; **every item in the rendered
"Suggested defer as issue" group is pre-checked**, so a one-click accept files exactly the set the `suggested` reply
files; and no "Other" / "type something" option is added — the tool surfaces one automatically, and the chat is always
available for `none`, a comma-list, or free text. A plain-text reply per the semantics in sub-step 6 is equally
acceptable. Item labels in the rendered list and in the option labels MUST use the same identifiers — Arabic numerals
only, never letters or roman numerals.

## 4. Select fix-now items for auto-apply

No prompt — every item in the `fix-now` group is applied in-session automatically. **Entry gate — skip sub-steps 4–5
entirely if the group is empty** and proceed to sub-step 6. Before applying, emit a one-line chat note listing the items
(`Auto-fixing 3 deferred items in-session: #1, #2, #4`).

## 5. Fix the fix-now items

- Snapshot every file a fix-now item will touch (`fix-delta.md`, cycle token `deferred`) — the re-review below carries
  the delta as an inline diff.
- Apply the fix-now items. Every item that is prose-only or clears the mechanical-lane gates (single file, ~<15 lines,
  no contract change) is applied **directly by the orchestrator**, no dispatch, exactly as the Step 5 lanes prescribe.
  Only the remainder — above that bound, up to gate 2's ~<30-line, small-contiguous-region ceiling — goes to
  `developer` (sonnet-tier; parallel agents for independent files; composed from `fix-dispatch.md`'s template minus its
  sibling-sweep bullets).
- Re-run `pnpm check`. If it fails after a single corrective `developer` delegation, surface the failure via Error
  Handling and stop — do not loop indefinitely.
- Spawn a single `quality-verifier` re-review scoped to **only** the files touched by the deferred fixes — **exempt on
  the same terms as Step 5 item 4**: when the orchestrator applied the whole batch directly (every item prose-only or
  clearing the mechanical-lane gates) and neither a `developer` fix dispatch nor the corrective delegation was needed,
  no re-review is spawned. The lanes' own verification is the completion gate in its place — and that is *not* the
  `pnpm check` alone: the mechanical-lane items ride a single `Targeted fix confirmation` (`lanes.md`'s template,
  carrying the snapshot delta inline — the snapshot is taken regardless of which verifier consumes it), and this is a
  fourth drain point for the prose carve-out, so where the change under review's own deliverable is prose the prose
  fixes ride that confirmation too. If a confirmation flags a problem, the confirmation re-route rules govern, and the
  regression/pre-existing split below applies to what they surface. Any item that went to a `developer` — gate 2 admits
  up to ~<30 lines, wider than the mechanical lane's ~<15 — keeps this re-review mandatory:

  ```md
  Task for quality-verifier: Adversarial re-review of deferred-item fixes for <ISSUE-ID>
  Context: Previously deferred Nice-to-Have items were just fixed. Verify correctness; try to break them.
  Changed files: [list]
  Fix delta (inline unified diff, captured per the snapshot recipe):
  [the concatenated per-file diffs]
  Previous deferred findings addressed: [list]
  Already tracked (do NOT re-flag, unless the deferred-fix delta made one worse — a latent gap turned reachable, a narrow case turned general — which is a new fix regression to report at its real severity): [each finding already filed as a Linear issue — its issue ID and a one-line summary — and each finding already routed to a deferred filing but not yet filed, with its planned disposition; omit this line entirely if there are none]
  Acceptance: Confirm fixes are correct. Flag any new findings (any severity) with concrete scenarios.
  ```

- If either of this sub-step's re-reviews — the mandatory one above or the optional confirmatory one under the
  upgrade-on-success exception below — surfaces new **Nice-to-Have** findings:
  - **Prose-only findings** are never fileable. The orchestrator applies each **directly** as its own isolated edit
    scoped to the comment/doc text, then re-runs `pnpm check` (it catches an edit that was not actually prose-only). On
    a clean check, record them under `Deferred fixed in-session` — a clean-check prose-only edit cannot be implicated in
    any Critical/High/Medium regression and stays listed as fixed regardless of how the next bullet resolves. If the
    check fails, the edit strayed beyond prose — treat the breakage as a regression through the Critical/High/Medium
    bullet below (routed to `Open items` if unrecovered, with no "fixed" label on a broken build). No further re-review
    cycle of its own.
  - Run all **other** new Nice-to-Have findings through sub-step 2's two-outcome procedure. Everything not prose-only
    lands `note-only` — including a `fix-now`-shaped nit, which is **not** re-fixed here (a single confirmatory pass,
    not a new fix loop) — recorded for `Deferred dropped` and **never** rendered in sub-step 6's group.
- If either re-review surfaces new **Critical/High/Medium** findings, first split them by **provenance** — per finding:
  - **Regression** — the finding implicates this sub-step's fix delta: the deferred-fix applications (direct or
    dispatched), plus the corrective-pass delta when the finding comes from the confirmatory re-review. Test: the
    finding would have been FALSE against the code as it stood when Step 4 assigned its verdict, and became true only
    because of fixes this sub-step applied.
  - **Pre-existing** — already true when Step 4's verdict was assigned; the re-review merely noticed it while looking at
    adjacent code (reviewer scope-widening — common for test-coverage and error-path gaps).
  - **Ambiguity resolves to regression.** Mis-calling a true regression "pre-existing" ships a break; mis-calling the
    other way merely reproduces the older, blocking behavior.
- **Pre-existing C/H/M findings never downgrade the verdict and are never fixed in this pass.** Fixing them re-arms the
  re-review cycle and breaks convergence — each fix invites a fresh re-review, which surfaces the next adjacent gap,
  unboundedly. Terminating over them is equally wrong: the main loop already converged without them, so they are
  discovered work, not a failed review. Route each directly into sub-step 6's "Suggested defer as issue" group as a
  **severity-carrying deferred item** — severity in the tag slot (`[MEDIUM]`), certified `specified` once its body
  clears the quality bar there (a draft below the bar is rewritten until it does, or routes `needs decision`; never
  filed unlabeled), so `/auto`-eligibility follows the bar, not the severity. Do NOT run them through sub-step 2:
  severity plus the membership definition's reachability test makes them ticket-worthy, a `fix-now` classification
  would re-enter the fix cycle, and `note-only` would silently drop a real risk. In auto mode they are filed by
  sub-step 6's `suggested` default; interactively the user can decline them (declined items land in `Deferred dropped`).
- If the **mandatory** re-review's split leaves any **regression** findings, make exactly **one** corrective pass:
  delegate to `developer` (sonnet-tier) to fix the regressions, then re-run `pnpm check`. Do **not** re-enter Step 5.
  - **Upgrade-on-success exception.** If the corrective pass produces a clean `pnpm check` AND the diff stays scoped to
    the regression area, an OPTIONAL single confirmatory `quality-verifier` re-review MAY be spawned (scoped to just the
    corrective-pass files). Compose its prompt inline — carrying the corrective-pass delta as an inline unified diff
    (snapshot token `corrective`) and the `Already tracked (do NOT re-flag, …)` line the template above carries, with
    its worsened-by-the-delta carve-out **re-scoped to the corrective-pass delta** ("unless the corrective-pass delta
    made one worse") rather than copied verbatim: a verbatim copy would leave an already-tracked item the corrective
    pass worsened silently suppressed and shipped under the restored verdict. Its findings route through the same lane
    bullets above — Nice-to-Have through the Nice-to-Have bullet, Critical/High/Medium through the provenance split —
    so every finding reaches a disposition. If no finding lands as a **regression**, **restore the verdict to
    `passed-after-fixes`** rather than terminating, and continue to sub-step 6 — routed-out pre-existing items and
    Nice-to-Have dispositions do not block the restore.
  - If the confirmatory re-review is skipped, or any of its findings lands as a **regression** (the single corrective
    pass is spent — there is no second), or the corrective `pnpm check` still fails, or any original regression remains
    unaddressed, terminate Step 6 immediately and populate the verdict block:
    - **Verdict:** `terminated-with-open-items` (overriding Step 4's).
    - **Deferred fixed in-session:** deferred items whose fixes are not implicated in the regression. If causation
      cannot be cleanly attributed (one delegation landed multiple fixes and the re-review surfaced regressions from
      "this delta"), list **none** of them as fixed and route every auto-applied item to `Open items` — readers should
      not see "fixed" labels on changes that broke the application. Clean-check prose-only fixes from the independent
      edits above are not swept in: they touch no code in the implicated delta and stay listed as fixed.
    - **Open items:** the surviving Critical/High/Medium regressions, **plus** the implicated deferred-item fixes,
      **plus** every not-yet-offered *fileable* item — sub-step 6's membership definition defines that set, and the
      whole set lands here regardless of which path routed each item into it, since the user never reached sub-step 6.
      `note-only` items are **not** swept here.
    - **Deferred dropped:** the `note-only` items, if any — from sub-step 2 or classified by the sub-step 5 re-reviews;
      their disposition was decided at classification. Skip sub-step 6.

## 6. Offer Linear issues for unfixed items

**Entry gate — skip sub-step 6 entirely if no *fileable* item remains.** Fileable items are exactly the members of the
"Suggested defer as issue" group — **membership is defined once, in the render rule below**. If none remain, skip the
prompt and emit the Output-section verdict block (the schema under `## Output`, not the template below). Skipping does
**not** exempt the auto-applied items from the verdict: they MUST still be listed under `Deferred fixed in-session:`,
and any `note-only` items — from sub-step 2 or the sub-step 5 re-reviews — under `Deferred dropped:`. This is the
common case: nothing fileable, no prompt.

Render the remaining unfixed items with the template below, then ask the question that follows. The render is REQUIRED
regardless of prompt mechanism — do not collapse to a single sentence; the user is context-switching across parallel
sessions and cannot scroll back to sub-step 3. Preserve sub-step 3's numbering: auto-applied `fix-now` items appear
under "Auto-fixed in-session (for context)" with their original numbers, and the severity-carrying items take the next
numbers in sequence.

**Membership definition — authoritative.** The "Suggested defer as issue" group's membership is defined HERE, once;
every other site — sub-step 3's pre-check, the entry gate above, the auto-mode paragraph, the filing inputs, and the
Open-items rescue — points here rather than restating it, so a future fileable class is added here and nowhere else.
Members: every **severity-carrying deferred item** — routed Critical/High/Medium findings from the sources the "second
input" note enumerates — rendered with severity in the tag slot (`[MEDIUM]`) **that passes the reachability test**: one
sentence naming the actor, the surface, and the input that produce the consequence in production, needing no
coincidence of independent conditions. Severity grades the *mechanism* — the reviewer is told to break things, and a
real mechanism earns Medium whether or not anyone can reach its consequence — so severity alone is not the gate. A
mechanism that is real in code but whose consequence needs a near-cap admin reason carrying hundreds of astral
characters, a superuser demo reset colliding with a rename to a seed label, or two tenants inviting the same brand-new
label inside a third session's 10s lock stall is not a member: it is `Deferred dropped`, recorded with its **re-open
trigger** exactly as gate 3 records a non-defect refinement. Audited against the code, a batch of filings from this lane
with severity as the only gate has been one real bug beside five unreachable mechanisms.

Never members: a severity-carrying item that fails the reachability test, Nice-to-Have findings of any origin (the lane
never files), prose-only findings (never fileable), and auto-applied `fix-now` items (already fixed). **Every member
renders INSIDE the one group**, in one continuous numbering run (if sub-step 3 numbered no items, number from 1) —
membership in that group is what makes the `suggested` reply and auto mode's default file them. There is **never** a
second fileable group. Omit a sub-group header entirely if empty; do not print "(none)".

**Every `<...>` token below is a substitution site** — replace each with the resolved value; never emit the literal
pipe-separated schema. The header line reads e.g. `Quality review verdict: passed-after-fixes (cycles: 3)`. This is the
canonical substitution rule other steps in this skill and `/start` point back to.

```text
Quality review verdict: <one of: passed-clean | passed-after-fixes>  (cycles: N)
Deferred items still unfixed after sub-step 5:

Auto-fixed in-session (for context, not actionable here):
  1. [Finding] — [file:line] — [tag]
  2. [Finding] — [file:line] — [tag]

Suggested defer as issue (recommended to file):
  3. [Finding] — [file:line] — [tag] — [rationale]
  4. [Finding] — [file:line] — [tag] — [rationale]
  5. [Finding] — [file:line] — [tag] — [rationale]
```

Every actionable item MUST include: finding text (verbatim from the reviewer, not paraphrased), `file:line`, tag, and
rationale. If the reviewer emitted no `file:line`, render `file:line: unknown` rather than omitting the field. Then ask:

> For which of the unfixed items should I create Linear issues? Reply with comma-separated numbers (e.g., `3, 4`),
> `suggested` to file the "Suggested defer as issue" group, `all`, or `none`. Unfixed items you do not select —
> including numbers omitted from a comma-list — become `Deferred dropped` in the verdict block, not silently re-added
> to any other category.

**Auto mode:** do not ask — still render the grouped list (it is the audit trail), then proceed as if the user replied
`suggested`. Filing the group's full membership keeps discovered work flowing back into Linear for later `/auto`
iterations without over-filing. If the state-name fallback would need to ask the user, file into the team's default
state instead and note the deviation in the verdict block — in an unattended run a re-statable issue beats a dropped
finding.

Reply semantics:

- `suggested` → file every item in the "Suggested defer as issue" group.
- `all` → identical to `suggested`; the safe default for a malformed reply.
- `none` → file nothing; remaining items become `Deferred dropped`.
- Numeric list → file the listed numbers verbatim, **excluding any that reference the "Auto-fixed in-session" group** —
  those are already fixed and sit outside the fileable group, so `suggested` skips them too; silently skip such numbers
  rather than filing a redundant issue.

File every chosen item per the core's Linear filing paragraph (`standards/linear-filing.md` and this skill's inputs to
it). **Every fileable item rendered at this prompt that the chosen reply did not select** goes to `Deferred dropped` —
explicit declines, numbers omitted from a numeric list, and the whole rendered fileable set under `none` alike — joined
by any `note-only` items from sub-step 2 or the sub-step 5 re-reviews, as one list for the verdict block. Two classes
route to `Open items` instead: items that never reached this prompt because Step 6 terminated early in sub-step 5, and
chosen items a create failure left unfiled.
