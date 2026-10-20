# Worktree hygiene — post-delegation checks in `wt` mode

Step 1 reads this when `WT_ABS != MAIN_CHECKOUT` (worktree mode is on). The delegation blocks themselves —
READ-SCOPING on every delegation, WRITE-PLACEMENT and the per-path `git -C <WT_ABS> status` probe on every write-capable
one — are `standards/git-worktrees.md` § Delegation placement, templated in `/start` Step 8; do not restate them. This
file carries what is specific to a review loop: delegates that are *supposed* to change nothing, and a tree whose
expected dirty set must survive many delegations unchanged.

## Deriving the two paths

Two plain probes, each its own Bash call — the isolation guard refuses `$(git …)` in exactly these sessions
(`standards/git-worktrees.md` § Worktree-isolated sessions): `git rev-parse --show-toplevel` prints `WT_ABS`;
`git rev-parse --path-format=absolute --git-common-dir` prints `<MAIN_CHECKOUT>/.git`, whose parent is `MAIN_CHECKOUT`.
Both must be non-empty existing directories — STOP otherwise. Carry the **literal absolute paths** through the run;
shell variables do not survive across Bash calls. `WT_ABS != MAIN_CHECKOUT` is the gate, necessary and sufficient:
unequal means a worktree nested under a shared main checkout; equal is the legitimate not-a-worktree case and nothing
below arms. Do not additionally require `git -C <WT_ABS> config --worktree --get start.source-branch` to return a
value: a wiped source-branch config is a documented hijack-corruption scenario (`standards/lifecycle-tags.md`,
`BLOCKED-ON-RECOVERY`), so requiring it would disarm the scoping exactly when it matters most. A missing value is worth
noting, not trusting as "not a worktree."

## Which dispatches carry what

READ-SCOPING is a floor on **every** delegation regardless of agent type. The WRITE-PLACEMENT block and the
post-dispatch path probe apply to this skill's write-capable delegations (`developer`); its read-only ones
(`quality-reviewer`, `quality-verifier`, `architect`, `Explore`) get neither — they change nothing and produce no
changed-path list; what they must not leave behind is the residue below. Every `Agent` dispatch in this skill and every
`SendMessage` resume in Error Handling is a delegation site. The mechanical-lane, prose-lane, drain, and gate-clearing
fix-now edits are **not**: the orchestrator applies them itself, in its own tree.

This matters most in the fix loop: a fix that lands in the wrong tree makes the re-review pass against code that was
never in the worktree — and neither a green `pnpm check` nor a delegate's success report is evidence of placement.

## Every read-only dispatch carries the probe clause

A bare "do not edit anything" reads as "do not change the implementation" while leaving a throwaway experiment fair
game; a delegate terminated mid-task leaves its probe in the tree, where `pnpm check` may never see it (a Ruby spec arm
under a JS-only check) and it is indistinguishable from the change under review. So every read-only delegation prompt
that forbids edits also carries:

> If you need a temporary probe to test a claim, remove it before you finish and state in your report that you did —
> delete only the specific paths you created, never `tmp/` itself: it also holds this run's fix-delta snapshots,
> expected-dirty hashes, and cross-skill handoff artifacts, so `rm -rf tmp/` destroys the checks the orchestrator runs
> the moment you return. Restore any file you touch by file copy — never `git checkout`, never `git restore`, and never
> `git stash`/`git stash pop`: the stash stack is shared across every worktree of the repo, so a concurrent session's
> push between your push and your pop makes `pop` apply their work into your tree and drop their entry — and the
> permissions hook sees only top-level `git` commands, so run from a script nothing will stop you.

A probe is a legitimate verification technique; an un-removed probe is indistinguishable from the change under review.
The removal clause needs the same bound as the restore clause beside it: this sentence is what *invites* the cleanup,
and a delegate reads its dispatch far more attentively than ambient config — CLAUDE.md's "never `rm -rf tmp/`" rule has
lost to an unbounded version of this sentence. No hook backstops it: `scratch-path-guard.sh` guards the system `/tmp`
only.

