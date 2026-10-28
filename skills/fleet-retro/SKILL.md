---
name: fleet-retro
description: Post-mortem on a finished fleet of parallel /loop /auto sessions — measure each session with scripts/fleet-metrics.py (capacity, churn, cost, trend), reconcile the shipped ledger against git and Linear, audit what the run filed, report ranked findings, apply approved fixes. Use when the user says 'fleet retro', 'review the fleet run', 'how did the fleet do', 'post-mortem the auto run', or invokes /fleet-retro.
argument-hint: "[--since YYYY-MM-DD | --hours N] [checkout-path]"
model: opus
effort: xhigh
---

# Fleet Retro — What the Last /auto Fleet Actually Did

`/auto-prep` sizes a fleet before it runs. This is the other end: after N parallel `/loop /auto` sessions finish, find
where the capacity actually went and what the run left behind.

**Measure, do not recall.** The findings that matter are quantities, and a fleet's own bookkeeping is not trustworthy
about them — a session that dies without running Step 4 reports `shipped: []` for an issue it merged. Run the analyzer
first, form conclusions second.

Interactive by design. Report the findings, get approval, then apply. Never run unattended.

## Membership — only the autonomous loop writes a ledger

The operator routinely works interactively in the same checkout while a fleet runs, and such a session claims issues,
creates worktrees, files issues and ships through `/finish` exactly like a fleet session. What it never does is write a
`tmp/auto-state-*.json` ledger — that file is the autonomous loop's own run state (`skills/auto/SKILL.md` Step 4) — so
it presents as the very fault Step 2 teaches you to hunt: work with no bookkeeping.

Discriminate before counting it. `fleet-metrics.py`'s `auto_session_mode` is the test: the transcript's FIRST human turn
carrying text must be the autonomous-loop command, and a later mention does not count. Read that turn yourself rather
than inferring membership from a table. Absence from the script's tables is not proof of interactivity either: an
explicitly named `--sessions` key skips the probe, and a ledger-less in-fleet session inside the run's own span is
excluded outright (the `--allow-partial` WARNING surfaces that case). `/fleet-status`'s In-flight section prints each
live worktree's owning session id from the identity sidecar with no session-type filter, so an owner id read there is
not a fleet member until its transcript says so. One mis-admitted session moves every headline — session-hours,
$/issue, filed-per-shipped — and the fix plan resting on them.

## Finished — a live session mimics a fault

Every signal that rests on bookkeeping *not yet written* reads identically for a session mid-run and one that died: its
ledger still says `status: "active"` with an empty `reason` (Step 4 writes `reason` only beside a terminal status), its
transcript carries no terminal tag and no `ScheduleWakeup(stop: true)`, its latest ship stays out of `shipped[]` until
its own Step 4 runs, and its in-flight tool call has no result yet. So **never armed a ScheduleWakeup**, **shipped
without recording it** and **dangling tool calls** are artifacts against a live session — and because a live session
carries no terminal tag, `quota_stalls()` marks it `unrecovered`, so two live sessions cluster into one group (zero lost
hours, `limit_kind: null`) and fire the "run was CUT OFF, both peaks are CEILINGS" banner `/fleet-launch` sizes the
next fleet against.

The event-based flags are real either way — classifier blocks, ran without a surviving ledger, shipped with no persisted
verdict, off-schema verdict body, drained early while siblings kept picking (it keys on a `drained` ledger, which a live
session never has). So is `wound down but never finalized its ledger`: it fires only on a terminal tag or a
stop-wakeup, exactly what a live session lacks, so its own condition is the finished gate. It complements `ended without
recording an outcome` — that one catches a loop that never terminated, this one a loop that terminated and lost only
its bookkeeping write; nothing is stranded, but `/fleet-status` reads the same field and renders the session as live or
wedged, inviting a needless kill.

Settle it from each transcript's last TIMESTAMPED record against now:
`tail -200 <transcript> | jq -r 'select(.timestamp) | .timestamp' | tail -1`. Not `ps -p <the ledger's pid>`: under
`claude agents` every session embeds the fleet root pid (`skills/auto/SKILL.md` Step 0 and Step 4), so it answers
identically for all of them; the session registry (`claude agents --json`) says whether a session is *running*, not
whether it has finished writing. Not `mtime`: the harness keeps appending untimestamped bookkeeping rows
(`last-prompt`, `cost-state`, `ai-title`, `agent-name`) to a finished session. And stale is not finished: a
quota-stalled session resumes hours later on a pending wakeup, so cross-check the fleet's marker — `tmp/fleet-deadline-<slug>.json`,
or its archived `tmp/fleet-deadline-<slug>.<launch_epoch>.json` once a later launch of that slug displaced it — (passed,
or `stopped`) and the sessions' harness limit messages. When a session may still be writing, wait for it or mark its row
provisional — never file a bookkeeping finding against it. `/fleet-status` is the read-only skill for a fleet still in
flight.

