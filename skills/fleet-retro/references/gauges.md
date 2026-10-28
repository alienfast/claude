# The gauges

Read from `/fleet-retro` Step 1 when reading any of the seven gauges past its one-line meaning: where each prints, how
to read it, and what a move between fleets means.

## Context distribution

Share of billable prompt volume by context size at call time — the context gauge. The `loop-boundary` mod compacts each
session to one boundary message at every iteration boundary (`mods/loop-boundary/README.md`), and the launch adds no
`--autocompact` cap, so the engine's own threshold governs inside an iteration. The mod's **Boundary compactions** line,
under Output tokens by agent type, gives the count, the per-shipped-issue rate and the mean context before and after —
the after is the floor each iteration restarts at. Read the share against the last capped fleet's row in
`tmp/fleet-metrics-history.jsonl`: a fall is the boundary compaction working; a rise with volume above ~460k is
iterations outgrowing the engine threshold, and `-- --autocompact 500000` on the launch restores a cap if $/Mtok out
rises with it. Under a cap the health signal is cadence — a handful of `compact_boundary` rows per session at
tens-of-minutes spacing; spacing collapsing to minutes is the orbit signature.

Before reading an orbit as the threshold, check what each orbiting compact carried: its `compactMetadata.postTokens`,
its `preTokens` minus the context of the last main-loop call before it (input + cache_creation + cache_read), and the
`nested_memory` attachment rows between that call and the boundary. A compact carrying far more than its siblings, with
the gap made of path-scoped rules injected after the last call, is rule size, not threshold: the compaction's
restored-file references name files in the rule's scope, so the next tool call re-injects the same rules and refills the
context in one turn, and a higher cap would hold the same rules twice. Trim or re-scope the injected rule, and recover
the issue with a fresh targeted `/auto <ID>`. The harness's own thrash message ("a file being read … is likely too
large") is right about the size and wrong about the file. A falling ctx share with RISING churn gauges means the
threshold is too aggressive — raise it rather than reverting.

## Shipped-issue provenance

Joins the shipped set against the Step 3 Linear exports; the fresh share (created during or <=7 days before the run) is
the treadmill gauge, read alongside R. It cannot tell a human seeding the backlog inside the window from the pipeline
minting for itself, so on a team whose backlog is younger than the window it reads 100% by construction and says nothing
about treadmill. Treat it as a treadmill gauge only once the section's `older` count is material; until then the
during-run count is the one bucket that still carries the signal — say so in the report, and discount the fresh% row it
leaves in the trend ledger.

## Cross-run trend

Every windowed run records its headline row in `tmp/fleet-metrics-history.jsonl`, keyed by session set: an identical
set replaces its row, a set sharing no session with any row appends, and a set sharing a session with a different row is
refused (`--allow-overlap` forces it), since those sessions' hours and ships are already in that row. The replace is
itself refused, keeping the stored row, when that row was recorded before the current launch or measured more reviews
than the re-run finds (`--rerecord` forces it, and `--no-record` writes nothing): a re-run of an older fleet can rebuild
only what survives, which drops its review columns. The report's tail
diffs the last six fleets. This is where drift lives: a cost-per-issue climb across consecutive fleets sits in
individually saved reports that nothing compares. Read $/issue through its two factors — ktok/issue (work per issue) x
$/Mtok out (context weight per unit of work) — before proposing levers, since they route differently (churn/specs vs
boundary-compaction/model mix). `rewr%` is the effort-phase gauge: the share of the main loop's ledgered requests that
`mods/effort-phase` sent at a rewritten effort (its mechanical and polling lanes); read its direction beside $/issue and
ktok/issue across fleets with the mod on, with finish-recover and review churn as the quality guard, and read the
report's **Effort lanes** and **Spawn policy** lines (under Output tokens by agent type) for the lane split and the spawn
rewrites. A `-` is a fleet with no effort-phase ledger.

## Pool exhausted

The idle-tail number Step 5's Capacity item leads with. Printed under **Totals** when the last ship landed an hour or
more before the deadline: hours from that landing to the deadline, the session-hours the deadline-drained sessions then
sat idle, and that as a share of the fleet (the trend table's `idle%`; `pool_exhausted` in the JSON). Landings are git
committer dates with the transcript's SHIPPED tag as fallback — tags alone miss ships and read the tail too long. An
empty pool is a prep finding, not a session fault: read it beside Step 3's Remaining pool census, and read the "drained
early, siblings kept picking" flag as its complement — a pool that was gated rather than empty. A session that DIED
holding on the pool never wrote `drained` (the holds never do), so it is admitted on a structural test instead — the
kill flag's own condition, a passed deadline, a final `noop: true` wakeup, and no `Agent` dispatch after its last landing
— and its tail is split at its last turn: the hours before it are pool idle and join this number (`held_sessions`), the
hours after it are **forfeited** (`forfeited_session_hours`, and on its `ended without recording an outcome` flag) and
never do. A dead session's evidence says nothing about the pool after its last turn, so forfeited hours are a session
fault, not a prep finding.

## Headroom throttle

Session-hours parked by `/auto`'s fleet headroom gate between picks: the `throttled` column per session (`parked hours
(THROTTLE probes/probes)`), a clause on the **Totals** line naming the reading source every probe reported, `thr%` in
the trend, and `throttle` in the JSON. A THROTTLE parks the session until its next probe, so the hours are those
intervals summed; where a park ran past the last ship it also sits inside idle%, and the Pool exhausted line prints the
overlap rather than subtracting it. Against a reading this is the gate working — read it with `windows.md`.
`source=none` on every probe is a config fault with its own flag (`Headroom gate ran blind`): no mods/rate-limits
reading existed for the session or the machine, so the gate failed open on every pick.

## Mid-run holds

Session-hours a session spent in `PLANNED-HOLD` / `BLOCKED-HOLD`, read from its `AUTO-CONTINUE: no pick` ticks (a hold
writes no ledger status): the `held` column per session (`hours (ticks)`), a clause on the **Totals** line, `hold%` in
the trend, and `holds` plus each session's `held` in the JSON. Beside idle%, never folded into it: idle% keys on the
fleet's last ship, so a session held for hours while a sibling kept shipping is invisible to it; the part of a hold past
a session's last ship sits in both, and the Pool exhausted line prints the overlap.

## Tests per shipped issue

The net test declarations each shipped issue added, as `Tests per shipped issue: +X.X rspec examples, +Y.Y vitest
tests, +Z.Z story exports` (under Output tokens by agent type, beside the cost line), `ex/ship`, `vt/ship` and `st/ship`
in the trend, `tests_per_shipped` in the JSON. It is a static count over each ship's landed diff — added minus removed
`it`/`specify`/`example`/`scenario` lines in `spec/**/*_spec.rb`, `it(`/`test(` lines with any modifier chain but
`skip`/`todo` in `*.test.ts(x)`, and `export const` lines in `*.stories.ts(x)`; `it_behaves_like`, `describe` and
`export default` never count — against the merge commit's first parent, or the fast-forward commits whose subject names
the issue. A ship with no landing commit is excluded from the denominator and counted (`N of M`); a `-` in the trend is a
row recorded before the gauge. Read all three columns: a fleet can add a third of a story suite in one night while the
rspec column reads `+0.0`. A rise against the previous fleet flags: ships are adding tests where the issue sits rather
than where the mechanism lives, so read the project's layer contract and route the duplicate arms to `/test-sweep`.
`/test-sweep`'s `baseline-series.sh` gives the suite-wide slope but reads only trees a session measured, so it cannot
attribute growth to ships.
