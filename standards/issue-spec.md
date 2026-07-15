# Issue Spec Standard

A **certified spec** is an issue description that states the problem, the desired outcome, and testable success criteria — reviewed by a human (or produced by a trusted pipeline) and marked with the `specified` label. Certification is what makes an issue safe for unattended pickup: `/auto` builds only certified issues.

Specs describe the **WHAT, never the HOW**. Implementation planning — technical approach, file lists, step-by-step design — happens in `/start` Step 6 (plan mode) at execution time, against the codebase as it exists then. Verification commands belong to project quality gates (`pnpm check`), not the ticket.

## The `specified` label

- **Semantics:** this issue's description is a certified spec — "an unattended agent may pick this up and ship it."
- **What it gates:** `/next <label>` filters candidates to a label; `/auto` dispatches `Skill(skill: "next", args: "specified")`, so only certified issues ship autonomously. Bare `/next` stays unfiltered — humans may deliberately work uncertified issues.
- **Who applies it:** `/prd` (on create), `/spec` (after research + interview + explicit signoff), `/reflect`'s filing script (its proposal bodies already carry problem/outcome/criteria), or a human in Linear when they judge a spec complete.
- **One workspace-level issue label.** `linear-cli labels create "specified" -t issue` creates it workspace-wide (the CLI cannot create team-scoped labels — a feature here: one label attaches across all teams). Never create team-scoped `specified` duplicates — name-based label operations become ambiguous.

## Applying the label — read-merge-set

`linear-cli issues update -l` **replaces the entire label set** (there is no add/remove subcommand). Always add through the helper, never a bare `-l`:

```bash
~/.claude/scripts/linear-add-label.sh PL-13 specified
```

It reads current labels, merges, sets, and verifies the attach; idempotent when the label is already present; exit 2 with a create-label pointer when the label is missing or unattachable. Direct `-l` is acceptable only on a just-created issue, whose label set is empty by construction.

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
- [ ] Original human text preserved under `## Original request` when regrooming

## Producers

- `/prd` — net-new epics + sub-issues (clarifying questions up front, certified on create)
- `/spec` — grooms existing/Triage issues into shape (research → interview → signoff → certify)
- `/reflect` — a **trusted-pipeline carve-out**, not an instance of the quality bar above: auto-filed proposals certify by pipeline provenance (the adversarial verify + triage gate in `skills/reflect/SKILL.md`), not by the interview. Their body still carries problem (the observation), outcome (the ready-to-paste diff — for a config/doc edit, the diff *is* the desired outcome, not deferred implementation planning), and criteria (the checkboxes); the quality bar's template and no-implementation-planning items govern the `/prd` and `/spec` paths.
