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

**Run all commands as parallel Bash calls — one command per call, never chained with `&&` or `;`:**

```bash
# Parallel call 1: Current cycle
linear i list --cycle current --team <TEAM> --format compact
```

```bash
# Parallel call 2: Team dependency graph
linear deps --team <TEAM>
```

```bash
# Parallel call 3: Issues assigned to me
linear i list --team <TEAM> --format compact
```

**If a just-completed issue exists, add this as a fourth parallel call:**

```bash
# Parallel call 4: What the completed issue was blocking
linear search --blocked-by <COMPLETED-ID>
```

### Step 2: Identify Candidates

From the cycle list and dependency graph, build a candidate set of issues that are **workable** — meaning:

- State is Todo, Planned, Backlog, or Triage (not Done, Ready For Release, In Progress, or Cancelled)
- All blockers are resolved (in Done/Ready For Release state)
- Not assigned to someone else who is actively working on it

If a just-completed issue exists, also identify **transitively unblocked** issues — not just direct dependents, but issues further down the dependency chain whose last remaining blocker was the completed issue (or was itself unblocked by it).

### Step 3: Rank Candidates

Ranking uses two key signals: **parent/epic status** and **assignment to you**.

**Parent status weight** — when a candidate has a parent (or grandparent) issue, that ancestor's state determines urgency:

- Parent **In Progress** → highest weight (active epic, finish it first)
- Parent **Planned** → second highest (committed to, up next)
- Parent **Backlog** → third (accepted work, not yet scheduled)
- Parent **Triage** → lowest weight (but not zero — Triage does not mean unimportant, just not yet categorized)
- No parent → neutral (ranked on its own merits)

Climb the full parent chain — if an issue's parent is a sub-issue of an In Progress epic, it inherits that weight.

**Apply this priority order:**

1. **Already assigned to you + unblocked** — Issues assigned to the current user with no remaining blockers. You've already committed to these — finish what you started. Rank by parent status weight, then priority.
2. **Current cycle + newly unblocked** — Issues in the active cycle that were blocked by the just-completed issue (directly or transitively). Rank by parent status weight, then priority.
3. **Current cycle + ready** — Other cycle issues with no remaining blockers. Rank by parent status weight, then priority.
4. **Newly unblocked + highest priority** — Issues directly unblocked by the completed issue, ranked by parent status weight, then priority.
5. **Sibling under same parent** — If the completed issue has a parent, look for sibling issues that are workable. Prefer the next one in dependency order within the parent.
6. **Highest priority workable** — Any remaining workable issue, ranked by parent status weight, then priority, then estimate.

**Tiebreakers within a tier:** parent status weight > priority (Urgent > High > Normal > Low) > in current cycle > fewer remaining blockers > lower estimate (quick wins maintain momentum).

**Note:** If there is no just-completed issue (standalone mode), tiers 2, 4, and 5 don't apply — start at tier 1 (assigned to you), then tier 3 (current cycle, ready), then tier 6.

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
