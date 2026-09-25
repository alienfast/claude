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

### A worktree or transcript in the checkout is not evidence of fleet membership

The operator routinely works interactively in the same checkout while a fleet runs — two such sessions
sat beside the three-session fleet on 2026-08-25 — and one of them claims issues, creates worktrees,
files issues and ships through `/finish` exactly like a fleet session. What it does not do is write a
`tmp/auto-state-*.json` ledger: that file is the autonomous loop's own run state, and nothing outside
that skill writes one. So it presents as the very fault the flag table teaches you to hunt — work with no
bookkeeping.

Discriminate before counting it. `fleet-metrics.py`'s `auto_session_mode` is the test: the transcript's
FIRST human turn carrying text must be the autonomous-loop command, and a later mention does not count.
Read that turn yourself rather than inferring membership from a table — absence from the script's tables
is not proof of interactivity either, since an explicitly named `--sessions` key skips the probe and a
genuinely ledger-less in-fleet session inside the run's own span is excluded outright (the script's
`--allow-partial` WARNING is what surfaces that case). A status readout's In-flight section prints each
live worktree's owning session id straight from the identity sidecar with no session-type filter at all —
only its Sessions table applies one — so an owner id read from there is not a fleet member until the
transcript says so.

Measured 2026-08-25: a retro counted one such owner as a fourth fleet session and reported 22.1
session-hours, 10 shipped and ~$81 per issue against the true 18.1 / 9 / $62.17, and a filed-per-shipped
ratio of 1.70 against 1.11 — the whole headline, plus a fix plan resting on it, from one unchecked
assumption.

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

The event-based flags are real either way — classifier blocks, ran without a surviving ledger, shipped
with no persisted verdict, off-schema verdict body, drained early while siblings kept picking (it keys on
a `drained` ledger, which a live session never has; a mid-fleet retro sees a smaller K, never a false
one). Only the bookkeeping ones need this gate.

**`wound down but never finalized its ledger` is a bookkeeping flag that is also real either way** — it
fires only on a terminal tag or a stop-wakeup, which is exactly what a live session lacks, so its own
condition IS the finished-gate. Do not discount it as a live-session artifact. It is the complement of
`ended without recording an outcome`, not a duplicate: that one catches a loop that never terminated,
this one a loop that terminated and lost only its bookkeeping write — nothing is stranded, but
`/fleet-status` reads the same field, so the session renders as live or wedged and invites a needless
kill.

**`ps -p <the state file's pid>` does not settle it.** Under `claude agents` every session in a fleet
embeds the *fleet root* pid (`skills/auto/SKILL.md` Step 0 and Step 4), so it answers identically for all
of them and can go empty mid-run. `/fleet-status` no longer inherits that limitation — its liveness
column joins the session registry (`claude agents --json`) on the ledger key and degrades to `unknown`,
never `dead`, when the registry is unavailable — but a registry answers whether a session is *running*,
not whether it has finished writing, so it does not settle this gate either. Compare each
transcript's last TIMESTAMPED record against now instead — never its `mtime`: the harness keeps
appending untimestamped bookkeeping rows to a finished session, so mtime tracks the harness, not the
loop. `scripts/auto-stall-watch.sh`'s header measured it 2026-08-29 on `last-prompt` and `cost-state`
rows; re-measured 2026-09-19, where three transcripts read an mtime one minute old while their last
turns were 4.5, 6.7 and 9.3 hours old, behind trailing `last-prompt`, `cost-state`, `ai-title` and
`agent-name` rows. `tail -200 <transcript> | jq -r 'select(.timestamp) | .timestamp' | tail -1` is the
read. And stale is not finished either: a quota-stalled session
resumes hours later on a pending wakeup, so cross-check `tmp/fleet-deadline.json` (passed, or `stopped`)
and the sessions' harness limit messages. When a session may still be writing, either wait for it or mark
its row provisional — never file a bookkeeping finding against it. `/fleet-status` is the read-only skill
for a fleet still in flight.

