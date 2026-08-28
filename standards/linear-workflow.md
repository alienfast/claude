# Linear Workflow

## Passing File Content to Linear CLI

**Never pass file content INTO `linear-cli` via shell operators (`<`, `cat |`, `$()`, heredocs).** Claude Code's permission wildcards don't match through shell operators, so these commands always trigger permission prompts regardless of allow-list rules. This is scoped to input plumbing: piping `linear-cli` *output* into `jq`/`grep` is unaffected and is the normal read path throughout this repo (`/auto`'s certification gate, `next-candidates.sh`, `linear-context.sh`).

For the two most common operations — updating a description or adding a comment — prefer `~/.claude/scripts/linear-post.sh`, which wraps the stdin plumbing and picks the right flag for each kind:

```bash
# Update issue description
~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md

# Add comment from file
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

For other operations (most notably `i create` with a file body), use the underlying `~/.claude/scripts/linear-stdin.sh` helper directly:

```bash
# Usage: ~/.claude/scripts/linear-stdin.sh <file> <linear-args...>

# Create issue with description from file
~/.claude/scripts/linear-stdin.sh tmp/description.md i create "Title" --team PL -d -
```

**Workflow** for any command that passes file content:

1. `mkdir -p tmp` (once per session)
2. `Write` content to `tmp/<descriptive-name>.md`
3. `~/.claude/scripts/linear-post.sh <comment|description> <issue-id> tmp/<file>.md`
   (or `~/.claude/scripts/linear-stdin.sh tmp/<file>.md <linear-args> -d -` for non-comment/description ops)

Short inline values can be passed directly: `linear-cli issues create "Bug" --team PL -d "Brief description"`

**This overrides any examples in the linear skill** that use `cat file | linear-cli`, `< file`, or `$(cat <<EOF)`. Those patterns will trigger permission prompts.

## Terminal States for Dependency Resolution

When evaluating whether an issue's blockers are resolved (for triage, dependency analysis, next-issue suggestions, or any workflow that checks "is this issue unblocked?"), treat all of these states as **completed**:

- **Done** — Fully released
- **Ready For Release** — Implementation complete, code reviewed, PR ready to merge (merge triggers automated deployment)
- **In Review** — Implementation complete, awaiting human review (keeper ruling 2026-08-21)

**Ready For Release** and **In Review** mean the work is finished from an implementation perspective. Downstream issues that depend on it can begin — they are unblocked. The remaining steps (review, PR merge, automated deployment) are operational concerns, not implementation dependencies. A review kick-back moves the issue out of In Review, which reinstates its blocks automatically.

**In Review must be matched by NAME, not state type.** Linear registers every team's In Review state as type `started`, and the API cannot change a state's type after creation (`WorkflowStateUpdateInput` carries only name/color/description/position — verified by introspection 2026-08-21), so a type-based terminal filter reads In Review as in-flight and silently holds its dependents out of every ranking.

## Implication for Skills

Any skill that checks whether blockers are resolved (triage, next) should treat "Ready For Release" and "In Review" identically to "Done" when determining if an issue is workable.

## Assignment Is a Claim

An assignee on an issue means a person has claimed that work or is investigating it to provide more context. An issue assigned to anyone other than you is therefore **never a candidate** — not for certifying (`/spec`), not for working (`/next`, `/auto`) — until they unassign it. Enforced in [scripts/next-candidates.sh](../scripts/next-candidates.sh): foreign-assigned issues are hidden from every ranking with a trailing hidden-count note (`--include-claimed` restores them for inspection); issues assigned to the viewer rank tier 1. Measured cost of the gap this closes: `/spec` recommended four issues claimed by other people as the top grooming picks (BF-183/182/178 → Blake, BF-71 → Robert, 2026-08-13).

## Stage Priorities: Planned → Backlog → Triage

Certifying and working share one strict stage order (keeper decision 2026-08-13): drain **Planned/Todo** completely, then **Backlog**, and touch the **Triage** inbox only when both are empty. **Within a tier**, stage outranks priority and label class — an Urgent Backlog or Triage issue never outranks any Planned issue in the same tier (the measured failure this codifies: `/spec` recommended BF-34, an Urgent Triage report, over the entire uncertified Planned queue). Tier assignment itself sorts ahead of stage: a certified reflection improvement (`specified`+`reflection`), a keeper batch on the keeper's machine, an issue assigned to you, or a newly-unblocked one all reach a senior tier and so precede every Planned issue below them. Almost everything lands in the bottom tier on a standalone run, which is why the within-tier order is what actually ranks the pool.

Enforced by [scripts/next-candidates.sh](../scripts/next-candidates.sh) (`state_rank`: unstarted 0, backlog 1, triage 2; Planned/Todo is additionally exempt from `--limit` truncation via the trailing "below the cut" section) and presented by `/spec` pick mode as three separate stage buckets — options and the recommendation come from the first non-empty bucket only. One exception holds in both: **a Backlog issue that (transitively) blocks a Planned/Todo issue belongs to the Planned stage** — an issue is scoped by what it gates, not by its column (keeper ruling 2026-08-13). `next-candidates.sh` inherits `state_rank` 0 for it at pick time (annotated `Stage inherited`), so a fleet reaches it before any deferred Backlog work whether or not its column was promoted; `/spec` lists it in the Planned bucket and promotes it on certification; `/auto-prep`'s `PROMOTE-SET` batch promotes the whole chain membership so the keeper's Planned view and grooming filter see it too. Any skill or report presenting backlog work follows the same order and never recommends across a stage boundary while an earlier stage still has work.

**The Planned gate (keeper ruling 2026-08-28): Backlog is withheld, not merely out-ranked, until the Planned/Todo column is drained — no usage is spent on Backlog while it holds work.** Ordering alone falls through to Backlog the moment no Planned issue is pickable *this instant* (the rest blocked behind in-flight work, or parked), which is exactly the usage the ruling forbids. `next-candidates.sh` therefore withholds every Backlog candidate while the column holds anything not claimed by another person, and prints a `PLANNED-HOLD` note classifying what holds it — pickable now, releasing on its own (blocked only behind in-flight or fleet-eligible chains), or the keeper's (parked, uncertified, an epic to close, or blocked behind such). Blockers and children of Planned work inherit the Planned stage, so the gate cannot deadlock on them. With nothing pickable the picker **waits** (`/auto` ticks at no usage until a chain releases or the keeper acts) and never reads the hold as a drained backlog; the fleet deadline is what ends an idle run. Consequences the keeper owns: an issue left in Planned that the fleet cannot ship — `needs decision`, `human`, `solo`, uncertified, an epic whose children have all shipped — idles the fleet once the pickable Planned work is gone; decide, certify, close, or move it out of the column deliberately. A claim by another person is the one carve-out (neither the fleet's nor the keeper's to drain). Discovery listings (`/spec`'s `--include-blocked`/`--include-triage` roster, the `solo` / `needs decision` / `human` label views) are exempt, and `--no-stage-gate` lifts the gate for inspection.

## Certified Specs (the `specified` label)

[issue-spec.md](issue-spec.md) owns the `specified` label — its definition, quality bar, canonical template, read-merge-set mechanics, and the autonomous-pickup gate. What belongs here is only which producer applies it: `/prd` certifies on create for single-issue runs (batches certify after collision edges are wired), and `/spec` grooms existing issues into shape.

## Spawned Issues Must Link to Their Parent

Any Linear issue created as a follow-up from another issue's workflow (deferred items from `/quality-review`, sub-tasks from `/prd`, etc.) MUST be linked to its originating issue. Use `~/.claude/scripts/linear-create-child.sh [--allow-planned] <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]` — the leading `--allow-planned` is required to pass `Planned` as the state (without it a caller-passed `Planned` is refused before anything is created), and the trailing `label`/`priority` slots are the certification and severity paths: a severity graded into the body alone is invisible to `/next`'s ranking, which reads the field. `linear-cli issues create` has no `--parent` flag (you can set the parent's UUID via `--data` `parentId`, but that path performs no verification), so the helper creates the issue, links the parent with `relations parent`, and **verifies the link, failing hard on an orphan** — with one benign exception: a parent at Linear's sub-issue nesting cap (10 ancestors) deterministically rejects every child, so the helper wires a `related` peer edge instead and exits 3 (the issue is filed, labelled, and usable; only the parent edge is a peer edge). Two other non-zero exits are also degraded-but-filed: 2 means the issue was created and the label could not attach, and 4 means both 2 and 3. Treat any of 2/3/4 as filed — the identifier is on stdout — and only exit 1 as "no issue exists".

Do not hand-roll create-then-link in a skill (`linear-cli issues create ...` followed by a separate `relations parent`/`issues update --data '{"parentId":...}'`). An un-verified second call is easy to skip when filing several issues in a row, easy to silently fail (the new issue already exists, so the workflow looks successful), and easy to mis-substitute when `<ISSUE-ID>` is a literal placeholder — leaving the issue orphaned in Linear's UI (no "Sub-issues" entry under the parent, no breadcrumb on the child). The helper exists precisely so the link is always made AND verified in one invocation; always route through it.

If the originating context has no issue ID, file the new issue without `--parent` — never invent a parent.

Parent linkage does not make the parent an epic. The workspace `epic` label marks issues deliberately decomposed into sub-issues that carry the work — `/prd` batch runs and `/spec` breakdowns attach it. A worked issue that accumulates deferred-item children stays unlabeled.
