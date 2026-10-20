# Simple tier

Step 3 reads this when the `simple` token is present — typed, or forwarded by `/start` when the issue carries the
`simple` label (`standards/issue-spec.md` § The `simple` label). One `quality-verifier` *scoped review* replaces
`quality-reviewer` discovery, Step 5 caps the loop at two review cycles, and four guards escalate fail-closed to the full
tier. A typed token is a request, never an exemption from the guards. Compatible with `auto`.

## The four guards

The first two run before anything is dispatched, the third is the verifier's own answer, the fourth is Step 5's cap.

1. **Reviewability ceiling.** Size the resolved scope: `git diff --stat <merge-base-sha>...HEAD` plus the working
   tree's tracked changes, **plus every untracked file's full line count** (`wc -l` — an untracked file is in Step 1's
   scope but contributes zero lines to `git diff`, so a change made of new files would otherwise measure as empty),
   excluding generated artifacts (`src/generated/*`, schema dumps, lockfiles). More than ~8 files or ~300 lines means
   one verifier cannot hold it without the full tier's domain split — escalate without dispatching.
2. **A forbidden co-label.** The issue carries `security`, `human`, `needs decision`, or `epic` — the labels the
   standard says `simple` is never on. `/start` forwards the token without adjudicating co-labels, so this is the one
   place they are read.
3. **The verifier's `ESCALATE:` answer** — its own read of the delta against the risk test, in the template below.
4. **A Critical or High finding on the change at any cycle, or any fix regression or unsound closure at cycle 2, at any
   severity.** A Critical on first read falsifies the risk-low classification whatever a fix could do about it; item 5
   makes regressions loop fuel at every cycle, and this tier has no cycle 3. A spec arm the cycle-1 fix left vacuous is
   such a regression — the scoped review grades a vacuous arm Medium, below the full tier's High, because read-based
   evidence is weaker, and escalation restores the full tier's treatment.

The tier's accepted residual: a mislabel the verifier's risk read does not recognize and that surfaces no Critical/High
ships with verifier-only review. The label's semantics, the ceiling, and `/auto-prep`'s re-audit bound it. The
mutation-testing obligation lapses by the same trade — the scoped review is read-based by contract, and item (d) in the
template is the read-based complement — because a vacuous arm on a risk-low change leaves behavior unpinned, not broken,
and `pnpm check` plus the falsifiability check bound what remains.

## Dispatch

Exactly **one** `quality-verifier`, in place of Step 3's `quality-reviewer` template — never both, never parallel
domain-split verifiers (a scope that needs splitting fails guard 1). Inline the change delta as a unified diff, or,
above 200 lines, write it with `>|` to `<repo-root>/tmp/qr-simple-delta-<issue-lower|no-issue>.diff` and pass that
**absolute** path, re-labeling the slot `Change delta (precomputed unified diff — read this file; do NOT re-derive)`
with the line count stated and the STOP-on-missing instruction carried — every clause of `fix-delta.md` § Passing a
large delta by path applies unchanged.

