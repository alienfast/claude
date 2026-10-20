---
name: spec
description: Groom a Linear issue into a certified spec — research, interview the user, rewrite the description in the canonical shape, attach `specified` (the /auto pickup gate). No args surfaces the uncertified roster to pick from; a "Decide X" issue takes the decision-grade path. Interactive-only. Use when the user says 'spec', 'spec next', 'groom this issue', 'certify PL-XX', 'debate this decision issue', or invokes /spec.
argument-hint: "[ISSUE-ID]"
---

# Spec (Certify an Issue)

Turns a rough human-entered issue into a **certified spec** and marks it `specified` — the label that makes it eligible
for `/next specified` and autonomous `/auto` pickup. The certification contract, canonical template, and quality bar
live in [standards/issue-spec.md](../../standards/issue-spec.md) — read it before grooming.

**Boundary:** `/spec` designs the WHAT — problem, desired outcome, success criteria, scope. Never the HOW.
Implementation planning is `/start` Step 6's job, in plan mode, at execution time. A spec that prescribes implementation
duplicates that step and constrains it with stale assumptions.

## Interactive-only — refuse autonomous contexts

`/spec` interviews a human and requires signoff (Step 5); there is no autonomous mode. Invoked with an `auto` token, or
from an unattended context with no user to interview, stop immediately: `ERROR: /spec is interactive-only — it needs a
human for the interview and signoff. Run it directly.` `/auto` never dispatches `/spec`; its NO-CANDIDATES message only
*suggests* a human run it.

## When to Use

- `/auto` reported `NO-CANDIDATES … Run /spec to certify backlog issues`
- A human filed a rough issue that should become agent-buildable
- Processing the Triage inbox (grooming doubles as triage acceptance)
- Re-grooming an issue whose scope shifted since certification

## Arguments

```text
/spec [ISSUE-ID]
```

- *(none)* → **pick mode** (Step 1): present the top uncertified issues; the user chooses.
- `ISSUE-ID` → groom that issue directly (start at Step 2).

Error on any other token (including `auto` — see above).

## Workflow

### Step 1: Pick mode — surface uncertified candidates (no-arg form)

Read [references/pick-mode.md](references/pick-mode.md) and follow it: team scope resolves mechanically as in `/next`
(never ask which team); the roster comes from `next-candidates.sh --exclude-label specified --include-triage
--include-blocked`, plus a `--label 'needs decision'` run for parked issues; it is presented as **three stage buckets in
fixed order — Planned, Backlog, Triage — never one mixed list**, each bucket a numbered `ID — title — why it ranks`
list with its parked issues beneath it and an empty bucket rendered as its one-line proof; AskUserQuestion offers
options from the **first non-empty bucket only**, recommendation on top — a Backlog blocker of a Planned candidate
renders inside the Planned bucket as the one exception; all three empty → `Everything workable is already certified.`
and stop.

### Step 2: Claim, then research

