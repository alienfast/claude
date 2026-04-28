# Commenting

## Default: no comments

Names, types, and tests document the WHAT. Don't restate it. A comment that
could disappear without confusing a future reader is a comment that shouldn't
exist.

## Add a comment when the WHY is non-obvious

- Hidden constraint or invariant
- Workaround for a specific bug or upstream quirk
- Behavior that would surprise a reader
- A choice between equally-valid alternatives where the rationale matters

## New files get a header docblock about WHY they exist

When creating a new source file, add a brief docblock above the primary
export explaining why this file exists — what gap it fills, what alternative
was rejected, what edge case it covers. The "why does this code exist"
question is almost always non-obvious from inside the file, and lives nowhere
else unless captured here. PR descriptions rot; commit messages are out of
sight.

Editing an existing file does not require adding a header — only do so if the
file's purpose has materially changed and its absence has caused confusion.

## What NOT to write

- WHAT the code does — well-named identifiers already do that
- References to the current task, fix, or callers ("used by X", "added for
  the Y flow", "handles issue #123") — those belong in the PR description
  and rot as the codebase evolves
- Multi-paragraph docstrings on internal functions
- Comments to flag removed code (`// removed XYZ`) — git is the history
