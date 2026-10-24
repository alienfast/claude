---
name: next
description: Suggest the best next issue to work on — workflow stage (Planned before Backlog), dependency graph, triage status, and what's unblocked. Tokens are a label such as `specified` (what /auto runs), `team:KEYS`, `epic:ID`, and `backlog` (the Planned-gate opt-in). Use when the user says 'what's next', 'next issue', or invokes /next.
argument-hint: "[label] [team:KEYS] [epic:ID] [backlog]"
---

# Next Issue

Suggests the most logical next issue by combining workflow stage, dependency analysis, and triage signals. All fetching,
blocker verification, and tier ranking is delegated to [scripts/next-candidates.sh](../../scripts/next-candidates.sh) —
this skill is the entry point and result narration.

## When to Use

- Starting a fresh day/week and unsure where to begin
- After finishing an issue — run manually; detects the just-completed issue from the current branch (or an explicit
  mention in conversation)
- Deciding between multiple candidate issues
- Restricting to certified work: `/next specified` (what `/auto` runs — [standards/issue-spec.md](../../standards/issue-spec.md))

## Arguments

```text
/next [label] [team:KEY[,KEY...]] [epic:ID] [backlog]
```

Four optional tokens, order-insensitive:

- A Linear issue-label name (e.g. `specified`): every candidate must carry it (ASCII-case-insensitive); pass as
  `--label <label>`. Bare `/next` is unfiltered — humans may deliberately pick uncertified issues; only `/auto` is gated
  to `specified`.
- `team:KEY[,KEY...]` (`team:BF`, `team:PL,BF`): an explicit team scope; pass through as `--team`. Outranks
  `$LINEAR_TEAM` in Step 2 — it is a direct instruction.
- `epic:ID` (`epic:BF-1826`): scope the whole ranking to that epic's graph — the epic, its transitive descendants, and
  the transitive blockers of any member, non-terminal only, cross-team included (`scripts/epic-graph.sh`); pass through
  as `--root <ID>`. The graph's teams join the fetch on their own, so `team:` merely widens it. Validated
  **fail-closed by the script**: an ID that does not exist or lacks the `epic` label exits 1 with the reason — surface
  it and stop; never fall back to the unscoped pool. The scope implies `backlog` (below) for the epic's own members.
- `backlog`: the Planned gate's human opt-in — pass through as `--backlog-fallback`. Planned/Todo stays strictly first;
  Backlog is offered only when nothing Planned/Todo is pickable at that instant, under a `_BACKLOG-FALLBACK: …_` note
  naming what still holds the column. `/auto backlog` forwards it (what `/fleet-launch backlog` dispatches). Implied
  by `epic:ID`.

Error on any other token.

## Workflow

### Step 1: Determine completed-issue context

`/finish` never invokes `/next` — this is run manually, afterward. Two ways the context can surface:

- The current branch matches a Linear issue (`kross/pl-260-foo`) AND that issue is Done or Ready For Release —
  capture it as `<COMPLETED-ID>`.
- The user explicitly mentions a just-completed issue ("I just finished PL-260, what's next?").

Otherwise run in standalone mode.

### Step 2: Run the ranking script

**Team scope is resolved mechanically — never guessed from session vibes and never asked about:**

1. A `team:` token (or the user naming a team) → that scope; pass as `--team`.
2. Else `$LINEAR_TEAM` exported — a single key (`PL`) or a comma list (`PL,BF`) — pass through implicitly (the script
   reads the env) or as `--team`.
3. Otherwise omit `--team`: the script discovers **every team in the workspace** and ranks them in one merged list.
   Tiers, priority, and estimates are comparable across teams, so the merge is a real ranking.

