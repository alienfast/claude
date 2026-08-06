---
name: fleet-retro
description: Post-mortem on a finished fleet of parallel /loop /auto sessions — measures each session with scripts/fleet-metrics.py (blind-sleep burn, dispatch mode, heartbeat compliance, classifier blocks, state-vs-reality drift, review churn with findings origins, token and estimated-dollar attribution by agent type and model — cache-aware, with main-loop thinking share and cost per shipped issue), reconciles the shipped ledger against git and Linear, audits the issues the run FILED for duplicates and stranded states, then reports ranked findings and applies the fixes you approve. The bookend to /auto-prep. Use when the user says 'fleet retro', 'review the fleet run', 'how did the fleet do', 'post-mortem the auto run', or invokes /fleet-retro.
argument-hint: "[--since YYYY-MM-DD | --hours N] [checkout-path]"
model: opus
effort: xhigh
---

# Fleet Retro — What the Last /auto Fleet Actually Did

`/auto-prep` sizes a fleet before it runs. This is the other end: after N parallel `/loop /auto` sessions
finish, find where the capacity actually went and what the run left behind.

**Measure, do not recall.** The findings that matter are quantities, and a fleet's own bookkeeping is not
trustworthy about them — a session that dies without running Step 4 reports `shipped: []` for an issue it
merged. Run the analyzer first, form conclusions second.

Interactive by design. Report the findings, get approval, then apply. Never run unattended.

## Step 1 — Measure

```bash
~/.claude/scripts/fleet-metrics.py --checkout <repo> --since YYYY-MM-DD   # or --hours N, --all
```

Discovers sessions from `<repo>/tmp/auto-state-*.json`, matches each to its transcripts (main **and**
worktree dirs, **including `subagents/`**), and emits fixed per-session, review-churn, and
token-attribution tables plus a Flags section. `--json` for machine use. Subagent transcripts matter
disproportionately: a delegated reviewer that gets blocked or stalls is invisible to its parent, which
sees only a slow `Agent` call.

The review-churn table reads `tmp/quality-review-verdict-*.md`: cycles, findings by severity, the
SEVERITY/origin split (`plan`/`impl`/`spec`/`test`/`latent` — verdicts written before 2026-08-04
predate the tag, so coverage is reported as tagged/total, not assumed), and deferred filings paired
against the fleet's ships as a filed-per-shipped rate. Cycles alone is a weak churn signal — the
review loop's convergence design pins it near 2 — so read findings volume, severity, and origin mix
instead. The token table is what turns model/effort tuning into arithmetic: it shows where output
tokens actually went (orchestration vs. exploration vs. review vs. fixes), by agent type and model.

The schema is fixed so two retros are comparable — that cross-run diff is the main long-term value. Add
columns freely; never quietly redefine an existing one.

### Close the quota bracket — the one measurement only the user can supply

Ask for the current **weekly %** and **5h burst %** (`/usage`) and pair them with what `/fleet-launch`
recorded at dispatch. Two readings plus the run's measured tokens calibrate the allowance's absolute
size, which nothing else can:

```bash
jq -s '.[0].at_launch as $a | {launch: $a, end: {weekly_pct: <PCT>, burst_pct: <PCT>},
        consumed_weekly_pct: ($a.weekly_pct - <PCT>)}' tmp/fleet-quota-launch.json
```

Then divide the run's output tokens by `consumed_weekly_pct/100` to get the 100% basis, and report it
against `windows.peak_168h_output_tokens` — they should agree within noise, and a large gap means the
limit is metering something other than output tokens (cache reads run ~400x output volume here), which
is worth knowing explicitly rather than rediscovering.

**Report three numbers back to `/auto-prep`'s next run**, all in the `windows` block already emitted:

1. `peak_5h_output_tokens` with `peak_5h_concurrency` — the burst-window floor, and the basis for the
   concurrency cap. It rises only when a fleet survives a denser window, so it is worth noting when a
   run sets a new one.
