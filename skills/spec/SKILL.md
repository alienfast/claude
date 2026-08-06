---
name: spec
description: Groom a Linear issue into a certified spec — research the issue and codebase context, interview the user for problem/outcomes/success criteria, rewrite the description in the canonical spec shape, and graduate it with the `specified` label that gates autonomous /auto pickup. With no args, surfaces the top-ranked uncertified issues (including the Triage inbox) to pick from. Interactive-only — never runs unattended. Use when the user says 'spec', 'spec next', 'groom this issue', 'certify PL-XX', 'spec the backlog', or invokes /spec.
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

Same ranking as `/next` — so the issues `/auto` would want next are certified first — plus the **Triage inbox**, which is precisely what grooming targets (unlike `/next`, where Triage is never workable). Blocked issues are included deliberately too: certifying a spec before its blocker resolves builds runway `/auto` can pick up the moment it unblocks. The ranking still favors triaged work, though — inbox items usually carry no priority or class label, so they land near the bottom of the fallback tier; raise `--limit` when processing a large inbox.

Issues parked behind a human decision keep `specified` plus a `needs decision` label (`standards/issue-spec.md`), so the exclude filter above hides them — list them with a second invocation:

```bash
~/.claude/scripts/next-candidates.sh --label 'needs decision' --include-blocked --limit 10
```

Present any hits as a separate **awaiting a decision** group alongside the uncertified list: grooming one means making and recording the decision in the interview, after which certification clears the label (Step 6 item 5). Present the roster as text first — one line per candidate, `ID — title`, plus a clause on why it ranks (tier, priority, Triage inbox, blocked-but-certifiable) — then AskUserQuestion with the top candidates as options: issue ID as the label, title + gist as the description. The dialog is where the user decides, so it must be legible on its own — a bare-ID option list sends them to Linear to find out what they're choosing. Both lists empty → `Everything workable is already certified.` and stop.

### Step 2: Research (read-only)

1. **The issue itself:**

   ```bash
   ~/.claude/scripts/linear-context.sh <ID>          # digest: desc + deps + standalone AND anchored comments
   linear-cli issues get <ID> -o json -q             # raw .description for round-tripping; note .state.name and labels
   ```

   The digest is for reading (anchored reviewer comments are invisible to plain `issues get` — linear skill gotcha #1); the raw `.description` is what gets preserved verbatim in Step 4.
2. **Related work:** `linear-cli search issues "<keywords>"` (workspace-wide — no `--team` flag) for duplicates/overlap; `~/.claude/scripts/linear-deps-graph.sh <ID>` for blockers and parent context.
3. **Codebase context** — delegate one read-only exploration to ground the interview in current behavior:

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

Then elicit what the quality bar needs: problem + who's affected, desired outcome, success criteria, scope boundaries (at least one explicit exclusion), priority, estimate.

- Use AskUserQuestion with batched questions and **pre-filled drafts as options** — the user corrects rather than authors.
- Each dialog stands alone: a later batch may arrive long after the brief scrolled by, so restate in the question text the sliver of context that decision needs (what the trade-off is, what the draft currently says) rather than assuming the brief is still on screen.
- Skip what the issue + research already answer confidently — confirm, don't re-ask.
- Iterate until every quality-bar item can be checked honestly.

**Decisive for autonomous processing is the bar — the spec's consumer is an unattended session that cannot ask anything.** "Groomed" means every judgment call the implementation will face is either answered in the spec or explicitly excluded. When the interview surfaces an open question, do not certify around it — route by what is missing:

- **Continue the interview** until the spec is decisive — the default; most gaps close with one more batched question.
- **A named human decision the user is not ready to make** → finish the spec, certify, and park it: `~/.claude/scripts/linear-add-label.sh <ID> 'needs decision'` plus a comment naming the pending decision (the certified-but-parked state from `standards/issue-spec.md`, hidden from every ranking until the label clears — see Step 6 item 5 for the ordering).
- **The work turns out human-performed** with no agent-shippable slice → apply the `human` label instead and skip certification.

An indecisive spec certified anyway does not ship — it burns an `/auto` slot and comes back as a skip or a review block.

### Step 4: Draft the spec

Write `tmp/spec-<id-lowercase>.md` in the canonical template shape ([standards/issue-spec.md](../../standards/issue-spec.md)). Append the original human text verbatim as a trailing `## Original request` blockquote (from the raw description captured in Step 2). Omit that section only when the original description is empty or already spec-shaped (e.g. re-grooming a `/prd`-created body — edit in place instead of quoting). Self-check against the quality bar before presenting.

### Step 5: Signoff — implicit when the draft only codifies the interview

Show the user the full draft either way — it is the artifact about to overwrite the Linear description, and it must be visible in chat before it lands. Whether to *ask* is what graduates:

- **Faithful codification → no approval prompt.** If every substantive element of the draft — problem, outcome, each success criterion, each scope exclusion, priority, estimate — traces to an interview answer the user gave or corrected, to the issue's own description and comments, or to template boilerplate, the interview already WAS the approval. Asking again re-asks settled questions. State in one line that the draft codifies the interview answers unchanged, present it, and proceed directly to Step 6.
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
4. **State:** if — and only if — the issue is in `Triage`, move it: `linear-cli issues update <ID> -s Planned` (grooming is triage acceptance). Never touch any other state; assignment and In Progress belong to `/start`.
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

Compact summary: what was rewritten, Triage → Planned (if moved), label applied, collision edges wired (if any), sub-issues created — and the handoff line: *eligible for `/next specified` and `/auto` pickup*. In pick mode, offer the next uncertified candidate; stop when the user is done.

## What /spec must NOT do

- **No implementation planning** — no technical approach, no step-by-step code plan, no key-file lists, no verification-command blocks. `/start` Step 6 (plan mode) owns all of that.
- **No claiming** — no assignment, no In Progress, no branch creation, no code edits.
- **No certification without signoff** — Step 5's approval is implicit only for a draft that purely codifies the interview answers; a spec carrying material the user never saw or approved never gets the label.

## Error Handling

- **Issue not found / linear-cli failure** → surface the error verbatim and stop.
- **`linear-add-label.sh` exit 2** → the spec landed but the issue is NOT certified; give the `linear-cli labels create "specified" -t issue` pointer and stop before the collision step and the comment.
- **Explore agent unavailable** → proceed on Linear context alone and say so before the interview.
- **`linear-cli auth status` logged out** → prompt: `linear-cli auth oauth`.
