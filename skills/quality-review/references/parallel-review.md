# Parallel reviewers

Step 3 reads this when the change spans several domains or is too large for one reviewer's context.

## Split by domain, in one message

For a large change spanning multiple domains, always spawn parallel reviewers scoped by domain in a single message (one
for backend, one for frontend, …). Reviews are independent and run simultaneously; consolidate findings before Step 4.

## Size each dispatch to the reviewer's context budget

A reviewer subagent starts at roughly 94k tokens of fixed overhead, and its working material — files read, diffs run —
is live context compaction cannot shed. Breadth is not the problem: chasing callers and boundaries file by file
accumulates slowly. Bulk ingestions — a branch-wide diff against a long-lived branch, a wholesale read of generated
artifacts — saturate it in one step, and a saturated reviewer does not fail loudly: it compacts, re-reads, and burns its
budget re-establishing state instead of reviewing. The template's incremental-ingestion bullet is the first defense;
when the change's own scope is too large for one context, split until each dispatch's share plausibly fits, and prefer
more, smaller reviewers over one saturated one.

## Parallel reviewers share one tree, and each is licensed to probe it

The probe clause every read-only dispatch carries (`worktree-hygiene.md`) tells the reviewer a temporary probe is
legitimate, restored by file copy — so between an agent's edit and its restore the tree is genuinely broken, and a
sibling running specs in that window sees real failures in files neither scope names. Every parallel read-only dispatch
therefore also carries: *"Other reviewers are working in this same worktree and may be transiently editing files to test
a claim. A red run, or a diff you did not write, may be a sibling's in-flight probe — re-run or re-read before you report
it, and do not assert who wrote it."* This narrows `standards/git.md`'s "treat anything you did not positively write as
another session's" without weakening it: that rule governs **disposition** — never revert, discard, or tidy away what
you did not write — and holds in full. What it must not license is an **attribution** in a report: say the tree was
transiently dirty and the cause was not attributable; never name a concurrent session. Where a clean signal matters
more than wall-clock, serialize the reviewers instead of warning them.

## Assign each dispatch its own probe path

The probe clause invites a file-copy backup under `tmp/`, and concurrent reviewers handed the same issue ID and the
same instructions choose the same obvious directory name — the first to finish deletes "the specific paths it created"
and the second finds its backups gone. Telling delegates to choose a unique name does not close it, since identical
inputs produce identical choices. Name the directory **in** each prompt: `tmp/qr-probe-<domain>/`, one per dispatch. A
collision is not a silent miss — the expected-dirty hash check catches an unrestored mutation as a hard stop — but the
work is lost: the restore path recovers `git show HEAD:<path>`, committed content only, so in a worktree whose change is
still uncommitted that file's edits go with the backup.

## Mutation testing: split by write license, not just by topic

Relax-a-clause-and-confirm-exactly-one-arm-reddens is the mandated method for any change carrying tests
(`agents/quality-reviewer.md`, "Reviewing test code: a green suite is not evidence"), so overlapping scopes mean
continuous, not incidental, mutation of the same files — and serializing turns the review step's wall-clock from the max
of the dispatches into their sum, on the one tier that runs at discovery pricing. Scope the dispatches so **no two
concurrent dispatches hold write license over the same files**. A domain split usually gives that for free; a
production/spec split does not, so name one owner. The owner may transiently mutate (restoring by file copy) and **owns
the falsifiability proofs for every spec arm in its files' blast radius, including the sibling's** — say so in its
dispatch. The other is told it may not edit those files and assesses arm strength by reading — *what else could make
this arm pass or fail? which single change would leave it green?* — a complement, never a substitute: reading cannot
distinguish an assertion that pins behavior from one that passes regardless, which is why the mutation obligation moves
to the owner rather than lapsing. (The simple tier is the one deliberate exception — its scoped review is read-based by
contract; `simple-tier.md` names the trade.) The transient-dirt warning is still carried by **both** dispatches — the
non-mutating sibling is the one most likely to meet a red run it did not cause. Where the dispatches also run tests
against a shared mutable resource (a test database, a fixture directory, a port), give each its own or let exactly one
run them; the project's own rules name the mechanism.
