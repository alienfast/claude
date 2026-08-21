# Testing Standards

How to construct a test that *can* fail. The protocol — revert the fix, confirm exactly that test goes red,
restore by file copy — belongs to [`agents/developer.md`](../agents/developer.md) (author side) and
[`agents/quality-reviewer.md`](../agents/quality-reviewer.md) (review side). This file owns the fixture.

## The fixture must contain the collapsing case

Distinct, non-overlapping values exercise the happy path of both the fixed and the broken implementation, so
the test passes either way. Include the case the fix exists for: the **same** id in both collections, not one
in each; input that nets to **empty**; a group where one item qualifies and a sibling does not; the boundary
value itself, not a value near it.

**Different records are not enough — they must straddle the predicate's boundary.** Where a predicate reads
one of several similar fields, or chooses A over B, the fixture pins *which* only if the candidates fall on
opposite sides of that predicate's crossing. Both halves fail in practice: a helper default or shared `let`
that makes A and B the same record, and genuinely divergent values that still sit on the same side — measured
2026-08-20, an `upsertProductStock` fixture set `available: 5, onHand: 8` and pinned nothing, because both sit
above the `<= 0 / > 0` crossing; repointing the crossing from one field to the other left the whole suite
green. Seed the rejected value as a different record that lands on the other side, and say why at the fixture.

Reading the test reveals none of this — every line is correct, and no linter is semantic enough to see it.
Measured 2026-08-19: a test named *still resolves a label after its order is removed from the batch* built its
map from a full batch, filtered a *local array*, then asserted against the map, so the helper under test never
saw a batch. Breaking the map's seeding left the entire 3998-test suite green.

## Three shapes stay green against their own mutation

- **A subset matcher cannot see a missing key.** `objectContaining`, `toMatchObject`, `arrayContaining` match
  a *subset*, so deleting the argument at the call site leaves the suite green — measured 2026-08-19,
  removing `settlementAckedReason` from a call pinned that way left 117/117 passing, and a refactor dropping
  it would have made every partly-settled invoice permanently unsendable. Assert the exact object.
- **A fixture that already satisfies the transformation exercises it as a no-op.** Same run: a test named
  *normalizes the acknowledgement key on both sides* exercised one side, because the stored task id was
  already the clean `'task-1'`; dropping the normalization from the *lookup* side left 98/98 passing.
  Construct the input so the untransformed value would fail the assertion.
- **A UI state-transition assertion must name a control unique to the destination.** Enumerate every view the
  component could be showing, not just the one it came from: a shared control proves nothing, and the absence
  of the origin's control is not enough when a third reachable view also lacks it. Where the destination has
  no unique control, assert the absence of every other reachable view's distinguishing one.

**Before moving on from any test, name the mutation it would catch. If you cannot name one, it is not
coverage.**
