# Testing Standards

How to construct a test that *can* fail. The protocol rules — revert, confirm red, restore — live in
[`agents/developer.md`](../agents/developer.md) § Testing Standards (author side) and
[`agents/quality-reviewer.md`](../agents/quality-reviewer.md) § *Reviewing test code: a green suite is not
evidence* (review side). This file owns what neither covers: choosing a **fixture** that discriminates, and
the shapes that stay green against the very mutation they exist to catch.

## A regression test must be falsifiable — prove it, don't assume it

Before reporting a fix complete, revert it, confirm that specific test goes red, and restore the file **by
file copy** — never `git checkout --` / `git restore`, which are hook-blocked and multi-session-unsafe
([git.md](git.md) § "To undo a temporary edit"). A test that passes against the un-fixed code proves nothing
and is worse than no test: it converts an open defect into a closed one.

**The discipline as usually practised covers fix deltas, not the implementation the fixes are applied to.**
Measured on JA-320: every fix dispatch required revert → confirm red → restore and every delegate complied,
yet the original implementation's own test was never mutation-checked. That test was named `still resolves a
label after its order is removed from the batch` — an accurate description of the requirement — and it was a
tautology: it built the map from a full batch, filtered a *local array*, then asserted against the map, so
the helper under test never saw a batch at all. Breaking the map's seeding so it rebuilt from the shrinking
batch on every render left the entire 3998-test suite green. Reading the test gave no signal; a reviewer
scanning test names would have approved it.

## Choose the degenerate shape, not a neighbouring one

The fixture must contain the *collapsing* case the fix exists for. A fixture built from distinct,
non-overlapping values exercises the happy path of both the fixed and the broken implementation, so it passes
either way — the single most common reason a falsifiable-looking test turns out not to be.

| Fix concerns | Fixture must include |
| --- | --- |
| An element appearing in two collections | The **same** id in both — not one id in each |
| A filter that can empty a list | Input that nets to **empty**, exercising the empty/null return |
| A per-item rule on a group | A group where **one** item qualifies and a sibling does not |
| An off-by-one boundary | The boundary value itself, not a value near it |

**Different values are not enough when the predicate has a decision boundary.** Where a predicate reads one
of several similar fields on the same object, a fixture pins *which* field only if the candidates fall on
**opposite sides of that predicate's boundary**. Measured on JA-349: an `upsertProductStock` fixture set
`available: 5, onHand: 8` — genuinely divergent values — and pinned nothing, because both sit above the
predicate's `<= 0 / > 0` crossing. Repointing the crossing from one field to the other left the whole suite
green. The intuitive rule ("give the fields different values") is wrong; the rule is about the boundary.

## Two shapes stay green against their own mutation, and both read as correct

Neither needs a revert to spot — they are read-time tells:

- **A subset matcher cannot see a missing key.** `expect.objectContaining`, `toMatchObject`, and
  `arrayContaining` match a *subset*, so deleting the argument at the call site leaves the suite green.
  Measured on JA-343: removing `settlementAckedReason` from a call the test pinned with `objectContaining`
  left 117/117 passing — and had a refactor dropped it, every partly-settled invoice would have become
  permanently unsendable. Assert the exact object when the point is to pin a specific argument.
- **A fixture that already satisfies the transformation under test exercises it as a no-op.** A
  normalization case whose stored value is already clean proves nothing about the normalizer. Same issue: a
  test named *"normalizes the acknowledgement key on both sides"* exercised one side, because the fixture's
  stored task id was already the clean `'task-1'` — dropping the normalization from the *lookup* side left
  98/98 passing. Construct the input so the untransformed value would fail the assertion.

**Before moving on from any test, name the mutation it would catch. If you cannot name one, it is not
coverage.**

## Assert the requirement, not that the code ran

A test guarding a layout, an ordering, a count, or a rendered string must assert that property. Asserting
only that the call returned, the file parsed, or no error was thrown passes while the requirement is
violated. Measured on JA-305: a test written to prove a PDF width budget asserted only the `%PDF-` magic
bytes, so it passed while rendering two lines — the exact failure it existed to catch.

## One mutation is not proof

Where several wrong implementations reach the same output, reverting the behavior an assertion names is the
first mutation, not the only one. The review-side treatment of this — enumerating the plausible wrong
implementations and reddening the arm for each — is in
[`agents/quality-reviewer.md`](../agents/quality-reviewer.md); it applies equally when authoring.
