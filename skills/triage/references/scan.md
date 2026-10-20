# The scan — unattended deep pass internals

Read this when launching, resuming, or debugging `/triage scan` (Step 3). The script is
[scripts/triage-scan.sh](../scripts/triage-scan.sh); the prompt is [scripts/scan-prompt.md](../scripts/scan-prompt.md);
the output schema is [scripts/proposal.schema.json](../scripts/proposal.schema.json).

## What a run does

The scan orders candidates by stage, then lane, then subject area, then stale-signal (`shipped?`, `drifted`, `touched`
first), chunks them five to a group, fetches any missing digest (`linear-context.sh`), and runs one headless `claude -p`
per group with structured output, read-only tools, an allow-list of read commands, and nothing the machine's settings
files would otherwise allow — `--restricted` ignores them, `--strict-mcp-config` loads no MCP server, and a
`--disallowedTools` deny list closes the write-shaped commands and every `linear-cli` write; the script names the
residual a prefix allow-list cannot exclude.

The prompt asks the same questions the deep pass asks in session: re-locate every subject by symbol, verdict against
HEAD with the code fact, criteria still binding for a certified issue, the shipped discriminator (a comment-only commit
is not shipped; an implementation that shipped under the issue's own id with the state never moved is `ship-close`),
the business-language translation by mechanism, epics by their children, and one search per distinctive title token for
duplicates and collisions. Each record carries the sha the agent measured, curated `subjects` (3 to 8 paths the next
script pass reads), the one-line `evidence` a dialog shows, and the full `report`.

## Tiers

Certified-lane groups run on the light model (`--model-light`, default sonnet); any light record flagged `escalate` or
with a disposition other than `keep` is re-run in a full-model group (`--model-full`, default opus). Uncertified groups
run on the full model. With both set to the same model the escalation pass is skipped. A two-issue light group runs
about 100 seconds and a few dollars; a five-issue group amortizes the fixed per-run overhead better.

## Resumable and safe to re-run

An issue with a pending proposal is skipped (`--force` re-scans), and so is one under `applied/` whose pool row's
`marker_sha` differs from that proposal's `sha` — the pool file predates the apply. A matching sha means the cheap pass
saw the marker and still flagged the issue, so it is re-scanned: `applied/` is never cleared, and skipping on presence
alone would silently block every later run's re-scans. `unchanged` and `claimed` rows are never scanned; a failed group
leaves no proposals, so the next invocation picks its issues up. `--max-groups 1 --ids A,B` is the trial run.

Progress and per-group cost go to `tmp/triage-scan.log`, with group ids prefixed by the run's start time so two lanes'
rows do not collide; `triage-scan.sh --summary` prints the counts by disposition and the non-keep lists with evidence.
Two lanes may run concurrently at a lower `--concurrency` each.

## A refused call stops the run (exit 3)

The account's session limit answers `is_error: true` under `subtype: success`, with `.result` naming the reset time.
Two shapes: a group **in flight** when the limit lands is cut off mid-run — many turns, no `structured_output`, and
`total_cost_usd` for the work already done — while a group **launched after** the limit is refused at `num_turns: 1`,
zero tokens, in seconds. Stopping at the first refusal recovers nothing already spent; it ends a pointless launch loop
and surfaces the reset time. Re-run both lanes after the reset: everything written before it stands, and the cut-off
groups are re-scanned because they left no proposals.

## In-session variant

For targeted mode (`ISSUE-ID ...`) or a small run, dispatch Explore agents yourself with the same prompt file, three to
six issues sharing an area per agent, handing over file paths rather than inlined text, and write each report to
`tmp/triage-deep-<group>.md`. Sizing: roughly 30 issues per seven agents, ten minutes, and about 830k agent tokens.
