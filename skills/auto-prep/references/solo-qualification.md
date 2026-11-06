# Qualifying a `solo` mark

Read this before marking an issue `solo` in `/auto-prep` Step 2. The disposition over-triggers, and a false positive is
expensive: it pulls a workable issue out of the fleet pool and parks it on the one serial resource, the user. Qualify on
exactly three grounds, and name which one in the comment.

## (a) It changes state a sibling session meets without merging main

Machine-global state outside any worktree's tree: a launchd agent or a hook under `~/.claude`, a docker image or
volume every stack slot shares by name, the stack-slot registry, a tool installed on the machine. The test is whether
a session that started *before* this landed is affected *without* merging main. A change a sibling meets only by
merging is met at `/finish`'s merged-tree gate, which runs `pnpm check` on the merged tree, and is not this ground:
merge drivers, the check/task graph, a shared CI gate and a dependency or lockfile change all fail the test (see Not
solo below). Nearly nothing `/auto` ships qualifies; a mark on this ground names the out-of-tree state in the comment.

## (b) It collides so broadly that serialization does not scale

A sweep across a directory where much of the certified pool lives. Make it quantitative: if wiring the Step 3 `blocks`
edges would take more than a handful, one `solo` mark is the same guarantee for a fraction of the wiring — count the
colliding issues and put the count in the comment. Below that threshold, wire the edges instead; that is what Step 3 is
for.

## (c) Its acceptance holds a machine-wide resource for hours

A load campaign, repeated cold runs of a lane that takes a machine-wide lock (the storybook browser lane), any criterion
naming a load level or a run count in the tens. Every sibling pays in every check it runs: BF-3010 (2026-10-31) held the
machine for twelve hours, and its three siblings' `pnpm check` medians tripled, 15% of their runs hit the 10-minute Bash
cap and their failure rate doubled. The test is whether the *acceptance*, not the change, is what the siblings would feel.
This ground applies at filing too: a pipeline filing that certifies itself takes `solo` beside `specified`
([linear-filing.md](../../../standards/linear-filing.md) § 5), since `/auto-prep` never sees an issue filed mid-run.

## Not solo, however it sounds

- **A dependency or lockfile change, a check-suite, tooling, compose or CI edit, or a merge-driver registration.** A
  sibling meets it only by merging main, where the merged-tree gate catches a stale install or a changed rule; a
  lockfile change needs a reinstall there, not sequencing. The 2026-11-06 audit found three of eight open marks on
  this reading, two of them with no comment at all.
- **Touching a generated artifact the repo already resolves.** Check `.gitattributes` for a `merge=ours` driver on those
  paths and CI for an unconditional regen; under both, sibling sessions never conflict there and CI rebuilds the truth.
  Changing the generation *pipeline or its gate* is an in-tree change too, met at the merged-tree gate; emitting
  different *content* through an unchanged pipeline is not solo either.
- **A class-scoped sweep confined to one file or type.** That is Step 3's serialization case by the same "same method →
  serialize" rule, and often already wired. Scope, not the word "sweep" or "audit," decides.
- **An ordinary schema or API change** whose only shared-file contact is the regenerated output above.

## The serial artifact — neither remedy fits

A **serial** artifact the repo does not resolve — a migration journal with chained snapshots, a numbered changelog — is
the case neither remedy fits: wiring edges puts every issue that touches it on one chain and chain-binds the forecast,
while `solo` takes them all out of the fleet. Surface the pipeline fix as a FOCUS-ROOT instead — a project rule that
regenerates the artifact at merge plus a consistency check and a drift check in the gate — and once it lands drop the
artifact-only edges, keeping the pairs that also share ordinary source files.
