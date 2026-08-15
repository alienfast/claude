---
name: spec
description: Groom a Linear issue into a certified spec — research the issue and codebase context, interview the user for problem/outcomes/success criteria, rewrite the description in the canonical spec shape, and graduate it with the `specified` label that gates autonomous /auto pickup. Decision-shaped issues ("Decide X") take the decision-grade path instead — architect-backed research, a debate brief with recommendations, a recorded decision, and filed follow-ups rather than certification. With no args, surfaces the top-ranked uncertified issues (including the Triage inbox) to pick from. Interactive-only — never runs unattended. Use when the user says 'spec', 'spec next', 'groom this issue', 'certify PL-XX', 'spec the backlog', 'debate this decision issue', or invokes /spec.
argument-hint: "[ISSUE-ID]"
---

# Spec (Certify an Issue)

Turns a rough human-entered issue into a **certified spec** and marks it `specified` — the label that makes it eligible for `/next specified` and autonomous `/auto` pickup. The certification contract, canonical template, and quality bar live in [standards/issue-spec.md](../../standards/issue-spec.md) — read it before grooming.

**Boundary:** `/spec` designs the WHAT — problem, desired outcome, success criteria, scope. Never the HOW. Implementation planning (technical approach, file lists, step-by-step design) is `/start` Step 6's job, in plan mode, at execution time. A spec that prescribes implementation both duplicates that step and constrains it with stale assumptions.

## Interactive-only — refuse autonomous contexts

`/spec` interviews a human and requires signoff (Step 5 — implicit for a purely-codifying draft, explicit on divergence); there is no autonomous mode. If invoked with an `auto` token, or from an unattended context with no user to interview, stop immediately: `ERROR: /spec is interactive-only — it needs a human for the interview and signoff. Run it directly.` `/auto` never dispatches `/spec`; its NO-CANDIDATES message only *suggests* a human run it.

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

Team scope resolves mechanically, exactly like `/next` Step 2: `$LINEAR_TEAM` if exported (single key or comma list), else omit `--team` and the script searches every team in the workspace — never ask which team. A user who explicitly names a team is the one exception (`--team <KEY>`). Run:

```bash
~/.claude/scripts/next-candidates.sh --exclude-label specified --include-triage --include-blocked --limit 10
```

Same ranking as `/next` — so its hard gates hold here too: an issue **assigned to anyone else is never offered for grooming** (assignment is a claim — `standards/linear-workflow.md`; the script hides them and appends a hidden-count note, surfaced verbatim). The ranking is a **strict stage order** (keeper decision 2026-08-13): every Planned/Todo issue outranks every Backlog issue, which outranks the entire **Triage inbox**, priority and class notwithstanding — an Urgent inbox report never outranks an unprioritized Planned issue (BF-34 did exactly that under the old stage tie and got recommended over the Planned queue the keeper was draining). Triage is included at all (unlike `/next`, where it is never workable) because grooming is what drains it — but only ever last. Blocked issues are included deliberately too: certifying a spec before its blocker resolves builds runway `/auto` can pick up the moment it unblocks. The **Planned/Todo queue is exhaustive by construction**: `next-candidates.sh` never hides unstarted-stage candidates behind the `--limit` cut — every below-cut Planned/Todo issue is appended in a trailing **"Planned/Todo below the cut"** section (keeper policy 2026-08-12). Treat that section's issues as full roster members. The limit trims only the Backlog/Triage tail; raise it when processing a large inbox.

Issues parked behind a human decision keep `specified` plus a `needs decision` label (`standards/issue-spec.md`), so the exclude filter above hides them — list them with a second invocation:

```bash
~/.claude/scripts/next-candidates.sh --label 'needs decision' --include-blocked --limit 10
```

