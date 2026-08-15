# Issue Spec Standard

A **certified spec** is an issue description that states the problem, the desired outcome, and testable success criteria — reviewed by a human (or produced by a trusted pipeline) and marked with the `specified` label. Certification is what makes an issue safe for unattended pickup: `/auto` builds only certified issues.

Specs describe the **WHAT, never the HOW**. Implementation planning — technical approach, file lists, step-by-step design — happens in `/start` Step 6 (plan mode) at execution time, against the codebase as it exists then. Verification commands belong to project quality gates (`pnpm check`), not the ticket.

## The `specified` label

- **Semantics:** this issue's description is a certified spec — "an unattended agent may pick this up and ship it."
- **What it gates:** `/next <label>` filters candidates to a label; `/auto` dispatches `Skill(skill: "next", args: "specified")`, so only certified issues ship autonomously. Bare `/next` stays unfiltered — humans may deliberately work uncertified issues.
- **Who applies it:** `/prd` (single-issue runs on create; batches after collision edges wire), `/spec` (after research + interview + explicit signoff), `/reflect`'s filing script (its proposal bodies already carry problem/outcome/criteria), `/quality-review`'s deferred-item filing — only for severity-carrying items (pre-existing Critical/High/Medium findings, routed by its Step 5 fix-loop lane split, by its Step 5 auto-mode ceiling resolution (Medium survivors only), or by its Step 6 sub-step 5 re-review), whose bodies it composes in the certifiable problem/outcome/criteria shape; its Nice-to-Have lane never files at all — or a human in Linear when they judge a spec complete.
- **One workspace-level issue label.** `linear-cli labels create "specified" -t issue` creates it workspace-wide (the CLI cannot create team-scoped labels — a feature here: one label attaches across all teams). Never create team-scoped `specified` duplicates — name-based label operations become ambiguous.

## Applying the label — read-merge-set

`linear-cli issues update -l` **replaces the entire label set** (there is no add/remove subcommand). Always add through the helper, never a bare `-l`:

```bash
~/.claude/scripts/linear-add-label.sh PL-13 specified
```

It reads current labels, merges, sets, and verifies the attach; idempotent when the label is already present; exit 2 with a create-label pointer when the label is missing or unattachable. Direct `-l` is acceptable only on a just-created issue, whose label set is empty by construction.

## Certification includes collision edges

`specified` is the pickability gate: the moment it attaches, `/auto` may select the issue in any session, so sequencing between issues must already be mechanical by then. Every producer attaching the label owes a collision check at attach time: an issue that touches the same file or method as another open issue gets a `blocks` edge (`linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`) — `next-candidates.sh` hides blocked issues, which is what actually prevents concurrent pickup. Disjoint files that share only a mechanism take `related` plus a comment; no overlap takes nothing. Description prose is never a scheduling control — `next-candidates.sh` reads relations and labels, not text. `/auto-prep`'s batch linking remains the pool-level sweep (collisions between issues certified far apart, and edges gone stale after ships); attach-time linking closes the window between certification and the next prep run.