```bash
~/.claude/scripts/fleet-metrics.py --checkout <repo>                      # scopes to the launch's recorded session set
~/.claude/scripts/fleet-metrics.py --checkout <repo> --sessions a,b,c     # an older fleet, or a marker without the set
~/.claude/scripts/fleet-metrics.py --checkout <repo> --since YYYY-MM-DD   # last resort: a time window (or --hours N, --all)
```

**A fleet is a session set, not a time window — scope by the set.** Every `/fleet-launch` since 2026-08-29
records `fleet_sessions` in `tmp/fleet-deadline.json` (the short id each `claude --bg` prints, which is the
ledger key), the bare invocation scopes to it, and the report header names the scope it used. `--sessions` is
the same thing typed by hand. A window is the last resort because it scopes by *when*, never by membership: a
targeted `/auto <ID>` run writes a ledger of exactly the same shape, and every such run in the window lands in
the tables and every total. Measured 2026-08-29 on a `/fleet-launch 3 12h` run: `--since 2026-08-28` reported
21 sessions, a tighter `--since 2026-08-28T18:50` reported 11, against a real fleet of 3; re-measured the same
day, a bare `--since` read 26 against a fleet of 5. Since then `/auto` stamps `mode` on its ledger and the
script keeps single runs (`mode: single` — targeted or one-shot) out of any undirected scope, naming them under
*Not fleet members*; in older data the tell is the per-session table's `wakeups` column — a `/loop /auto`
session arms one per iteration, a single run shows `0 (0 stop)`.

Discovers sessions from `<repo>/tmp/auto-state-*.json`, matches each to its transcripts (main **and**
worktree dirs, **including `subagents/`**), and emits fixed per-session, review-churn, and
token-attribution tables plus a Flags section. `--json` for machine use. Subagent transcripts matter
disproportionately: a delegated reviewer that gets blocked or stalls is invisible to its parent, which
sees only a slow `Agent` call.