A `<COMPLETED-ID>` or branch prefix feeds `--completed` only — it does **not** narrow the team scope (scoping to the
prefix's team is exactly how certified work in a sibling team gets missed).

```bash
~/.claude/scripts/next-candidates.sh                                  # standalone (workspace-wide unless $LINEAR_TEAM pins it)
~/.claude/scripts/next-candidates.sh --completed <COMPLETED-ID>       # post-finish: transitively unblock from <COMPLETED-ID>
~/.claude/scripts/next-candidates.sh --label <label>                  # label-filtered (/auto's pick: /next specified)
~/.claude/scripts/next-candidates.sh --team PL,BF --limit 5           # explicit scoping / more results
~/.claude/scripts/next-candidates.sh --root BF-1826 --label specified # epic-scoped (/next epic:BF-1826; what /auto epic:… runs; implies --backlog-fallback)
~/.claude/scripts/next-candidates.sh --label specified --backlog-fallback   # /next specified backlog; what /auto backlog runs
```

`--label` composes with `--completed` — the unblock analysis is label-agnostic; the filter applies to the final set.
`--root` composes with both: the fetched list is cut to the epic's members right after the fetch, before the Planned gate
and every hold/hidden note, so the order, holds, counts, and drained headline all describe the epic alone (a `_Scope:
epic <ID> — N non-terminal member(s) …_` line says so, and headlines read `in epic <ID> (team <KEY>)`).

The script emits a markdown ranked list with tier, parent chain, and reasoning per candidate. It exits 0 even with no
workable candidates — `_No workable issues in team <KEY>._` or `_… in teams <KEY, KEY>._`, naming the label when a filter
was active. Under the Planned gate the empty case reads differently on purpose — `_Nothing pickable right now … the
Planned/Todo column is not drained, so Backlog is withheld (PLANNED-HOLD below) …_` — and that difference is what `/auto`
keys on to wait rather than end its run. Under `--backlog-fallback` the gate closes only while a Planned/Todo candidate
is pickable or Backlog has nothing to offer, so the same wait headline still appears when neither column is pickable — a
held column never reads as drained.

The same wait-not-drained distinction holds when the gate is open but every remaining candidate sits behind an
unresolved blocker: if at least one will release on its own (its chain runs through in-flight or fleet-eligible work),
the empty case prints `_Nothing pickable right now … every remaining candidate waits behind an unresolved blocker, and N
will release on their own (BLOCKED-HOLD below)._` with a `_BLOCKED-HOLD: …_` note naming what each hidden issue waits on
— the pool is chained, not drained, and `/auto` parks on it. Blocked issues are otherwise counted in a plain `_N
issue(s) hidden behind unresolved blockers — …_` note; a pool blocked only behind keeper-owned work keeps the drained
headline, since nothing in it releases without a human.

### Step 3: Present the result

Narrate the script's stdout naturally — and **definitively**:

- Lead with the top candidate: identifier, title, why it is the recommendation (the tier reason encodes this). Never
  hedge with "say the word if you want another team" or ask which team to search; scope was resolved in Step 2.
- Name the scope searched in one clause ("across PL, BF, and MAR"; "in PL, per $LINEAR_TEAM"; under `epic:` the
  script's `_Scope: epic …_` line) so an empty or surprising result is self-explaining.
- A runner-up that is qualitatively different (tier, parent epic, team) → "also consider."
- Surface a `_PLANNED-HOLD: …_` note **verbatim** — the answer to "why is nothing from Backlog here" and, for the keeper,
  the list of what to decide, certify, or close so the column drains. When nothing is pickable under a hold, say the
  fleet is waiting on the Planned/Todo column (name the releasing and keeper-owned entries) — never suggest Backlog work
  or `/spec`-for-Backlog around it.
- Surface a `_BLOCKED-HOLD: …_` note **verbatim** — "waiting on a sibling to ship `<ID>`", never a `/spec` or Backlog
  suggestion.
- Surface an `_EPIC-DRAINED: …_` note **verbatim** — under `epic:` the scope has nothing left the fleet can ship (only
  keeper-gated members remain and nothing is in flight): "the fleet is done with this epic until the keeper acts", with
  the note's list as what to decide, certify or close. It arrives with the drained headline, not a hold.
- Surface a `_BACKLOG-FALLBACK: …_` note **verbatim** — the pick is Backlog work taken under the `backlog` opt-in while
  the column still holds work; never call the column drained around it. Under `epic:` it is the epic's own deferred
  work, taken by construction.
- Surface an `_In flight: …_` line **verbatim** under `epic:` — the members siblings are shipping; while it is present
  the scope is not drained, whatever else the ranking shows.
- No workable issues (the column drained) → say so plainly; do not invent a suggestion. Under `--label specified`,
  suggest `/spec` to certify backlog issues (or `/prd` to seed new certified ones).

The script's tier reasons ("newly unblocked", "sibling under completed parent") already explain the *why* — surface them.

## Error Handling

- Exit 1 — arg error, or an `epic:` scope that refused (missing issue, no `epic` label). Surface stderr verbatim and
  stop — an epic scope never degrades to the unscoped pool.
- Exit 2 — Linear/network failure, including team discovery failing when no team was pinned. Surface verbatim and stop.
- Exit 3 — missing dependency (`linear-cli`, `jq`). Tell the user to install it.
- Exit 4 — Linear rate limit (`RATELIMITED`): the per-user request window (2,500/hour on an API key, shared by every
  session and script on the machine) is spent. Surface and stop. Under `/auto` this is the transient-API rule (wait
  ~15 minutes), never an immediate re-run.
- `linear-cli auth status` logged out → `linear-cli auth oauth`.

## Notes on the Algorithm

Only **Backlog / Planned / Todo** issues are workable. **Triage** — the unreviewed inbox — is excluded before any
tiering (never a valid "next"); terminal states (Done, Canceled, Ready For Release, …) likewise.

**Backlog sorts behind Planned/Todo in every tier.** Stage is the one planning signal a human sets by hand, so bouncing
work to Backlog has to actually defer it.

**The Planned gate — Backlog is withheld, not merely out-ranked, until the Planned/Todo column drains.** Ordering alone
holds only while a Planned issue is pickable this instant; the moment the rest of the column is blocked or parked,
ordering falls through to Backlog and spends usage the gate forbids. So while the column holds anything not claimed by
another person, every Backlog candidate (tiers 0 and 1 included — promote a Backlog reflection filing or self-assigned
issue to Planned to run it first) is withheld and a `PLANNED-HOLD` note classifies each held issue: *pickable now*,
*will release on its own* (every unresolved blocker in its chain is in flight or fleet-eligible), or *needs the keeper*
(parked, uncertified under the filter, an epic to close, or blocked behind such an issue). Inherited-stage Backlog
issues — blockers of Planned work — are Planned scope and stay pickable, so the gate cannot deadlock on them. A claim by
another person is the one carve-out: that work is neither the fleet's nor the keeper's to drain. With nothing pickable,
the caller **waits** — `/auto` ticks cheaply until a chain releases or the keeper acts — and never treats the hold as a
drained backlog. Discovery listings (`--include-blocked`, `--include-triage`, `--label solo|'needs decision'|human`) are
exempt, and `--no-stage-gate` lifts it to inspect what waits behind it.

**The `backlog` opt-in relaxes the gate without reordering anything.** `--backlog-fallback` still withholds Backlog
while a Planned/Todo candidate is pickable now (inherited-stage ones included), so Planned stays strictly first across
tiers — which `--no-stage-gate` does not promise (with the gate simply lifted, a tier-0 reflection filing or tier-1
assigned issue in Backlog outranks every Planned issue). Once nothing Planned is pickable, Backlog candidates are offered
under a `BACKLOG-FALLBACK` note; a releasing Planned issue does not make the caller wait, because ordering takes it at
the next pick. With nothing pickable in either column the hold is the gate's (`PLANNED-HOLD`, wait). It is a literal
token on the invocation — `/fleet-launch backlog`, `/loop /auto backlog`, `/next specified backlog` — never inferred
from a usage reading; the default stays the gate (`standards/linear-workflow.md` § Stage Priorities).

**An epic scope implies the opt-in.** `--root` opens the fallback by construction: the goal of a scoped run is to
complete the epic, and a member's column says nothing about that — a review's deferred filing lands as a Backlog
sub-issue mid-run and is still the epic's work. The member cut precedes the gate, so only the epic's own Backlog
members are offered, never the team's; Planned/Todo members still go first at every pick, and `EPIC-DRAINED` still
ends the run once only keeper-gated members remain. Every scoped run also prints an `_In flight: …_` line under the
scope line while a member is started, since a landing can file children into the scope.

A label filter applies after the workable/blocker filtering and before tiering — it changes the pool, never the ranking
math. `--exclude-label`, `--include-triage`, and `--include-blocked` are `/spec`'s grooming-discovery knobs, never used
by `/next` itself. The `specified` contract lives in [standards/issue-spec.md](../../standards/issue-spec.md).

**A hard gate sits above all of these: an issue assigned to anyone other than the viewer is hidden from every ranking**
— assignment is a claim (`standards/linear-workflow.md`), and neither certification nor implementation may move
underneath the person. `--include-claimed` restores them for inspection, and a trailing hidden-count note reports what
the gate removed (counted over workable stages only — nearly every In Progress issue is assigned, so an all-states count
would drown the signal). Issues assigned to the viewer rank tier 1. Likewise hidden from every ranking, each surfaced
only by its own `--label` listing: `needs decision` (a human must step in before pickup), `solo` (ships fine unattended
but not alongside a fleet — only the automatic pick is blocked; a targeted `/auto <ID>` still runs one), `human` (the
work is human-performed; no mode runs one, and targeted `/auto <ID>` refuses it too), and `epic` (a delegated container
whose children carry the work — certify per child; the epic closes itself when its last child releases via
`mark-ready-for-release.sh`'s parent walk — so it never counts fleet-workable, matching `fleet-blockers.sh` and
`fleet-forecast.py`), `deploy-gated` (held until every `blocks` blocker reaches one of the project's
`$LINEAR_DEPLOYED_STATES`; surfaced via `--label deploy-gated` — `standards/issue-spec.md` § The `deploy-gated` label),
and — with no label — every issue a running `/fleet-sequence` holds, named in a trailing note. Whenever a gate hid candidates the script appends a hidden-count note — surface those verbatim.
The count spans every fetched issue carrying the label, including states no ranking lists, so a note exceeding the
corresponding `--label` listing is expected; the reconciliation recipe is `/auto-prep` Step 4.

Multi-team runs merge every team's issues **before** tiering: each team contributes its own dependency graph, then one
ranked list comes out — a Tier 2 newly-unblocked BF issue beats a Tier 4 PL fallback regardless of which team the
session was "in." Identifiers carry the team.

Tier scheme (exact logic in [scripts/next-candidates.sh](../../scripts/next-candidates.sh); numbers match the output):

- **Tier 0** — certified reflection improvement (`specified` + `reflection` — `/reflect`'s filings): config/process
  fixes change how every later issue runs, so they ship ahead of the work they improve. Those additionally labeled
  `keeper` (edits to the shared `~/.claude` repo) appear **only** on the keeper's machine (`git -C ~/.claude config
  reflect.keeper` → `true`); everywhere else the script excludes them entirely — `/auto` included — with a trailing
  hidden-count note. On the keeper's machine they rank **first within this tier**: cross-project multiplier, and no other
  machine can drain them.
- **Tier 1** — already assigned to you.
- **Tier 2** — newly unblocked by `<COMPLETED-ID>`.
- **Tier 3** — sibling under the same parent as `<COMPLETED-ID>`.
- **Tier 4** — everything else workable.

Tiers 2 and 3 populate only under `--completed`, so a standalone run puts almost everything in tier 4 and **the
within-tier order is what actually ranks the pool**: workflow stage first, a strict three-way order — Planned/Todo
drains fully, then Backlog, then (only under `--include-triage`) the Triage inbox — Urgent included (a Backlog issue is
a deliberate human deferral; an unreviewed inbox item has not been accepted for work, so it never outranks either); then
**Urgent priority** (within a stage it pierces the label classes — a deliberate "drop everything" escalation outranks
any label) > label class (`security` > `bug` > everything else — defects before improvements, within a stage) >
remaining priority (High > Normal > Low > None) > spread penalty (a sibling under the same parent, or a `related`
partner, is In Progress/In Review, so a live session is likely in nearby files — soft de-rank, annotated; `related` is
the file-level overlap signal, `blocks` the prerequisite/same-method one) > parent-epic state (In Progress > Planned >
Backlog > Triage) > estimate > age, oldest first (without the explicit key a tie keeps Linear's newest-first fetch order,
and a fleet chases its own fresh review filings). Terminal-blocker matching is case-insensitive.

Stage sits above label class deliberately: moving an issue to Backlog defers a whole area of work, and that has to hold
for defects too or the deferral only half-lands — `Urgent` remains the escape hatch WITHIN a stage, never across them.
Triage ranks strictly LAST even under `--include-triage`: certify all of Planned, then all of Backlog, and look at the
inbox only after both — an Urgent inbox report must never be recommended over the uncertified Planned queue.

**Stage is inherited down a blocking chain.** A Backlog issue that (transitively) blocks a Planned/Todo issue is release
scope by implication — an issue is scoped by what it gates, not by its column (`standards/linear-workflow.md` § Stage
Priorities) — so it ranks in the Planned stage, annotated `Stage inherited: Backlog, but it blocks Planned/Todo <IDs>`,
and surfaces in the below-the-cut section like any Planned issue. The walk stops at terminal blockers and never lifts
Triage. Without this, a fleet drains every other Planned issue and then picks Backlog work by class while the one issue
standing between it and a Planned item sits at Backlog rank; `/auto-prep`'s `PROMOTE-SET` fixes the column at prep
time, but chains wired between preps re-create the inversion mid-run.

**Linear cycle membership is deliberately not a signal.** With auto-assign-on-start/complete, the cycle records what has
already been worked rather than what is planned, and rollover keeps never-started issues in it indefinitely — one such
issue can outrank the entire Planned column for months on that basis alone. Stage carries the planning signal; nothing
in this toolkit reads cycles.

Two structural de-ranks sit outside the tier scheme:

- **Delegated epics**: a candidate with 1+ sub-issues, none in a workable state, has no independent work — its children
  carry it. De-ranked below every non-delegated candidate and annotated `Delegated` (child states come from the same
  top-K `issues get` payload the parent walk fetches — no extra calls). An epic whose children have all shipped is
  annotated as likely needing closure, not implementation.
- The spread penalty is a soft tie-break, never an exclusion — a High-priority candidate still outranks a None-priority
  one with no sibling or `related` partner in flight.
