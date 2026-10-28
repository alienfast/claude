# Linear Workflow

## Passing File Content to Linear CLI

**Never pass file content INTO `linear-cli` via shell operators (`<`, `cat |`, `$()`, heredocs).** Claude Code's
permission wildcards don't match through shell operators, so these commands always trigger permission prompts regardless
of allow-list rules. This is scoped to input plumbing: piping `linear-cli` *output* into `jq`/`grep` is unaffected and is
the normal read path throughout this repo.

For the two most common operations, updating a description or adding a comment, use `~/.claude/scripts/linear-post.sh`,
which wraps the stdin plumbing and picks the right flag for each kind:

```bash
~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

For other operations (most notably `i create` with a file body), use `~/.claude/scripts/linear-stdin.sh <file>
<linear-args...>` directly:

```bash
~/.claude/scripts/linear-stdin.sh tmp/description.md i create "Title" --team PL -d -
```

**Workflow** for any command that passes file content:

1. `mkdir -p tmp` (once per session)
2. `Write` content to `tmp/<descriptive-name>.md`
3. `~/.claude/scripts/linear-post.sh <comment|description> <issue-id> tmp/<file>.md`
   (or `~/.claude/scripts/linear-stdin.sh tmp/<file>.md <linear-args> -d -` for other operations)

Short inline values can be passed directly: `linear-cli issues create "Bug" --team PL -d "Brief description"`.

**This overrides any example in the linear skill** that uses `cat file | linear-cli`, `< file`, or `$(cat <<EOF)`.

## Terminal States for Dependency Resolution

When evaluating whether an issue's blockers are resolved (for triage, dependency analysis, next-issue suggestions, or
any workflow that checks "is this issue unblocked?"), treat all of these states as **completed**:

- **Done**: fully released
- **Ready For Release**: implementation complete, code reviewed, PR ready to merge (merge triggers automated deployment)
- **In Review**: implementation complete, awaiting human review

**Ready For Release** and **In Review** mean the work is finished from an implementation perspective. Downstream issues
that depend on it can begin. The remaining steps (review, PR merge, automated deployment) are operational concerns, not
implementation dependencies. A review kick-back moves the issue out of In Review, which reinstates its blocks
automatically.

**The close-out is `/finish`'s, whichever branch carries the code.** A fix tracked as an issue but landed on a branch no
`/start` created — a Renovate bundle, a hotfix PR, an integration branch — still ends with `/finish <ID> pr`: it checks
off the satisfied requirements, posts the completion comment, gates on `pnpm check` and on the `/quality-review` verdict
(a missing verdict prompts `yes` / `re-run` / `abort`; it never passes silently), opens the PR or updates the one the
branch already has, then moves the issue to Ready For Release — an open PR is work waiting for its release, and the PR
merging later changes nothing in Linear. An issue still In Progress on a green, mergeable PR is the tell that the
close-out was done by hand or not at all.

**The one exception is a dependency on the release itself, carried by the `deploy-gated` label**: such an issue waits
until every blocker reaches one of the project's declared deployed states ([issue-spec.md](issue-spec.md) § The
`deploy-gated` label).

**In Review must be matched by NAME, not state type.** Linear registers every team's In Review state as type `started`,
and the API cannot change a state's type after creation, so a type-based terminal filter reads In Review as in-flight and
silently holds its dependents out of every ranking.

## Implication for Skills

Any skill that checks whether blockers are resolved (triage, next) should treat "Ready For Release" and "In Review"
identically to "Done" when determining if an issue is workable, except for a `deploy-gated` dependent, whose blockers
resolve only at the project's declared deployed states.

## Assignment Is a Claim

An assignee on an issue means a person has claimed that work or is investigating it to provide more context. An issue
assigned to anyone other than you is therefore **never a candidate**, not for certifying (`/spec`), not for working
(`/next`, `/auto`), until they unassign it. Enforced in [scripts/next-candidates.sh](../scripts/next-candidates.sh):
foreign-assigned issues are hidden from every ranking with a trailing hidden-count note (`--include-claimed` restores
them for inspection); issues assigned to the viewer rank tier 1.

### A self-claim does not hide an issue — it promotes it

That hiding is asymmetric, deliberately: `next-candidates.sh` drops issues assigned to **someone else** and keeps issues
assigned to **you**, at tier 1. Two consequences follow, and both are routinely read the wrong way round:

- **The `hidden as claimed by a person` note is not a check that your claim landed.** Its count selects
  `assignee != $me`, so a self-claim never moves it. Confirm a claim by reading `.assignee` back
  ([skills/linear/SKILL.md](../skills/linear/SKILL.md) gotcha #8), never by watching that number.
- **Where sessions share one Linear viewer identity (every fleet on one machine), claiming an issue does not protect it
  from siblings; it puts it first in their ranking.** The reachable case is re-grooming an already-`specified` issue: the
  claim is held for a whole interview while the issue stays pickable and now outranks the pool. Use a control that
  actually hides it (`needs decision` while the question is open, or work it outside the fleet window), and treat a
  claim as a signal to other *people*, not a lock against other *sessions*.

Note which half of a claim does the hiding when one is also writing a state: for a fleet it is the **state**, since
`WORKABLE_STATES` is Backlog/Planned/Todo and In Progress is not among them. A claim whose assignee landed but whose state
did not looks claimed to a human while staying fully pickable to every session, which is why both halves are verified
rather than inferred from the write's exit status ([scripts/linear-claim.sh](../scripts/linear-claim.sh)).

## Stage Priorities: Planned → Backlog → Triage

Certifying and working share one strict stage order: drain **Planned/Todo** completely, then **Backlog**, and touch the
**Triage** inbox only when both are empty. **Within a tier**, stage outranks priority and label class: an Urgent Backlog
or Triage issue never outranks any Planned issue in the same tier. Tier assignment itself sorts ahead of stage: a
certified reflection improvement (`specified`+`reflection`), a keeper batch on the keeper's machine, an issue assigned to
you, or a newly-unblocked one all reach a senior tier and so precede every Planned issue below them. Almost everything
lands in the bottom tier on a standalone run, which is why the within-tier order is what actually ranks the pool.

Enforced by [scripts/next-candidates.sh](../scripts/next-candidates.sh) (`state_rank`: unstarted 0, backlog 1, triage 2;
Planned/Todo is additionally exempt from `--limit` truncation via the trailing "below the cut" section) and presented by
`/spec` pick mode as three separate stage buckets; options and the recommendation come from the first non-empty bucket
only. One exception holds in both: **a Backlog issue that (transitively) blocks a Planned/Todo issue belongs to the
Planned stage**; an issue is scoped by what it gates, not by its column. `next-candidates.sh` inherits `state_rank` 0 for
it at pick time (annotated `Stage inherited`), so a fleet reaches it before any deferred Backlog work whether or not its
column was promoted; `/spec` lists it in the Planned bucket and promotes it on certification; `/auto-prep`'s
`PROMOTE-SET` batch promotes the whole chain membership so the keeper's Planned view and grooming filter see it too. Any
skill or report presenting backlog work follows the same order and never recommends across a stage boundary while an
earlier stage still has work.

**The Planned gate: Backlog is withheld, not merely out-ranked, until the Planned/Todo column is drained; no usage is
spent on Backlog while it holds work.** Ordering alone falls through to Backlog the moment no Planned issue is pickable
*this instant* (the rest blocked behind in-flight work, or parked), which is exactly the usage the gate forbids.
`next-candidates.sh` therefore withholds every Backlog candidate while the column holds anything not claimed by another
person, and prints a `PLANNED-HOLD` note classifying what holds it: pickable now, releasing on its own (blocked only
behind in-flight or fleet-eligible chains), or the keeper's (parked, uncertified, an epic to close, or blocked behind
such). Blockers and children of Planned work inherit the Planned stage, children at any depth, climbing through a shipped
parent too (a Backlog child of a Ready-for-Release issue under a Planned epic is still that epic's scope), so the gate
cannot deadlock on them. With nothing pickable the picker **waits** (`/auto` ticks at no usage until a chain releases or
the keeper acts) and never reads the hold as a drained backlog; the fleet deadline is what ends an idle run, except an
epic-scoped run, which ends on `EPIC-DRAINED` ([lifecycle-tags.md](lifecycle-tags.md) § Tag vocabulary, the `NO-CANDIDATES` row). Consequences
the keeper owns: an issue left in Planned that the fleet cannot ship (`needs decision`, `human`, `solo`, uncertified, an
epic whose children have all shipped) idles the fleet once the pickable Planned work is gone; decide, certify, close, or
move it out of the column deliberately. A claim by another person is the one carve-out. Discovery listings (`/spec`'s
`--include-blocked`/`--include-triage` roster, the `solo` / `needs decision` / `human` label views) are exempt, and
`--no-stage-gate` lifts the gate for inspection.

**The `backlog` opt-in: on a day with spare usage, the human may let a fleet fall through to Backlog once nothing
Planned/Todo is pickable.** The gate stays the default; the opt-in is a literal token on the launch (`/fleet-launch …
backlog`, dispatched as `/loop /auto backlog`, which `/next` passes to `next-candidates.sh --backlog-fallback`), never
inferred from a usage reading. Planned/Todo stays strictly first at every pick, across tiers, so the moment a Planned
issue releases the next pick takes it; a releasing Planned issue does not make a session wait, because idling for a
chain is exactly what spare usage should not do. With nothing pickable in either column the session waits on
`PLANNED-HOLD` as under the gate, and `/auto`'s headroom gate still parks near the 5h ceiling: the token changes the
spending policy, not the burst protection. A `_BACKLOG-FALLBACK: …_` note on the pick names what still holds the column,
so the ledger and the retro can tell fallback work from a gate failure.

**An epic scope implies the opt-in.** `/fleet-launch epic:<ID>`, `/auto epic:<ID>` and `/next epic:<ID>` run
`next-candidates.sh --root`, which opens the fallback by construction: the goal of a scoped run is to complete the epic,
and a member's column says nothing about that — a review's deferred filing lands as a Backlog sub-issue mid-run and is
still the epic's work. The member cut precedes the gate, so only the epic's own Backlog members are offered, never the
team's; Planned/Todo members still go first at every pick, and `EPIC-DRAINED` still ends the run once only keeper-gated
members remain. `/epic-prep`'s promotion to Planned is for the board, not the picker. `/fleet-launch epic:<ID>`
dispatches the literal `backlog` token so the marker and every ledger record the mode.

## Certified Specs (the `specified` label)

[issue-spec.md](issue-spec.md) owns the `specified` label: its definition, quality bar, canonical template, read-merge-set
mechanics, the autonomous-pickup gate, and which producer applies it when (§ Producers).

## Spawned Issues Must Link to Their Parent

Any Linear issue created as a follow-up from another issue's workflow (deferred items from `/quality-review`, sub-tasks
from `/prd`, etc.) MUST be linked to its originating issue, through `~/.claude/scripts/linear-create-child.sh`, which
creates the issue, links the parent with `relations parent`, and verifies the link. Never hand-roll create-then-link: an
un-verified second call is easy to skip when filing several issues in a row, easy to silently fail (the new issue already
exists, so the workflow looks successful), and leaves the issue orphaned in Linear's UI. If the originating context has
no issue ID, file with `-` as the parent; never invent one. The helper's arguments, flags and exit codes are in
[linear-filing.md](linear-filing.md) § Create through the helper.

Parent linkage does not make the parent an epic. The workspace `epic` label marks issues deliberately decomposed into
sub-issues that carry the work (`/prd` batch runs and `/spec` breakdowns attach it); a worked issue that accumulates
deferred-item children takes no `epic` label.

## Every Agent Filing Takes the Filing Recipe

Any issue an agent files on its own initiative goes through [linear-filing.md](linear-filing.md): search before filing,
`linear-create-child.sh` under the parent, class labels and a priority at create, collision edges, a routing label last.

## A batch approval covers the presented set, not a selector

When a set of Linear writes (state moves, label changes, cancellations, promotions) is presented for one approval, the
approval attaches to exactly the ids shown. Hand the applier that frozen list; never a selector ("every cancel
proposal", "every Backlog issue on the chain") re-evaluated at apply time, and never a re-derivation of the rows. Both
directions fail: a selector picks up proposals a background scan wrote between the presentation and the apply, and a
re-derivation drops rows the presentation had. Each applier takes the ids as an argument
(`skills/triage/scripts/triage-apply.sh --ids`; `/auto-prep`'s PROMOTE-SET takes the FOCUS-ROOT rows) and skips an id
whose record no longer matches rather than widening to whatever matches now.
