# The prose and mechanical lanes in full

Step 5 item 5 reads this before the first prose-lane or mechanical-lane fix of a run. The lane *definitions* and the
routing bullets are in the core; this file carries each lane's completion, second-attempt, and re-route rules and the
mechanical lane's confirmation template.

## Prose lane: when the prose IS the deliverable, confirm it

When the change under review's own deliverable is prose — an issue whose success criteria demand a *recorded*
decision, rationale, or invariant ("record the reason at `<call site>`", an ADR, a documented contract), or a
doc/config-only change such as a `keeper`-labeled `/reflect` filing whose diff is entirely rule/standard/skill text — a
finding that the recorded claim is false, unqualified, or misleading is a defect **of the change**, not a comment nit.
The lane still applies unchanged (not loop fuel, not counted in `Cycles:`) — promoting it to substantive would make the
lane a no-op on doc-only changes and restore the per-nit grind it exists to end. What changes is verification:
`pnpm check` cannot evaluate a factual claim, so the fix additionally rides a `Targeted fix confirmation` (the
mechanical lane's dispatch, never a review cycle), **required wherever this lane drains with no re-review to follow it**
— the convergence drain, the ceiling's lane drain, any batch item 4's all-prose/mechanical exemption converges without a
re-review, and Step 6 sub-step 5's exempt deferred batch. Nowhere else: the snapshot recipe captures direct-applied
edits in any lane, so a fixing-phase prose fix in a batch carrying substantive fixes already reaches item 4's re-review
in that cycle's delta. A correction to a load-bearing rationale routinely asserts *new* factual claims of its own —
exactly what a verifier exists to check — and the non-gating treatment would otherwise converge the loop with no one
ever having read them.

**Read the trigger narrowly: the change's own deliverable being prose, never the fix batch happening to be prose.** A
code change whose cycle-N fixes edit only comments and doc-strings drains at convergence with no confirmation — the
exemption working as designed; the orchestrator's own measurement discipline (`rules/comments.md`) covers any empirical
claims those comments carry. A code change has spent a quarter of its review phase on a confirmation whose trigger its
deliverable did not meet.

**The confirmation is bounded, and a pure deletion needs none.** A flagged problem re-enters the prose lane by the
re-route rules, which at the *convergence* drain would otherwise buy another confirmation, and another — a prose
re-route is never loop fuel and a `Targeted fix confirmation` is never a review cycle, so nothing counts and nothing
terminates. So: one corrective round (the ping-pong paragraph rewrite), re-confirmed once; still flagged after that,
converge and record the surviving flag under `Deferred dropped` with its rationale. That is the one exception to
Termination's "every mechanical confirmation has returned clean" gate, and it is narrow by construction — it reaches
only a prose-only problem that has already spent its rewrite and its re-confirmation, on a lane that is never loop fuel
and never fileable. Skip the confirmation entirely for a corrective edit that only **removes** text and removes no claim
with it — a provenance anchor or byline, a verbatim duplicate of adjacent text, a cross-reference to something that does
not exist: the carve-out exists because a correction asserts *new* claims, and such a deletion asserts none. Deleting a
qualifier, an exception, or a scope clause is not that — it silently widens what the surrounding text governs, a new
claim by omission that owes the confirmation. A corrective edit that **deletes the claim the confirmation named as
false**, adding nothing in its place, likewise needs none. Prefer it to a replacement whenever the bound is spent:
shipping wording the confirmation handed back is shipping an unchecked new factual claim, and a run that has already
produced two confident-but-false corrections is the worst place to trust a third. Where the surrounding rule requires a
claim to be present at that site, the honest outcome is the surviving flag under `Deferred dropped`, not a replacement
no one has verified.

## Prose ping-pong — a surviving prose fix earns a paragraph rewrite, never a second qualifier

When a later verifier pass — a re-review or a `Targeted fix confirmation` — flags prose this run already fixed once (the
corrected sentence still ambiguous, the qualifier still wrong, a new defect in the fix's own wording), do not patch it
minimally again. Rewrite the surrounding paragraph comprehensively so the whole thought reads clearly and consistently,
instead of threading one more qualifier into a sentence that has already failed review — qualifier-stacking is how one
sentence eats three dispatches. The rewrite stays inside the **wording scope** `fix-dispatch.md` § A wording finding
earns a wording fix sets for the first attempt: comprehensive at paragraph scale, but still restating only what the
text already governs, never specifying previously-unspecified behavior, with the same pre-existing-gap routing. First
attempt minimal and wording-only, second attempt paragraph-comprehensive, both inside wording scope — what burns cycles
is new surface, not minimal patching, and neither attempt is licensed to create it. Applies wherever the prose lane
drains: the fixing phase, the convergence drain, and the ceiling's lane drain alike.

## Prose class completion — sweep the sibling surface in the same pass

Doc/rule prose duplicates by convention — the same cross-reference repeated across `standards/*.md`, the same claim
restated in several rule docs or sibling skills — so a prose finding is often one visible site of a class, and in a
prose-heavy repo (`~/.claude` is almost entirely instruction text) that is the dominant shape. When the prose defect is
class-shaped — a stale claim, wrong cross-reference, or contradiction that convention duplicates — do not stop at the
named site: before applying the fix, grep the convention-defined sibling surface for the duplicated text
(`standards/*.md`, `rules/*.md`, sibling `skills/*/SKILL.md` — whichever family the named file belongs to) and apply the
same correction at every instance, in the same direct-apply pass. **Sweep by token, not by file family — the edited
file included.** Those globs are `~/.claude` doc families and reach no source file, so a wrong docblock in
`apps/…/Foo.tsx` has no enumerated surface at all; grep the claim's *distinctive token* (a header name, a symbol, an
option) across the repo's source roots instead, and count a same-file duplicate as class-shaped even though it does not
"duplicate across sibling files". That is the commonest shape and the cheapest to miss: a stale claim's nearest sibling
is usually a few lines below, in the code consuming the value, where the use-site comment restates it. This is the
prose lane's member of the complete-the-class family, with its own bound in place of theirs: `fix-dispatch.md`'s sweep
is bounded by the `Findings` file list and backed by a `pnpm check` that can fail, while here the bound is the
**prose-only definition itself** — every swept edit touches only comments, doc-strings, or standalone doc/rule text,
enforced by the orchestrator at edit time, because prose edits pass `pnpm check` by construction and the check can bound
nothing. Swept sibling fixes are part of the same prose-lane pass: covered by the same isolated `pnpm check`, never loop
fuel, never re-review-mandating, adding nothing to the cycle count, and listed with the named site under
`Findings resolved` (sites covered, mirroring the fix dispatch's report). Applies wherever the prose lane drains.

## Mechanical class completion — complete in scope, defer beyond it

The mechanical lane classifies by the fix, so a class-shaped finding can land here legitimately — most often when its
siblings live in the named file itself, which passes the localization gate intact. Before dispatching the confirmation,
complete the class, split by where the siblings live: **(a) in scope** — siblings in the named file or in files inside
the change under review's resolved scope (Step 1) are completed in the same direct-apply pass; each site is the same
choice-free fix, each is listed per item in the confirmation's `Fixes` and `Class sweep` lines, and the whole set rides
the confirmation's inline diff, so no swept edit lands unverified; **(b) beyond scope** — grep the shared decision across
its domain (the same named-decision-and-domain form the re-review sweep uses) and route every instance in files the
change never touched to the pre-existing lane as a **severity-carrying deferred item** carrying the class finding's
severity — surfaced, never edited, because that is exactly what it is: a pre-existing instance of the defect in code
outside this loop's scope. Editing it here would be the scope expansion the fix dispatch's sweep boundary exists to
prevent; leaving it unmentioned is the silent-sibling gap this rule exists to close. The lane's gates still govern the
completed fix as a whole: if completing the in-scope class blows the size bound or introduces a choice between
alternatives, the finding was never mechanical — doubt resolves to substantive (in a drain, that lands on Termination's
dirty-drain withdrawal path). Applies wherever the mechanical lane runs: the fixing phase, the convergence drain, and
the ceiling's lane drain alike — the drains are the most exposed paths, running after the last re-review, where nothing
downstream would ever surface a missed sibling.

## The targeted fix confirmation

After the orchestrator applies a mechanical fix directly and runs `pnpm check` plus the targeted specs, it dispatches
exactly one confirmation to `quality-verifier`:

```md
Task for quality-verifier: Targeted fix confirmation for PL-13
Context: Mechanical fixes for the findings below were just applied. Confirm each fix resolves its finding and introduces nothing new in the touched lines. This is a confirmation pass, not a review — do not widen scope.
Fixes: [finding → fix applied, per item]
Class sweep: [only when a finding was class-shaped: the shared decision, the domain searched, the in-scope sites completed, and each beyond-scope sibling routed to a deferred filing — omit this line entirely otherwise]
Changed files: [list]
Fix delta (inline unified diff, captured per the snapshot recipe):
[the concatenated per-file diffs]
Already tracked (do NOT re-flag, unless one of the fixes above made one worse — a latent gap turned reachable, a narrow case turned general — which is a new fix regression to report at its real severity): [each finding already filed as a Linear issue — its issue ID and a one-line summary — and each finding already routed to a deferred filing but not yet filed, with its planned disposition; omit this line entirely if there are none]
Acceptance: Per fix: confirmed, or a concrete scenario where it fails plus a severity (Critical/High/Medium) for the problem you are flagging.
```

Its response is judged against that Acceptance, never against the Required findings format (`error-handling.md`).

## Confirmation re-route — a flagged problem does not close its finding

- **Re-route from the top.** The flagged problem re-enters item 5's lane split as its own classification — never
  promoted straight to substantive: a prose-only problem (a doc-string on a touched line left contradicting the new
  symbol) goes to the prose lane; a gap plainly pre-existing beyond the change routes out as a severity-carrying
  deferred item; everything else is substantive (loop fuel). At the soft ceiling's lane drain the loop cannot re-arm —
  the ceiling's **one-round bound** governs there instead (`soft-ceiling.md`).
- **The original finding closes on disposition, not on the flag.** It closes when the re-routed problem is
  dispositioned — that lane's fix landing with a clean check, or the deferred item being filed or dropped — and is then
  listed under `Findings resolved` like any other fixed finding. If the run terminates first, it goes to `Open items`
  alongside the flagged problem.
- **Severity is inherited upward.** The re-entrant carries the severity of the finding whose fix was being confirmed,
  unless the confirmation named a higher one — then the higher. Settle it before the re-route: the pre-existing lane
  renders it in the tag slot and the ceiling gate branches on it.
- **The mechanical lane is a one-way door.** A fix whose confirmation flagged a problem is not directly checkable any
  more, so it never re-enters the mechanical lane — the doubt-resolves-to-substantive rule closes the door, and there is
  no fix-and-confirm ping-pong. A `Targeted fix confirmation` dispatch is **not a review cycle** and is never counted as
  one.
- **Mixed-lane batches order by lane.** When a re-review's findings span lanes: the prose ones land first as their own
  isolated direct edits, the mechanical ones are direct-applied alongside that cycle's fix batch, and the substantive
  ones drive the normal cycle — the lanes change what re-arms the loop, not which cycle fixes land in.