**Present the roster as three stage buckets in this fixed order — Planned, Backlog, Triage — never one mixed list** (keeper priority 2026-08-13: certify ALL of Planned first, then all of Backlog, and look at the inbox only once both are empty — the buckets exist so the user can SEE that a stage is drained). Bucket membership comes from each entry's `State:` line. Each bucket renders as its own numbered list — one line per candidate, `ID — title`, plus a clause on why it ranks (tier, priority, blocked-but-certifiable), never a prose paragraph — with that bucket's parked (`needs decision`) issues directly beneath it in the SAME rendering (measured 2026-08-12: parked Planned issues compressed into a prose sentence were missed and re-asked; a parked issue is part of draining its bucket — grooming one means making and recording the decision in the interview, after which certification clears the label, Step 6 item 5). An empty bucket still renders, as its one-line proof — `Planned: fully certified, nothing parked.` — because showing a stage is drained is half the roster's job. Then AskUserQuestion with options drawn from the **first non-empty bucket only**, top-ranked first, the recommendation its top item — parked issues included as options when they outrank the uncertified ones. Never offer or recommend a Backlog issue while the Planned bucket holds any candidate (uncertified or parked), nor a Triage issue while either earlier bucket does; `Other` already covers a deliberate out-of-order pick. **One exception, and it renders inside the Planned bucket:** a Backlog issue that BLOCKS a Planned candidate is Planned work in waiting — when a Planned candidate shows unresolved blockers, resolve them (`~/.claude/scripts/linear-deps-graph.sh <ID>`) and list any Backlog blocker in the Planned bucket annotated `Backlog — blocks <Planned-ID>`, fully eligible as an option; certifying it includes promoting it to Planned (Step 6 item 4's blocker-promotion clause). The dialog is where the user decides, so it must be legible on its own — a bare-ID option list sends them to Linear to find out what they're choosing. All three buckets empty → `Everything workable is already certified.` and stop.

### Step 2: Research (read-only)

