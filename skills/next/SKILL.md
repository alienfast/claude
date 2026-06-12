---
name: next
description: Suggest the best next issue to work on. Considers current cycle, dependency graph, triage status, and what's unblocked. Use when the user says 'what's next', 'next issue', or invokes /next.
---

# Next Issue

Suggests the most logical next issue to work on by combining cycle planning, dependency analysis, and triage signals. All fetching, blocker verification, and tier ranking is delegated to [scripts/next-candidates.sh](../../scripts/next-candidates.sh) — this skill is just the entry point and result narration.

## When to Use

- Starting a fresh day/week and unsure where to begin
- After finishing an issue (invoked from `/finish`)
- Deciding between multiple candidate issues

## Workflow

### Step 1: Determine completed-issue context

Check whether there's a just-completed issue providing context. Two ways this can surface:

- Invoked from `/finish` with the issue ID already in scope — capture it as `<COMPLETED-ID>`.
- Current branch name matches a Linear issue (e.g. `kross/pl-260-foo`) AND that issue is in Done or Ready For Release — capture as `<COMPLETED-ID>`. Otherwise treat as standalone.

If neither applies, run in standalone mode.

### Step 2: Run the ranking script

Run from inside the project directory so the script can read `.linear.yaml` for the team key. Use the appropriate form:

```bash
# Standalone
~/.claude/scripts/next-candidates.sh

# Post-finish (transitively unblock from <COMPLETED-ID>)
~/.claude/scripts/next-candidates.sh --completed <COMPLETED-ID>

# Show more than the default 3
~/.claude/scripts/next-candidates.sh --limit 5
```

The script emits a markdown-formatted ranked list with tier, parent chain, and reasoning per candidate. It exits 0 even when no workable candidates exist (it prints `_No workable issues in team <KEY>._`).

### Step 3: Present the result

Read the script's stdout and narrate it naturally:

- Lead with the top candidate: identifier, title, why it's the recommendation (the tier reason already encodes this).
- If there's a runner-up that's qualitatively different from the top pick (different tier, different parent epic), mention it as "also consider."
- If the script reported no workable issues, say so plainly — do not invent a suggestion.

The script's tier reasons (e.g. "in current cycle + newly unblocked", "sibling under completed parent") already explain the *why* — surface them rather than rephrasing.

## Error Handling

- Exit 1 — arg error. Read stderr and fix the invocation.
- Exit 2 — Linear/network failure. Surface the error message verbatim and stop.
- Exit 3 — missing dependency (`linear-cli`, `jq`). Tell the user to install it.
- If `linear-cli auth status` shows logged out, prompt: `linear-cli auth oauth`.

## Notes on the Algorithm

The script applies the same six-tier scheme the previous prose version of this skill described — see [scripts/next-candidates.sh](../../scripts/next-candidates.sh) for the exact logic. The high-level priority order:

1. Already assigned to you (finish what you started)
2. In current cycle + newly unblocked by `<COMPLETED-ID>`
3. In current cycle, ready
4. Newly unblocked anywhere
5. Sibling under the same parent as `<COMPLETED-ID>`
6. Highest-priority workable fallback

Within each tier: parent-epic state (In Progress > Planned > Backlog > Triage) > priority > cycle membership > estimate.
