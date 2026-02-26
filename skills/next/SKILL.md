---
name: next
description: Suggest the best next issue to work on. Considers current cycle, dependency graph, triage status, and what's unblocked. Use when the user says 'what's next', 'next issue', or invokes /next.
---

# Next Issue

Suggests the most logical next issue to work on by combining cycle planning, dependency analysis, and triage signals.

## When to Use

- Starting a fresh day/week and unsure where to begin
- After finishing an issue (invoked from `/finish`)
- Deciding between multiple candidate issues

## Workflow

### Step 1: Gather Context

Determine if there's a just-completed issue providing context (e.g., invoked from `/finish` with an issue ID, or a branch name that maps to one). If so, note it as `<COMPLETED-ID>`.

Determine the team key from `.linear.yaml` or the issue prefix.

**Run these commands:**

```bash
# Current cycle — what's been planned and triaged
linear i list --cycle current --team <TEAM> --format compact

# Team dependency graph — full picture of blocking relationships
linear deps --team <TEAM>
```

**If a just-completed issue exists, also run:**

```bash
# What was directly blocked by the completed issue (now unblocked)
linear search --blocked-by <COMPLETED-ID>
```

### Step 2: Identify Candidates

From the cycle list and dependency graph, build a candidate set of issues that are **workable** — meaning:

- State is Todo, Planned, Backlog, or Triage (not Done, Ready For Release, In Progress, or Cancelled)
- All blockers are resolved (in Done/Ready For Release state)
- Not assigned to someone else who is actively working on it

If a just-completed issue exists, also identify **transitively unblocked** issues — not just direct dependents, but issues further down the dependency chain whose last remaining blocker was the completed issue (or was itself unblocked by it).

### Step 3: Rank Candidates

Apply this priority order:

1. **Current cycle + newly unblocked** — Issues in the active cycle that were blocked by the just-completed issue (directly or transitively). Highest signal: planned work that was waiting on you.
2. **Current cycle + ready** — Other cycle issues with no remaining blockers. The cycle plan already determined these should happen now.
3. **Newly unblocked + highest priority** — Issues directly unblocked by the completed issue, ranked by priority (Urgent > High > Normal > Low). Even if not in the cycle, unblocking work has momentum value.
4. **Sibling under same parent** — If the completed issue has a parent, look for sibling issues that are workable. Prefer the next one in dependency order within the parent.
5. **Highest priority workable** — Any remaining workable issue from the backlog, ranked by priority then estimate.

**Tiebreakers within a tier:** higher priority > in current cycle > fewer remaining blockers > lower estimate (quick wins maintain momentum).

**Note:** If there is no just-completed issue (standalone mode), tiers 1, 3, and 4 don't apply — start directly at tier 2 (current cycle, ready) and fall through to tier 5.

### Step 4: Present Suggestion

> **Suggested next issue:** PL-17 — "Payment webhook handler"
> Priority: High | Estimate: 3 points | State: Planned (Cycle 24)
> **Why**: In current cycle, was transitively blocked by PL-14 (now unblocked) — highest-signal next pick.

If a runner-up exists in a different tier, mention it briefly:

> **Also consider:** PL-13 — "Auth proxy" (High, 2 points) — sibling under same parent, unblocked, not yet in cycle.

If no clear next issue exists, say so — don't force a suggestion.

## Error Handling

- If no current cycle exists, skip cycle-based tiers and work from the full backlog
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If the team has no workable issues, say so clearly