2. `output_tokens_per_session_hour_at_peak` paired with that concurrency — one point on the burn-rate
   curve. Recorded across runs at different `n`, these replace the flat-rate assumption that makes
   large-`n` projections optimistic.
3. Any `quota_stall_groups` — sessions that died together untagged. **This is the fingerprint that
   distinguishes a clean deadline wind-down from an allowance cutoff**, and only the second leaves
   in-flight worktrees needing a human. Check those worktrees before reaping anything.

Compare realized burn against the `sizing.rate_tok_per_session_hour` that
`tmp/fleet-recommendation.json` assumed. A projection that missed by 2x is the finding — silently
repeating it next run is how a sizing error becomes permanent.

## Step 2 — Read the flags, then chase them

The script finds *shapes*; it does not explain them. Each flag is a lead:

| Flag | What it usually means | Where to look |
|---|---|---|
| never armed a ScheduleWakeup | silent loop death — the run stopped with no `NO-CANDIDATES`/`AUTO-HALTED` | should now be caught by `hooks/auto-heartbeat.sh`; if it recurs, that hook failed |
| shipped without recording it | Step 4 never ran; the run's own tally undercounts | compare against `git log` and Linear state |
| classifier blocks | a permission-shaped stall; check whether the agent rerouted or silently dropped the step | the subagent transcript — read what it did *next* |
| contamination halts | the graduated contamination response (`/start` Step 8 item 1) hard-stopped an issue — each is either a real mis-bound delegate or a false positive the graduation failed to absorb | adjudicate every halt **true/false positive** — flagged paths vs the delegation's scope and footprint, via the issue's contamination comment and the transcript — and read the benign-continue note comments on issues alongside; the false-positive rate is the number that decides whether further relaxation is justified |
| dangling tool calls | unanswered prompt or killed turn | the tail of that transcript |
| high blind-sleep % | agents waiting on background dispatch | correlate with the `bg/sync` column |
| shipped but no commit | the ledger is wrong, or the merge never landed | `git log --all --grep=<ID>`, `/merge-queue` |
| shipped with no persisted verdict | `/quality-review` never persisted its Output block, or the issue shipped outside the review pipeline | that issue's `/full` run in the session transcript |
| plan-heavy origin mix | the posted plans leak requirements/scope — planning is the stage to tune (model, effort, or a dedicated plan/plan-review step) | the tagged findings' issues; diff each posted plan against what the review had to fix |
| impl-heavy origin mix | plans were right, code diverged — developer model/effort or delegation prompts are the lever, not more planning | the fix-dispatch prompts and the findings they addressed |
| high filed-per-shipped rate | each shipped issue spawns near or above one new issue — at that rate the backlog cannot drain | Step 3's Linear census: severity + certification mix of what was filed |

**Correlate across sessions before concluding.** The 2026-08-01 run's biggest finding existed only in the
comparison: blind-sleep burn tracked dispatch mode exactly (0% at 0 background dispatches; 55% at 32). No
single session showed it. When one column varies wildly between sessions doing the same work, that spread
is the finding.

Read the actual transcript for anything you intend to act on. The script tells you a 337-minute gap
happened; only the transcript says a classifier denied an rspec run twice and the third retry escalated to
a permission prompt.

## Step 3 — Reconcile the ledger

Independent of the transcripts, establish what the run really produced:

- **Shipped** — every issue in `shipped[]` plus every `SHIPPED-*` tag observed. Confirm each is in a
  release-ready state and has a commit. The script's merge reconciliation flags the gaps.
- **Filed** — issues *created* during the window. This is the half a retro forgets.

```bash
linear-cli api query 'query { issues(filter: { team: { key: { eq: "<KEY>" } }, createdAt: { gte: "<ISO>" } }, first: 100) { nodes { identifier title createdAt state { name } labels { nodes { name } } } } }' -o json \
  | jq -r '.data.issues.nodes | sort_by(.createdAt) | .[] | "\(.identifier) | \(.state.name) | [\(.labels.nodes|map(.name)|join(","))] | \(.title)"'
```

