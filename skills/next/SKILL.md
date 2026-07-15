---
name: next
description: Suggest the best next issue to work on. Considers current cycle, dependency graph, triage status, and what's unblocked. Optionally filters to a label — `/next specified` restricts to certified specs (what /auto runs). Use when the user says 'what's next', 'next issue', or invokes /next.
argument-hint: "[label] [team:KEYS]"
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
/next [label] [team:KEY[,KEY...]]
```

Two optional tokens, order-insensitive:

- A Linear issue-label name (e.g. `specified`): every candidate must carry that label (ASCII-case-insensitive name match); pass it to the script as `--label <label>`. Bare `/next` is unfiltered — humans may deliberately pick uncertified issues; only `/auto` is gated to `specified`.
- `team:KEY[,KEY...]` (e.g. `team:BF`, `team:PL,BF`): an explicit team scope; pass through as `--team`. This outranks `$LINEAR_TEAM` in Step 2's resolution — it is a direct instruction.

Error on any other token.

## Workflow

### Step 1: Determine completed-issue context

Check whether there's a just-completed issue providing context. `/finish` never invokes `/next` — this is run manually, afterward. Two ways the context can surface:

- Current branch name matches a Linear issue (e.g. `kross/pl-260-foo`) AND that issue is in Done or Ready For Release — capture as `<COMPLETED-ID>`.
- The user explicitly mentions a just-completed issue in the conversation (e.g., "I just finished PL-260, what's next?") — capture it as `<COMPLETED-ID>`. Otherwise treat as standalone.

If neither applies, run in standalone mode.

### Step 2: Run the ranking script

**Team scope is resolved mechanically — never guessed from session vibes and never asked about:**

1. A `team:` argument token (or the user naming a team in the request) → that is the scope; pass as `--team`.
2. Else `$LINEAR_TEAM` exported → that is the scope. It may be a single key (`PL`) or a comma list (`PL,BF`) — pass through implicitly (the script reads the env) or as `--team`.
3. Otherwise → omit `--team` entirely: the script discovers **every team in the workspace** and ranks all of them in one merged list. Tiers, priority, and estimates are comparable across teams, so the merge is a real ranking, not a concatenation.

A `<COMPLETED-ID>` or branch prefix feeds `--completed` only — it does **not** narrow the team scope (scoping to the prefix's team is exactly how certified work in a sibling team gets missed).

```bash
# Standalone (workspace-wide unless $LINEAR_TEAM pins the scope)
~/.claude/scripts/next-candidates.sh

# Post-finish (transitively unblock from <COMPLETED-ID>)
~/.claude/scripts/next-candidates.sh --completed <COMPLETED-ID>

# Label-filtered (e.g. /auto's certified-only pick: /next specified)
~/.claude/scripts/next-candidates.sh --label <label>

# Explicit scoping / more results
~/.claude/scripts/next-candidates.sh --team PL,BF --limit 5
```

`--label` composes with `--completed` — the unblock analysis is label-agnostic; the filter applies only to the final candidate set.

The script emits a markdown-formatted ranked list with tier, parent chain, and reasoning per candidate. It exits 0 even when no workable candidates exist — printing `_No workable issues in team <KEY>._` (single team) or `_No workable issues in teams <KEY, KEY>._` (multi), with the label named when a filter was active.

### Step 3: Present the result

Read the script's stdout and narrate it naturally — and **definitively**:

- Lead with the top candidate: identifier, title, why it's the recommendation (the tier reason already encodes this). The answer to "what's next" is that candidate — never hedge with "say the word if you want another team" or ask which team to search; the scope was already resolved mechanically in Step 2.
- Name the scope searched in one clause (e.g. "across PL, BF, and MAR" or "in PL, per $LINEAR_TEAM") so an empty or surprising result is self-explaining.
- If there's a runner-up that's qualitatively different from the top pick (different tier, different parent epic, different team), mention it as "also consider."
- If the script reported no workable issues, say so plainly — do not invent a suggestion. When the filter was `--label specified`, suggest running `/spec` to certify backlog issues (or `/prd` to seed new certified ones).

The script's tier reasons (e.g. "in current cycle + newly unblocked", "sibling under completed parent") already explain the *why* — surface them rather than rephrasing.

## Error Handling

- Exit 1 — arg error (bad flag value, malformed team key). Read stderr and fix the invocation.
- Exit 2 — Linear/network failure, including workspace team discovery failing when no team was pinned. Surface the error message verbatim and stop.
- Exit 3 — missing dependency (`linear-cli`, `jq`). Tell the user to install it.
- If `linear-cli auth status` shows logged out, prompt: `linear-cli auth oauth`.

## Notes on the Algorithm

Only **Backlog / Planned / Todo** issues are workable candidates. Issues in **Triage** — Linear's unreviewed inbox — are excluded outright before any tiering, since they haven't been accepted for work yet (a Triage issue is never a valid "next"). Terminal states (Done, Canceled, Ready For Release, …) are likewise excluded.

A label filter (`--label`) applies after the workable/blocker filtering and before tiering — it never changes the ranking math, only the candidate pool. The script also has `--exclude-label`, `--include-triage`, and `--include-blocked`: those are `/spec`'s grooming-discovery knobs (find uncertified issues, including the Triage inbox and issues with unresolved blockers) and are never used by `/next` itself. The `specified` label contract lives in [standards/issue-spec.md](../../standards/issue-spec.md).

Multi-team runs merge every team's issues **before** tiering: each team contributes its own dependency graph and active-cycle set, then one ranked list comes out — a Tier 3 in-cycle BF issue beats a Tier 6 PL fallback regardless of which team the session was "in." Identifiers carry the team (`PL-…`, `BF-…`), so no extra labeling is needed in the output.

The script applies the same six-tier scheme the previous prose version of this skill described — see [scripts/next-candidates.sh](../../scripts/next-candidates.sh) for the exact logic. The high-level priority order:

1. Already assigned to you (finish what you started)
2. In current cycle + newly unblocked by `<COMPLETED-ID>`
3. In current cycle, ready
4. Newly unblocked anywhere
5. Sibling under the same parent as `<COMPLETED-ID>`
6. Highest-priority workable fallback

Within each tier: parent-epic state (In Progress > Planned > Backlog > Triage) > priority > cycle membership > estimate.
