---
name: fleet-retro
description: Post-mortem on a finished fleet of parallel /loop /auto sessions — measures each session with scripts/fleet-metrics.py (blind-sleep burn, dispatch mode, heartbeat compliance, classifier blocks, state-vs-reality drift, review churn with findings origins and the implementing-tier join, token and estimated-dollar attribution by agent type and model plus the developer-lane split (implementation vs fix batch) — cache-aware, with main-loop thinking share, cost per shipped issue, the context-size distribution (the autocompact gauge), shipped-issue provenance (the treadmill share), and a cross-run trend ledger diffing the last six fleets' headline gauges), reconciles the shipped ledger against git and Linear, audits the issues the run FILED for duplicates and stranded states, then reports ranked findings and applies the fixes you approve. The bookend to /auto-prep. Use when the user says 'fleet retro', 'review the fleet run', 'how did the fleet do', 'post-mortem the auto run', or invokes /fleet-retro.
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

### Confirm the fleet has finished before reporting — a live session mimics a fault

Every signal that rests on bookkeeping *not yet written* reads identically for a session mid-run and one
that died: its state file still says `status: "active"` with an empty `reason` (Step 4 writes `reason`
only alongside a terminal status), its transcript carries no terminal tag and no
`ScheduleWakeup(stop: true)`, its latest ship stays out of `shipped[]` until its own Step 4 runs, and its
in-flight tool call has no result yet. So **never armed a ScheduleWakeup**, **shipped without recording
it**, and **dangling tool calls** are artifacts against a live session — and because a live session
carries no terminal tag, `quota_stalls()` marks it `unrecovered` at its last activity, so two live
sessions cluster into one group (zero lost hours, `limit_kind: null`) and fire the "run was CUT OFF, both
peaks are CEILINGS" banner that `/fleet-launch` sizes the next fleet against. Measured on the 2026-08-08
basefund run, begun ~10 minutes before the last session closed out: the missing-terminal-status and
un-armed-loop findings were both artifacts, and that session wrote a correct `halted` status with an
accurate `reason` while the report was still being drafted.

The event-based flags are real either way — classifier blocks, contamination halts, ran without a
surviving ledger, shipped with no persisted verdict, off-schema verdict body. Only the bookkeeping ones
need this gate.

**`ps -p <the state file's pid>` does not settle it.** Under `claude agents` every session in a fleet
embeds the *fleet root* pid (`skills/auto/SKILL.md` Step 0 and Step 4), so it answers identically for all
of them and can go empty mid-run; `/fleet-status`'s ALIVE/dead column reads the same `pid`/`pidStart`
pair and inherits the limitation. Compare the newest transcript `mtime` against now instead — and stale
is not finished either: a quota-stalled session resumes hours later on a pending wakeup, so cross-check
`tmp/fleet-deadline.json` (passed, or `stopped`) and the sessions' harness limit messages. When a session
may still be writing, either wait for it or mark its row provisional — never file a bookkeeping finding
against it. `/fleet-status` is the read-only skill for a fleet still in flight.

```bash
~/.claude/scripts/fleet-metrics.py --checkout <repo> --since YYYY-MM-DD   # or --hours N, --all
```

Discovers sessions from `<repo>/tmp/auto-state-*.json`, matches each to its transcripts (main **and**
worktree dirs, **including `subagents/`**), and emits fixed per-session, review-churn, and
token-attribution tables plus a Flags section. `--json` for machine use. Subagent transcripts matter
disproportionately: a delegated reviewer that gets blocked or stalls is invisible to its parent, which
sees only a slow `Agent` call.

Three gauges ride the same run and the retro reads all three, not just the tables:

- **Context distribution** — share of billable prompt volume by context size at call time. This is the
  autocompact gauge: fleet-launch pins `--autocompact 150000` (2026-08-14; before that, `opus[1m]`
  sessions never compacted and the 2026-08-13/14 fleets ran 91-94% of their volume at >=200k context).
  Expect the >=200k share near zero on post-change runs; a high share means compaction didn't engage
  (check the dispatch flags), and a falling share with RISING churn gauges means the threshold is too
  aggressive — raise it rather than reverting.
- **Shipped-issue provenance** — joins the shipped set against the Step 3 Linear exports; the fresh
  share (created during or <=7 days before the run) is the treadmill gauge, read alongside R.
- **Cross-run trend** — every windowed run appends its headline row to
  `tmp/fleet-metrics-history.jsonl` (keyed by session set, so re-runs replace) and the report's tail
  diffs the last six fleets. This is where drift lives: the $90 → $161 cost-per-issue climb across the
  2026-08-05..14 fleets sat in individually-saved reports that nothing compared until it was found by
  hand. Read $/issue through its two factors — ktok/issue (work per issue) x $/Mtok out (context
  weight per unit of work) — before proposing levers, since they route differently (churn/specs vs
  autocompact/model mix).

The review-churn table reads `tmp/quality-review-verdict-*.md`: cycles, findings by severity, the
SEVERITY/origin split (`plan`/`impl`/`spec`/`test`/`latent` — verdicts written before 2026-08-04
predate the tag, so coverage is reported as tagged/total, not assumed), and deferred filings paired
against the fleet's ships as a filed-per-shipped rate. Cycles alone is a weak churn signal — the
review loop's convergence design pins it near 2 — so read findings volume, severity, and origin mix
instead. The token table is what turns model/effort tuning into arithmetic: it shows where output
tokens actually went (orchestration vs. exploration vs. review vs. fixes), by agent type and model.

The schema is fixed so two retros are comparable — that cross-run diff is the main long-term value. Add
columns freely; never quietly redefine an existing one.

**Do not ask for `/usage` readings** (keeper-settled 2026-08-10): the launch/close quota-bracket
calibration is retired — the weekly allowance stopped being a constraint when the keeper moved to
multiple accounts, and concurrency is fixed at 3 by the measured 5h-burst bracket (`/auto-prep`
Step 5). No `tmp/fleet-quota-launch.json` is written at dispatch anymore, so there is nothing to
close here.

**Report four numbers**, all in the `windows` block already emitted:

1. `peak_5h_output_tokens` with `peak_5h_concurrency` — the burst-window floor. It rises only when a
   fleet survives a denser window, so it is worth noting when a run sets a new one.
2. `output_tokens_per_session_hour_at_peak` paired with that concurrency — one point on the burn-rate
   curve. Recorded across runs at different `n`, these replace the flat-rate assumption that makes
   large-`n` projections optimistic.
3. Any `quota_stall_groups` — sessions that stopped together. **This is the fingerprint that
   distinguishes a clean deadline wind-down from an allowance cutoff**, and only the second leaves
   in-flight worktrees needing a human. Check those worktrees before reaping anything. A group whose
   `kind` is `recovered` looks *entirely* clean in every other column — the sessions woke hours later
   and drained with proper terminal tags — so this field is the only thing that will tell you.

   **Expect several groups on a long run, and read `recovery_lag_s` rather than the lost-hours total.**
   An allowance that refills on a fixed period cuts a fleet off once per period, so a 12h run at the
   sustainable concurrency produces two or three groups. Lost hours bundle two costs: the allowance's
   own duration, which nothing can avoid, and the lag after it reset, which is the entire actionable
   finding. Report them separately. The cheap groups are not noise — they are the **control**: on
   2026-08-14 the 04:48 cutoff cost 0.25 avoidable session-hours and the 10:05 one cost 4.96, same
   fleet and same limit, and the only difference was whether a `ScheduleWakeup` happened to be pending
   when the turn died. That comparison is what identifies the mechanism; a report showing only the
   expensive stall reads as "quota is the problem" and points at `n`.

   **Read `limit_kind`, but treat it as the harness's WORDING, not as the meter's scope — the two
   disagree.** The field is read from the harness message (`You've hit your <kind> limit · resets
   <time>`), so it is evidence about what was said, and the limits produce an identical
   synchronized-silence fingerprint. `weekly` caps total session-hours (lever: **account rotation**
   since 2026-08-10 — the keeper runs multiple accounts, so a weekly cutoff says nothing about fleet
   shape). When the field is absent no limit message was found at all — treat the cause as
   unestablished (machine sleep, daemon restart, network) rather than assuming quota.

   **`session` does NOT mean per-session — measured 2026-08-14, and reading it that way sends the
   whole retro to "the lever is neither".** Two cutoffs that run reported `session`, and both were the
   account-level 5-hour window: the stated resets fell on exact 5h boundaries (12:10am → 5:10am →
   10:10am CDT), and every session that was *actively making a request* hit within 9s at the first
   cutoff and 32s at the second. A genuinely per-session cap cannot synchronize independently-launched
   sessions to the second. The one session that missed both was idle at those instants and so made no
   request to be refused — **absence from a cutoff is evidence about activity, not about scope**, so
   check each session's entry count in the window before concluding a limit spared it. Route a
   `session` cutoff exactly as a `5-hour` one: the levers are **n** and stall recovery.

   Derive the ceiling per cutoff rather than trusting one number: sum output tokens in the 5h window
   ending at each cutoff, deduped by `requestId` across every transcript on the machine (the meter is
   account-wide, so fleet-scoped sums undercount, and subagent transcripts double-count without the
   dedup). The 2026-08-14 run measured **1,394,893** and **1,213,190** — two independent ceilings for
   one `limit_kind`, ~13% apart.

   **Cross-run token comparisons are valid only within one `limit_kind`.** The 2026-08-08 retro nearly
   shipped a confident, wrong conclusion here: trailing-5h total-billable at three cutoffs agreed to
   **0.08%** while output diverged **23%**, which reads unmistakably as having identified the meter —
   and two of those cutoffs were `weekly` while the third was a `session` limit. Unrelated ceilings can
   coincide closely; a 5h window is also simply the wrong instrument for a weekly cutoff. (That third
   one now reads as a 5h cutoff under the correction above, which does not rescue the comparison — a
   `weekly` and a 5h ceiling agreeing to 0.08% is still coincidence.)
4. **When a stall group exists, `peak_5h_output_tokens` is a CEILING, not a floor** — the run was cut
   off at that volume, so it bounds the limit from above where every un-throttled observation bounds
   it from below. Say plainly which kind of observation the run produced. It is a ceiling on the limit
   named in `limit_kind` only; a weekly cutoff leaves the 5h burst ceiling still unobserved.

   **A `session`/`5-hour` cutoff at n≤3 re-opens the settled n=3 concurrency cap (`/auto-prep` Step
   5) — and the 2026-08-14 answer was to KEEP n=3 and fix recovery instead.** Divide the measured
   ceiling by per-session burn in the same window: that run's three sessions burned 425–510k each
   against a 1.21–1.39M ceiling, putting sustainable n at ≈2.85. n=3 therefore runs at ~102% of the
   refill rate and will hit the ceiling roughly **once per 5h window by construction** — which is the
   right trade at ~5–22min of reset wait per stall, and ruinous only when recovery is not automatic
   (it cost 4.85 session-hours and ~2 issues that run). Shrinking to n=2 forfeits ~30% of the
   allowance to fix a stall that costs minutes. Check the recovery mechanism before touching n.

**A session that wound down deliberately is not a stalled one, however long it then sits quiet.** The
detector already excludes a silence beginning at a `ScheduleWakeup(stop: true)` with no limit message,
because an ended loop has no wakeup pending and going quiet is its contract. Do not undo that by hand
when reading the report: on 2026-08-08 one session read the deadline with 18 minutes left, judged that
too little for an issue averaging 1.5–2.5h, and halted — and counting its 9.3h of correct silence as
lost capacity would have turned exemplary judgement into the run's largest apparent fault (26.1 vs the
real 16.8 session-hours).

