---
name: next
description: Suggest the best next issue to work on. Considers workflow stage (Planned before Backlog), dependency graph, triage status, and what's unblocked. Optionally filters to a label — `/next specified` restricts to certified specs (what /auto runs). Use when the user says 'what's next', 'next issue', or invokes /next.
argument-hint: "[label] [team:KEYS]"
---

# Next Issue

Suggests the most logical next issue to work on by combining workflow stage, dependency analysis, and triage signals. All fetching, blocker verification, and tier ranking is delegated to [scripts/next-candidates.sh](../../scripts/next-candidates.sh) — this skill is just the entry point and result narration.

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

The script emits a markdown-formatted ranked list with tier, parent chain, and reasoning per candidate. It exits 0 even when no workable candidates exist — printing `_No workable issues in team <KEY>._` (single team) or `_No workable issues in teams <KEY, KEY>._` (multi), with the label named when a filter was active. Under the Planned gate (below) the empty case reads differently on purpose — `_Nothing pickable right now … the Planned/Todo column is not drained, so Backlog is withheld (PLANNED-HOLD below) …_` — and that difference is what `/auto` keys on to wait rather than end its run.

The same wait-not-drained distinction holds when the gate is open but every remaining candidate sits behind an unresolved blocker: if at least one of them will release on its own (its chain runs through in-flight or fleet-eligible work), the empty case prints `_Nothing pickable right now … every remaining candidate waits behind an unresolved blocker, and N will release on their own (BLOCKED-HOLD below)._` with a `_BLOCKED-HOLD: …_` note naming what each hidden issue waits on — the pool is chained, not drained, and `/auto` parks on it. Blocked issues are otherwise counted on every path in a plain `_N issue(s) hidden behind unresolved blockers — …_` note, like every other exclusion; a pool blocked only behind keeper-owned work keeps the drained headline, since nothing in it releases without a human.

### Step 3: Present the result

Read the script's stdout and narrate it naturally — and **definitively**:

- Lead with the top candidate: identifier, title, why it's the recommendation (the tier reason already encodes this). The answer to "what's next" is that candidate — never hedge with "say the word if you want another team" or ask which team to search; the scope was already resolved mechanically in Step 2.
- Name the scope searched in one clause (e.g. "across PL, BF, and MAR" or "in PL, per $LINEAR_TEAM") so an empty or surprising result is self-explaining.
- If there's a runner-up that's qualitatively different from the top pick (different tier, different parent epic, different team), mention it as "also consider."
- Surface a `_PLANNED-HOLD: …_` note **verbatim** — it is the answer to "why is nothing from Backlog here" and, for the keeper, the list of what to decide, certify, or close so the column drains. When the script reported *nothing pickable* under a hold, say that the fleet is waiting on the Planned/Todo column (name the releasing and keeper-owned entries) — never suggest Backlog work or `/spec`-for-Backlog around it.
- Surface a `_BLOCKED-HOLD: …_` note **verbatim** the same way — it names the in-flight issue each hidden candidate waits on, so the narration is "waiting on a sibling to ship `<ID>`", never a `/spec` or Backlog suggestion.
- If the script reported no workable issues (the column drained and nothing remains), say so plainly — do not invent a suggestion. When the filter was `--label specified`, suggest running `/spec` to certify backlog issues (or `/prd` to seed new certified ones).

The script's tier reasons (e.g. "newly unblocked", "sibling under completed parent") already explain the *why* — surface them rather than rephrasing.

## Error Handling

- Exit 1 — arg error (bad flag value, malformed team key). Read stderr and fix the invocation.
- Exit 2 — Linear/network failure, including workspace team discovery failing when no team was pinned. Surface the error message verbatim and stop.
- Exit 3 — missing dependency (`linear-cli`, `jq`). Tell the user to install it.
- If `linear-cli auth status` shows logged out, prompt: `linear-cli auth oauth`.

## Notes on the Algorithm

Only **Backlog / Planned / Todo** issues are workable candidates. Issues in **Triage** — Linear's unreviewed inbox — are excluded outright before any tiering, since they haven't been accepted for work yet (a Triage issue is never a valid "next"). Terminal states (Done, Canceled, Ready For Release, …) are likewise excluded.

Workable is not the same as equal: **Backlog sorts behind Planned/Todo** in every tier. Stage is the one planning signal in the pool a human sets by hand, so bouncing an area of work to Backlog has to actually defer it — see the within-tier order below.

