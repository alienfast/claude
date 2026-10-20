# Qualifying a `solo` mark

Read this before marking an issue `solo` in `/auto-prep` Step 2. The disposition over-triggers, and a false positive is
expensive: it pulls a workable issue out of the fleet pool and parks it on the one serial resource, the user. Qualify on
exactly two grounds, and name which one in the comment.

## (a) It changes the rules other in-flight sessions are already playing by

Merge-driver or `.gitattributes` registration, the check/task graph, a package's `test` script going from stub to real, a
shared CI gate, a dependency or lockfile change every other worktree's install predates. The test is whether a session
that started *before* this merged would behave differently after it — not whether the file sounds important.

## (b) It collides so broadly that serialization does not scale

A sweep across a directory where much of the certified pool lives. Make it quantitative: if wiring the Step 3 `blocks`
edges would take more than a handful, one `solo` mark is the same guarantee for a fraction of the wiring — count the
colliding issues and put the count in the comment. Below that threshold, wire the edges instead; that is what Step 3 is
for.

## Not solo, however it sounds

- **Touching a generated artifact the repo already resolves.** Check `.gitattributes` for a `merge=ours` driver on those
  paths and CI for an unconditional regen; under both, sibling sessions never conflict there and CI rebuilds the truth.
  Changing the generation *pipeline or its gate* can still qualify under (a); emitting different *content* through an
  unchanged pipeline does not.
- **A class-scoped sweep confined to one file or type.** That is Step 3's serialization case by the same "same method →
  serialize" rule, and often already wired. Scope, not the word "sweep" or "audit," decides.
- **An ordinary schema or API change** whose only shared-file contact is the regenerated output above.

## The serial artifact — neither remedy fits

A **serial** artifact the repo does not resolve — a migration journal with chained snapshots, a numbered changelog — is
the case neither remedy fits: wiring edges puts every issue that touches it on one chain and chain-binds the forecast,
while `solo` takes them all out of the fleet. Surface the pipeline fix as a FOCUS-ROOT instead — a project rule that
regenerates the artifact at merge plus a consistency check and a drift check in the gate — and once it lands drop the
artifact-only edges, keeping the pairs that also share ordinary source files.
