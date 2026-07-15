---
name: spec
description: Groom a Linear issue into a certified spec — research the issue and codebase context, interview the user for problem/outcomes/success criteria, rewrite the description in the canonical spec shape, and graduate it with the `specified` label that gates autonomous /auto pickup. With no args, surfaces the top-ranked uncertified issues (including the Triage inbox) to pick from. Interactive-only — never runs unattended. Use when the user says 'spec', 'spec next', 'groom this issue', 'certify PL-XX', 'spec the backlog', or invokes /spec.
argument-hint: "[ISSUE-ID]"
---

# Spec (Certify an Issue)

Turns a rough human-entered issue into a **certified spec** and marks it `specified` — the label that makes it eligible for `/next specified` and autonomous `/auto` pickup. The certification contract, canonical template, and quality bar live in [standards/issue-spec.md](../../standards/issue-spec.md) — read it before grooming.

**Boundary:** `/spec` designs the WHAT — problem, desired outcome, success criteria, scope. Never the HOW. Implementation planning (technical approach, file lists, step-by-step design) is `/start` Step 6's job, in plan mode, at execution time. A spec that prescribes implementation both duplicates that step and constrains it with stale assumptions.

## Interactive-only — refuse autonomous contexts

`/spec` interviews a human and requires explicit signoff; there is no autonomous mode. If invoked with an `auto` token, or from an unattended context with no user to interview, stop immediately: `ERROR: /spec is interactive-only — it needs a human for the interview and signoff. Run it directly.` `/auto` never dispatches `/spec`; its NO-CANDIDATES message only *suggests* a human run it.

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

Resolve `<TEAM>` from `$LINEAR_TEAM`, else the current branch's issue prefix, else ask. Run:

```bash
~/.claude/scripts/next-candidates.sh --team <TEAM> --exclude-label specified --include-triage --include-blocked --limit 10
```

Same ranking as `/next` — so the issues `/auto` would want next are certified first — plus the **Triage inbox**, which is precisely what grooming targets (unlike `/next`, where Triage is never workable). Blocked issues are included deliberately too: certifying a spec before its blocker resolves builds runway `/auto` can pick up the moment it unblocks. The ranking still favors cycle/unblocked work, though — Triage-inbox and blocked items rank low, so raise `--limit` when processing a large inbox. Present the ranked list and let the user pick one (AskUserQuestion, top candidates as options). Empty list → `Everything workable is already certified.` and stop.

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

Present the research findings first (current behavior, related issues, anything that reframes the request), then elicit what the quality bar needs: problem + who's affected, desired outcome, success criteria, scope boundaries (at least one explicit exclusion), priority, estimate.

- Use AskUserQuestion with batched questions and **pre-filled drafts as options** — the user corrects rather than authors.
- Skip what the issue + research already answer confidently — confirm, don't re-ask.
- Iterate until every quality-bar item can be checked honestly.

### Step 4: Draft the spec

Write `tmp/spec-<id-lowercase>.md` in the canonical template shape ([standards/issue-spec.md](../../standards/issue-spec.md)). Append the original human text verbatim as a trailing `## Original request` blockquote (from the raw description captured in Step 2). Omit that section only when the original description is empty or already spec-shaped (e.g. re-grooming a `/prd`-created body — edit in place instead of quoting). Self-check against the quality bar before presenting.

### Step 5: Signoff — hard gate

Show the user the full draft. Iterate until they explicitly approve. No approval → stop; nothing has been written to Linear.

### Step 6: Apply to Linear (order matters)

1. **Description** — if the interview ran long, re-fetch the raw description first with `linear-cli issues get <ID> -o json -q --no-cache` (bypassing linear-cli's read cache — a stale cached copy would silently "confirm" a concurrent human edit, and the next command would clobber it) and reconcile any conflict rather than overwriting it. Then:

   ```bash
   ~/.claude/scripts/linear-post.sh description <ID> tmp/spec-<id-lowercase>.md
   ```

2. **Sub-issues** (only if the quality bar's sizing check failed — epic-sized work): offer a breakdown; for each child Write a spec-shaped body to `tmp/`, then:

   ```bash
   ~/.claude/scripts/linear-create-child.sh <ID> <TEAM> Planned "<title>" <body-file>
   linear-cli relations add <BLOCKER> <BLOCKED> -r blocks     # blocker FIRST (blocked-by enum is broken on 0.3.26)
   ```

   Each child is certified too (item 5 applies to every created issue).
3. **Metadata** from the interview, only what changed: `linear-cli issues update <ID> -p <priority> -e <estimate>`.
4. **State:** if — and only if — the issue is in `Triage`, move it: `linear-cli issues update <ID> -s Planned` (grooming is triage acceptance). Never touch any other state; assignment and In Progress belong to `/start`.
5. **Certify:**

   ```bash
   ~/.claude/scripts/linear-add-label.sh <ID> specified
   ```

   Read-merge-set — never a bare `issues update -l`, which replaces the whole label set. Exit 2 → the spec landed but the issue is **not** certified: surface the helper's pointer, report certification incomplete, and skip item 6.
6. **Certification comment** (only after the label attached): Write a short body to `tmp/spec-comment-<id-lowercase>.md` — certified via `/spec`, one-line scope summary, sub-issues created (if any), original request preserved in the description — then:

   ```bash
   ~/.claude/scripts/linear-post.sh comment <ID> tmp/spec-comment-<id-lowercase>.md
   ```

### Step 7: Report and continue

Compact summary: what was rewritten, Triage → Planned (if moved), label applied, sub-issues created — and the handoff line: *eligible for `/next specified` and `/auto` pickup*. In pick mode, offer the next uncertified candidate; stop when the user is done.

## What /spec must NOT do

- **No implementation planning** — no technical approach, no step-by-step code plan, no key-file lists, no verification-command blocks. `/start` Step 6 (plan mode) owns all of that.
- **No claiming** — no assignment, no In Progress, no branch creation, no code edits.
- **No certification without signoff** — Step 5 is a hard gate; a spec the user never approved never gets the label.

## Error Handling

- **Issue not found / linear-cli failure** → surface the error verbatim and stop.
- **`linear-add-label.sh` exit 2** → the spec landed but the issue is NOT certified; give the `linear-cli labels create "specified" -t issue` pointer and stop before the comment.
- **Explore agent unavailable** → proceed on Linear context alone and say so before the interview.
- **`linear-cli auth status` logged out** → prompt: `linear-cli auth oauth`.