1. **The issue itself:**

   ```bash
   ~/.claude/scripts/linear-context.sh <ID>          # digest: desc + deps + standalone AND anchored comments
   linear-cli issues get <ID> -o json -q             # raw .description for round-tripping; note .state.name, labels, .assignee
   ```

   The digest is for reading (anchored reviewer comments are invisible to plain `issues get` — linear skill gotcha #1);
   the raw `.description` is what Step 4 preserves verbatim.

   **Claim for the interview's duration.** When `.assignee` is empty, `linear-cli issues assign <ID> me` — **not**
   `issues update <ID> --assignee me`, which prints success at exit 0 whether or not the field was written (linear
   gotcha #8); `assign` echoes the server's resulting assignee. **Confirm `.assignee` on a fresh `issues get
   --no-cache` before interviewing**; still empty means re-issue it. Assignment is a claim
   (`standards/linear-workflow.md`): it hides the issue from **other people's** rankings — not from a sibling session
   sharing this Linear identity, where `next-candidates.sh` keeps an assigned-to-me issue at tier 1 — so in a fleet
   window re-grooming a `specified` issue *raises* its pick rank; wire `needs decision` or work it outside the window.
   Step 6 item 8 restores the pre-groom state, and every earlier exit restores it too (Error Handling). An issue already
   assigned to someone else is never touched — groom it without cycling their claim.
2. **Related work:** `linear-cli search issues "<keywords>"` (workspace-wide — no `--team` flag) for duplicates and
   overlap; `~/.claude/scripts/linear-deps-graph.sh <ID>` for blockers and parent context.
3. **Classify before dispatching research.** The issue is **decision-grade** when its deliverable is a decision rather
   than a buildable spec: the title or a "Decision needed" section asks a question ("Decide …"), two-plus candidate
   designs are named, an authorization or policy surface is in play, or other issues block on the answer. Read
   [references/decision-grade.md](references/decision-grade.md) and run its deltas over Steps 2–6 — starting with the
   deeper `architect` dispatch that replaces item 4. Everything else proceeds unchanged.
4. **Codebase context** — delegate one read-only exploration to ground the interview in current behavior:

   ```text
   Task for Explore agent: Given this issue summary <title + description>,
   identify current behavior, the user-facing surface it touches, and existing
   related mechanisms in the codebase. Do NOT propose an implementation
   approach, file-by-file plan, or technical design — return observations only:
   what exists today, where, and what the issue's problem statement corresponds
   to in the product.
   ```

5. **A moved gate, on both paths.** When the issue moves who may set a gating state (a confirmation, an approval, a
   ratification) to a new role, the research also enumerates every predicate that **reads** that state and what each
   grants the new setter, and every path that reverses the state and whether the new setter's mistake can be undone.
   The old setter's check may have been the only one between two capabilities the new setter already half-holds. Each
   grant the issue does not already intend, and each missing reversal, goes to the interview as a question in product
   terms, and the answer is written into the spec — otherwise it surfaces at review, after a green implementation.

### Step 3: Interview the user

**Issue brief first — the user answers from your summary, never from a Linear tab.** Immediately before the first
AskUserQuestion — directly above the dialog, not behind research narration — emit a compact brief: `<ID> — <title>`;
state / priority / estimate / labels; a 2–4 sentence digest of the description as filed; anything load-bearing from the
comments; the research findings that reframe the request.

Then elicit what the quality bar needs: problem + who's affected, desired outcome, success criteria, scope boundaries
(at least one explicit exclusion — deliverable exclusions; a mechanism-exclusion only to record containment the human
chose, marked `(decided: <who/why>)`, and none when the root cause is undiagnosed; add missing markings while regrooming
— `standards/issue-spec.md` § Out of Scope bounds the deliverable, never the evidence), priority. Do NOT ask about the
estimate — recommend one and apply it; a volunteered estimate still wins.

- **Walk the `### Nice to Have` list explicitly before certifying** — the tier is a brainstorm surface, and grooming is
  its one promotion moment. For each line offer: promote to `### Must Have`, keep (implemented only if it falls out
  easily, never deferred or filed), or delete. Batch into the existing dialogs; offer the interview's own brainstormed
  angles as *new* lines. A kept line certifies as non-binding color.
- Use AskUserQuestion with batched questions and **pre-filled drafts as options** — the user corrects rather than
  authors.
- **Recommend, don't menu.** Every question with a defensible default leads with a "(Recommended)" option stating why it
  fits this codebase and product. An option set you cannot rank is the signal to research more, not to ask anyway.
- Each dialog stands alone: restate the sliver of context the decision needs rather than assuming the brief is still on
  screen.
- Skip what the issue + research already answer confidently — confirm, don't re-ask. Iterate until every quality-bar
  item can be checked honestly.

**The bar is decisiveness — the spec's consumer is an unattended session that cannot ask anything.** Every judgment call
the implementation will face is either answered or explicitly excluded. When the interview surfaces an open question,
do not certify around it — route by what is missing:

- **Continue the interview** until the spec is decisive — the default; most gaps close with one more batched question.
- **A named human decision the user is not ready to make** → finish the spec, certify, and park it:
  `~/.claude/scripts/linear-add-label.sh <ID> 'needs decision'` plus a comment naming the pending decision (Step 6 item
  5 has the ordering).
- **The work turns out human-performed** with no agent-shippable slice → apply `human` instead and skip certification.
- **Mixed — human acts embedded in otherwise agent-shippable work** (a console action, a dashboard change, a
  ratification) → never label the whole issue; shrink the human surface. **Split**: the agent-shippable slice becomes
  its own certified issue and the human act reduces to a named prerequisite or checklist item — often not an issue at
  all. **Shrink in place**: when the human act *is* the core, re-shape it so agents prepare and the human ratifies. This
  is the receiving end of `/auto-prep`'s "flag it for `/spec` to split at the handoff."

  **Carve-out: a human act that gates whether the shipped code works in production is always its own tracked issue** —
  an operator-set secret or env var, a vendor-console setting, a DNS or webhook registration. "Often not an issue at
  all" covers a gate on the *agent's* progress, never on the *product's*: when the spec legitimately requires clean
  degradation, every downstream gate reads green while the feature sits dark in production. File it `human` at
  certification (the label records the executor, not spec quality) and place it in `Planned` via Step 6 item 2's
  `--allow-planned`, which this interactive run may use — a `human` issue there keeps the column from reading drained
  and is what `/auto-prep`'s release-scope audit reports. Its edges follow the `human` carve-out in
  `standards/issue-spec.md` § Certification includes collision edges: `related` when the dependent merely goes dark
  without the act, `blocks` from the `human` issue when the dependent's shipped behavior would be wrong without it, and
  the reverse — the agent issue `blocks` the `human` one — when the act is performed on what the agent ships (a
  hand-deploy after the merge).

An indecisive spec certified anyway does not ship — it burns an `/auto` slot and comes back as a skip or a review block.

### Step 4: Draft the spec

Write `tmp/spec-<id-lowercase>.md` in the canonical template shape ([standards/issue-spec.md](../../standards/issue-spec.md)).
Its Problem is the story the interview surfaced — the named actor, what they saw, the stake in their units, then the
mechanism — with the measurements it does not carry under `## Evidence` (that standard's § The Problem is a story).
Append the original human text verbatim as a trailing `## Original request` blockquote (from the raw description in
Step 2); omit it only when the original is empty or already spec-shaped (re-grooming a `/prd` body — edit in place). A
criterion that describes behavior names the layer that pins it — the drafter's call from Step 2's code read, never an
interview question. Self-check against the quality bar before presenting.

### Step 5: Signoff — implicit when the draft only codifies the interview

Show the user the full draft either way — it is about to overwrite the Linear description and must be visible in chat
before it lands. Whether to *ask* is what graduates:

- **Faithful codification → no approval prompt.** If every substantive element — problem, outcome, each criterion, each
  exclusion, priority — traces to an interview answer, to the issue's own description and comments, or to template
  boilerplate, the interview already WAS the approval (the estimate is exempt: recommended, never elicited). State in one
  line that the draft codifies the interview unchanged, present it, proceed to Step 6.
- **Material divergence → explicit approval, asked on the delta.** If the draft carries anything the interview never put
  to the user — a research-driven reframing, a criterion or exclusion you authored, a scope change discovered after
  their answers — lead with that delta, then iterate until they explicitly approve. No approval → release the claim and
  stop; nothing beyond Step 2's temporary claim has been written.

Cheapest way to stay on the first branch: fold anything drafting surfaces into a final interview batch as pre-filled
options rather than carrying it silently into the draft.

### Step 6: Apply to Linear (order matters)

1. **Description** — if the interview ran long, re-fetch the raw description first with
   `linear-cli issues get <ID> -o json -q --no-cache` (a stale cached copy would silently "confirm" a concurrent human
   edit, and the next command would clobber it) and reconcile any conflict. Then:

   ```bash
   ~/.claude/scripts/linear-post.sh description <ID> tmp/spec-<id-lowercase>.md
   ```

2. **Sub-issues** (only if the quality bar's sizing check failed — epic-sized work): offer a breakdown; for each child
   Write a spec-shaped body to `tmp/`, then:

   ```bash
   ~/.claude/scripts/linear-create-child.sh --allow-planned --allow-unrouted <ID> <TEAM> Planned "<title>" <body-file>   # Planned is deliberate here (interactive); item 5 certifies each child afterwards
   linear-cli relations add <BLOCKER> <BLOCKED> -r blocks     # blocker FIRST (-r blocked-by 400s — linear gotcha #10)
   ~/.claude/scripts/linear-add-label.sh <ID> epic            # the groomed issue is now a delegated epic — its children carry the work
   ```

   Each child is certified too (item 5 applies to every created issue).
3. **Metadata** from the interview, only what changed: `linear-cli issues update <ID> -p <priority> -e <estimate>`.
4. **State:** if — and only if — the issue is in `Triage`, move it: `linear-cli issues update <ID> -s Planned` (grooming
   is triage acceptance). **Blocker promotion:** a `Backlog` issue picked from the Planned bucket's `blocks
   <Planned-ID>` annotation moves to `Planned` the same way — the user's pick is the approval. Never touch any other
   state — assignment and In Progress belong to `/start`; the one exception is the decision-grade close to `Done`
   ([references/decision-grade.md](references/decision-grade.md)).
5. **Certify:**

   ```bash
   ~/.claude/scripts/linear-add-label.sh <ID> specified
   ~/.claude/scripts/linear-remove-label.sh <ID> 'needs decision'
   ```

   Read-merge-set — never a bare `issues update -l`, which replaces the whole label set. Exit 2 on the add → the spec
   landed but the issue is **not** certified: surface the helper's pointer, report certification incomplete, skip items
   6–7. The removal is a no-op when the label is absent; when present, this certification is what clears it. The one
   exception: when this run is what parked the issue (Step 3), skip the removal and instead apply the label — with its
   naming comment — right after `specified` attaches.

   **Tier:** when the certified spec meets the `simple` semantics (`standards/issue-spec.md` § The `simple` label —
   risk-low, no open decision; effort does not matter), also `linear-add-label.sh <ID> simple` and say so in item 7's
   comment. Never on a `security`, `human`, `needs decision`, or `epic` issue — so never in a run that parked the issue
   or made it an epic; in doubt leave it off (`/auto-prep` re-audits both directions). Exit 2 on this add is
   inconclusive (linear gotcha #17), affects only the review tier, and never skips items 6–7.
6. **Collision edges — wire them now; prose is not a control.** Certification makes the issue pickable, and grooming is
   the moment its touched files and methods are actually known (Step 2 just read the code) — the last reliable point to
   make sequencing mechanical. Check the issue (and every sub-issue just created) against other open issues touching
   the same code — including issues certified earlier in the same session, the commonest colliders — and run 2–3
   `linear-cli search issues "<token>"` probes on the change's most distinctive single tokens (method or predicate
   names, distinctive basenames; for a generic basename like `SKILL.md`, `CLAUDE.md` or `README.md` substitute the
   skill's directory name, the full repo-relative path of a nested file, or the project name), one token per call, never
   a composed phrase (matches are contiguous substrings), and read the non-terminal hits for file overlap. Calibrate per
   [standards/issue-spec.md](../../standards/issue-spec.md) § Certification includes collision edges — `blocks` only for a
   prerequisite, a same-method collision (both edits in one region of a function body; disjoint branches are `related`,
   an edit every branch runs under collides with each), or a deliberate increment, blocker first (no discernible order →
   the earlier/already-open one); `related` plus a comment for a shared file, spec, locale, config, or mechanism; nothing
   for no overlap; never `blocks` behind an uncertified, `needs decision`, or `solo` collider. For a `blocks` edge, verify
   it took (`linear-cli relations list <BLOCKED>`) and confirm the blocked issue no longer appears in
   `next-candidates.sh` output run with a generous `--limit` (the default is 3, so absence at the default can be
   truncation; a `solo` label alone also hides an issue there). A `related` edge changes no ranking, so that check does
   not apply. Report blocker status with the ranking's semantics: a blocker in `Done`, `Canceled`, `Duplicate`, or
   `Ready for Release` (`TERMINAL_STATES`, case-insensitive) is RESOLVED, whatever Linear's UI shows.

   A constraint recorded only in prose is invisible to automation — `next-candidates.sh` reads relations and labels,
   never text — so two colliding certified issues WILL be picked concurrently unless the edge exists. Wire it
   immediately after item 5; the standard's accepted residual window is seconds, not a step to defer.
7. **Certification comment** (only after the label attached): Write a short body to `tmp/spec-comment-<id-lowercase>.md`
   — certified via `/spec`, one-line scope summary, sub-issues created (if any), original request preserved — then:

   ```bash
   ~/.claude/scripts/linear-post.sh comment <ID> tmp/spec-comment-<id-lowercase>.md
   ```

8. **Release the claim:** if Step 2 claimed a previously-unassigned issue, restore that state —
   `linear-cli issues assign <ID>` (the bare form unassigns, linear gotcha #4). Certification is the handoff to
   unattended pickup, and the released claim is part of it: an assignment left behind reads as a person's in-flight
   work and hides the issue from every teammate's ranking. An issue that carried an assignee before grooming keeps it.

### Step 7: Report and continue

Compact summary: what was rewritten, state moved (Triage → Planned, or a Backlog blocker promoted), label applied,
collision edges wired, sub-issues created, the temporary claim released — and the handoff line: *eligible for
`/next specified` and `/auto` pickup*. In pick mode, re-run the roster and re-render all three buckets for every
subsequent pick, announcing a drained bucket as its own milestone line (`references/pick-mode.md` § After each
certification). Stop when the user is done.

## What /spec must NOT do

- **No implementation planning** — no technical approach, no code plan, no key-file lists, no verification-command
  blocks. `/start` Step 6 (plan mode) owns all of that.
- **No persistent claiming** — no In Progress, no branch creation, no code edits beyond the committed decision-comment
  rewrite (`references/decision-grade.md` § Output), and no assignment that outlives the grooming: Step 2's temporary
  claim is the one assignment it makes, and every exit path releases it.
- **No certification without signoff** — Step 5's approval is implicit only for a draft that purely codifies the
  interview; a spec carrying material the user never saw never gets the label.
- **No undisposed exits** — every run ends with the issue certified (optionally parked `needs decision`), labeled
  `human` and left uncertified, closed `Done` (decision-grade), or restored to its pre-groom state with the claim
  released. Stopping to ask permission for a state move this skill's own path prescribes is an undisposed exit, not
  caution.

## Error Handling

- **Issue not found / linear-cli failure** → surface the error verbatim and stop.
- **Any exit after Step 2's claim that never reaches Step 6 item 8** — signoff withheld, an error below, the work turning
  out `human`, the user moving on — release the claim before stopping (`linear-cli issues assign <ID>`): a dangling
  assignment hides the issue from teammates' rankings indefinitely.
- **`linear-add-label.sh` exit 2** → the spec landed but the issue is NOT certified; give the
  `linear-cli labels create "specified" -t issue` pointer and stop before the collision step and the comment.
- **Explore agent unavailable** → proceed on Linear context alone and say so before the interview.
- **`linear-cli auth status` logged out** → prompt: `linear-cli auth oauth`.