Compare realized burn against the `sizing.rate_tok_per_session_hour` that
`tmp/fleet-recommendation.json` assumed. A projection that missed by 2x is the finding — silently
repeating it next run is how a sizing error becomes permanent.

## Step 2 — Read the flags, then chase them

The script finds *shapes*; it does not explain them. Each flag is a lead:

| Flag | What it usually means | Where to look |
|---|---|---|
| never armed a ScheduleWakeup | silent loop death — the run stopped with no `NO-CANDIDATES`/`AUTO-HALTED` | should now be caught by `hooks/auto-heartbeat.sh`; if it recurs, that hook failed |
| a stall far outlasting its own stated reset | the cutoff killed the turn **mid-iteration**, before any wakeup was armed — so nothing was pending to wake it and the session is dead until a human prompts it. **No hook can catch this**: a turn killed by an API error fires no Stop hook at all (verified — no `stop_hook_summary` follows the limit message), so `auto-heartbeat.sh` is structurally unable to see it | compare each stalled session's resume against the reset named in its limit message. A session with a wakeup pending resumes 1–8 min after reset; one without does not resume at all. On 2026-08-14 that split 1-recovered / 2-dead within one cutoff — 4.85 avoidable session-hours. The mitigation is `scripts/auto-stall-watch.sh` (launchd agent `com.alienfast.auto-stall-watch`, installed by `update.sh`) — detection only, since a live background agent accepts no scripted prompt, so recovery is the operator running `claude attach <id>`. If a stall outlived it silently, read `~/.claude/logs/auto-stall-watch.log` for whether the watcher flagged it and whether anyone acted |
| shipped without recording it | Step 4 never ran; the run's own tally undercounts | compare against `git log` and Linear state |
| classifier blocks | a permission-shaped stall; check whether the agent rerouted or silently dropped the step | the subagent transcript — read what it did *next* |
| contamination halts | the graduated contamination response (`/start` Step 8 item 1) hard-stopped an issue — each is either a real mis-bound delegate or a false positive the graduation failed to absorb | adjudicate every halt **true/false positive** — flagged paths vs the delegation's scope and footprint, via the issue's contamination comment and the transcript — and read the benign-continue note comments on issues alongside; the false-positive rate is the number that decides whether further relaxation is justified |
| dangling tool calls | unanswered prompt or killed turn | the tail of that transcript |
| high blind-sleep % | agents waiting on background dispatch | correlate with the `bg/sync/ign` column — and read `sync` as what the model *typed*, never as how dispatches ran: a non-zero `ign` means the harness lacked `run_in_background`, every dispatch backgrounded regardless, and neither a low `sync` count (no discipline failure) nor a high one (no proof of discipline) says anything about behavior |
| shipped but no commit | the ledger is wrong, or the merge never landed | `git log --all --grep=<ID>`, `/merge-queue` |
| shipped with no persisted verdict | `/quality-review` never persisted its Output block, or the issue shipped outside the review pipeline | that issue's `/full` run in the session transcript |
| plan-heavy origin mix | the posted plans leak requirements/scope — planning is the stage to tune (model, effort, or a dedicated plan/plan-review step) | the tagged findings' issues; diff each posted plan against what the review had to fix |
| impl-heavy origin mix | plans were right, code diverged — developer model/effort or delegation prompts are the lever, not more planning. **Precondition: read the script's implementing-tier join before routing at model/effort.** /quality-review pins fix batches to sonnet-tier developers, so the by-agent token table always reads "developer is mostly sonnet" no matter what tier implemented — on the 2026-08-09 basefund fleet that table drove a move-to-opus proposal while 86% of the developer/sonnet row was fix batches, 14 of 23 issues had already been implemented at the opus agent default, and the 8 discretionary sonnet downgrades carried no more impl findings per issue than the opus group. Model is the lever only when the join puts the impl-origin findings on issues implemented at the *lower* tier; when they sit on the top tier already, look at the delegation prompts or the downgrade discretion instead | the **Implementing-tier join** and **Developer lanes** lines in the script's churn and token sections; then the fix-dispatch prompts and the findings they addressed |
| test-heavy origin mix | plan and code were sound — review is repairing coverage the implementation never wrote (`test` = behavior correct but unpinned), so the lever is the test bar in `/start` Step 8's `developer` implementation dispatch, which today asks for no coverage on the change beyond a green `pnpm check`; not planning, and not developer model/effort. Some share of this bucket is the *intended yield* of `quality-reviewer`'s test-review modality rather than churn to design away | the tagged findings' issues; for each, check whether the fix touched spec files or app files — an app-file fix means the finding was mis-tagged `test` and belongs to `impl` |
| spec-heavy origin mix | the certified spec itself is what review keeps correcting — the lever is `/spec` rigor at certification time, not planning or implementation effort | the tagged findings' issues; diff each issue's Problem/Success Criteria against what the review had to restate |
| latent-heavy origin mix | pre-existing defects the change merely surfaced — NOT a signal about this fleet's plan, code or specs, and not a lever at all. Expect it to decay across runs as the pool drains; a share that stays flat or rises means the reviewer is finding genuinely new latent surface, which is worth its own investigation | Step 3's Linear census: are these being filed, and is the filed-per-shipped rate falling run over run? |
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
# One command, two consumers: the census listing below, and tmp/fleet-linear-window.json, which
# fleet-metrics.py's shipped-issue provenance join reads. Keep `creator` in the field list — the
# join's by-creator split needs it.
linear-cli api query 'query { issues(filter: { team: { key: { eq: "<KEY>" } }, createdAt: { gte: "<ISO>" } }, first: 100) { nodes { identifier title createdAt creator { name displayName } state { name } labels { nodes { name } } } } }' -o json \
  | tee tmp/fleet-linear-window.json \
  | jq -r '.data.issues.nodes | sort_by(.createdAt) | .[] | "\(.identifier) | \(.state.name) | [\(.labels.nodes|map(.name)|join(","))] | \(.title)"'

