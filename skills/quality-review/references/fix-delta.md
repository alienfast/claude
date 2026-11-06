# The fix delta: snapshot, diff, and hand-off

Step 5 item 2 reads this before the first snapshot of a run, and whenever a delta is passed by path. Step 6 sub-step 5
uses the same recipe with the `deferred` and `corrective` cycle tokens.

## Snapshot the dirty set before any fix lands

The working tree carries the implementation's own uncommitted changes, so a plain `git diff` cannot isolate what a
cycle's fixes changed. Before any fix of the cycle lands — dispatched or direct-applied, in any lane — take the
snapshot, and once the fixes are applied and checked, take the delta; both are `~/.claude/scripts/qr-fix-delta.sh`:

```bash
~/.claude/scripts/qr-fix-delta.sh snapshot <issue|no-issue> <cycle>                 # clears and refills the base dir
~/.claude/scripts/qr-fix-delta.sh delta    <issue|no-issue> <cycle> [--out <file>]  # the concatenated diff, a/ -> b/
~/.claude/scripts/qr-fix-delta.sh dirty    [-0]                                     # the derived dirty set
```

`<issue>` is the Linear id in any case, or the literal `no-issue` when Step 1 resolved none (the same scoping the
verdict artifacts use); `<cycle>` is the integer cycle, or `deferred` / `corrective` for Step 6 sub-step 5's batches.
The snapshot copies every dirty path outside `tmp/` (`git status --porcelain --untracked-files=all -- ':!tmp'`, renames
and spaced paths intact) and records deleted ones. The delta diffs every snapshotted path against its copy, dirty now
or not, so a reverted or deleted file shows; a path the snapshot never saw was clean when it was taken and diffs
against HEAD — the script names these on stderr as the fallback set, beside the file and line counts the 200-line rule
reads. An empty delta exits 0 and says so; `delta` with no snapshot exits 2 — take the snapshot, never replay an earlier
delta.

**Why a script, and why these rules live in it.** Both sets are derived, never hand-written: "each file a fix will
touch" is a prediction, and the complete-the-class and scope-escape-hatch rules make fixes land outside the findings'
named files routinely — a hand-written snapshot list and a hand-written fallback list have each omitted a file a
cycle-1 fix edited, producing a delta of the right length that described one file fewer than the cycle changed. The
base directory is issue-scoped and cleared on every snapshot: `tmp/` is reaped only by age (the daily `/reap-tmp` ages
a `qr-fix-base-*` snapshot out after a week) while every cycle token repeats across runs, and a stale base is worse
than a missing one because it **disarms the fallback** — a previous issue's copy is present, readable and diffable, so
a strayed file diffs against another issue's content and exits 0. The hand-typed form of this recipe
(`rm -rf … && for … in ${(f)"$(git status …)"}`) is a shape the Bash tool refuses — the rm safety check cannot parse
the `${(f)…}` flag, rm or not (`standards/shell.md` § Reserved names and expansion), and a worktree-isolated session
refuses any loop or `$(…)` — which is why it is a script and is never retyped. The expected-dirty hash step derives its
path set the same way: `qr-fix-delta.sh dirty -0 | xargs -0 shasum -a 256`.

Item 4's re-review and item 5's `Targeted fix confirmation` both carry this diff — a bare changed-file list makes the
verifier re-derive the delta from the whole tree, which is re-discovery pricing for verification work.

## Never replay a concatenated delta through `patch`

`patch` takes its target from each section's own `+++` header for every file after the one named on the command line:
`patch <one-file> < <the-delta>` applies section 1 to the named file, then resolves sections 2..N against the **working
tree**, finds them already applied, and reverse-applies them, exiting **0**. The
`Reversed (or previously applied) patch detected!  Assume -R? [y]` prompt self-answers because an agent session has no
controlling tty — **not** because stdin is the patch, so `-i <file>` is equally destructive. Files silently revert to
their pre-cycle state, taking a whole cycle's fixes with them, while `git status` still shows them ` M` (the
implementation's own changes are still there) and no `.rej` or `.orig` is written — nothing in the normal signal set
flags it.

To isolate a later cycle's delta, take that cycle's snapshot **before** its fixes land, as the recipe already requires;
never replay an earlier delta to recover a snapshot you skipped (`delta` refuses to run without one, and its HEAD
fallback covers only paths that were clean when one was taken). If you must apply a delta anyway, **split it per
file** and pass each section with an explicit target — the split is what protects, since `-o <output>` redirects only
the section whose target you named and leaves sections 2..N resolving from their headers into the working tree — and
add `-N`/`--forward`, which refuses a reverse-apply, leaves the tree intact, and exits 1 with `.rej` files instead of
silently succeeding.

## Passing a large delta by path — above 200 lines only

Inlining is mandatory for any concatenated delta of **200 lines or fewer**: it cannot go stale, cannot go missing, and
at that size costs nothing worth saving. Above 200 lines the orchestrator re-emitting the whole diff verbatim becomes
its own fidelity risk — one elided or truncated hunk means the verifier confirms less than the delta while reporting it
confirmed, the failure this rule exists to prevent. So above that bound:

- Write the concatenated delta with `delta <issue> <cycle> --out tmp/qr-fix-delta-<issue-id-lowercased>-<cycle>.diff`,
  the whole token matching the snapshot directory's (`no-issue` substitution and the `deferred`/`corrective` tokens
  included); the script overwrites, so an imported `NO_CLOBBER` cannot leave a previous run's file in place.
- Pass the **absolute** path in the `Fix delta` slot of whichever template is in use, re-labeled
  `Fix delta (precomputed unified diff — read this file; do NOT re-derive)`, stating the line count so the choice is
  auditable.
- The dispatch says, in as many words: read that file first as the authoritative delta; do NOT re-derive it from
  `git diff` over the tree, because the working tree still carries the implementation's own uncommitted changes and a
  plain `git diff` would mix pre-fix hunks in; and if the file is missing, empty, or unreadable, **STOP and report
  that** rather than falling back to anything — a verifier that silently re-derives is the original failure mode, and
  one that silently verifies an earlier cycle's stale file is worse.
- The STOP condition structurally cannot catch a cross-issue stale file — a previous issue's delta is present,
  non-empty, and readable — so the template's `Changed files:` line is the staleness cross-check, and it is only sound
  when its two sides have independent sources. Populate it from the fixes' own footprint — the `developer` dispatches'
  reported changed paths plus the orchestrator's direct edits — never from the delta file, which is what it exists to
  check (a cross-check derived from what it checks can never fire), and tell the verifier to confirm the file covers
  exactly that list and to report a mismatch instead of proceeding. That independence is the only reason a delta
  omission has ever surfaced: `pnpm check` was green, and the expected-dirty path-set and hash checks both saw the
  omitted file as correctly dirty and unchanged.

What the inline rule protects is that the verifier gets the exact fix delta rather than re-discovering it from a dirty
tree; a precomputed file under these conditions satisfies that, a bare changed-file list does not.