```md
Task for quality-verifier: Scoped review (simple tier) for PL-13
Context: Implementation of [issue title or one-line summary] is complete. The issue is labeled or requested `simple` — risk-low, no open decision. This is a scoped review of the WHOLE change: not a verification of prior findings (there are none), and not discovery. Prove the change does what the issue asks and breaks nothing in its blast radius.
Issue requirements: [Paste requirement and success-criteria checkboxes — omit this line entirely if no issue was resolved in Step 1]
Files: [every file in the resolved scope from Step 1]
Change delta (inline unified diff, or the path of the precomputed diff file):
[the diff]
In scope: (a) each requirement and success criterion actually satisfied — not approximately; (b) regressions in the change's blast radius — callers, callees, and shared state of every changed line; (c) conformance of the touched lines to user-level and project-level conventions; (d) for every new or changed spec arm, name the single production change that would leave it green — an arm you cannot name one for is vacuous; report it at Medium. Read-based only: do not mutate the tree.
Out of scope: modalities beyond (a)–(d) — no first-ever mutation sweeps, comment-accuracy audits, spec-pinning passes over unchanged code, or class sweeps beyond the changed lines. A real issue outside the delta goes in its severity section flagged `[out-of-delta]`.
ESCALATE first: before reviewing, read the delta against the simple tier's risk test (standards/issue-spec.md § The `simple` label). If it touches an authorization/policy predicate or gate, tenant or viewer scoping, money-movement/ledger/KYC state, a lock or transaction boundary, a public contract other callers depend on, or a data migration beyond an additive index/constraint — or the change turns on a decision the issue does not prescribe — answer with a single line `ESCALATE: <reason>` and nothing else.
Acceptance: Either that single `ESCALATE:` line, or exactly the Required findings format — `## Review Findings` and the five `### <severity>` subheadings in order, no other structure.
```

## Escalating — one recipe for every guard

Name the trigger in chat. When Step 1 resolved an issue ID and the issue carries the `simple` label, remove it and
record why, so the next pickup runs the full tier from the start instead of repeating the mismatch:
`~/.claude/scripts/linear-remove-label.sh <ISSUE-ID> simple`, then write one line
(`simple tier escalated at /quality-review: <trigger>`) to `<repo-root>/tmp/simple-escalation-<issue-lower>.md` (an
absolute path) and post it with `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> <that absolute path>`. Bookkeeping
never blocks the escalation: a failing remove or post is annotated in the tier note (`label not removed: <first stderr
line>`) and the run proceeds; a token-only request has nothing to remove; with no issue ID resolved (the scope-mismatch
guard, an unauthenticated auto run) the label cannot be touched — say so in chat and in the tier note, since the next
pickup repeats the mismatch until a human or `/auto-prep` clears it.

Then dispatch Step 3's `quality-reviewer` template as the next review cycle, **adding** two lines it does not natively
carry: `Previous findings addressed:` naming what the simple-tier cycles already fixed, and the `Already tracked (do NOT
re-flag, …)` line from Step 5 item 4's template whenever anything has been filed or routed this run (Step 1's
carry-forward rule). From that dispatch on the run is the full tier for everything below, and for the soft ceiling that
dispatch is cycle 1: the full tier gets its own five cycles counted from the escalation, while the verdict's `Cycles:`
counts every review-cycle dispatch of the run, simple-tier ones included, and the tier note says so.

An `ESCALATE:` answer is not a completed review cycle for `Cycles:` — nothing was reviewed — and it wins wherever it
appears: a line matching `^ESCALATE:` anywhere in the scoped review's response (alone, as preamble, or as an appendix
after a findings block) is the escalation, the rest of the response is discarded, and the Error Handling
malformed-output criteria never apply to it. A well-formed findings block with no such line IS cycle 1 and proceeds to
Step 4 like any other review; its `[out-of-delta]` findings in files the change touches follow Step 5 item 1 (fixed),
and those in files it does not touch route out as severity-carrying deferred items per item 5's pre-existing bullet —
never as escalation triggers, since they are not findings on the change.

## Step 5 cap — two review cycles, then the full tier

The scoped review is cycle 1 and item 4's re-review is cycle 2, grounded in dispatch history exactly as
`soft-ceiling.md` requires (a scoped-review dispatch counts; an `ESCALATE:` answer and `Targeted fix confirmation`
dispatches do not). Guard 4 fires per its definition above; on the trigger, escalate by the recipe. Everything else at
cycle 2 takes item 5's routes: a new Medium of the change is filed as a severity-carrying deferred item (noting it is a
defect of this change, as the narrowed-fuel route prescribes — this tier files at cycle 2 what the full tier files from
cycle 3), a pre-existing gap routes out, prose and mechanical findings drain in their lanes, and a re-review with nothing
substantive converges normally.

## The tier note in the verdict block

Append `Review tier: simple (quality-verifier scoped review; N cycles)` — or
`Review tier: simple → escalated at <trigger> (cycle N of M)` when a guard fired, with `pre-dispatch` in place of
`cycle N` when guard 1 or 2 fired or the `ESCALATE:` answer arrived before any cycle completed, plus any
`label not removed:` annotation — as the first line of the Output block's trailing process-notes paragraph: a blank line
after `Open items:`, never the line directly below it, which `/finish` Step 8 may read as a continuation of that field.
Consumers ignore it today; `fleet-metrics.py`'s impl-vs-fix developer-lane split keys on the first `quality-reviewer`
dispatch, so a simple run that never escalates reads its fix batches as `impl` until that script learns the note.
