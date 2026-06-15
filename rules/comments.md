---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.mjs"
  - "**/*.cjs"
---

# Comments

## Default: no comments

Names, types, and tests document the WHAT. Don't restate it. A comment that
could disappear without confusing a future reader is a comment that shouldn't
exist.

## Add a comment when the WHY is non-obvious

- Hidden constraint or invariant
- Workaround for a specific bug or upstream quirk
- Behavior that would surprise a reader
- A choice between equally-valid alternatives where the rationale matters

## Proportion: size to the reader, not the effort

Size a comment to what a reader needs **at that line**, not to the effort it
took you to discover it. A four-hop debugging chain is not four hops' worth of
comment — it's usually one sentence naming the single constraint the code can't
show. The effort feels valuable to write because the mechanism is fresh in your
head; the reader pays for it on every pass.

Split what you're tempted to write into *facts the code already states* vs. *the
one fact it can't*, and keep only the latter:

- Already in another file / expression / locale string → **cut** — the reader can see it
- Recoverable from git / PR / Linear → **cut** — optionally leave a one-line pointer (see [What NOT to write](#what-not-to-write))
- The invisible constraint or invariant → **keep**

If the WHY genuinely needs a paragraph, it belongs in the PR or Linear issue,
with a one-line pointer in code. A 5-line comment on simple code *lies about
complexity* — it signals "danger here" over what is really one noted constraint.
Match the terseness of the code around it.

## New files get a header docblock about WHY they exist

When creating a new source file, add a brief docblock above the primary
export explaining why this file exists — what gap it fills, what alternative
was rejected, what edge case it covers. The "why does this code exist"
question is almost always non-obvious from inside the file, and lives nowhere
else unless captured here. PR descriptions rot; commit messages are out of
sight.

Editing an existing file does not require adding a header — only do so if the
file's purpose has materially changed and its absence has caused confusion.

## Line length

Wrap comments at ~160 characters, not ~80. Modern editors are wide; the
old 80-column convention produces stubby, multi-line comments that are
harder to read than one long line. Let the comment breathe — break only
when the line genuinely exceeds the soft limit, or at a natural sentence
boundary inside a long block.

## Scope: fixing comments while you're in the file

Bringing comments in a file up to this standard is **in-scope** for any
edit that touches the file. The PostToolUse comment-width hook flags
violations file-wide on every Edit — fixing them is the intended
response, not churn. Do not split these fixes into a separate PR.

Reviewers and orchestrators must NOT classify comment-width or
comment-formatting fixes as "scope creep," "unrelated changes," or
"churn outside scope," and must NOT instruct the developer to revert
them. The only exception is a comment fix in a file the change does not
otherwise touch — that one is genuinely unrelated.

## What NOT to write

- WHAT the code does — well-named identifiers already do that
- **Provenance decoration** — `"used by X"`, `"added for the Y flow"`, `"fixes #123"`,
  `"part of the Z refactor"`. Backward-looking, adds nothing a reader needs, and
  rots as the code moves. It belongs in the PR description or commit body.
- References to `tmp/` paths (investigations, screenshots, scratch notes) —
  `tmp/` is transient and regularly cleaned, so the link will dangle. If the
  WHY needs more than the comment can hold, capture it in a Linear issue or
  commit message body — don't point readers at a path that may not exist.
- Multi-paragraph docstrings on internal functions
- Comments to flag removed code (`// removed XYZ`) — git is the history

### The one exception: a durable pointer

On a regression-prone line whose full rationale won't fit, a forward anchor to a
*persistent* issue is fine — it points at retrievable rationale the code can't
show, e.g. `// PL-454: must stay a registered field or Link breaks after a partial submit failure`.

The distinction is **pointer vs. decoration**: a pointer to durable, retrievable
rationale (a Linear issue, an ADR) is allowed; provenance decoration ("added
for…", "fixes…") is not. As with `tmp/` paths, never anchor to something
transient — the target must outlive the code.