1. **The issue itself:**

   ```bash
   ~/.claude/scripts/linear-context.sh <ID>          # digest: desc + deps + standalone AND anchored comments
   linear-cli issues get <ID> -o json -q             # raw .description for round-tripping; note .state.name and labels
   ```

   The digest is for reading (anchored reviewer comments are invisible to plain `issues get` — linear skill gotcha #1); the raw `.description` is what gets preserved verbatim in Step 4.
2. **Related work:** `linear-cli search issues "<keywords>"` (workspace-wide — no `--team` flag) for duplicates/overlap; `~/.claude/scripts/linear-deps-graph.sh <ID>` for blockers and parent context.
3. **Classify before dispatching research.** The issue is **decision-grade** when its deliverable is a decision rather than a buildable spec: the title or a "Decision needed" section asks a question ("Decide …"), two-plus candidate designs are named, an authorization/policy surface is in play, or other issues block on the answer. Decision-grade grooming runs the deltas in [Decision-grade issues](#decision-grade-issues) over Steps 2–6 — starting with the deeper `architect` dispatch replacing item 4 below. Everything else proceeds unchanged.
4. **Codebase context** — delegate one read-only exploration to ground the interview in current behavior:

   ```text
   Task for Explore agent: Given this issue summary <title + description>,
   identify current behavior, the user-facing surface it touches, and existing
   related mechanisms in the codebase. Do NOT propose an implementation
   approach, file-by-file plan, or technical design — return observations only:
   what exists today, where, and what the issue's problem statement corresponds
   to in the product.
   ```

### Step 3: Interview the user

**Issue brief first — the user answers from your summary, never from a Linear tab.** Immediately before the first AskUserQuestion — so it sits directly above the dialog, not scrolled away behind research narration — emit a compact brief: `<ID> — <title>`; state / priority / estimate / labels; a 2–4 sentence digest of the description as filed (what's being asked and why); anything load-bearing from the comments; and the research findings that reframe the request (current behavior, related issues). This is the recurring failure the brief exists to prevent: interview questions arriving unanchored, and the user opening Linear mid-interview to work out what issue they're even deciding about.

Then elicit what the quality bar needs: problem + who's affected, desired outcome, success criteria, scope boundaries (at least one explicit exclusion), priority. Do NOT ask about the estimate — recommend one and apply it without a question (keeper direction 2026-08-13: always fine with the recommendation; the field stays on the issue but is not otherwise tracked). A volunteered estimate still wins over the recommendation.

- **Walk the `### Nice to Have` list explicitly before certifying** — the tier is a brainstorm surface (`standards/issue-spec.md`: target of opportunity, not a requirement), and grooming is its one promotion moment. For each line, offer: promote to `### Must Have` (it turned out to matter), keep as Nice to Have (a genuine target of opportunity — implemented only if it falls out easily, never deferred or filed), or delete (brainstorm that didn't earn its keep). Batch this into the interview's existing dialogs; also offer the interview's own brainstormed angles as *new* Nice to Have lines — that is the tier's purpose. A kept line certifies as non-binding color: the unattended session plans around it only when trivially in-path.
- Use AskUserQuestion with batched questions and **pre-filled drafts as options** — the user corrects rather than authors.
- **Recommend, don't menu.** Every question with a defensible default leads with a "(Recommended)" option stating the reason it fits this codebase and product — the user corrects a stance rather than adjudicating an unweighted list. An option set you cannot rank is the signal to research more, not to ask anyway.
- Each dialog stands alone: a later batch may arrive long after the brief scrolled by, so restate in the question text the sliver of context that decision needs (what the trade-off is, what the draft currently says) rather than assuming the brief is still on screen.
- Skip what the issue + research already answer confidently — confirm, don't re-ask.
- Iterate until every quality-bar item can be checked honestly.

**Decisive for autonomous processing is the bar — the spec's consumer is an unattended session that cannot ask anything.** "Groomed" means every judgment call the implementation will face is either answered in the spec or explicitly excluded. When the interview surfaces an open question, do not certify around it — route by what is missing:

- **Continue the interview** until the spec is decisive — the default; most gaps close with one more batched question.
- **A named human decision the user is not ready to make** → finish the spec, certify, and park it: `~/.claude/scripts/linear-add-label.sh <ID> 'needs decision'` plus a comment naming the pending decision (the certified-but-parked state from `standards/issue-spec.md`, hidden from every ranking until the label clears — see Step 6 item 5 for the ordering).
- **The work turns out human-performed** with no agent-shippable slice → apply the `human` label instead and skip certification.
- **Mixed — human acts embedded in otherwise agent-shippable work** (a console action, a dashboard change, a ratification) → never label the whole issue; shrink the human surface, by whichever fits. **Split**: the agent-shippable slice becomes its own certified issue and the human act reduces to a named prerequisite or checklist item — often not an issue at all (BF-858's gate was a two-minute console probe, and parking the whole issue cost 21 verified files 91 commits of drift). **Shrink in place**: when the human act *is* the issue's core, re-shape it so agents prepare and the human ratifies — BF-877's recommend-then-ratify, a prefilled worksheet with deliberation reserved for a named hard set, kept `human` but got an order of magnitude cheaper. This is the receiving end of `/auto-prep`'s "flag it for `/spec` to split at the handoff."

An indecisive spec certified anyway does not ship — it burns an `/auto` slot and comes back as a skip or a review block.

### Step 4: Draft the spec

Write `tmp/spec-<id-lowercase>.md` in the canonical template shape ([standards/issue-spec.md](../../standards/issue-spec.md)). Append the original human text verbatim as a trailing `## Original request` blockquote (from the raw description captured in Step 2). Omit that section only when the original description is empty or already spec-shaped (e.g. re-grooming a `/prd`-created body — edit in place instead of quoting). Self-check against the quality bar before presenting.

### Step 5: Signoff — implicit when the draft only codifies the interview

Show the user the full draft either way — it is the artifact about to overwrite the Linear description, and it must be visible in chat before it lands. Whether to *ask* is what graduates:

- **Faithful codification → no approval prompt.** If every substantive element of the draft — problem, outcome, each success criterion, each scope exclusion, priority — traces to an interview answer the user gave or corrected, to the issue's own description and comments, or to template boilerplate, the interview already WAS the approval. (The estimate is exempt from this trace: it is recommended, never elicited, so it can never block the no-prompt path.) Asking again re-asks settled questions. State in one line that the draft codifies the interview answers unchanged, present it, and proceed directly to Step 6.
- **Material divergence → explicit approval, asked on the delta.** If the draft carries anything the interview never put to the user — a research-driven reframing, a criterion or exclusion you authored rather than they selected, a scope change discovered after their answers — lead with that delta (what is new and why), then iterate until they explicitly approve it. No approval → stop; nothing has been written to Linear.

Cheapest way to stay on the first branch: when drafting surfaces something new, fold it into a final interview batch as pre-filled options (Step 3's correct-don't-author pattern) rather than carrying it silently into the draft.

### Step 6: Apply to Linear (order matters)

1. **Description** — if the interview ran long, re-fetch the raw description first with `linear-cli issues get <ID> -o json -q --no-cache` (bypassing linear-cli's read cache — a stale cached copy would silently "confirm" a concurrent human edit, and the next command would clobber it) and reconcile any conflict rather than overwriting it. Then:

   ```bash
   ~/.claude/scripts/linear-post.sh description <ID> tmp/spec-<id-lowercase>.md
   ```

2. **Sub-issues** (only if the quality bar's sizing check failed — epic-sized work): offer a breakdown; for each child Write a spec-shaped body to `tmp/`, then:

   ```bash
   ~/.claude/scripts/linear-create-child.sh <ID> <TEAM> Planned "<title>" <body-file>
   linear-cli relations add <BLOCKER> <BLOCKED> -r blocks     # blocker FIRST (blocked-by 400s in every published version through 0.3.27)
   ~/.claude/scripts/linear-add-label.sh <ID> epic            # the groomed issue is now a delegated epic — its children carry the work
   ```

   Each child is certified too (item 5 applies to every created issue).
3. **Metadata** from the interview, only what changed: `linear-cli issues update <ID> -p <priority> -e <estimate>`.
4. **State:** if — and only if — the issue is in `Triage`, move it: `linear-cli issues update <ID> -s Planned` (grooming is triage acceptance). **Blocker promotion:** a `Backlog` issue picked from the Planned bucket's `blocks <Planned-ID>` annotation (Step 1's exception) moves to `Planned` the same way — bringing it forward to unblock Planned work is why it was offered, and the user's pick is the approval. Never touch any other state — assignment and In Progress belong to `/start`, and the one exception is the decision-grade close-to-Done defined in [Decision-grade issues](#decision-grade-issues).
5. **Certify:**

   ```bash
   ~/.claude/scripts/linear-add-label.sh <ID> specified
   ~/.claude/scripts/linear-remove-label.sh <ID> 'needs decision'
   ```

   Read-merge-set — never a bare `issues update -l`, which replaces the whole label set. Exit 2 on the add → the spec landed but the issue is **not** certified: surface the helper's pointer, report certification incomplete, and skip items 6–7. The removal is a no-op when the label is absent; when present, this certification is exactly what clears it — the interview recorded the decision the label was waiting on (`standards/issue-spec.md`). The one exception: when this run is what parked the issue (Step 3's decisiveness rule left a named decision open), skip the removal and instead apply the label — with its naming comment — right after `specified` attaches.
6. **Collision edges — wire them now; prose is not a control.** Certification is what makes this issue pickable by `/auto`, and grooming is the moment its touched files/methods are actually known (Step 2 just read the code) — so this is the cheapest and last reliable point to make sequencing mechanical (`/auto-prep` re-derives collisions later from description text alone, and the quality bar keeps file lists out of descriptions). Check the issue (and every sub-issue just created) against other open issues touching the same code — including issues certified earlier in the same session, which are the commonest colliders. Beyond those, run 2–3 `linear-cli search issues "<token>"` probes on the change's most distinctive single tokens — method/predicate names, distinctive file basenames (skip generic ones like `SKILL.md`, `CLAUDE.md`, or `README.md` — substitute a method/predicate token, the skill's directory name, the full repo-relative path of a nested file, or the project name for a project `CLAUDE.md` or a repo-root `README.md`, whose path is just the bare basename), one token per call, never a composed phrase (matches are contiguous substrings) — and read the non-terminal hits for file overlap. Calibration:
   - **Same file or same method** → `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` (blocker = the logically-prior issue; when no order is discernible, the earlier/already-open one). When the collider is uncertified, `needs decision`, or `solo`, use `related` + comment instead — a blocks edge behind a never-unattended-shipping blocker strands this issue (standards/issue-spec.md). For a `blocks` edge, verify it took (`linear-cli relations list <BLOCKED>`) and confirm the blocked issue no longer appears in `~/.claude/scripts/next-candidates.sh` output — run it with a generous `--limit` (the default is 3, so absence at the default limit can be truncation, not blocking — and a `solo` label alone also hides the issue there, independent of any edge); a `related` edge changes no ranking, so that absence check does not apply to it. When reporting blocker status anywhere in this skill, use the ranking's own semantics: a blocker in `Done`, `Canceled`, `Duplicate`, or `Ready for Release` (the script's `TERMINAL_STATES`, matched case-insensitively) is RESOLVED — Linear's UI shows a `blocks` relation as blocking until the issue closes, and repeating that framing misreports shipped blockers as still open.
   - **Disjoint files sharing a mechanism** (a concern or helper both are likely to reach for) → `-r related` plus a comment naming the mechanism; don't serialize speculatively.
   - **No overlap** → no edge.

   A sequencing constraint recorded only in description prose is invisible to automation — `next-candidates.sh` reads relations and labels, never description or comment text — so two colliding certified issues WILL be picked concurrently by a fleet unless the edge exists. Wire it immediately after item 5 certifies — the standard's accepted residual window (standards/issue-spec.md) is seconds long, not a step to defer.
7. **Certification comment** (only after the label attached): Write a short body to `tmp/spec-comment-<id-lowercase>.md` — certified via `/spec`, one-line scope summary, sub-issues created (if any), original request preserved in the description — then:

   ```bash
   ~/.claude/scripts/linear-post.sh comment <ID> tmp/spec-comment-<id-lowercase>.md
   ```

### Step 7: Report and continue

Compact summary: what was rewritten, state moved (Triage → Planned, or a Backlog blocker promoted), label applied, collision edges wired (if any), sub-issues created — and the handoff line: *eligible for `/next specified` and `/auto` pickup*. In pick mode, **re-run Step 1's roster and re-render the full three-bucket presentation for every subsequent pick** — same buckets, same rules each time, so the state of every stage stays visible across the session. When this certification just DRAINED a bucket (nothing uncertified, nothing parked left in it), announce the milestone as its own line before offering anything further — `Planned is fully certified — moving to Backlog.` / `Backlog is fully certified — the Triage inbox is next.` — the milestone is the point of the bucket order, not a footnote. Stop when the user is done.

## Decision-grade issues

The deliverable is a **recorded decision plus filed follow-ups**, not a certified description — running the standard path instead certifies criteria that ask the implementer to decide, which the quality bar forbids. The standard steps still run, with these deltas (worked case: BF-1002, "Decide the backing set for counterparty selection"):

**Research — dispatch `architect` (Fable/max by definition), and interrogate, don't survey.** The generic Explore prompt returns a map too shallow to debate from. Build a structured interrogation from the issue's own claims: quote the gate/predicate bodies verbatim, enumerate every write site of the state in question, schema shapes, the linkage (or its absence) between the tables involved, and who-mints-what. Add `git log --grep <ID>` / `git log -S<symbol>` probes — commit messages are where deferred decisions get recorded (BF-878's commit read "BF-1002 carries that decision"), and prior-decision provenance reframes the debate. Architect unavailable → Explore with the same prompt, and say so.

**Verify the option space before debating it.** The issue's A-vs-B framing is a filing-time reading, not a constraint: check whether an option structurally collapses (BF-1002's "pure global" collapsed into a hybrid because per-tenant relationship data hung off the table it would have replaced) or a third shape dominates both. Reframing the forks is the highest-value move in this path and must happen before the first question.

**Interview — position first, then forks.** Before the first AskUserQuestion, present a debate brief: the reframing facts from research, your position, and the strongest counterargument against it. Then interview only the genuine forks, staged — product intent first, the design consequences of those answers second, residuals third. Step 3's recommend-don't-menu rule is mandatory here: every fork's recommended option cites the code fact it rests on.

**Output — record, file, propagate, close.**

- Record the decision **on the issue**: who decided, when, each question's answer with its rationale — including any invariant the decision *refines*, stated in its refined form (otherwise the next reviewer reads the change as a regression against the old invariant).
- Check off the criteria the record satisfies; a criterion the follow-ups will discharge stays unchecked, with the comment naming which issue carries it.
- File follow-ups in canonical shape; certify only those meeting the bar. One whose requirements cannot yet prescribe behavior (criteria would read "decide X") files **uncertified + `needs decision`** (`standards/issue-spec.md`), never certified around the gap. Wire collision edges per Step 6 item 6 — including against open issues touching the units the follow-ups will extend.
- Close the decision issue `Done` — a decision with no code change rides no release, so `Ready for Release` is wrong for it. This is the one place `/spec` touches state beyond Triage → Planned.

**Propagate to dependents before clearing their gates.** Write the decision into each dependent's *description*, never only a comment (`standards/issue-spec.md`). Before removing `needs decision` from any dependent, re-read its spec for judgment calls the recorded decision does not answer — clearing the label makes a certified issue fleet-pickable, so an unstated scope ships as an unattended agent's invention. The human is present: interview the residual now (BF-879's affiliation read-scope was caught exactly here; one question closed it).

**Session model.** The judgment that pays in this path — catching a residual gate, noticing the option-space collapse — lives in the main loop, which no dispatch upgrades. Suggest `/model claude-fable-5` before a decision-grade grooming when the session is on a lower tier.

## What /spec must NOT do

- **No implementation planning** — no technical approach, no step-by-step code plan, no key-file lists, no verification-command blocks. `/start` Step 6 (plan mode) owns all of that.
- **No claiming** — no assignment, no In Progress, no branch creation, no code edits.
- **No certification without signoff** — Step 5's approval is implicit only for a draft that purely codifies the interview answers; a spec carrying material the user never saw or approved never gets the label.

## Error Handling

- **Issue not found / linear-cli failure** → surface the error verbatim and stop.
- **`linear-add-label.sh` exit 2** → the spec landed but the issue is NOT certified; give the `linear-cli labels create "specified" -t issue` pointer and stop before the collision step and the comment.
- **Explore agent unavailable** → proceed on Linear context alone and say so before the interview.
- **`linear-cli auth status` logged out** → prompt: `linear-cli auth oauth`.
