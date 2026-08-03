# Issue Spec Standard

A **certified spec** is an issue description that states the problem, the desired outcome, and testable success criteria — reviewed by a human (or produced by a trusted pipeline) and marked with the `specified` label. Certification is what makes an issue safe for unattended pickup: `/auto` builds only certified issues.

Specs describe the **WHAT, never the HOW**. Implementation planning — technical approach, file lists, step-by-step design — happens in `/start` Step 6 (plan mode) at execution time, against the codebase as it exists then. Verification commands belong to project quality gates (`pnpm check`), not the ticket.

## The `specified` label

- **Semantics:** this issue's description is a certified spec — "an unattended agent may pick this up and ship it."
- **What it gates:** `/next <label>` filters candidates to a label; `/auto` dispatches `Skill(skill: "next", args: "specified")`, so only certified issues ship autonomously. Bare `/next` stays unfiltered — humans may deliberately work uncertified issues.
- **Who applies it:** `/prd` (on create), `/spec` (after research + interview + explicit signoff), `/reflect`'s filing script (its proposal bodies already carry problem/outcome/criteria), `/quality-review`'s deferred-item filing — only for severity-carrying items (pre-existing Critical/High/Medium findings, routed by its Step 5 fix-loop lane split, by its Step 5 auto-mode ceiling resolution (Medium survivors only), or by its Step 6 sub-step 5 re-review), whose bodies it composes in the certifiable problem/outcome/criteria shape — or a human in Linear when they judge a spec complete.
- **One workspace-level issue label.** `linear-cli labels create "specified" -t issue` creates it workspace-wide (the CLI cannot create team-scoped labels — a feature here: one label attaches across all teams). Never create team-scoped `specified` duplicates — name-based label operations become ambiguous.

## Applying the label — read-merge-set

`linear-cli issues update -l` **replaces the entire label set** (there is no add/remove subcommand). Always add through the helper, never a bare `-l`:

```bash
~/.claude/scripts/linear-add-label.sh PL-13 specified
```

It reads current labels, merges, sets, and verifies the attach; idempotent when the label is already present; exit 2 with a create-label pointer when the label is missing or unattachable. Direct `-l` is acceptable only on a just-created issue, whose label set is empty by construction.

## Certification includes collision edges

`specified` is the pickability gate: the moment it attaches, `/auto` may select the issue in any session, so sequencing between issues must already be mechanical by then. Every producer attaching the label owes a collision check at attach time: an issue that touches the same file or method as another open issue gets a `blocks` edge (`linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`) — `next-candidates.sh` hides blocked issues, which is what actually prevents concurrent pickup. Disjoint files that share only a mechanism take `related` plus a comment; no overlap takes nothing. Description prose is never a scheduling control — `next-candidates.sh` reads relations and labels, not text. `/auto-prep`'s batch linking remains the pool-level sweep (collisions between issues certified far apart, and edges gone stale after ships); attach-time linking closes the window between certification and the next prep run.

## The `needs decision` label

- **Semantics:** a human must step in before unattended pickup — the issue hit something no agent may resolve: a product/design decision with no testable success criteria, work needing credentials/console/vendor access, or an explicit do-not-ship-unattended note. The issue **keeps `specified`** — the spec is gated, not wrong; de-certifying would discard grooming work and hide *why* the issue is parked.
- **What it gates:** `next-candidates.sh` hides `needs decision` issues from every ranking — `/auto` never picks them, `/next` never suggests them — unless invoked with `--label 'needs decision'`, which lists exactly those (how `/spec` pick mode surfaces them). `/start` refuses to claim one in auto mode and warn-asks interactively.
- **Who applies it:** `/auto` on a durable decline and on a decision-shaped mid-flight stop (which also parks the issue back to `Planned`, unassigned — never `stalled`, which is reserved for pipeline failures), `/auto-prep`'s certification audit, and any skill that discovers a human-decision gate on an issue. Always paired with a comment naming the specific decision or access needed — the label flags, the comment explains.
- **Who clears it:** a human, once the decision is recorded on the issue — directly (`~/.claude/scripts/linear-remove-label.sh <ID> 'needs decision'`), via `/spec <ID>` (re-certification clears it), or by proceeding through `/start`'s interactive warn-ask (proceeding is the decision).
- **One workspace-level issue label**, same as `specified`: `linear-cli labels create "needs decision" -t issue`. `linear-add-label.sh` exit 2 gives this pointer when the label doesn't exist yet.

## The `solo` label