## Step 1 — Measure

```bash
~/.claude/scripts/fleet-metrics.py --checkout <repo> --list-fleets        # every fleet marker: slug, launch, deadline, sessions, retro'd or not
~/.claude/scripts/fleet-metrics.py --checkout <repo>                      # the one fleet, or the one fleet not yet in the history
~/.claude/scripts/fleet-metrics.py --checkout <repo> --fleet bf-2948      # a running fleet, by slug (team, or the lowercased epic id)
~/.claude/scripts/fleet-metrics.py --checkout <repo> --fleet team@1793136086   # an archived run, by slug@launch_epoch
~/.claude/scripts/fleet-metrics.py --checkout <repo> --sessions a,b,c     # a marker without the set, or a hand-picked set
~/.claude/scripts/fleet-metrics.py --checkout <repo> --fleet bf-2839 --no-record   # compare against an already-recorded fleet
~/.claude/scripts/fleet-metrics.py --checkout <repo> --since YYYY-MM-DD   # last resort: a time window (or --hours N, --all)
```

**Which fleet.** Several fleets run side by side in one checkout and each keeps its own marker
(`tmp/fleet-deadline-<slug>.json`; an ended run a later launch of the same slug displaced is archived as
`tmp/fleet-deadline-<slug>.<launch_epoch>.json`), and a launch keeps every fleet this retro has not measured
(`skills/fleet-launch/SKILL.md` § Ledger expiry), so there may be several to choose from. Start with `--list-fleets`.
The bare run measures the single marker, or the single fleet the history (`tmp/fleet-metrics-history.jsonl`) does not
yet name; with several un-retro'd fleets it lists them and exits 2 — ask (AskUserQuestion) which one, with each row's
slug, launch time and session count in the question, then re-run with `--fleet`. Measuring a fleet writes its history
row, and the next launch expires its marker and ledgers; a fleet never measured is kept until the operator decides.

A re-run of an already-recorded fleet reads it through the current launch's verdict filter and deadline, after
`/reap-tmp` has aged its verdicts out, so its review columns come back empty. The analyzer keeps the stored row in that
case and says so (`--rerecord` overwrites it); pass `--no-record` to make the comparison run write nothing at all.

**A fleet is a session set, not a time window — scope by the set.** `/fleet-launch` records `fleet_sessions` in the
fleet's marker (the short id each `claude --bg` prints, which is the ledger key; the marker's fields are
`skills/fleet-launch/SKILL.md` § The deadline contract (shared with /auto)). The bare invocation and `--fleet` scope to
it and the report header names the marker it used; `--sessions` is the same thing typed by hand. A window scopes by
*when*, never by membership: a targeted `/auto <ID>` run writes a ledger of exactly the same shape, and every such run in
the window lands in the tables and every total. `/auto` stamps `mode` on its ledger and the script keeps single runs
(`mode: single`) out of any undirected scope, naming them under *Not fleet members*.

The script discovers sessions from `<repo>/tmp/auto-state-*.json`, matches each to its transcripts (main **and**
worktree dirs, **including `subagents/`**), and emits fixed per-session, review-churn and token-attribution tables plus
a Flags section; `--json` for machine use. Subagent transcripts matter disproportionately: a delegated reviewer that gets
blocked or stalls is invisible to its parent, which sees only a slow `Agent` call.

