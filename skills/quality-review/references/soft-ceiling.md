# Soft ceiling

Step 5 reads this when the review-cycle count reaches the ceiling — 5 for the full tier (the initial review plus up to
4 re-reviews), counted from the escalation dispatch when the simple tier escalated — and at the convergence drain, which
runs the same lane drain.

Reviewers tend to find *something* on every cycle, so an unbounded loop can run away even while the implementation is
materially improving; the ceiling pauses and asks instead of looping silently. It is not a hard cap — the user can
extend it, and in auto mode the trend gate extends it once on its own for a converging run.

## Ground the count in dispatch history, not memory

Count the review-cycle dispatches actually made in this loop — Step 3's initial `quality-reviewer` review (or the simple
tier's `quality-verifier` scoped review) plus each Step 5 item 4 `quality-verifier` re-review — never a running mental
tally or a self-assigned label on a dispatch ("Cycle-5"). `Targeted fix confirmation` dispatches are **not** review
cycles and are never counted; the count is keyed off the dispatch task headers, which are the history. Labels and
counters drift across a long loop with many interleaved fix/check delegations: before pausing — or, in auto mode, before
applying the trend gate, lane drain, and provenance resolution — recount from the dispatch history if there is any doubt.

## Order of operations at the ceiling

1. **Auto mode only — the trend gate.** Before draining or resolving anything, list the per-cycle counts of new
   loop-fuel findings (item 5's substantive lane) for the cycles run so far, grounded in dispatch and routing history.
   If the count is **decreasing over the most recent three cycles** — the latest strictly below the previous, and the
   previous no higher than the one before — the run is converging: raise the ceiling by 3, note the extension and the
   trend in chat, and resume the loop. **Once per run** — hitting the raised ceiling resolves below regardless of trend.
   The window is recent cycles, not full history, so an early fix-regression spike (7 → 14 → 7 → 4) does not disqualify
   a run that is clearly converging afterward. A flat or growing recent trend falls through. Interactive mode has no
   trend gate — the prompt puts the trend in front of the user, who extends via option 1.
2. **Drain the mechanical and prose lanes — both modes.** Route every surviving finding through item 5's lanes:
   prose-only survivors are fixed under the prose lane (ping-pong and class-completion rules included) and confirmed
   with `pnpm check` (a failing check means the edit was not prose-only — a regression, per that lane); mechanical
   survivors are fixed and verified under the mechanical lane (class-completion rule included) with a targeted
   confirmation, not a new cycle. Only substantive, judgment-requiring survivors reach the prompt or the auto
   resolution. A ceiling reached with only mechanical and prose survivors **converges** (`passed-after-fixes`, once
   confirmations return clean) without asking anyone — terminating over an unapplied one-line fix is the deadlock this
   drain removes.
3. **One corrective round when a drain confirmation flags a problem.** The confirmation re-route rules still classify
   it, but at the ceiling the loop cannot re-arm, so the drain owes exactly one round: a problem landing in the prose
   lane is fixed under that lane (ping-pong — the paragraph rewrite, never another qualifier) and re-confirmed **once**;
   a problem landing substantive — including everything the mechanical one-way door pushes there — gets no round at all.
   Still flagged after the single re-confirmation, or landed substantive: it is a **post-drain survivor** —
   interactively it joins the prompt's findings list, in auto mode it enters the provenance resolution. An unbounded
   fix-and-re-confirm at the ceiling would be the very loop the ceiling exists to end. (At the **convergence** drain the
   bound splits by lane: a substantive re-route re-arms the loop normally, so none is owed there; a prose one re-arms
   nothing and is bounded by the prose carve-out's own rule in item 5.)
4. Interactively, render the prompt below. In auto mode, resolve by provenance.

## The prompt (interactive)

```text
The implementation has gone through 5 review cycles and still has unresolved findings:
[list current findings]

Cycle-by-cycle trend: [e.g., "5 → 3 → 2 → 2 → 2" so the user can see whether progress is stalling or converging]

Options:
1. Continue fixing — run another N cycles, default N=3
2. Accept current state — terminate with verdict `terminated-with-open-items` and treat surviving findings as Open items
3. Revisit the approach with the architect agent

Reply with `1` (optionally `1 5` for a custom N), `2`, or `3`.
```

- `1` → resume the loop with the ceiling raised by N.
- `2` → terminate with `terminated-with-open-items`.
- `3` → terminate with `escalated-to-architect`: populate `Open items` with the surviving findings as of cycle N, plus
  every severity-carrying deferred item item 5's deferred routes (the pre-existing lane and the narrowed-fuel Medium
  route) sent out of the loop in any cycle, plus the consolidated Nice-to-Have list per Step 6 sub-step 1 — deferred
  items are never silently lost, and Step 6 does not run on this path. Skip Step 6 entirely and surface the situation to
  the `architect` agent; its recommendation supersedes anything downstream consumers (`/start` Step 10, `/finish`
  Step 8) would otherwise do with the verdict block.

## Auto mode: resolve the post-drain survivors by provenance

Do not ask. Use the regression-vs-pre-existing split Step 6 sub-step 5 defines. What this gate adjudicates:

- **Provenance is adjudicated for Medium survivors only.** A surviving Critical or High is never adjudicated here:
  branch 1 routes it on severity alone, before provenance is considered, and no provenance finding can rescue it.
- **This is where item 5's tie-break is spent, not re-applied.** That tie-break parks ambiguous Mediums in the
  substantive lane so they reach a decision point with the whole loop's history in view — this is that point.
  Adjudicate each on the evidence now available; only one that still cannot be exonerated stays a regression.
- **Both branches are live for every survivor**, ambiguous or not — an unambiguous Medium regression that reached the
  ceiling is routed by branch 1 like any other regression.

The two branches:

- **Any surviving Critical or High, or any surviving finding that is a regression/defect of the change under review**
  → option 2 immediately: `terminated-with-open-items`, surviving findings as Open items. Five cycles of genuine
  non-convergence in an unattended run is a signal for a human, not more unattended cycles; the failing verdict makes
  `/finish auto` abort and `/auto` count the issue as a failure, which is the intended surfacing path.
- **Every surviving finding is Medium AND adjudicates here as pre-existing** → the implementation itself has converged;
  the residue is reviewer scope-widening into adjacent gaps, not this change's defects. Exit Step 5 with
  `passed-after-fixes` and route every survivor into Step 6 as a severity-carrying deferred item — item 5's pre-existing
  lane: rendered in sub-step 6's "Suggested defer as issue" group with severity in the tag slot, certified `specified`
  once its body clears the quality bar (a draft below it is rewritten or routed `needs decision`, never filed
  unlabeled), `Backlog` for these Mediums unless `security`-labeled — where auto mode's `suggested` default files them.

This trend-then-drain-then-provenance resolution is what auto mode substitutes for the prompt and nothing more: it does
not scope item 5's lane split, which routes every re-review's findings in both modes, on every cycle, ceiling or no
ceiling. The classifier in item 5 must not read this gate as a safety net that will re-classify whatever it defers.