Wiring a `blocks` edge is a guard, not a reflex: wire one only when the blocked side is (or is about to become) fleet-pickable (`specified`) and the blocker will actually ship unattended — certified, not `needs decision`, not `solo` — mirroring `/auto-prep`'s "never chain through a Step 2-flagged issue" doctrine, since blocker resolution reads the blocker's *state*, never its labels, and `next-candidates.sh` filters blocked issues out before ranking, so anything wired behind a blocker that never ships unattended is stranded invisibly. When the would-be blocker is uncertified, `needs decision`, or `solo`, record the overlap as `related` plus a comment naming the shared file instead. Direction: the blocker is whichever issue should land first — semantic/work order when discernible (mechanism before consumers, a surgical fix before the sweep that enumerates its area), else the earlier/already-open issue blocks the newer one. A producer that structurally attaches the label before wiring edges (a single-issue grooming run certifies before its collision check runs; a `/reflect` filing's issue ID exists only after the filing script returns) closes the resulting window by wiring immediately after attach — the window is seconds long and accepted. A producer without code context applies the check at the finest granularity it has — `/prd` works from component and feature decomposition, never file lists — and that coarser judgment satisfies the obligation.

## The `needs decision` label

- **Semantics:** a human must step in before unattended pickup — the issue hit something no agent may resolve: a product/design decision with no testable success criteria, an unstated scope or mapping a criterion silently depends on, or an explicit do-not-ship-unattended note. (Work that is *itself* human-performed takes [`human`](#the-human-label) instead — that gate is permanent; this one clears when the decision lands.) The issue **keeps `specified`** — the spec is gated, not wrong; de-certifying would discard grooming work and hide *why* the issue is parked.
- **Filing before the decision exists:** an issue whose requirements cannot yet prescribe behavior — its criteria would read "decide X", which the quality bar forbids certifying — files **without** `specified`, carrying `needs decision` alone and saying so in the body. The keeps-`specified` rule above is for issues certified *before* hitting the gate; a decision-shaped filing earns certification only through re-grooming once the decision lands.
- **What it gates:** `next-candidates.sh` hides `needs decision` issues from every ranking — `/auto` never picks them, `/next` never suggests them — unless invoked with `--label 'needs decision'`, which lists exactly those (how `/spec` pick mode surfaces them). `/start` refuses to claim one in auto mode and warn-asks interactively.
- **Who applies it:** `/auto` on a decision-shaped durable decline or mid-flight stop (which also parks the issue back to `Planned`, unassigned — never `stalled`, which is reserved for pipeline failures; a stop whose gate is a human-performed *step* routes to [`human`](#the-human-label) instead), `/auto-prep`'s certification audit, and any skill that discovers a human-decision gate on an issue. Always paired with a comment naming the specific decision or access needed — the label flags, the comment explains. When the parking strands verified committed work (a preserved worktree whose branch carries green-verified commits), the comment also pre-stages the keeper's call: state the split-vs-wait option with the drift cost, so the decision is a one-question interview rather than a re-derivation — BF-858's second parking comment is the model.
- **Who clears it:** a human, once the decision is recorded on the issue — directly (`~/.claude/scripts/linear-remove-label.sh <ID> 'needs decision'`), via `/spec <ID>` (re-certification clears it), or by proceeding through `/start`'s interactive warn-ask (proceeding is the decision).
- **One workspace-level issue label**, same as `specified`: `linear-cli labels create "needs decision" -t issue`. `linear-add-label.sh` exit 2 gives this pointer when the label doesn't exist yet.

## The `human` label

- **Semantics:** the work itself is human-performed — customer outreach, vendor contact, production data remediation, sign-offs, briefings, or a roll-up a person owns. Unlike `needs decision` (agent work parked until a human decides), no pending input ever hands it back to an agent: no mode of any skill can ship it. The issue **keeps `specified`** when its spec meets the bar — certification records spec quality; this label records the executor.
- **What it gates:** `next-candidates.sh` hides `human` issues from every ranking unless invoked with `--label human`, which lists exactly those — the team's own to-do view. Unlike `solo` there is **no targeted-mode carve-out**: `/auto <ID>` refuses a `human`-labeled target, and `/start` warns interactively (proceeding assists a human owner; the label stays) and skips in auto mode — running it is not a remedy an agent can provide.
- **Distinguish from `needs decision`:** that one clears — decision recorded, label removed, an agent ships it. This one lives as long as the issue does; it clears only by re-scoping through `/spec`, typically splitting the agent-shippable slice into its own issue while the human acts keep the label. The routing test is *what the human must do*, not how much agent work surrounds it: a partially-implemented issue whose **remaining** gate-step is human-performed (console/credential configuration, a vendor contact) takes this label too — recording an answer on the issue would hand nothing back, and the keeper's `needs decision` sweep (`/spec`) would find no question to answer. When agent work remains after the human acts, the hand-back is the same re-scope — or the human clears the label after acting, which is that decision made directly.
- **Who applies it:** `/prd` at certification for human-executed sub-issues, `/auto-prep`'s Step 2 audit for the same class, `/auto` on a capability-shaped durable decline or mid-flight park, or a human. Pair it with an assignee or a comment naming who owns the work when known.
- **One workspace-level issue label**, like the others: `linear-cli labels create "human" -t issue`.

## The `solo` label

- **Semantics:** shippable unattended, but not *concurrently*. A `/start wt` worktree isolates the working tree, and nothing that makes these issues dangerous lives there — the merge point every session shares and the `pnpm check` command every concurrent session hard-gates on. Typical members: repo-wide sweeps, and edits to the root `package.json` or the shared check suite. (Schema/codegen regeneration is NOT solo — keeper ruling 2026-08-15: `schema_gen` is a routine task, and a description-only regen manifests as comments with zero code implications.) The issue **keeps `specified`** — it is certified, just not parallelizable.
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

The checkboxes are load-bearing: `/start` Step 6 treats description checkboxes as requirements, and `/finish` checks them off on completion. Keep every requirement and success criterion a checkbox. (`### Nice to Have` boxes are the one exception — they carry the opportunity semantics below, are planned around only when trivially in-path, and gate nothing.)

**`### Nice to Have` means target of opportunity — not a requirement, and never a deferral.** Implement one only when it falls out easily from work already in hand; skipping is the normal outcome, needs no more than a one-line note at completion, and creates no obligation — no follow-up filing, no plan-comment promise, no unchecked-box guilt (`/finish` never gates on the tier). The tier's real value is at grooming: it is a brainstorm surface for other angles, and its only promotion path is a **human** moving a line into `### Must Have` (usually via `/spec`'s promotion pass). The machine never moves it anywhere — filing a skipped Nice to Have is feature creep, converting an optional brainstorm line into tracked work nobody prioritized (BF-1182, canceled: a skipped notify-others line filed `human` behind a vendor dependency on the precedent of BF-1123 — which gates a **Must Have**; the analogy fails on the tier). The same opportunity semantics govern `/quality-review`'s reviewer-finding Nice-to-Have lane: fix it if easy, otherwise record and drop — that lane never files.

## Quality bar — certify only if ALL hold

- [ ] Problem names who is affected and why it matters now
- [ ] Desired outcome is observable — verifiable without reading code
- [ ] Every success criterion is testable and implementation-agnostic
- [ ] Boundaries name at least one explicit exclusion
- [ ] Sized for one focused session (<150k tokens of context); epic-sized work is broken into sub-issues — each certified individually — via `~/.claude/scripts/linear-create-child.sh`
- [ ] No implementation planning: no technical approach, no file lists, no verification-command blocks
- [ ] No success criterion asks for a decision ("decide X", "determine whether Y" as an open question) — open product/design questions are resolved *before* certification, and the criterion prescribes the chosen behavior. An **empirical determination is not a decision**: a criterion may direct a measurement when it prescribes the response to each outcome ("measure whether the chain is reachable; if it is, bind the argument and assert the downstream predicate; if not, record why at the site") — the forbidden shape is the question left open, not the experiment (BF-673 shipped unattended on exactly such a criterion)
- [ ] No success criterion embeds a literal pattern (regex, glob, SQL predicate, field index) as its pass condition — state the property the data must have and let execution derive the check
- [ ] Original human text preserved under `## Original request` when regrooming

## A decision belongs in the description, never in a comment

A criterion reading "decide X" is not unattended-shippable. `/start` Step 6 takes "the issue description, checkboxes, and parent context as requirements", so the run re-derives the same open question and stops — and that decline is per-session (`/auto`'s skip lists live in `tmp/auto-state-<runKey>.json`, and `next-candidates.sh` reads no comments at all), so a fresh session ranks the issue first again and stops the same way.

Answering it in a comment does not fix this. The digest `/start` reads shows anchored comments in full but truncates standalone comments to their first line (`/start` Step 4), and even a fully-read comment leaves the checkbox still saying "decide X". A comment recording only that a conversation happened — `Confirmed with <name>.` — is worse than none, because it looks like an answer.

When the decision lands, re-groom through `/spec <ISSUE-ID>`: write the answer into the description, quoting whoever decided and keeping any constraint they attached, and rewrite the criterion to prescribe the chosen behavior. Then leave a comment pointing at the description so an earlier `/auto` skip reads as resolved. This is the interactive, pre-run edit; an in-flight implementation run never rewrites the description.

## An either/or Desired Outcome is ordered — a fallback arm, not a menu

A Desired Outcome of the form "X cannot happen, or if it can, the failure is Y" names a preference and a fallback, in that order. It licenses shipping Y only when X is unreachable or out of proportion to the issue — it never makes the arms equal choices. When the implementing session's own investigation proves the stronger arm reachable — the evidence already in hand with no new investigation needed, the change within the files the issue's work already touches, and no product/design decision pending — delivering the stronger arm is **in-mandate**: "beyond this issue's mandate" cannot describe the issue's own first-choice outcome. Deferring it in that position files away the session's loaded evidence and re-prices cheap hot work at a full cold session (BF-673 measured the single-lock-scope change that closes its residual deadlock outright, shipped the retry arm, and filed the stronger arm as BF-1175 — whose success criteria cite measurements only the finished session could reproduce). When the stronger arm genuinely fails one of those gates — new investigation needed, a contract outside the issue's file scope, a pending human decision — the fallback plus a recorded reason satisfies the outcome, and any follow-up routes through `/quality-review`'s deferred-item bar rather than filing automatically.

**Distinguish the fallback form from a genuine fork.** The ordered reading applies when Y is a degraded handling of the very failure X prevents — "cannot deadlock, or the failure is retried/clean". A Desired Outcome offering two *complete end-states* — "either the twins align, or the divergence is documented as intentional with the reason" — is a fork, not a fallback: the arms are co-equal and the choice turns on judgment or a product call. A fork is resolved on its merits, never by reflex toward the busier arm (BF-1044's `resend?` criterion offered a grant or a recorded denial; the session correctly chose the denial, because the grant was far wider than the need). A fork whose choice is a product call the session may not make routes to `needs decision`, per this standard.

## A success criterion that carries its own pattern IS the gate

A criterion embedding a literal regex, glob, SQL predicate, or field index — `SELECT COUNT(*) … REGEXP '<pattern>'` returning 0 — asserts that the pattern's matches are exactly the population the issue is about. That assertion inherits every blind spot of the pattern, and the blind spot here does not merely understate a survey: **the criterion is the acceptance gate, so whatever the pattern misses is certified as fixed.** A remediation issue closes green with the defect it was filed for still live — and the narrower the pattern looks, the more precise the criterion reads.

The quality bar forbids this twice already — "no verification-command blocks" and "testable and implementation-agnostic" — and both get read past, because a pattern over data feels like the *most* testable thing a criterion could say. State the criterion as the **property** the data must have ("no `versions` row still carries a live sign-up token") and leave the pattern to execution time, where it is derived against the code that produces the values. A criterion only one specific pattern can satisfy is one the filer answered on the implementer's behalf, from outside the code.

## Producers

- `/prd` — net-new epics + sub-issues (clarifying questions up front; single-issue runs certify on create, batches certify after collision edges are wired)
- `/spec` — grooms existing/Triage issues into shape (research → interview → signoff → certify)
- `/reflect` — a **trusted-pipeline carve-out**, not an instance of the quality bar above: auto-filed proposals certify by pipeline provenance (the adversarial verify + triage gate in `skills/reflect/SKILL.md`), not by the interview. Their body still carries problem (the observation), outcome (the ready-to-paste diff — for a config/doc edit, the diff *is* the desired outcome, not deferred implementation planning), and criteria (the checkboxes); the quality bar's template and no-implementation-planning items govern the `/prd` and `/spec` paths.
- `/quality-review` — files severity-carrying deferred items only (Critical/High/Medium), whose bodies it composes in the certifiable problem/outcome/criteria shape; its Nice-to-Have lane never files
