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
that makes A and B the same record, and genuinely divergent values that still sit on the same side
(`available: 5, onHand: 8` against a `<= 0 / > 0` crossing pins nothing, and repointing the predicate from one
field to the other leaves the suite green). Seed the rejected value as a different record that lands on the other
side, and say why at the fixture.

Reading the test reveals none of this: every line is correct, and no linter is semantic enough to see it. A test
that builds its map from a full batch, filters a *local array*, then asserts against the map never shows the
helper under test a batch, and breaking the map's seeding leaves the whole suite green.

## Three shapes stay green against their own mutation

- **A subset matcher cannot see a missing key.** `objectContaining`, `toMatchObject`, `arrayContaining` match
  a *subset*, so deleting the argument at the call site leaves the suite green, and a refactor that drops a key
  pinned only that way ships. Assert the exact object.
- **A fixture that already satisfies the transformation exercises it as a no-op.** A test named *normalizes the
  key on both sides* exercises one side when the stored id is already clean, and dropping the normalization from
  the *lookup* side stays green. Construct the input so the untransformed value would fail the assertion.
- **A UI state-transition assertion must name a control unique to the destination.** Enumerate every view the
  component could be showing, not just the one it came from: a shared control proves nothing, and the absence
  of the origin's control is not enough when a third reachable view also lacks it. Where the destination has
  no unique control, assert the absence of every other reachable view's distinguishing one.

**Before moving on from any test, name the mutation it would catch. If you cannot name one, it is not
coverage.**