- **Semantics:** shippable unattended, but not *concurrently*. A `/start wt` worktree isolates the working tree, and nothing that makes these issues dangerous lives there — the merge point every session shares, the generated artifacts (`packages/graphql/src` and the like) siblings gate against, and the `pnpm check` command every concurrent session hard-gates on. Typical members: codegen/schema regeneration, repo-wide sweeps, and edits to the root `package.json` or the shared check suite. The issue **keeps `specified`** — it is certified, just not parallelizable.
- **What it gates:** exactly one thing — the automatic pick. `next-candidates.sh` hides `solo` issues from every ranking (`/auto` never picks one, `/next` never suggests one) unless invoked with `--label solo`, which lists exactly those. It is deliberately **not** a claim-time refusal: `/auto <ID>` and `/full <ID>` ship a solo issue normally, since targeted mode gates on `specified` alone and running it *is* the remedy. Never add a refusal on this label — that would strand automatable work.
- **Distinguish from `needs decision`:** that one means a human must *decide* something and the issue must not ship until they do. This one means no human is needed at all, only an empty fleet.
- **Who applies it:** `/auto-prep`'s certification audit (Step 2's solo disposition), or a human who knows an issue will collide with everything else in flight.
- **Who clears it:** whoever ships it — a scheduling constraint on an open issue dies with the issue. Clear it early (`~/.claude/scripts/linear-remove-label.sh <ID> solo`) only if the blast radius proves narrower than the audit judged.
- **How to run one:** while no fleet is active, first or last, never mid-fleet. `~/.claude/scripts/next-candidates.sh --label solo` lists the pool; `/auto <ID>` ships one unattended.
- **One workspace-level issue label**, same as `specified`: `linear-cli labels create "solo" -t issue`.

## Canonical spec template

```markdown
## Problem
<1-3 sentences: what is wrong or missing today, who is affected, why it matters now>

## Desired Outcome
<observable behavior/result after the work — user- or system-visible, never implementation>

## Requirements

### Must Have
- [ ] <core requirement>

### Nice to Have
- [ ] <optional enhancement>

## Success Criteria
- [ ] <specific, testable, implementation-agnostic criterion>

## Boundaries

### In Scope
- <what this ticket covers>

### Out of Scope
- <what should be separate tickets>

## Original request
> <verbatim original human text — only when regrooming an existing issue>
```

The checkboxes are load-bearing: `/start` Step 6 treats description checkboxes as requirements, and `/finish` checks them off on completion. Keep every requirement and success criterion a checkbox.

## Quality bar — certify only if ALL hold

- [ ] Problem names who is affected and why it matters now
- [ ] Desired outcome is observable — verifiable without reading code
- [ ] Every success criterion is testable and implementation-agnostic
- [ ] Boundaries name at least one explicit exclusion
- [ ] Sized for one focused session (<150k tokens of context); epic-sized work is broken into sub-issues — each certified individually — via `~/.claude/scripts/linear-create-child.sh`
- [ ] No implementation planning: no technical approach, no file lists, no verification-command blocks
- [ ] No success criterion asks for a decision ("decide X", "determine whether Y") — open product/design questions are resolved *before* certification, and the criterion prescribes the chosen behavior
- [ ] Original human text preserved under `## Original request` when regrooming

## A decision belongs in the description, never in a comment

A criterion reading "decide X" is not unattended-shippable. `/start` Step 6 takes "the issue description, checkboxes, and parent context as requirements", so the run re-derives the same open question and stops — and that decline is per-session (`/auto`'s skip lists live in `tmp/auto-state-<runKey>.json`, and `next-candidates.sh` reads no comments at all), so a fresh session ranks the issue first again and stops the same way.

Answering it in a comment does not fix this. The digest `/start` reads shows anchored comments in full but truncates standalone comments to their first line (`/start` Step 4), and even a fully-read comment leaves the checkbox still saying "decide X". A comment recording only that a conversation happened — `Confirmed with <name>.` — is worse than none, because it looks like an answer.

When the decision lands, re-groom through `/spec <ISSUE-ID>`: write the answer into the description, quoting whoever decided and keeping any constraint they attached, and rewrite the criterion to prescribe the chosen behavior. Then leave a comment pointing at the description so an earlier `/auto` skip reads as resolved. This is the interactive, pre-run edit; an in-flight implementation run never rewrites the description.

## Producers

- `/prd` — net-new epics + sub-issues (clarifying questions up front, certified on create)
- `/spec` — grooms existing/Triage issues into shape (research → interview → signoff → certify)
- `/reflect` — a **trusted-pipeline carve-out**, not an instance of the quality bar above: auto-filed proposals certify by pipeline provenance (the adversarial verify + triage gate in `skills/reflect/SKILL.md`), not by the interview. Their body still carries problem (the observation), outcome (the ready-to-paste diff — for a config/doc edit, the diff *is* the desired outcome, not deferred implementation planning), and criteria (the checkboxes); the quality bar's template and no-implementation-planning items govern the `/prd` and `/spec` paths.
