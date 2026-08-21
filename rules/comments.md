---
paths:
  - "**/*"
  - "**/.*"
  - "**/.*/**"
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

## Empirical claims: measure before you write

A comment asserting how something behaves — a tool's exit semantics, a platform
difference, a version-specific quirk — is the kind a reader trusts without
re-checking, and the kind this file most invites you to write. Run it on the
machine first. If you can't, write the narrower claim you did confirm.

**Deciding to leave a detail out is a claim too.** Omitting a concrete — an error
string, a command, a path — because you believe it varies rests on a belief about
behavior, and that belief needs the same measurement an assertion would. The
narrowing above is for a measurement genuinely out of reach, not a way past a
one-command check, and hedging is not free: the concrete is usually the one thing
the reader would have searched for. Measured: a build-failure note said "a
module-load env assertion" instead of naming the error string, on the unverified
premise that an earlier-imported database client's constructor would throw first
and change the message. That constructor defers its validation and does not throw,
so in the absent-config case the note was written for, the named string is exactly
what the operator gets — the hedge traded away their only search anchor to cover a
case that never arises.

**Measure the value production actually produces, not a plausible stand-in.**
Running *something* is not the bar — the input has to be the one the system
builds. Where a library or framework constructs the value, construct it the
same way (call the context builder, apply the scope, run the serializer)
instead of hand-typing a literal that looks right. A stand-in routinely omits
the property that made the real value interesting — a hand-written
`version: '25.5.0'` for an OS context whose real `version` is the whole kernel
banner — so the measurement confirms the claim you already believed. When that
same stand-in becomes the test fixture, the arm covering the claim passes
whether or not the code works.

Never cite a number that moves with ambient machine state (a file count, a
timing, a line count). It reads as evidence but reproduces nowhere else — state
the qualitative claim the reader can re-test instead.

The same applies to a **roster or count of code facts** — the callers of a
helper, the implementations of an interface, the sites sharing a shape.
Verifiability is what makes these tempting, and they rot on the next commit that
adds a caller — leaving a reader who spots one stale entry unable to tell whether
the comment's *argument* is stale too. Name the property that makes the set
interesting ("most of its callers add no guard of their own") rather than listing
its members, and let a grep produce the current membership.

The sharpest case is a comment calling code redundant, defensive, or kept for a
future refactor — it does not describe the line, it licenses deleting it. Prove
it first: remove the line, run the tests covering it, restore by file copy (never
`git restore`, and never `git stash` — the stash stack is shared across every
worktree of the repo; see `standards/git.md` § Safe Commands). Anything red means the claim is false; nothing red means check
the tests reach that line at all before you claim it.

**A claim about a family is falsified by the member the change skipped.** When a
change fixes some members of a set and a scope boundary leaves the rest alone,
the prose it writes routinely states the new property universally ("every reader
fails closed on this"). The excluded member was excluded for behaving
differently, which is what makes it the counterexample. Scope the claim to what
you changed, or name the exception — in a rule or doc sentence the change adds
as much as in a comment at the call site.

## Proportion: size to the reader, not the effort

Size a comment to what a reader needs **at that line**, not to the effort it
took you to discover it. A four-hop debugging chain is not four hops' worth of
comment — it's usually one sentence naming the single constraint the code can't
show.

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

**Measure characters, not bytes.** macOS's `/usr/bin/awk` counts bytes whatever
the locale, so the obvious `awk 'length > 160'` over-counts every multi-byte
character (+2 per em-dash) and flags prose already inside the limit. It never
misses a genuinely long line, so it is fine as a cheap first pass — but confirm
before rewording: `grep -n '.\{161,\}' <file>` counts characters.

## Scope: fixing comments while you're in the file

Bringing comments in a file up to this standard is **in-scope** for any
edit that touches the file. This rule is injected whenever you touch a
file, so pre-existing violations are visible to you — fixing them is the
intended response, not churn. Do not split these fixes into a separate PR.

Reviewers and orchestrators must NOT classify comment-proportion or
comment-formatting fixes as "scope creep," "unrelated changes," or
"churn outside scope," and must NOT instruct the developer to revert
them. The only exception is a comment fix in a file the change does not
otherwise touch — that one is genuinely unrelated.

**"Unrelated" licenses leaving it, never filing it.** A stale or wrong
comment you have already read and diagnosed is a fix you can make in the
same breath; routing it to a deferred issue spends a filing, a pick, a
worktree, and a review cycle to change a line of prose you were already
looking at. That is never the cheaper path, and the issue it creates
reads as real work to whoever picks it up. This binds hardest on the
audit surfaces — `/reflect sweep`, `/quality-review`, any review reading
files it is not otherwise editing — because the exception above appears
to cover them exactly when their context makes the fix trivial. Fix it
in place and note it in the report. Never open an issue whose entire
remedy is a comment edit.

## What NOT to write

- WHAT the code does — well-named identifiers already do that
- **Provenance decoration** — `"used by X"`, `"added for the Y flow"`, `"fixes #123"`,
  `"part of the Z refactor"`, `"# Review Finding 3: …"`, `"# BF-123 review finding 2 — …"`.
  Backward-looking, adds nothing a reader needs, and
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
