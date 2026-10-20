# Scoping pitfalls

Read from `/fleet-retro` Step 1 when the discovered session count disagrees with the fleet's, when the report carries a
WARNING, or before quoting any subagent token figure, `obs` count or review-churn number.

## A session set can span a fleet already retro'd

A top-up carries every session the registry still lists into the new set (the `retiring` ones included), and the analyzer
measures a session from its first turn, so a session alive when the previous fleet's retro ran counts its earlier hours
and ships twice. The analyzer refuses the trend row with a WARNING naming the earlier row and the shared sessions. A
partial-scope WARNING naming another of that earlier fleet's sessions is the same overlap (the launch cleared its
ledger), and neither of its remedies helps: `--since`/`--hours` still measure the carried sessions, and `--allow-partial`
only reaches the overlap refusal, while every total above already double-counts. Report the post-relaunch leg,
re-deriving its hours, ships and cost from the transcripts.

No flag clips a session's events by time: `--since`/`--hours`/`--until` keep or drop whole sessions, and are ignored
under a session set.

## Ledgers without `mode`

`/auto` stamps `mode` on its ledger, and the analyzer keeps `mode: single` runs out of any undirected scope. In older
data without the stamp the tell is the per-session table's `wakeups` column — a `/loop /auto` session arms one per
iteration, a single run shows `0 (0 stop)`.

## Subagent output tokens are a floor below full coverage

Read the `Subagent usage rows` line under the token table before any output-token figure. A subagent transcript streams
one row per content block, all sharing the message id, and only the row stamped `stop_reason` carries the message's whole
output count — the rest carry a placeholder of a few tokens. The script credits the largest value per id and reports how
many subagent messages have a final row at all; below 100% every subagent figure, ktok/issue and burn rate is a floor and
$/Mtok out a ceiling (the trend table's `sub-final%`). Coverage varies by run with no cause established — near-complete
on most fleets, a small fraction on some, on one harness version — so a low share is a finding to carry, not to explain
away.

## The `obs` count's three witnesses

The per-session `obs` count reads the bare `SHIPPED-*: <ID>` line, the `mark-ready-for-release.sh <ID>` call the merge
path makes, and /auto's `AUTO-CONTINUE: <ID> shipped (<tag>)` iteration line; `observed_by` in the JSON splits them as
`tags`, `calls` and `outcomes`. The call is the reliable witness for a merge that lands in the session — the tag alone
misses most of them — but a merge deferred to the queue gets its call from the drainer (`merge-queue.sh`), later and
outside any session, so the outcome line is its only trace. When ledgers have been deleted, the witnesses are what
remains: count them before reading `shipped` as the total. A session whose `obs` lags its ledger is a witness gap (tag
drift, or a queued ship), not an unrecorded ship.

## Which verdicts are this fleet's reviews

The review-churn table reads `tmp/quality-review-verdict-*.md`: cycles, findings by severity, the SEVERITY/origin split
(`plan`/`impl`/`spec`/`test`/`latent` — a verdict without the tag counts toward the tagged/total coverage figure and is
never assumed), and deferred filings paired against the fleet's ships as a filed-per-shipped rate. It counts only
verdicts for issues the session set shipped, failed, canceled or dispatched a reviewer for; any other verdict in the
window — typically an interactive review beside the fleet — is named on its own "Not this fleet's reviews" line and
counted in nothing. Cycles alone is a weak churn signal — the review loop's convergence design pins it near 2 — so read
findings volume, severity and origin mix instead. The token table is what turns model/effort tuning into arithmetic: it
shows where output tokens went (orchestration vs exploration vs review vs fixes), by agent type and model.
