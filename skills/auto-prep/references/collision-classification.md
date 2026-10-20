# Collision classification — which mentions become `blocks` edges

Read this while confirming the candidate pairs `auto-prep-pool.sh --collisions` emits (`/auto-prep` Step 3). The script
does the extraction; this is the judgment it cannot make. The cost is asymmetric and silent: a false edge hides a
workable issue from every ranking until its supposed blocker ships, with no trailing note reporting it, while a missed
edge costs at most one merge conflict resolved in-session. Every rule below leans toward fewer edges.

## A named file is not an edited file

Descriptions cite paths for three reasons that are not collisions: as **precedent** ("the sibling half of this flow
already locks — `email_verification.rb:11`"), as **explanation** of blast radius ("`useQuery.tsx` rethrows to the error
boundary, so one missing row kills the page"), and as a **pattern to follow** ("following `spec/lib/bullet_spec.rb`'s
`around`-block pattern").

The discriminator is which *section* the mention sits in, never how precise it is. Success Criteria / Requirements
checkboxes and In Scope entries are what the issue will edit — `/start` takes the checkboxes as its requirements, and
[standards/issue-spec.md](../../../standards/issue-spec.md)'s quality bar bans implementation-planning file lists from
specs, with one exception: a spec whose *work* is site enumeration, where the census is the requirement and is written as
greppable shapes anchored to a commit. A path that survives certification inside a criterion names the work target.
Prose in Problem, Notes, or a Boundaries rationale is a citation.

Line numbers prove the author read the code, not that they will change it: `tenant.rb:72-77` quoted in a Problem to
explain a symptom is a citation; a criterion naming a bare `debt_series/create.rb` is an edit.

Keep a pair only where **both** sides edit. One-sided contact is not a collision — at most a `related` link when the
mechanism is genuinely shared.

## Paths are the weak signal; subjects are the strong one

The same certification bar that makes a surviving path trustworthy makes it rare: a well-groomed pool names its work
target as a *symbol* in prose (a class, policy, operation, mutation, component) far more often than as a path, and the
real collisions in a pool routinely share no literal path string in either description. So extract the CamelCase and
namespaced identifiers from each issue's title and criteria, resolve each to the file(s) on disk (`find`/`grep`), and
build the overlap groups on the *resolved* paths, running the path pass second. Resolution is what lands two issues
naming one subject different ways in a single group. A symbol resolving to nothing means renamed or moved, not gone —
re-locate it (`git log -S <symbol>`) before dropping it from the analysis.

## A subject takes the same edit-vs-citation test

The section rule does not apply the test for you: a pattern-to-follow citation sits comfortably inside a Success
Criteria bullet, where the section discriminator reads it as an edit, and every path collision the section rule surfaces
alone tends to be exactly that shape. Read the clause around each mention, symbol or path, before it becomes an edge. A
wider net without that read buys recall by manufacturing false edges.

## Same file is not same method

Two issues naming one class or file are not yet a collision; two whose edits land in one region of a method body are.
Disjoint branches of a long multi-branch body merge mechanically and take `related`; an edit at the top of the body that
every branch runs under collides with each of them and takes `blocks`. A same-file, same-spec-file, or same-mechanism
pair is `related`: `next-candidates.sh` soft-de-ranks it while the partner is in flight and `/finish` re-gates the merged
tree, so git reconciles the file.

## Why a consolidated canonical must name the absorbed subject in its description

Family consolidation (Step 3) selects on same fix *shape*, deliberately not same *file*, so the canonical's `### In
Scope` and criteria routinely do not reach the file, class, or predicate the absorbed issue names. Appending the absorbed
criteria as a comment is not enough: `/start` reads absorbed criteria out of the comment, but `/quality-review` sources
its requirements from `linear-cli issues get <ID>` (description only, no standalone comments) and `/finish` checks off
*description* checkboxes — so a criterion living only in a comment is shipped at the planner's discretion, verified by no
reviewer, and checked off by nobody, while the absorbed issue sits de-certified in the duplicate state tracking nothing.
Strip `specified` from the absorbed issue only once the canonical's description names its subject; otherwise leave the
pair `related` with `specified` intact on both, or absorb and flag the canonical for `/spec` to widen its Boundaries and
criteria first.