**Check the discovered session count against the fleet's own before reading any number.** Compare the report header's
`sessions:` count against `fleet_sessions | length` in the fleet's marker (`count` on a marker that predates the
set; with no marker, count the `/loop` sessions yourself), and read the direction, because the two disagreements are
opposite faults. **More than the fleet's** = non-fleet sessions admitted: re-scope with `--sessions <the /loop run
keys>`, delete the junk row the mis-scoped run appended to `tmp/fleet-metrics-history.jsonl`, and re-run — the
corrected set shares sessions with that row, so the analyzer refuses to write it while the junk row stands. **Fewer than
the fleet's** = a fleet session missing from discovery, which is a finding in itself — chase it; `--sessions` would only
hide it. Read `references/scoping-pitfalls.md` for the other scope faults: a set spanning a fleet already retro'd,
ledgers without `mode`, the `Subagent usage rows` coverage line, the `obs` witnesses, and which verdicts count as this
fleet's reviews.

The schema is fixed so two retros are comparable — that cross-run diff is the main long-term value. Add columns freely;
never quietly redefine an existing one.

### The gauges

Seven gauges ride the same run and the retro reads all seven, not just the tables. Each is one line here; read
`references/gauges.md` for where each prints, how to read it, and what a move between fleets means.

- **Context distribution** — share of billable prompt volume by context size at call time (the context gauge), with the
  **Boundary compactions** line the `loop-boundary` mod feeds.
- **Shipped-issue provenance** — the fresh share of the shipped set (the treadmill gauge), joined from Step 3's Linear
  exports and read alongside R.
- **Cross-run trend** — the headline row in `tmp/fleet-metrics-history.jsonl`, keyed by session set; the report's tail
  diffs the last six fleets, and $/issue is read through ktok/issue x $/Mtok out.
- **Pool exhausted** — idle session-hours after the last ship, charged to prep; split from the **forfeited** hours of a
  session that died, which are a session fault.
- **Headroom throttle** — session-hours parked by `/auto`'s headroom gate between picks (`throttled`, `thr%`).
- **Mid-run holds** — session-hours in `PLANNED-HOLD` / `BLOCKED-HOLD` (`held`, `hold%`), beside idle%, never folded
  into it.
- **Tests per shipped issue** — the net test declarations each ship added: rspec examples, vitest tests, story exports.

### Windows and quota

Do not ask for `/usage` readings: the weekly allowance is handled by account rotation and concurrency is settled before
launch at 3 per account with room (`skills/fleet-launch/SKILL.md` § The count — 3 per account with room;
`scripts/fleet-cap.sh`). Report the four
numbers in the `windows` block — `peak_5h_output_tokens` with `peak_5h_concurrency`,
`output_tokens_per_session_hour_at_peak` (with `output_tokens_per_in_window_session_hour` beside it), any
`quota_stall_groups`, and whether the peak is a floor or a ceiling — then read the `Window readings` line and its
Headroom verdict before sizing anything on the token peaks. Read `references/windows.md` for the reading rules:
`limit_kind` as wording rather than scope, `recovery_lag_s` over lost hours, which 5h blocks count, and why a deliberate
wind-down is not a stall. Compare realized burn against the `sizing.rate_tok_per_session_hour` that the fleet's own
`tmp/fleet-recommendation-<slug>.json` assumed (the team's, or the epic's): a projection that missed by 2x is the
finding, and silently repeating it next run is how a sizing error becomes permanent.

## Step 2 — Read the flags, then chase them

The script finds *shapes*; it does not explain them. Each flag is a lead, and `references/flags.md` carries every flag's
full meaning and where to chase it. The flags and what each usually means:

| Flag | What it usually means |
|---|---|
| never armed a ScheduleWakeup | silent loop death with no `NO-CANDIDATES`/`AUTO-HALTED`; `hooks/auto-heartbeat.sh` catches it, and stands down by design after an operator interjection |
| a stall far outlasting its own stated reset | the cutoff killed the turn mid-iteration before a wakeup was armed; `hooks/auto-rewake.sh` on `StopFailure` is the recovery, so the flag means it failed, was capped or was never registered |
| ended without recording an outcome | an operator kill, or an idle death — the last armed wakeup never produced a turn and the daemon retired the session past 60 idle minutes, leaving the ledger `active` |
| shipped without recording it | Step 4 never ran; the run's own tally undercounts |
| classifier blocks | a permission-shaped stall; check whether the agent rerouted or silently dropped the step |
| classifier unavailable | the check failed — not a denial; the agent should retry the same call once, unchanged |
| dangling tool calls | unanswered prompt or killed turn |
| Linear RATELIMITED answers (`linear rl` > 0) | the account's per-user request window ran out, shared by every session, script and launchd job on the machine; the answer is a wait, never a re-rank |
| high blind-sleep % | agents waiting on background dispatch; correlate with the `bg/sync/ign` column |
| shipped but no commit | the ledger is wrong, or the merge never landed |
| shipped with no persisted verdict | `/quality-review` never persisted its Output block, or the issue shipped outside the review pipeline |
| plan-heavy origin mix | the posted plans leak requirements/scope — planning is the stage to tune |
| impl-heavy origin mix | plans were right, code diverged — read the implementing-tier join before routing at model/effort |
| test-heavy origin mix | plan and code were sound; review is repairing coverage the implementation never wrote, and some share is the reviewer's intended yield |
| spec-heavy origin mix | the certified spec is what review keeps correcting — the lever is `/spec` rigor |
| latent-heavy origin mix | pre-existing defects the change surfaced — not a lever; expect it to decay as the pool drains |
| high filed-per-shipped rate | each shipped issue spawns near or above one new issue — the backlog cannot drain |
| drained early, siblings kept picking | the ranking reported an empty pool for a transient reason and the session latched sticky `drained` |
| held N.Nh while siblings landed K ship(s), or with Backlog candidates waiting behind the gate | Backlog held work a session launched without `backlog` could not reach: a mixed launch (`backlog` siblings shipped from Backlog), or a uniform one whose ticks named candidates waiting — often the fleet's own filings; not raised when every `PLANNED-HOLD` tick proved Backlog dry (the fallback's empty clause, or a stated zero; a `BLOCKED-HOLD` tick prints neither) |
| ledger carries N off-schema entries | /auto Step 4 (or a hand edit) wrote objects where the ledger takes bare ids; the counts hold, the writer drifted |
| rewakes classified spurious | `hooks/auto-rewake.sh` woke a live session — a regression of a guarded shape, or a third one |
| Headroom gate ran blind | every `fleet-headroom.sh` probe answered `source=none`: no mods/rate-limits reading, so the gate failed open; no capacity lost, but the protection was off |
| `loop-boundary` compacted nothing | the mod is loaded but its match conditions never fired; read the dominant pass reason in its ledger |

**Correlate across sessions before concluding.** A run's biggest finding can exist only in the comparison — blind-sleep
burn tracking dispatch mode exactly across sessions, with no single session showing it. When one column varies wildly
between sessions doing the same work, that spread is the finding.

Read the actual transcript for anything you intend to act on. The script tells you a long gap happened; only the
transcript says a classifier denied an rspec run twice and the third retry escalated to a permission prompt.

## Step 3 — Reconcile the ledger

Independent of the transcripts, establish what the run really produced:

- **Shipped** — every issue in `shipped[]` plus every ship the transcript witnesses (a `SHIPPED-*` tag, a
  `mark-ready-for-release.sh <ID>` call, or an `AUTO-CONTINUE: <ID> shipped (…)` line — the call is the reliable
  witness for an in-session merge and the outcome line for a queued one; `references/scoping-pitfalls.md`). Confirm
  each is in a release-ready state and has a commit. The script's merge reconciliation flags the gaps.
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
linear-cli api query 'query { issues(filter: { team: { key: { eq: "<KEY>" } }, number: { in: [<numbers>] } }, first: 100) { nodes { identifier createdAt creator { name displayName } } } }' -o json >| tmp/fleet-shipped-issues.json
```

