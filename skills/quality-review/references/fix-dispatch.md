# The fix dispatch and the bounds on applying a remedy

Step 5 item 2 reads this when composing the first fix dispatch of a run. Every other `developer` site in the skill —
Step 2's gate fix, Step 6 sub-step 5's above-bound fix-now items and corrective pass — composes its prompt from this
template's shape and **drops the sweep-dependent bullets** (enum partition, class siblings, exit paths): the file-list
bound only item 2's dispatches carry is what makes a delegated sweep safe.

## The template

```md
Task for developer: Fix review findings for PL-13
Context: Quality reviewer identified the following issues.
Findings:
- [Finding 1]: [File:line] — [explanation]
- [Finding 2]: [File:line] — [explanation]
Requirements:
- Address each finding precisely — no unrelated changes
- When a finding involves classifying enum variants, error kinds, states, or cases into behavioral buckets (transient/terminal, retry/fail, etc.): enumerate EVERY variant from the defining source and classify each explicitly — never fix only the flagged variant(s) or write "etc.". Completing the partition is part of addressing the finding precisely, not an unrelated change; incomplete partitions are how the same defect resurfaces one variant at a time across re-review cycles.
- When a finding names one site of a class-shaped decision — the same predicate, guard, formatting rule, or authorization/scoping check reimplemented independently at more than one call site rather than at a single isolated site: fix EVERY sibling that lives in a file named in the `Findings` above, applying the same fix at each, and report the sites you covered. Do NOT edit a sibling outside those files — that is out of this loop's scope — and do NOT extract a new shared abstraction to deduplicate them, which is a refactor this loop does not undertake. Completing the class is part of addressing the finding precisely, not an unrelated change; patching only the named site is how one finding costs a re-review cycle per sibling.
- When a finding is that an EXIT PATH failed to carry or report something the function already knew — a `return` omitting a field the caller depends on, an early return skipping a stamp, a cleanup, or an audit write: enumerate EVERY `return` in that function and state, for each, whether the obligation applies to it and whether it is met; report that enumeration. Exits where the obligation genuinely does not apply (the value does not exist yet at that point) are part of the enumeration, not omissions from it. This stays inside the function named in the `Findings`, so it never reaches past the file-list bound. Completing the exits is part of addressing the finding precisely, not an unrelated change; fixing only the named exit is how one defect costs a re-review cycle per exit path, and the enumeration — not the fix — is what shows the class is closed.
- When a finding is addressed by adding or revising a **guard** — any predicate that halts, skips, fails, or flags rather than computing a value: enumerate in your report the input classes it will actually receive and its verdict for each — the triggering case, well-formed input, absent/empty input, malformed input (null elements, wrong container type), and input where the data the guard needs to decide is itself missing or unreadable. This is a reporting obligation, not licence to widen the fix. A guard specified only by its triggering case over-fires on a class nobody enumerated — which is how a fix becomes the next cycle's finding.
- Scope escape hatch: if resolving a finding requires restructuring beyond the findings listed above — a new abstraction, moving code across files, or edits outside the listed findings' files and their direct blast radius — STOP and report what the resolution needs instead of doing it. This does not relax the completion bullets above: completing any class they name, within the named files, is required precision rather than restructuring; the hatch covers only work those bullets already exclude. A stop-and-report is a successful outcome of this dispatch, not a failure.
- Hold the code THIS batch adds to the invariant the fix establishes — a widened rescue, a new guard, a closed fail-open path. The class bullet above sweeps pre-existing siblings; a helper you introduce on the fixed path is not one, so a batch that widens one rescue while writing a second, narrower one beside it re-opens the finding in its own new code. Before reporting, re-read what you added along the fixed path against that invariant.
- Do NOT annotate an edit with where it came from. `# Review Finding 3: …`, `# PL-13 review finding 2 — …`, `# Round 2 fix: …` is the provenance decoration `~/.claude/rules/comments.md` forbids — and so are the short labels THIS dispatch uses to name its findings (`F3`, `A1`, `HIGH-2`), in any form: `# F5: …`, `(PL-13 review, F1)`, a bare `(PL-13 review)`, or prose narrating a sibling finding (`since F4 widened …`). Those labels are cross-references between this dispatch and its re-review, never identifiers the code may cite; they rot as the code moves and tell a future reader nothing. This governs the WHY-header on a file the fix creates too: state the invariant the file pins, not the finding that asked for it. Keep a non-obvious WHY and drop the review citation; a forward pointer to a durable issue explaining an invariant (`# PL-13: must stay … or X breaks`) remains allowed.
- Verify with type checks or tests as appropriate
Acceptance: All listed findings resolved, no regressions — or a stop-and-report naming the restructuring a listed finding needs; for any class-shaped finding, the sites-covered report emitted; for any exit-path finding, the per-`return` enumeration emitted; for any added or revised guard, its input-class verdicts emitted — and state explicitly if no finding was class-shaped, exit-path-shaped, or guard-adding.
```

In `wt` mode the READ-SCOPING and WRITE-PLACEMENT blocks precede this body (`worktree-hygiene.md`).

## Routing a stop-and-report

The orchestrator decides, never the delegate: resolve the finding another way this cycle (a narrower fix within the
named files, or in-session), or — when the only real fix is the out-of-scope restructure — route it out of the loop as
a severity-carrying deferred item (item 5's deferred machinery), stating in the filing that the fix requires the
reported restructure. Never re-dispatch the same finding with instructions to "just do the restructure": an unreviewed
restructure absorbed mid-loop is scope the issue never asked for.

## Complete-the-class — one principle, four paths, each with its own bound

A finding that names one site of a duplicated decision is completed as a class, never patched site by site — and every
handling path carries its own discovery mechanism and its own bound, none borrowing another's:

1. **Item 2's substantive fix dispatches** — the delegate fixes every sibling in a file named in `Findings`, bounded by
   that file list, never beyond it. The sweep-dependent template bullets belong to these delegations alone.
2. **Item 4's re-reviews** — the dispatch names the shared decision and the directory/domain to search, so cross-file
   siblings surface as findings routed by item 5's lanes (`lanes.md`, the prose and mechanical class-completion sections).
3. **The prose lane** — the orchestrator sweeps the convention-defined sibling surface at fix time, bounded by the
   prose-only definition (`lanes.md` § Prose class completion).
4. **The mechanical lane** — the orchestrator completes in-scope siblings and defers beyond-scope ones, bounded by the
   change's resolved scope and the lane's own gates (`lanes.md` § Mechanical class completion).

The drains inherit (3) and (4) by routing their survivors through those lanes.

## A remedy clause names a scope the reviewer may not have read — enumerate before authorizing a deletion

The four paths above all *widen* a fix; nothing bounds one the finding's own phrasing authorized. Reviewers write what
they saw — "replace the constant + its two spec examples", "delete that describe block", "drop the helper and its
callers" — and relaying that phrasing into a `Findings` block turns an observation into an authorization: the delegate
deletes exactly what it was told to, and "no unrelated changes" cannot bound it because the instruction *is* the scope.
**A member count is not an enumeration**: the reviewer can count the group correctly and still have examined only the
member that motivated the finding. So when a remedy prescribes deleting a *group* rather than a named line, open the
group, name each member and what it pins, and dispatch the deletion by member name — dropping any member that turns out
to carry its own invariant. Enumerate *in addition to* the reviewer's wording; the finding text still relays verbatim.
Deletion-specific because of the asymmetry: a wrongly-added line reddens something, a deleted passing assertion reddens
nothing and `pnpm check` cannot see it — item 4's re-review over the fix delta is the backstop, and it costs the cycle it
catches it in.

## A remedy that names an EXTERNAL artifact is a claim about that artifact — open it before applying

This binds every route that applies a remedy — item 2's fix dispatches, the prose and mechanical lanes, and Step 6's
`fix-now` lane, where a comment-only remedy auto-applies with no prompt and, under sub-step 5's exemption, no re-review.
Reviewers routinely close a finding by pointing somewhere — "append `tracked in <ID>`", "defer to `<file>` §
`<section>`", "that is what `<helper>` is for" — and the pointer is the part they are least likely to have opened,
because the finding was found by reading the code the pointer leads *away* from. A citation that **resolves but does not
cover** reddens nothing anywhere: the gates that exist test existence (a compiler, a markdown-anchor check), never
whether the target says what the remedy claims, and `rules/comments.md`'s durable-pointer exception licenses such a
pointer on durability alone. So fetch the named artifact — `linear-cli issues get <ID>`, read the section, open the
helper — and confirm it covers what the remedy claims. When it does not, the finding may still be real while its remedy
is wrong: resolve it another way (file the issue that would own it; leave already-accurate prose alone) and record why
the prescribed pointer was not used.

## A wording finding earns a wording fix

When a finding names an ambiguity, an over-claim, or an imprecise scope — not a behavioral defect — fix the text and
stop, whichever route applies it (a fix dispatch, or the orchestrator directly via the prose lane). Do NOT specify the
behavior the ambiguous sentence happened to touch: if that behavior was already unspecified before this change, it is a
pre-existing gap — route it out via item 5's pre-existing lane as a severity-carrying deferred item and let the wording
fix close the finding (resolved, not deferred, so item 1's not-deferrable rule holds). Behavior specified in answer to a
wording finding is new reviewable surface, and the remaining cycles get spent on ground the issue never asked about. A
wording fix that itself survives review escalates per the prose ping-pong rule — a comprehensive rewrite of the
surrounding paragraph, still within this wording scope — never a second minimal patch.

## Before item 3, sweep the batch for the dispatch's own finding labels

Grep the dirty set (the file list the snapshot recipe derives) for whatever label scheme the `Findings:` block used plus
the issue-review forms — e.g. `grep -nE '\bF[1-9]\b|\bA[1-9]\b|<ISSUE-ID> review|review finding'` — and read each hit:
one that names a finding is the provenance decoration the template bullet forbids, which the orchestrator strips
directly (a comment-only deletion asserting no claim, so item 3's check covers it and the delta item 4 carries is
already clean); a same-shaped token that is not a label (a spreadsheet cell, a key name) stays. Nothing downstream
catches this — item 4's template puts comment audits out of the verifier's scope — and parallel dispatches handed the
bullet have still written `# F5: …`, `(<ID> review, F1)`, and `since F4 widened …` across many files, found only after
the re-review returned.