# Provenance coverage for ships created BEFORE the window (the window census misses them by
# construction): fetch the shipped set itself and save it where the script looks. <numbers> is the
# numeric part of each shipped identifier, comma-separated.
linear-cli api query 'query { issues(filter: { team: { key: { eq: "<KEY>" } }, number: { in: [<numbers>] } }, first: 100) { nodes { identifier createdAt creator { name displayName } } } }' -o json > tmp/fleet-shipped-issues.json
```

Re-run `fleet-metrics.py` after writing these — its Shipped-issue provenance section then classifies
every ship (during-run / week-before / older) instead of reporting them unknown.

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
  **Re-verify each carried claim against current code before writing it onto the survivor; never transcribe.**
  The losing issue is stale by construction — that is why it is being canceled — and its cited evidence is the
  oldest part of it. Measured while canceling BF-1052: of three cited consumers, two (`Organization::EditTeam`,
  `Tenant::TransferClient`) had since been rewritten pair-wide and locked, and `Accessable#access_for` was
  described as a bare `.last` when it is a three-tier precedence chain. Carried verbatim, all three would have
  become a durable and wrong record on the survivor, arguing from consumers that are no longer vulnerable.
  Re-checking replaced them with the one claim that still holds — `Types::Tenant`'s unordered `find_by`
  disagreeing with `access_for`'s precedence, so a duplicate pair renders the sharing toggle off while sharing
  is on. Carry what survives the re-check, and state in the comment which claims were dropped and why.

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

**Then run the batched reflection: `Skill(skill: "reflect", args: "fleet")`.** Since 2026-08-15 this is
the ONLY scheduled reflection surface — the per-issue `/quality-review` tail is retired (it cost 7–13
minutes plus two verification dispatches on every shipped issue and could not see cross-session
patterns), so skipping it here means no reflection happens for the run at all. Hand it the retro's
findings; it owns the triage bar, batching, the certified-issue filing, and the `keeper`-label path for
`~/.claude` targets that `/auto` cannot ship — and its fleet mode's filing-quality lens (duplicates,
missing links, stranded states) is fed directly by this skill's Step 4 audit. This skill keeps the
fleet-specific half: metrics, ledger, issue audit.

Commit and push only on an explicit grant (`standards/git.md`) — running this skill is not one.
