---
name: next
description: Suggest the best next issue to work on. Considers current cycle, dependency graph, triage status, and what's unblocked. Optionally filters to a label — `/next specified` restricts to certified specs (what /auto runs). Use when the user says 'what's next', 'next issue', or invokes /next.
argument-hint: "[label]"
---

# Next Issue

Suggests the most logical next issue to work on by combining cycle planning, dependency analysis, and triage signals. All fetching, blocker verification, and tier ranking is delegated to [scripts/next-candidates.sh](../../scripts/next-candidates.sh) — this skill is just the entry point and result narration.

## When to Use

- Starting a fresh day/week and unsure where to begin
- After finishing an issue — run manually; detects the just-completed issue from the current branch (or an explicit mention in conversation)
- Deciding between multiple candidate issues
- Restricting to certified work: `/next specified` (what `/auto` runs — see [standards/issue-spec.md](../../standards/issue-spec.md))

## Arguments

```text
/next [label]
```

One optional token — a Linear issue-label name. When present, every candidate must carry that label (ASCII-case-insensitive name match); pass it to the script as `--label <label>`. Bare `/next` is unfiltered — humans may deliberately pick uncertified issues; only `/auto` is gated to `specified`. Error on more than one token.

## Workflow

### Step 1: Determine completed-issue context

Check whether there's a just-completed issue providing context. `/finish` never invokes `/next` — this is run manually, afterward. Two ways the context can surface:

- Current branch name matches a Linear issue (e.g. `kross/pl-260-foo`) AND that issue is in Done or Ready For Release — capture as `<COMPLETED-ID>`.
- The user explicitly mentions a just-completed issue in the conversation (e.g., "I just finished PL-260, what's next?") — capture it as `<COMPLETED-ID>`. Otherwise treat as standalone.

If neither applies, run in standalone mode.

### Step 2: Run the ranking script

The script resolves the team key from `--team` or `$LINEAR_TEAM`, erroring if neither is set. Unless `$LINEAR_TEAM` is exported in the environment, pass `--team <TEAM>` explicitly — derive `<TEAM>` from the `<COMPLETED-ID>` prefix (e.g. `PL-260` → `PL`) or the current branch name (`kross/pl-260-foo` → `PL`). Use the appropriate form:

```bash
# Standalone
~/.claude/scripts/next-candidates.sh --team <TEAM>

# Post-finish (transitively unblock from <COMPLETED-ID>)
~/.claude/scripts/next-candidates.sh --team <TEAM> --completed <COMPLETED-ID>

# Show more than the default 3
~/.claude/scripts/next-candidates.sh --team <TEAM> --limit 5

# Label-filtered (e.g. /auto's certified-only pick: /next specified)
~/.claude/scripts/next-candidates.sh --team <TEAM> --label <label>
```

If `$LINEAR_TEAM` is exported, `--team` may be omitted from each form. `--label` composes with `--completed` — the unblock analysis is label-agnostic; the filter applies only to the final candidate set.

The script emits a markdown-formatted ranked list with tier, parent chain, and reasoning per candidate. It exits 0 even when no workable candidates exist (it prints `_No workable issues in team <KEY>._` — with the label named when a filter was active).

### Step 3: Present the result

Read the script's stdout and narrate it naturally:

- Lead with the top candidate: identifier, title, why it's the recommendation (the tier reason already encodes this).
- If there's a runner-up that's qualitatively different from the top pick (different tier, different parent epic), mention it as "also consider."
- If the script reported no workable issues, say so plainly — do not invent a suggestion. When the filter was `--label specified`, suggest running `/spec` to certify backlog issues (or `/prd` to seed new certified ones).

The script's tier reasons (e.g. "in current cycle + newly unblocked", "sibling under completed parent") already explain the *why* — surface them rather than rephrasing.

## Error Handling

- Exit 1 — arg error. Read stderr and fix the invocation.
- Exit 2 — Linear/network failure. Surface the error message verbatim and stop.
- Exit 3 — missing dependency (`linear-cli`, `jq`). Tell the user to install it.
- If `linear-cli auth status` shows logged out, prompt: `linear-cli auth oauth`.

## Notes on the Algorithm

Only **Backlog / Planned / Todo** issues are workable candidates. Issues in **Triage** — Linear's unreviewed inbox — are excluded outright before any tiering, since they haven't been accepted for work yet (a Triage issue is never a valid "next"). Terminal states (Done, Canceled, Ready For Release, …) are likewise excluded.

A label filter (`--label`) applies after the workable/blocker filtering and before tiering — it never changes the ranking math, only the candidate pool. The script also has `--exclude-label`, `--include-triage`, and `--include-blocked`: those are `/spec`'s grooming-discovery knobs (find uncertified issues, including the Triage inbox and issues with unresolved blockers) and are never used by `/next` itself. The `specified` label contract lives in [standards/issue-spec.md](../../standards/issue-spec.md).

The script applies the same six-tier scheme the previous prose version of this skill described — see [scripts/next-candidates.sh](../../scripts/next-candidates.sh) for the exact logic. The high-level priority order:

1. Already assigned to you (finish what you started)
2. In current cycle + newly unblocked by `<COMPLETED-ID>`
3. In current cycle, ready
4. Newly unblocked anywhere
5. Sibling under the same parent as `<COMPLETED-ID>`
6. Highest-priority workable fallback

Within each tier: parent-epic state (In Progress > Planned > Backlog > Triage) > priority > cycle membership > estimate.