## After every delegation: compare the dirty set in both directions

Compare `git -C <WT_ABS> status --porcelain --untracked-files=all` against the expected-dirty set — Step 1's resolved
scope plus the fix deltas applied so far this run.

- **An extra path is the delegate's residue.** Inspect it and undo it: an untracked leftover is deleted; a tracked path
  is rewritten from `git show HEAD:<path>` by file copy — never `git restore` (hook-blocked, multi-session-unsafe) and
  never `git stash` (one worktree-shared stack; its mutating forms hook-blocked — `standards/git.md` § Safe Commands).
  Record it in the Output block's process notes; never accept it silently as part of the change under review.
- **An expected path now absent is a finding exactly like an extra one.** WRITE-PLACEMENT reports the delegate's own
  Edit/Write calls, not what a restore-by-copy through Bash removed, and a file this session created is untracked, so
  its disappearance reads as silence rather than a delta. `pnpm check` closes nothing — the artifact at risk is the one
  nothing imports: a generated manifest, fixture, or codegen output referenced only from a docblock. Restore it (re-run
  its generator; if tracked, rewrite from `git show HEAD:<path>` by file copy) and record it. Run this after
  **write-capable** delegations too: mutation testing is where it happens, and a `developer` that restores a mutated
  source by copy need not restore the untracked artifacts sharing its directory. Keep `--untracked-files=all` — under
  the default a directory collapses to one `?? dir/` line that is byte-identical after a file inside it is deleted and
  simply disappears when the last one is. A path this run deliberately removed leaves the expected set with it rather
  than re-flagging on every later delegation.

## Hash the expected-dirty paths — a bad restore leaves the set unchanged

A delegate that mutation-tests a file already in the change (the normal case — that is what there is to mutate) and
restores it badly changes neither set, so both comparisons report clean; restores do fail silently. A bare path set
also misses a write landing on a path that was *already* dirty. Carry a `shasum -a 256` per expected-dirty path in
`<WT_ABS>/tmp/qr-expected-hashes.txt`, rewritten whenever a fix batch legitimately changes one, and re-hash after every
delegation: a hash that moved with no fix landing in between is a bad restore.

- **Compare by hashing only** — never by replaying the fix delta through `patch` (`fix-delta.md`), and never by gating
  on the delegate having *reported* a restore, which is corroboration and not the check, exactly as WRITE-PLACEMENT is
  held.
- **Count mismatches positively.** Through `shasum -c`, use `grep -c ': FAILED'`, never `grep -cv ': OK$'`: on any
  failure `shasum` writes a `WARNING: N computed checksums did NOT match` summary to **stderr**, so an inverted count
  over a `2>&1`-merged capture reads one high — an extra path no fix touched, the exact bad-restore signature the check
  exists to catch. The positive count is correct whether or not stderr was merged.
- **A mismatch is a hard stop, not a re-restore.** Record it in the Output block's process notes. `pnpm check` is a
  partial backstop and no substitute: a live mutation that reddens an arm turns a later check red, detached from its
  cause and reading as a regression in the change, while the mutation that reddens *nothing* ships under a verdict
  describing an implementation that is not the one in the tree.
- **Capture the baseline — and every rewrite of it — in a message that dispatches nothing.** Tool calls in one message
  run concurrently, so a `shasum` issued alongside an `Agent` dispatch is unordered against that agent's edits and can
  hash a file mid-probe. That breaks the check in both directions: a correctly restored file then mismatches and reads
  as a bad restore, while a delegate that never restores hashes *equal* to the mutated baseline and reports clean. Hash
  first, dispatch next. `standards/agent-coordination.md`'s "writing to `tmp/` is free" governs orchestrator *edits*
  colliding with an agent's reads and does not license this.