**The Planned gate — Backlog is withheld, not merely out-ranked, until the Planned/Todo column drains** (keeper ruling 2026-08-28: every Planned/Todo issue is worked before any Backlog issue, and no usage is spent on Backlog while that column is not drained). Ordering alone only holds while a Planned issue is pickable this instant; the moment the rest of the column is blocked behind in-flight work or parked, ordering falls through to Backlog — the usage the ruling forbids. So while the column holds anything not claimed by another person, every Backlog candidate (tiers 0 and 1 included — a reflection filing or an issue assigned to you in Backlog waits too; promote it to Planned to run it first) is withheld and a `PLANNED-HOLD` note classifies each held issue: *pickable now*, *will release on its own* (every unresolved blocker in its chain is in flight or fleet-eligible), or *needs the keeper* (parked, uncertified under the filter, an epic to close, or blocked behind such an issue). Inherited-stage Backlog issues — blockers of Planned work — are Planned scope and stay pickable, so the gate cannot deadlock on them. A claim by another person is the one carve-out: that work is neither the fleet's nor the keeper's to drain. With nothing pickable, the caller **waits** — `/auto` ticks cheaply until a chain releases or the keeper acts — and never treats the hold as a drained backlog. Discovery listings (`--include-blocked`, `--include-triage`, `--label solo|'needs decision'|human`) are exempt, and `--no-stage-gate` lifts it to inspect what waits behind it.

A label filter (`--label`) applies after the workable/blocker filtering and before tiering — it never changes the ranking math, only the candidate pool. The script also has `--exclude-label`, `--include-triage`, and `--include-blocked`: those are `/spec`'s grooming-discovery knobs (find uncertified issues, including the Triage inbox and issues with unresolved blockers) and are never used by `/next` itself. The `specified` label contract lives in [standards/issue-spec.md](../../standards/issue-spec.md).

A hard gate sits above all of these: **an issue assigned to anyone other than the viewer is hidden from every ranking** — assignment is a claim (`standards/linear-workflow.md`): a person has taken the work or is investigating it, and neither certification nor implementation may move underneath them. `--include-claimed` restores them for inspection, and a trailing hidden-count note reports what the gate removed (counted over workable stages only, unlike the label notes — nearly every In Progress issue is assigned, so an all-states count would drown the signal). Issues assigned to the viewer rank tier 1, as ever. Likewise, issues labeled `needs decision` are hidden from every ranking — bare `/next` and `/next specified` alike — because a human must step in before pickup (the label contract is in [standards/issue-spec.md](../../standards/issue-spec.md)). The one exception is invoking with `--label 'needs decision'` itself, which lists exactly those issues. Issues labeled `solo` are hidden by the identical mechanism (surfaced by `--label solo`) for a different reason — they ship fine unattended but not alongside a fleet, so only the automatic pick is blocked and a targeted `/auto <ID>` still runs one. Issues labeled `human` are hidden the same way (surfaced by `--label human`) for the strongest reason — the work is human-performed, so no mode ever runs one; unlike `solo`, targeted `/auto <ID>` refuses it too. Issues labeled `epic` are hidden the same way (surfaced by `--label epic`): a delegated container whose children carry the work — certify per child, close the epic when they release (BF-95) — so it never counts fleet-workable, certified or not, matching `fleet-blockers.sh` and `fleet-forecast.py`; before the Planned gate the BF-504 de-rank alone sufficed only because the whole Backlog stood in front of a Planned epic, and with Backlog withheld it would have been the next pick. Whenever any gate hid candidates, the script appends a hidden-count note, so the thinner list is never silent — surface those notes to the user verbatim. The count spans every fetched issue carrying the label, including states no ranking would list (In Progress, Ready for Release, Triage, Duplicate), so a note that exceeds the corresponding `--label` listing is expected, not a bug — the reconciliation recipe is `/auto-prep` Step 4.

Multi-team runs merge every team's issues **before** tiering: each team contributes its own dependency graph, then one ranked list comes out — a Tier 2 newly-unblocked BF issue beats a Tier 4 PL fallback regardless of which team the session was "in." Identifiers carry the team (`PL-…`, `BF-…`), so no extra labeling is needed in the output.

The script applies a tier scheme — see [scripts/next-candidates.sh](../../scripts/next-candidates.sh) for the exact logic. Tier numbers below match what the output prints:

