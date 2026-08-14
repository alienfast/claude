# Fleet context-compaction investigation

**Loading this doc is the trigger to re-run the verification protocol below** — it exists so the
autocompact tuning gets re-adjudicated against fresh fleet data, not remembered. Status of each pass
goes in the log at the bottom.

## The finding (2026-08-14)

Fleet productivity fell while burn rose: 3 sessions exhausted a 5h usage window that 9 leaner
sessions had survived on 2026-08-06, and one 3-session night consumed ~50% of the weekly allowance.
Measured, not felt — cost per shipped issue climbed monotonically across five fleets:

| fleet start | sessions | $/issue | ktok/issue | $/Mtok out | plan% | ctx>=200k% |
|---|---|---|---|---|---|---|
| 2026-08-05 | 9 | $89.94 | 146 | $617 | 29% | not yet measured |
| 2026-08-06 | 4 | $109.68 | 154 | $711 | 22% | — |
| 2026-08-07 | 3 | $121.25 | 159 | $765 | 23% | — |
| 2026-08-13 | 6 | $148.43 | 194 | $767 | 37% | 94% |
| 2026-08-13 (night) | 3 | $161.49 | 200 | $809 | 40% | — |

The +80% decomposes as **+37% output tokens per issue** (more work per issue: review findings per
review 6.2 → 9.5, Critical+High per review roughly doubled, plan-origin findings 29% → 40%) times
**+31% dollars per output token** (fatter context behind every call).

## Root cause of the context factor

`fleet-launch.sh` pinned every session to `opus[1m]`, and auto-compact's default threshold scales
with the model window — so a `/loop /auto` session accumulating context across iterations for 12+
hours effectively **never compacted**. Measured on the 2026-08-13/14 transcripts: 29,272 API calls
moved 9.7B billable prompt tokens in 24h, **91% at >200k context, 44% at >400k, only 4% below
150k**; cache reads ran at ~1,000x output volume. Opus 5's 1M window carries no premium rate — the
cost is pure linear scaling of cache-read volume with context size, multiplied by every tool call.

Secondary contributors, distinct levers:

- **Keeper-side Fable 5 sessions** on the same account (2.8M output + 351M cache-read in 48h at
  $10/$50) — invisible to fleet metrics, which only read the fleet checkout, but metered by the same
  account allowances. "N agents hit the limit" undercounts by these.
- **Treadmill share** — the workspace minted ~500 issues (BF-643 → BF-1138) in the two weeks the
  fleets shipped ~120; reviews file 1.24 issues per ship. Throughput on self-generated work is not
  backlog drain. Now measured directly (provenance gauge below).

## The intervention (2026-08-14)

`fleet-launch.sh` adds `--autocompact 150000` as a default dispatch flag (per-launch overridable:
`fleet-launch 3 10h -- --autocompact 250000`). Rationale in `skills/auto/SKILL.md` and
`skills/fleet-launch/SKILL.md`: `/auto`'s cross-iteration state lives in `tmp/auto-state-*.json`,
verdict files, and Linear — not in context — so compaction between issues is designed to be
loss-free. `[1m]` stays, for single-oversized-issue headroom.

Instruments added to `scripts/fleet-metrics.py` the same day:

- **Context distribution** — share of billable prompt volume by context size at call time
  (per-session `ctx>=200k` column, fleet-level bucket line, trend column).
- **Cross-run trend** — every windowed run appends a headline row to
  `tmp/fleet-metrics-history.jsonl` (keyed by session set; re-runs replace) and the report's tail
  diffs the last six fleets. Backfilled 2026-08-14 from the saved per-fleet reports.
- **Shipped-issue provenance** — joins ships against retro Step 3's Linear exports
  (`tmp/fleet-shipped-issues.json`, `tmp/fleet-linear-window.json`); fresh share = treadmill gauge.

## Re-verification protocol (run this when the doc is loaded)

1. `~/.claude/scripts/fleet-metrics.py --checkout ~/projects/basefund --hours 36` (or `--since` the
   latest fleet's launch). Read **Context distribution** and **Cross-run trend** first.
2. **Did the cap engage?** Post-change fleets should show the >=200k share collapsed from ~94%
   toward ~0, with volume pooled in 50–150k. If it did NOT: auto-compact is not firing in background
   `claude agents` sessions — this was never explicitly confirmed in the docs (checked v2.1.232,
   2026-08-14) — so check the dispatch log for the flag, then test `--autocompact` behavior in a
   background session directly. That is the one unverified assumption in the whole intervention.
3. **Sized too small?** The signature is rework, read off the trend row against the 2026-08-13
   baselines above:
   - ktok/issue **rising** while $/Mtok out falls — re-derivation tax, the sharpest single tell;
   - cycles / findings-per-review rising **in the impl/test origin lanes** (plan-origin rises track
     spec quality, not compaction — the origins split discriminates);
   - hours per shipped issue rising;
   - contract-forgetting flags clustering (shipped-without-recording, state drift, dangling calls).
   Any two of these with the ctx share down → raise the threshold stepwise (200k → 250k → 300k) via
   the launch override; an A/B inside one night is two `fleet-launch` invocations with different
   values, attributed by the per-session ctx column.
4. **Sized right?** ctx>=200k% near zero, $/Mtok out down materially (baseline $767–809), churn
   gauges flat within noise, ktok/issue flat or down. Then consider whether $/issue's remaining
   excess is the churn factor (plan% ≥ 37% says spec/planning quality is the live lever, not
   context) and whether fresh% says the fleet is eating its own filings.
5. **Record the verdict in the log below** — date, fleet measured, ctx share, the gauge readings,
   and the action taken (kept 150k / raised to N / follow-up filed).

## Open follow-ups

- Compactions-per-shipped-issue counter in fleet-metrics (direct thrash measure; transcripts mark
  compaction boundaries). Deliberately deferred until an ambiguous verdict needs it — verify the
  marker row shape before implementing.
- Keeper-side burn accounting: fleet sizing reads only the fleet checkout, but the account meters
  every session. A retro column summing non-fleet usage in the same window would close the "3 agents
  hit the limit" undercount.
- Treadmill: if fresh% stays high across retros with R (filed/shipped) near 1, the lever is filing
  policy and spec quality, not fleet size or context — route via /auto-prep and /spec, not here.

## Verdict log

| date | fleet | ctx>=200k% | ktok/issue | cycles | impl-origin trend | action |
|---|---|---|---|---|---|---|
| 2026-08-14 | 2026-08-13 x6 (pre-change baseline) | 94% | 194 | 2.11 | baseline | shipped `--autocompact 150000` |