Re-run `fleet-metrics.py` after writing these — its Shipped-issue provenance section then classifies every ship
(during-run / week-before / older) instead of reporting them unknown.

- **Net backlog delta** — drained vs. filed, stated as the reproduction ratio **R = issues filed / issues shipped** for
  the window (the script's filed-per-shipped rate covers only review-pipeline filings; this census is the full number).
  **The pool is the workable backlog only — `Planned`, `Backlog`, `Triage`, plus in-flight — and `Ready for Release`
  counts as done in every metric here.** Deployment cadence is a separate axis, and the rule holds whatever Linear type
  the state carries — a state-type census sweeps shipped-awaiting-deploy work into "open" and overstates the pool
  (`scripts/linear-deps-graph.sh` drops RFR nodes for the same reason). Track R across retros — it is the convergence
  gauge: below 1 the backlog drains and the drain rate says when it empties; at or above 1 no amount of fleet capacity
  catches up, and the lever is filing policy or defect prevention, not more sessions. Read it with the severity mix of
  what was filed: an R near 1 made of Medium deferrals is the reviewer mining a finite latent pool and should decay
  across runs; an R near 1 with fresh Critical/High findings means new code is minting defects as fast as the fleet
  retires them. A security sweep legitimately grows the backlog as each fix exposes adjacent surface; that is a
  conscious call to surface, not a defect to hide.
- **Remaining pool** — `~/.claude/scripts/next-candidates.sh --team <KEY> --label specified` so the next run's fuel is
  a known quantity.

## Step 4 — Audit what the run filed

Filed issues are output too, and they fail in ways the metrics cannot see. Every agent filing takes the recipe in
`standards/linear-filing.md`; this step audits the result. Check every one for:

- **Duplicates.** Re-run each filing's dedup search *properly* — single tokens, one per call (linear skill gotcha #14).
  A phrase-shaped search returns empty with exit 0 and reads exactly like "no duplicate".
- **Stranded states.** Anything in `Triage` is invisible to `/next` and `/auto` permanently. List it:
  `linear-cli api query` filtered on `state.name == "Triage"`.
- **Routing.** Every filing carries `specified`, `needs decision`, or `human` — an issue with none of them is unrouted:
  nothing ranks it, nothing parks it for a human, and the next session re-diagnoses and re-files it
  (`standards/issue-spec.md` § An agent filing never lands unrouted). List rows omit labels (linear skill gotcha #13),
  so read each filing with `issues get <ID> -o json | jq '[.labels.nodes[].name]'`. A severity-carrying filing at
  priority None is the same fault on the other field, and a reply token such as `suggested` passed as a label is no
  routing at all. `quality-review-write-verdict.sh` reads every filed id back from Linear and exits 3 on an unrouted
  one, so a filing that still lands unrouted means its verdict was never published, the session ignored the exit 3, or
  Linear did not answer the read (a `routing is unverified` WARN in the transcript); read that session's write-verdict
  call before filing a finding against the rule.
- **Certification and placement.** `specified` present where the issue is meant to be auto-shippable; absent where it
  needs `/spec` first. Pipeline self-certification is sanctioned: a filing whose body meets `standards/issue-spec.md`'s
  bar may carry `specified` from birth, and the retro audits the *bar*, not the label's provenance. What it must audit is
  **placement**: certified-at-filing issues belong in `Backlog` (the human curates Planned; the two sanctioned
  exceptions are a chain-inversion promotion per `/auto-prep`'s FOCUS rules, and the `--allow-planned` routing in
  `standards/linear-filing.md` § 3 of a Critical/High (priority 1–2) or `security`-labeled filing into `Planned` at
  birth — audit a Planned filing against that rule before flagging it), and anything in the team's default/Triage state
  is a stranded filing — a raw `issues create` without `--state` — to move to Backlog and trace to its filing path.
  **An issue's state at retro time is not its state at birth — read its `history` before calling a Planned issue
  misplaced.** The keeper curates while a fleet runs — by hand, or through an interactive skill that promotes on the
  keeper's approval — so a pipeline filing found in Planned may have been filed to Backlog correctly and promoted
  afterwards, which is the keeper's call and not a filing fault: never propose moving it back. The transitions show it:
  `linear-cli api query 'query { issue(id: "<ID>") { createdAt history(first: 100) { nodes { createdAt fromState { name } toState { name } } } } }' -o json | jq -r '.data.issue | "created \(.createdAt)", (.history.nodes[] | select(.toState) | "\(.createdAt) \(.fromState.name) -> \(.toState.name)")'`
  — a `Backlog -> Planned` row later than `createdAt` is a promotion, and a filing born in Planned has no such row: its
  first transition, if it has one, starts from `Planned`. Rows come newest-first and most carry no state change (label,
  relation and assignee edits), so a short `first:` drops a busy issue's oldest rows, the promotion among them. On the
  keeper's own Linear login every row's `actor` is the one identity; the run's transcripts show which session wrote a
  state.
- **Missing collision edges.** Group the run's filings by mechanism/file (their titles and bodies name it) and check
  `linear-cli relations list` on each same-mechanism sibling pair: two fleet-pickable `specified` siblings editing one
  method body, or one a prerequisite of the other, need a `blocks` edge; siblings sharing only a file or a mechanism
  need a `related` edge plus a comment (the three meanings of `blocks`, the direction rule and the certification guard
  live in `standards/issue-spec.md` § Certification includes collision edges; the filing-time step is
  `standards/linear-filing.md` § 4). The filing-time rule loses under exactly this audit's conditions, so this bullet is
  the systematic backstop, and it is what produces the "missing links" half of the filing-quality feed Step 6 hands to
  `/reflect fleet`.
- **Correct cancellations.** An issue absorbed by another's fix should be canceled *with its evidence carried onto the
  survivor first* — the losing issue often holds a verified vector the winner lacks. **Re-verify each carried claim
  against current code before writing it onto the survivor; never transcribe.** The losing issue is stale by
  construction and its cited evidence is the oldest part of it — a consumer it names may have been rewritten, a
  mechanism it describes may have grown — and carried verbatim it becomes a durable, wrong record on the survivor. Carry
  what survives the re-check, and state in the comment which claims were dropped and why.

## Step 5 — Report

Lead with where the capacity went, in hours. Then, ranked by cost:

1. **Ledger** — shipped, filed, net delta, remaining certified pool.
2. **Capacity** — total session-hours and what each fault cost, as hours and as a share of the fleet. When the **Pool
   exhausted** line printed (Step 1's gauge), it is the first entry: capacity the fleet could not have used, charged to
   prep — the pool — rather than to any session. Its **forfeited** hours are the opposite charge and are reported
   separately: sessions that died before the deadline, a session fault with its own finding, however gated the pool was
   when they died. **Headroom-parked** hours (the Totals clause, `thr%` in the trend) are a third charge: against a
   reading they are the gate working and cost what the limit would have. A session whose probes all ran blind (its flag)
   parked nothing, so there is no charge — but the protection was off; charge that to config and enable the mod before
   the next launch.
3. **Findings** — one per fault: evidence (numbers + `file:line` or transcript timestamps), root cause, and the specific
   fix. Distinguish a **compliance failure** (the rule exists and was ignored — prose will not fix it again) from a
   **gap** (no rule covers it).
4. **Issue-quality** — duplicates, strandings, certification gaps.
5. **Readiness** — anything blocking the next run: dirty tree, leftover worktrees (`standards/git-worktrees.md`;
   `/reap-worktrees` reclaims the provably finished ones), merge queue, stranded candidates.

Prefer a mechanical guard over more prose whenever a rule already existed and lost. That is what
`hooks/full-continue.sh`, `hooks/auto-heartbeat.sh`, and `hooks/no-blind-sleep.sh` each are — every one replaced
instructions that had already failed two or more times.

## Step 6 — Apply on approval

Present findings and wait. On approval, implement, then verify honestly:

- Hooks and scripts ship with a regression suite carrying the **real shape of every live feed the script consumes** as
  fixtures — transcripts, agent lists (`claude agents --json`), state files — re-snapshotted from the live feed at edit
  time, never written from memory (a hand-written fixture keeps a suite green against a feed whose shape has moved), and
  every existing suite stays green (`hooks/*.test.sh`).
- Re-run `fleet-metrics.py` after any change to numbers you cited — an ad-hoc measurement taken during investigation is
  easy to overstate, and a figure baked into a hook header must be one the script reproduces.
- Settings changes load at **session start**: state plainly that a new hook is inert in the current session and live
  for the next fleet.

**Then run the batched reflection: `Skill(skill: "reflect", args: "fleet")`.** It is the only scheduled reflection
surface, so skipping it here means no reflection happens for the run at all. Hand it the retro's findings; `/reflect`
(`skills/reflect/SKILL.md`, its `references/fleet-mode.md`) owns the triage bar, batching, the certified-issue filing,
and the `keeper`-label path for `~/.claude` targets that `/auto` cannot ship — and its fleet mode's filing-quality lens
(duplicates, missing links, stranded states) is fed directly by this skill's Step 4 audit. This skill keeps the
fleet-specific half: metrics, ledger, issue audit.

Commit and push only on an explicit grant (`standards/git.md`) — running this skill is not one.

## References

- [references/scoping-pitfalls.md](references/scoping-pitfalls.md) — a session set spanning a fleet already retro'd,
  ledgers without `mode`, subagent token coverage, the `obs` witnesses, which verdicts count as this fleet's reviews.
  Read when the session count disagrees with the fleet's, or before quoting a subagent, `obs` or churn figure (Step 1,
  Step 3).
- [references/gauges.md](references/gauges.md) — the seven gauges: where each prints, how to read it, what a move
  between fleets means (Step 1).
- [references/windows.md](references/windows.md) — the `windows` block's four numbers, reading a stall group, the
  `Window readings` line and its Headroom verdict, why a deliberate wind-down is not a stall (Step 1).
- [references/flags.md](references/flags.md) — every flag's full meaning and chase recipe (Step 2).

Owned elsewhere, pointed at from here: the deadline marker and the n=3 count (`skills/fleet-launch/SKILL.md`); the
`auto-state-*.json` ledger (`skills/auto/SKILL.md` Step 4); agent filing (`standards/linear-filing.md`);
iteration-boundary compaction (`mods/loop-boundary/README.md`); worktree rules (`standards/git-worktrees.md`); the
`fleet` reflection mode (`skills/reflect/SKILL.md`).