**Check the discovered session count against the fleet's own before reading any number.** Compare the
report header's `sessions:` count against `fleet_sessions | length` in `tmp/fleet-deadline.json` (`count` on a
marker that predates the set; a marker from before 2026-08-29 is absent altogether when the launch carried no
duration — then count the `/loop` sessions yourself), and read the direction, because the two disagreements are
opposite faults. **More than the fleet's** = non-fleet sessions admitted: re-scope with `--sessions <the /loop
run keys>` and re-run, since a mis-scoped run also appends a junk row to `tmp/fleet-metrics-history.jsonl`.
**Fewer than the fleet's** = a fleet session missing from discovery, which is a finding in itself — chase it;
`--sessions` would only hide it.

**Read the `Subagent usage rows` line under the token table before any output-token figure.** A subagent
transcript streams one row per content block, all sharing the message id, and only the row stamped
`stop_reason` carries the message's whole output count — the rest carry a placeholder of a few tokens. The
script credits the largest value per id and reports how many subagent messages have a final row at all;
below 100% every subagent figure, ktok/issue and burn rate is a floor and $/Mtok out a ceiling (the trend
table's `sub-final%`). Until 2026-09-22 the script credited the FIRST row: the 2026-09-21 fleet's subagents
read 714k output tokens against 6.68M on their final rows, every fleet's ktok/issue sat at a third of its
real value, and the n=3 5h burst floor `/auto-prep` sized against read 1.9M where the corrected ledger says
4.3–5.5M. Coverage itself varies by run with no cause established — 99% on most fleets, 25% on 2026-09-05
and 15% on 2026-09-22, all on harness 2.1.278 — so a low share is a finding to carry, not to explain away.

Four gauges ride the same run and the retro reads all four, not just the tables:

- **Context distribution** — share of billable prompt volume by context size at call time. This is the
  autocompact gauge: fleet-launch pins `--autocompact 500000` (150000 shipped 2026-08-14 and
  thrash-aborted its first fleet; 300000 orbited mid-review; 500000 kept across all four 2026-08-15/16
  fleets — doc/compacting-investigation.md, verdict log). Under 500k the session floor is ~115–177k and
  the sawtooth tops out at the ~460k trigger, so a LARGE >=200k share (84–94% on the verified fleets) is
  the expected pre-compact shoulder, not a failure — the engagement signal is no volume above ~460k, and
  the health signal is cadence (a handful of compact_boundary rows per session at tens-of-minutes
  spacing; spacing collapsing to minutes is the orbit signature). Before reading an orbit as the
  threshold, check what each orbiting compact carried: its `compactMetadata.postTokens`, its `preTokens`
  minus the context of the last main-loop call before it (input + cache_creation + cache_read), and the
  `nested_memory` attachment rows between that call and the boundary. Measured 2026-09-24 at 500k: normal
  compacts carried 33–95k forward, but every compact that carried 142k or more had a ~110k gap made of
  path-scoped rules injected after the last call (a 365KB project rule scoped to `apps/api/**/*.rb` plus
  a 60KB one), carried them, and sat at ~325–340k on the next call instead of ~165–178k. The next tool
  call re-injected the same rules, whatever it touched, because the compaction's restored-file references
  named files in their scope, refilling to ~440k in one turn. That orbit is rule size, not threshold: a
  higher cap would hold the same rules twice. Trim or re-scope the injected rule, and recover the issue
  with a fresh targeted `/auto <ID>`. The harness's own thrash message ("a file being read … is likely
  too large") is right about the size and wrong about the file. A falling ctx share with RISING churn
  gauges means the threshold is too aggressive — raise it rather than reverting.
- **Shipped-issue provenance** — joins the shipped set against the Step 3 Linear exports; the fresh
  share (created during or <=7 days before the run) is the treadmill gauge, read alongside R. It cannot tell a human seeding the backlog inside the window from the pipeline minting for itself, so on a team whose backlog is younger than the window it reads 100% by construction and says nothing about treadmill — the first BFP fleet (2026-09-05) read 96% with 19 of 24 ships seeded the day before launch, 4 filed during the run and 1 older. Treat it as a treadmill gauge only once the section's `older` count is material; until then the during-run count is the one bucket that still carries the signal, say so in the report, and discount the fresh% row it leaves in the trend ledger.
- **Cross-run trend** — every windowed run appends its headline row to
  `tmp/fleet-metrics-history.jsonl` (keyed by session set, so a re-run replaces its row only when it yields the
  identical set — a differently-scoped re-run APPENDS) and the report's tail
  diffs the last six fleets. This is where drift lives: the $90 → $161 cost-per-issue climb across the
  2026-08-05..14 fleets sat in individually-saved reports that nothing compared until it was found by
  hand. Read $/issue through its two factors — ktok/issue (work per issue) x $/Mtok out (context
  weight per unit of work) — before proposing levers, since they route differently (churn/specs vs
  autocompact/model mix).
- **Pool exhausted** — the idle-tail number Step 5's Capacity item leads with. Printed under **Totals**
  when the last ship landed an hour or more before the deadline: hours from that landing to the deadline,
  the session-hours the deadline-drained sessions then sat idle, and that as a share of the fleet (the
  trend table's `idle%`; `pool_exhausted` in the JSON). Landings are git committer dates with the
  transcript's SHIPPED tag as fallback — tags alone missed 6 of the 2026-09-16 BFP fleet's 21 ships and
  read the tail 3h too long. An empty pool is a prep finding, not a session fault: read it beside Step 3's
  Remaining pool census, and read the "drained early, siblings kept picking" flag as its complement — a
  pool that was gated rather than empty. On that fleet the number was 10.4 session-hours, 28% of the
  fleet, while every per-session row read clean and Flags said None. A session that DIED holding on the
  pool never wrote `drained` (the holds never do), so it is admitted on a structural test instead — the
  kill flag's own condition, a passed deadline, a final `noop: true` wakeup, and no `Agent` dispatch
  after its last landing — and its tail is split at its last turn: the hours before it are pool idle and
  join this number (`held_sessions`), the hours after it are **forfeited** (`forfeited_session_hours`,
  and on its `ended without recording an outcome` flag) and never do. A dead session's evidence says
  nothing about the pool after its last turn, so forfeited hours are a session fault, not a prep finding.
  Measured 2026-09-19: 5.3 held (32%) and 19.4 forfeited, on a run where the gauge had printed nothing.

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

   **Unit trap since 2026-09-22:** `fleet-metrics.py` now credits each message its final usage row, but
   `scripts/fleet-headroom.sh` still credits the FIRST row per `requestId` — on a streamed subagent
   message a placeholder of a few tokens, since every row of one message shares its `requestId` (3,442
   of 3,442 messages across one 2026-09-22 BFP session's 142 subagent transcripts, and the shape is as
   old as the oldest transcript on disk, 2026-08-14 on 2.1.232), while a main-session message carries
   its final count on every row. So the probe's trailing-5h meter, its 1,500,000 default, both
   2026-08-17 observations in `~/.claude/telemetry/five-hour-ceiling.json`, and every figure in this
   section are in the old unit; on a fleet-dominated window the script's unit runs roughly 3× higher
   (its re-measured peaks moved 1.9M → 4.3–5.5M), less when interactive work fills the window. The
   file's `ceiling_output_tokens` is 100,000,000 by keeper directive 2026-08-30 (multi-account: the
   machine-wide meter maps to no one account's window), so the probe throttles on nothing today, and
   the trap fires when that note's "restore a measured per-account ceiling" is followed: a new-unit
   observation restored against the old-unit meter is a ceiling the probe can never approach, and the
   fleet dies mid-issue with the gate silent. Do NOT write the script's cutoff-window figure into that
   file — `skills/fleet-launch/SKILL.md`, `skills/auto/SKILL.md` and the probe's own header still say
   to; record it in the retro report only, until the probe counts the largest row per `requestId`
   (still a floor where a subagent's final row was never written — the `Subagent usage rows` share
   above), its default is re-derived, and `scripts/fleet-forecast.py`'s throttle line — the same
   ceiling read against a rate the re-measured history already states in the new unit — is converted
   with it.

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
| never armed a ScheduleWakeup | silent loop death — the run stopped with no `NO-CANDIDATES`/`AUTO-HALTED` | should now be caught by `hooks/auto-heartbeat.sh`; if it recurs, that hook failed — but first check for an operator interjection: the hook deliberately stands down when a human message follows the iteration anchor (`human-override` in its decide() output; replay it with `TRANSCRIPT_PATH=<transcript> bash -c 'source ~/.claude/hooks/auto-heartbeat.sh; decide'`), so an attach-recovered session that ends un-armed is the hook working as designed, not failing — the bookkeeping gap it leaves is /auto's attach-recovery contract (skills/auto/SKILL.md) |
| a stall far outlasting its own stated reset | the cutoff killed the turn **mid-iteration**, before any wakeup was armed — so nothing was pending to wake it and the session is dead until a human prompts it. **No `Stop` hook sees this** — a turn killed by an API error fires no Stop hook at all (verified — no `stop_hook_summary` follows the limit message), so `auto-heartbeat.sh` is structurally unable to see it — **but `StopFailure` does**: it fires INSTEAD of Stop, with `error` set (`rate_limit` on a 429, `server_error` on a 529; matcher on that field) and the error text in `last_assistant_message`. Measured 2026-09-19 on 2.1.278 against a mock API. Its output and exit code are ignored, yet a `StopFailure` command hook marked `asyncRewake: true` that later exits 2 wakes the session with its stderr as a system reminder — a rate-limit-killed turn issued its next model request 4s after such a hook exited. `hooks/auto-rewake.sh` is that hook (registered on `StopFailure` for `rate_limit`, `overloaded`, `server_error`, `unknown`): it retries every ~900s, 24 times, and stands down if a turn followed. So a stall of this shape on a run with the hook registered means the hook failed or was capped — `~/.claude/logs/auto-rewake.log` says which (`wait`, `rewake`, `stood-down`, `skip reason=…`), and no lines at all for the session means it was never registered (the `asyncRewake` and `timeout` fields in `settings.json` are both load-bearing and both fail silently) | compare each stalled session's resume against the reset named in its limit message. A session with a wakeup pending resumes 1–8 min after reset; one without does not resume at all. On 2026-08-14 that split 1-recovered / 2-dead within one cutoff — 4.85 avoidable session-hours. The mitigation is `scripts/auto-stall-watch.sh` (launchd agent `com.alienfast.auto-stall-watch`, installed by `update.sh`) — detection only, since a live background agent accepts no scripted prompt, so recovery is the operator running `claude attach <id>`. If a stall outlived it silently, read `~/.claude/logs/auto-stall-watch.log` for whether the watcher flagged it and whether anyone acted |
| ended without recording an outcome | two causes, and the daemon log separates them. An operator kill is routine and logs `bg settled <id> (killed)`. The other is an idle death: the session's last armed wakeup never produces a turn, and the daemon retires a background session at its first one-minute tick past 60 idle minutes (logged as `idle 60m` or `idle 61m`), leaving the ledger `active`. Measured 2026-09-19 on a 3-session fleet: 110 wakeups armed (30 + 27 + 53) — 84 superseded by an agent message or task notification before they came due, 23 fired on time, and the last one in each session never produced a turn. All three were `noop: true` hold ticks (600s, 1800s, 1800s) during a `PLANNED-HOLD`, against 14 such ticks that had fired. Each retirement landed 60m37s–60m56s after the session's last timestamped record. Not the quota stall above — no limit message or API-error record in any transcript, and the last turns were hours apart. `auto-heartbeat.sh` cannot catch it: it ran at the end of each final turn (`stop_hook_summary` lists it) and passed, because a wakeup WAS armed — the condition it checks — and no Stop event follows when no turn follows. Whether a `Notification` (`idle_prompt`) or `SessionEnd` hook would fire is unmeasured; neither is wired. What IS measured (2026-09-19, a real `claude --bg` session): a `Stop` command hook marked `asyncRewake: true` that exits 2 wakes a background session sitting idle at its prompt — the turn ended, 20s passed, the hook exited 2, and the model answered the hook's stderr — and `hooks/auto-rewake.sh` is the hook built on it: it outlives each armed wakeup's due time plus a 300s grace and exits 2 only when no turn followed. Replayed over that fleet's 101 real turn ends it stood down on 97, skipped 1 un-armed turn `auto-heartbeat.sh` had already caught, and would have woken exactly the 3 that died, 26–46 minutes before the daemon retired them. So this death on a run with the hook registered means the hook failed, was capped (12 consecutive rewakes), or was never registered — read `~/.claude/logs/auto-rewake.log` first. Why the wakeup was lost is unestablished | `~/.claude/daemon.log` for `bg retire <id>` (reason `idle-prompt` or `settled`, plus idle minutes — grep `bg retire`, not a literal `61m`, which misses half of them) and `bg settled <id>` (`(done)` after a retire, `(killed)` after a kill). Then the transcript's last `ScheduleWakeup`: its timestamp plus `delaySeconds` is the due time, check whether it was `noop: true`, and nothing follows that turn's `stop_hook_summary`. Then `~/.claude/logs/auto-stall-watch.log`: since 2026-09-19 the watcher flags a session with a wakeup pending only once that wakeup is 300s overdue (detail `wakeup overdue <N>m (armed <delay>s)`), so its first flag on a holding session is the real onset — replayed over that night's 72 ticks it raised no false flag and caught each death 21–36 minutes after the session's last turn. In a log older than that, read the LAST unbroken run of flags (`silent_min` climbing), never the first: the flat 25-minute rule it replaced flagged healthy 1800s holds in their final minutes (8 of 9 on that run, one 1h34m before the session's real last turn). The retire line is not shown to end recoverability: all three sessions were re-claimed onto a spare hours after retirement. A `self-restarting for upgrade` line inside the run is a lead, not a cause — the daemon restarted mid-fleet and adopted all three, and 19 wakeups armed after that fired normally before the 3 that did not |
| shipped without recording it | Step 4 never ran; the run's own tally undercounts | compare against `git log` and Linear state |
| classifier blocks | a permission-shaped stall; check whether the agent rerouted or silently dropped the step | the subagent transcript — read what it did *next* |
| classifier unavailable | the check failed — not a denial. The result (`… cannot determine the safety of …`, opening with `gave no verdict` or `<model> is temporarily unavailable (rate-limited\|timed out)`) tells the agent to retry the same call once, unchanged; nothing needs rerouting, and a reroute is the agent misreading the failure. The wait names the cause: service-side unavailability returns in seconds (7–15s, once 122s, measured 2026-08-27..09-25), while every wait over 2 min measured so far was the host asleep | the record before the result, for `API Error: Your computer went to sleep mid-response`; `pmset -g log \| grep -E ' (Sleep\|DarkWake\|Wake) '` over the call's window (local time); then the next assistant record, for a retry as-is versus a reroute on a wrong theory |
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
| drained early, siblings kept picking | the ranking reported an empty pool for a transient reason — every remaining candidate chained behind a sibling's in-flight issue (now `BLOCKED-HOLD` in `next-candidates.sh`, which /auto must honor as a wait, not a drain), an empty fetch the double-run also hit, a label flap, or work certified after the drain — and the session latched sticky `drained`. If it recurs after the BLOCKED-HOLD fix, that prose gate lost, exactly as the deadline gate did before `auto-deadline-gate.sh` | that session's last `/next` output in its transcript; `linear-cli relations list` on the issues its siblings shipped next; the flag's K and H give the cost |
| rewakes classified spurious | `hooks/auto-rewake.sh` woke a session that was alive and told it to run an iteration — invisible in every other column, because the injected turn looks like ordinary loop activity and arrives as `task-notification`, not `human`. Two shapes are known and both were fixed 2026-09-20, so on a log newer than that a flag is a regression or a third shape. The transcript MOVED while the hook slept: a worktree enter or exit re-keys the session's project directory, and the instance read the emptied path as silence (73 of that run's 74; now logged `stood-down … reason=transcript-unreadable`). The ZERO WAIT: an arm already past due + grace when its turn ended was checked before the overdue wakeup's record could exist (1 of 74; the wait is now never shorter than the grace) | the flagged line in `~/.claude/logs/auto-rewake.log`, then the transcript between its `armed_at` and its timestamp: which opener landed there. A turn that ran while the hook slept means its stand-down read failed — check whether the session's cwd changed in the window. A `scheduled_task_fire` inside the line's own second, under a `wait kind=stop wait_s=0` line, is the zero-wait race |

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
- **Routing.** Every filing carries `specified`, `needs decision`, or `human` — an issue with none of them is
  unrouted: nothing ranks it, nothing parks it for a human, and the next session re-diagnoses and re-files it
  (`standards/issue-spec.md` § An agent filing never lands unrouted). List rows omit labels (linear skill gotcha
  #13), so read each filing with `issues get <ID> -o json | jq '[.labels.nodes[].name]'`. A severity-carrying
  `/quality-review` filing at priority None is the same fault on the other field. Measured 2026-09-22: fourteen
  filings over five weeks carried a minted `suggested` label — the skill's reply token, passed as a label — and
  nothing else; none was ever picked, and a keeper audit found one real bug among the nine still open. Later the
  same day a fleet filed BFP-251 and BFP-252 with no label and priority None, four hours after the rule landed, so
  `quality-review-write-verdict.sh` now reads every filed id back from Linear and exits 3 on an unrouted one. A
  filing that still lands unrouted on a run after that means one of three things — its verdict was never
  published, the session ignored the exit 3, or Linear did not answer the read (a `routing is unverified` WARN in
  the transcript) — so read that session's write-verdict call before filing a finding against the rule.
- **Certification and placement.** `specified` present where the issue is meant to be auto-shippable;
  absent where it needs `/spec` first. Pipeline self-certification is sanctioned (keeper ruling
  2026-08-15): a filing whose body meets `standards/issue-spec.md`'s bar may carry `specified` from
  birth — the retro audits the *bar*, not the label's provenance. What it must audit is **placement**:
  certified-at-filing issues belong in `Backlog` (the human curates Planned; two sanctioned
  exceptions — a chain-inversion promotion per `/auto-prep`'s FOCUS rules, and `/quality-review`'s
  filing recipe routing a severity-carrying Critical/High (priority 1–2) or `security`-labeled
  filing into `Planned` at birth, so audit a Planned filing against that rule before flagging it),
  and anything in the team's default/Triage state is a stranded filing — a raw `issues create`
  without `--state` — to move to Backlog and trace to its filing path.
  **An issue's state at retro time is not its state at birth — read its `history` before calling a Planned issue
  misplaced.** The keeper curates while a fleet runs — by hand, or through an interactive skill that promotes on the
  keeper's approval — so a pipeline filing found in Planned may have been filed to Backlog correctly and promoted
  afterwards, which is the keeper's call and not a filing fault: never propose moving it back. The state transitions
  show it:
  `linear-cli api query 'query { issue(id: "<ID>") { createdAt history(first: 100) { nodes { createdAt fromState { name } toState { name } } } } }' -o json | jq -r '.data.issue | "created \(.createdAt)", (.history.nodes[] | select(.toState) | "\(.createdAt) \(.fromState.name) -> \(.toState.name)")'`
  — a `Backlog -> Planned` row later than `createdAt` is a promotion, and a filing born in Planned has no such row: its
  first transition, if it has one, starts from `Planned`. Rows come newest-first and most carry no state change at
  all (label, relation and assignee edits), so a short `first:` drops a busy issue's oldest rows — the promotion among
  them — and the issue then reads as born in Planned. Where the fleet runs on the keeper's own Linear login the row's
  `actor` cannot say who moved it, since every row carries the one identity; the run's transcripts can, because a
  session that wrote the state shows the call. Measured on two consecutive retros (2026-09-19, 2026-09-20) — one
  flagged a High-priority filing the sanctioned routing had placed, the next flagged two that the keeper had promoted
  by hand an hour after they were filed to Backlog, and proposed moving them back.
- **Missing collision edges.** Group the run's filings by mechanism/file (their titles and bodies name
  it) and check `linear-cli relations list` on each same-mechanism sibling pair: two fleet-pickable
  `specified` siblings editing one method body, or one a prerequisite of the other, need a `blocks`
  edge; siblings sharing only a file or a mechanism need a `related` edge plus a comment (the three
  meanings of `blocks`, the direction rule, and the certification guard live in standards/issue-spec.md § Certification
  includes collision edges). The filing-time rule (quality-review's dedup/edge-wiring sub-step) loses
  under exactly this audit's conditions — measured on two consecutive fleets (2026-08-16:
  BF-1201/BF-1202/BF-1205; 2026-08-17: BF-1220→BF-1221, BF-1223↔BF-1203, BF-1208↔BF-1213), every edge
  wired at retro by hand — so this bullet is the systematic backstop, and it is what actually produces
  the "missing links" half of the filing-quality feed Step 6 hands to /reflect fleet.
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
   When the **Pool exhausted** line printed (Step 1's gauge), it is the first entry: capacity the fleet
   could not have used, charged to prep — the pool — rather than to any session. Its **forfeited** hours
   are the opposite charge and are reported separately: sessions that died before the deadline, a
   session fault with its own finding, however gated the pool was when they died.
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

- Hooks and scripts ship with a regression suite carrying the **real shape of every live feed the
  script consumes** as fixtures — transcripts, agent lists (`claude agents --json`), state files —
  re-snapshotted from the live feed at edit time, never written from memory (auto-stall-watch's
  hand-written agent-list fixture kept its suite green through 371 ticks of a watcher that matched
  zero live rows), and
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