- **Net backlog delta** — drained vs. filed, stated as the reproduction ratio **R = issues filed /
  issues shipped** for the window (the script's filed-per-shipped rate covers only review-pipeline
  filings; this census is the full number). **The pool is the workable backlog only — `Planned`,
  `Backlog`, `Triage`, plus in-flight — and `Ready for Release` counts as done in every metric
  here.** Deployment cadence is a separate axis; RFR is an unstarted-*type* state in Linear, so a
  naive state-type census sweeps shipped-awaiting-deploy work into "open" and overstates the pool
  (the 2026-08-04 census misread it by 220 issues before this rule existed). Track R across retros — it is the convergence gauge:
  below 1 the backlog drains and the drain rate says when it empties; at or above 1 no amount of
  fleet capacity catches up, and the lever is filing policy or defect prevention, not more sessions.
  Read it with the severity mix of what was filed: an R near 1 made of Medium deferrals is the
  reviewer mining a finite latent pool and should decay across runs; an R near 1 with fresh
  Critical/High findings means new code is minting defects as fast as the fleet retires them. A
  security sweep legitimately grows the backlog as each fix exposes adjacent surface; that is a
  conscious call to surface, not a defect to hide.
- **Remaining pool** — `~/.claude/scripts/next-candidates.sh --team <KEY> --label specified` so the next
  run's fuel is a known quantity.

## Step 4 — Audit what the run filed

Filed issues are output too, and they fail in ways the metrics cannot see. Check every one for:

- **Duplicates.** Re-run each filing's dedup search *properly* — single tokens, one per call (linear skill
  gotcha #14). A phrase-shaped search returns empty with exit 0 and reads exactly like "no duplicate".
- **Stranded states.** Anything in `Triage` is invisible to `/next` and `/auto` permanently. List it:
  `linear-cli api query` filtered on `state.name == "Triage"`.
- **Certification.** `specified` present where the issue is meant to be auto-shippable; absent where it
  needs `/spec` first. Never attach `specified` here — that is `/spec`'s human gate, and auto-certifying
  from a retro defeats the thing that keeps `/auto` safe.
- **Correct cancellations.** An issue absorbed by another's fix should be canceled *with its evidence
  carried onto the survivor first* — the losing issue often holds a verified vector the winner lacks.

## Step 5 — Report

Lead with where the capacity went, in hours. Then, ranked by cost:

1. **Ledger** — shipped, filed, net delta, remaining certified pool.
2. **Capacity** — total session-hours and what each fault cost, as hours and as a share of the fleet.
3. **Findings** — one per fault: evidence (numbers + `file:line` or transcript timestamps), root cause,
   and the specific fix. Distinguish a **compliance failure** (the rule exists and was ignored — prose
   will not fix it again) from a **gap** (no rule covers it).
4. **Issue-quality** — duplicates, strandings, certification gaps.
5. **Readiness** — anything blocking the next run: dirty tree, leftover worktrees, merge queue, stranded
   candidates.

Prefer a mechanical guard over more prose whenever a rule already existed and lost. That is what
`hooks/full-continue.sh`, `hooks/auto-heartbeat.sh`, and `hooks/no-blind-sleep.sh` each are — every one
replaced instructions that had already failed two or more times.

## Step 6 — Apply on approval

Present findings and wait. On approval, implement, then verify honestly:

- Hooks and scripts ship with a regression suite carrying the **real transcript shape** as a fixture, and
  every existing suite stays green (`hooks/*.test.sh`).
- Re-run `fleet-metrics.py` after any change to numbers you cited — an ad-hoc measurement taken during
  investigation is easy to overstate, and a figure baked into a hook header must be one the script
  reproduces.
- Settings changes load at **session start**: state plainly that a new hook is inert in the current
  session and live for the next fleet.

Route the config-improvement half through **`/reflect`** rather than reimplementing it — it already owns
batching, the certified-issue filing, and the `keeper`-label path for `~/.claude` targets that `/auto`
cannot ship. This skill owns the fleet-specific half: metrics, ledger, issue audit.

Commit and push only on an explicit grant (`standards/git.md`) — running this skill is not one.