- **Tier 0** — certified reflection improvement (`specified` + `reflection` labels — `/reflect`'s filings): config/process fixes change how every later issue runs, so they ship ahead of the work they improve. Those additionally labeled `keeper` (they edit the shared user-level `~/.claude` repo) appear **only** on the keeper's machine (`git -C ~/.claude config reflect.keeper` → `true`); everywhere else the script excludes them from the pool entirely — `/auto` included — and prints a trailing note with the hidden count. On the keeper's machine, keeper filings rank **first within this tier**: their multiplier is cross-project rather than per-repo, and no other machine can ever drain them
- **Tier 1** — already assigned to you (finish what you started)
- **Tier 2** — newly unblocked by `<COMPLETED-ID>`
- **Tier 3** — sibling under the same parent as `<COMPLETED-ID>`
- **Tier 4** — everything else workable

Tiers 2 and 3 only ever populate under `--completed`, so a standalone run puts almost everything in tier 4 and **the within-tier order below is what actually ranks the pool**: **workflow stage first, a strict three-way order — Planned/Todo drains fully, then Backlog, then (only under `--include-triage`) the Triage inbox — Urgent included** (a Backlog issue is a deliberate human deferral, and bouncing work to Backlog has to actually defer it — keeper decision 2026-08-05, narrowing BF-583; an unreviewed inbox item has not even been accepted for work, so it never outranks either — keeper decision 2026-08-13), then **Urgent priority** (within a stage it still pierces the label classes — a deliberate human "drop everything" escalation outranks any label, BF-583) > label class (`security` > `bug` > everything else — defects ship before improvements, but within a stage) > remaining priority (High > Normal > Low > None) > spread penalty (a sibling under the same parent, or a `related` partner, is In Progress/In Review, so a live session is likely in nearby files — soft de-rank, annotated in the output; `related` is the file-level overlap signal, `blocks` the prerequisite/same-method one — standards/issue-spec.md § Certification includes collision edges) > parent-epic state (In Progress > Planned > Backlog > Triage) > estimate. Terminal-blocker matching is case-insensitive (workspace state names vary: "Ready for Release" vs "Ready For Release").

Stage sits above label class deliberately. Moving an issue to Backlog is how a human defers a whole area of work, and that has to hold for defects too or the deferral only half-lands — `Urgent` remains the escape hatch WITHIN a stage for anything parked that genuinely cannot wait, but it never crosses stages. Triage ranks strictly LAST even under `--include-triage` (keeper decision 2026-08-13, superseding the earlier ranks-with-Planned choice): the measured cost of the old tie was `/spec` recommending an Urgent Triage report (BF-34) over the entire uncertified Planned queue — the keeper certifies all of Planned, then all of Backlog, and looks at the inbox only after both.

**Stage is inherited down a blocking chain.** A Backlog issue that (transitively) blocks a Planned/Todo issue is release scope by implication — an issue is scoped by what it gates, not by the column it sits in (keeper ruling 2026-08-13, `standards/linear-workflow.md` § Stage Priorities) — so it ranks in the Planned stage, annotated `Stage inherited: Backlog, but it blocks Planned/Todo <IDs>`, and surfaces in the below-the-cut section like any Planned issue. The walk stops at terminal blockers (a chain through a shipped issue gates nothing) and never lifts Triage. Without this, a fleet drained every other Planned issue and then picked Backlog work by class and priority while the one issue standing between it and a Planned item sat at Backlog rank — `/auto-prep`'s `PROMOTE-SET` batch fixes the column at prep time, but chains wired between preps (review filings, a hand promotion of the dependent alone) re-created the inversion mid-run.

**Linear cycle membership is deliberately not a signal.** On a team with Linear's auto-assign-on-start/complete settings the cycle records what has already been worked rather than what is planned, and cycle rollover keeps never-started issues in it indefinitely — one BF issue rolled forward for four months while outranking the entire Planned column on that basis alone. Stage carries the planning signal instead. A team that curates cycles by hand can reintroduce the tier, but nothing in this toolkit reads cycles today.

Two structural de-ranks sit outside the tier scheme:

- **Delegated epics** (BF-504): a candidate with 1+ sub-issues, none of them in a workable state, has no independent work of its own — its children carry the work. It is de-ranked below every non-delegated candidate and annotated `Delegated` (child states come from the same top-K `issues get` payload the parent walk already fetches — no extra API calls). An epic whose children have all shipped is annotated as likely needing closure, not implementation.
- The spread penalty above is a soft tie-break, never an exclusion — a High-priority candidate still outranks a None-priority one with no sibling or `related` partner in flight.
