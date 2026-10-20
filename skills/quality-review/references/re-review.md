# The re-review: verification of the fix delta

Step 5 item 4 reads this on the first re-review of a run.

## The template

```md
Task for quality-verifier: Adversarial re-review of fixes for PL-13
Context: Previous adversarial review findings were addressed. Verify the fixes — this is a verification pass over the fix delta, NOT a from-scratch re-review of the whole change.
In scope: (a) each fix actually resolves its finding; (b) any finding closed by argument rather than by change — test the argument's soundness; (c) regressions in the fix delta's blast radius: callers, callees, and shared state of the changed lines.
Out of scope: review modalities the initial review did not run (do not introduce a mutation sweep, comment-accuracy audit, or similar new lens here), and re-litigating unchanged code a prior cycle already examined. If you notice a real issue outside the fix delta anyway, report it in its severity section flagged `[out-of-delta]` — it is routed by disposition, not automatically treated as loop fuel.
Changed files: [list of files touched by the fixes]
Fix delta (inline unified diff, captured per the snapshot recipe — never just the file list):
[the concatenated per-file diffs]
Previous findings addressed: [list]
Accepted risks this cycle: [each residual a fix accepted by argument, phrased as the measurement to make — omit this line entirely if there are none]
Already tracked (do NOT re-flag, unless this cycle's fix delta made one worse — a latent gap turned reachable, a narrow case turned general — which is a new fix regression to report at its real severity): [each finding already filed as a Linear issue — its issue ID and a one-line summary — and each finding already routed to a deferred filing but not yet filed, with its planned disposition; omit this line entirely if there are none]
Acceptance: Confirm findings resolved. Flag fix regressions and unsound closures as Critical/High/Medium with concrete scenarios; flag anything else `[out-of-delta]`.
```

Above 200 lines the delta goes by path (`fix-delta.md` § Passing a large delta by path). In `wt` mode the READ-SCOPING
block precedes this body (`worktree-hygiene.md`).

## Why verification, not re-discovery

Multi-cycle grinds come from re-reviews escalating their own modality each cycle — behavioral findings in cycle 1,
spec-pinning mid-loop, a first-ever mutation sweep at cycle 5 — so convergence means "the reviewer ran out of new
lenses", which a strong reviewer never does. Depth belongs in Step 3's initial review, which fans out parallel domain
reviewers and chooses its own modalities; the re-review's job is to prove the fixes sound. A latent finding the initial
review missed can still arrive `[out-of-delta]`, and substantive defects of the change still gate through item 5's
routing — the loop just stops paying a full review cycle for each new lens. The `quality-verifier` tier enforces the
same boundary economically: a verification pass whose scope is bounded by contract does not need the discovery
configuration. The class-shaped sweep below is the one sanctioned expansion of re-review scope — a specific shared
decision to hunt for, not a new modality.

## Broaden for class-shaped findings — and bound the sweep so it terminates

If any finding addressed this cycle described a duplicated, re-derived, or copy-pasted decision — the same predicate,
guard, formatting rule, or authorization/scoping check reimplemented independently at more than one call site — do not
scope the re-review to only the fixed files. Add a sweep instruction naming the shared decision and the directory/domain
to search (e.g. "Also search `apps/app/src/domains/stx/` for any other call site re-deriving
`isCoordinator || isClosing || isFlowSender(flow)` instead of importing it from `entityScope.ts`"). A file-scoped
re-review lets sibling instances surface one at a time across many cycles instead of being caught in one pass.

Broadening is for *finding* the class, not for fixing all of it inside this ticket, and the convergence test cannot
terminate work discovered mid-review. So when a class-shaped sweep is dispatched, require the fix delegation to:
**(a)** produce a **complete audit list** of examined sites with a disposition for each (fixed / already-guarded /
deliberately-not, with the reason), so coverage is auditable without re-sweeping; **(b)** **fix only** the sites
reachable from the change under review, plus any divergence the sweep itself introduces — a half-applied sweep can be
worse than none, breaking an invariant that held precisely because both sides failed identically; **(c)** **report, do
not fix**, every remaining instance, routed as deferred items per item 5's lanes. (b) and (c) govern only what the sweep
reaches **beyond** the findings' named files — inside those files `fix-dispatch.md`'s sibling rule is unchanged and
still wins. State the bound in the delegation prompt in as many words ("fix every sibling in the findings' files;
beyond them, fix only what this change reaches and report further instances"), or the next cycle re-opens the sweep at
the new frontier, finds the next frontier plus the Highs the partial sweep itself introduced, and the loop cannot
converge.

## An accepted risk is a closure by argument — name it, with the question phrased as a measurement

A fix can close its finding by *change* while accepting a residual by *argument*: the recovery valve lands, and the
remainder — "it degrades only to the pre-change behavior, and only for a narrow population" — is recorded as a deliberate
trade-off. The degradation is read off the code that produces it; the **population size** is the half that gets inferred
from that same code rather than measured, and when it turns out to be the common case the trade-off was never a
trade-off — it is the requirement, undelivered. In scope (b) already owns this on arrival (an accepted residual is a
closure by argument, and its falsification is an unsound closure — loop fuel at any cycle), so this adds no new
modality; what is missing is only the routing: neither `Previous findings addressed` nor `Already tracked` is where a
residual accepted *inside* a fix lands, and the verifier cannot test an argument it was never shown. Little else is
positioned to catch it — this template carries no `Issue requirements:` line, `pnpm check` cannot evaluate a claim about
a population, and `/finish` decides the issue's checkboxes by this session's own assessment. So fill
`Accepted risks this cycle:` with each residual, stating the question as a measurement — "determine how large that
population actually is" — never as a summary of why it was accepted, which invites agreement instead of a check. A valve
that could not distinguish "the actor lost their grant" from "the actor never had one" has been accepted as narrow and
measured as the majority of real bindings.
