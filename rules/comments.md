---
paths:
  - "**/*"
  - "**/.*"
  - "**/.*/**"
---

# Comments

**Default: none.** Names, types and tests document the WHAT. A comment that could disappear without confusing a future
reader shouldn't exist.

**Add one when the WHY is non-obvious:** a hidden constraint or invariant, a workaround for a specific bug or upstream
quirk, behavior that would surprise a reader, or a choice between equally valid alternatives where the rationale matters.

## Claims must be measured

- A comment asserting how something behaves (exit semantics, a platform difference, a version quirk) is trusted without
  re-checking, so run it on this machine first; if you can't, write the narrower claim you did confirm. Leaving a
  concrete out (an error string, a command, a path) because you believe it varies is also a claim and needs the same check.
- Measure the value the system actually produces, built the way the system builds it, not a hand-typed stand-in that
  omits the property that made the real value interesting.
- Never cite a number that moves with machine state (a file count, a timing); state the qualitative claim a reader can
  re-test. Likewise never list the members of a code fact (callers, implementations, sites sharing a shape): name the
  property that makes the set interesting and let a grep produce the membership.
- A comment calling code redundant, defensive or kept for later licenses deleting it. Prove it first: remove the line,
  run the tests that cover it, restore by file copy (never `git restore` or `git stash`; see `standards/git.md`), and
  check that the tests reach the line at all.
- A comment justifying a guard names a failure you have never seen. Check the triggering condition (the type that admits
  null, the caller that passes it), not the guard; where only runtime semantics decide, remove the guard, run what covers
  it, and record what actually broke.
- A claim about a family is falsified by the member the change skipped: scope the claim to what you changed, or name the
  exception.

## Proportion

Size a comment to what a reader needs at that line, not to the effort it took to discover it. Keep only the fact the
code can't state: anything visible in another file, expression or locale string is cut; anything recoverable from git,
the PR or Linear is cut, optionally leaving a one-line pointer. If the WHY needs a paragraph it belongs in the PR or
issue with a pointer in code. A long comment on simple code lies about complexity.

**New files** get a brief header docblock above the primary export saying why the file exists: the gap it fills, the
alternative rejected, the edge case it covers. Existing files don't get one retroactively unless the purpose materially
changed.

**Wrap at ~160 characters**, not 80. Measure characters, not bytes: macOS awk counts bytes, so confirm with
`grep -n '.\{161,\}' <file>`.

## Scope

Bringing comments in a file you are already editing up to this standard is in scope, never scope creep or churn;
reviewers and orchestrators must not ask for those fixes to be reverted or split out. The only genuinely unrelated case
is a file the change does not otherwise touch, and even then a stale comment you have already diagnosed is fixed in
place, not filed: never open an issue whose entire remedy is a comment edit.

## What not to write

- WHAT the code does.
- Provenance decoration: "used by X", "added for the Y flow", "fixes #123", "part of the Z refactor", "Review Finding
  3". It rots as code moves and belongs in the PR or commit body.
- References to `tmp/` paths; the reaper ages them out and the link dangles.
- Multi-paragraph docstrings on internal functions.
- Markers for removed code; git is the history.

**The one exception** is a durable pointer on a regression-prone line whose rationale won't fit:
`// PL-454: must stay a registered field or Link breaks after a partial submit failure`. A pointer to retrievable
rationale (a Linear issue, an ADR) is fine; decoration is not; never anchor to something transient.
