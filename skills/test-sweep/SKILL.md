---
name: test-sweep
description: Audit a project's test suites for cost and redundancy — rank rspec files by seconds and seconds per example, story files by exports and repetition, and propose one disposition per candidate (retire, consolidate, detag, hoist-ddl). `scan` runs unattended and read-only; `apply` executes mechanical proposals under the ledger gates and files judgment items. Use when the user says 'test sweep', 'what tests are slow', 'test-sweep scan', 'test-sweep apply', or invokes /test-sweep.
argument-hint: "[scan|apply] [suite:rspec|storybook|both] [top:N] [--dry-run] [--max-groups N]"
---

# Test Sweep — Audit the Suites for Cost and Redundancy

Test suites here only grow. Every rule that asks for a missing arm adds one, and nothing ever flags the arm that re-runs
a matrix another layer already pins — a request spec walking a policy spec's clauses again, a consumer's story re-running
a shared dialog's rejection path. This skill measures where the time goes, reads the costliest and most-repeated tests
against the layer that owns each mechanism, and removes the copies under gates that prove nothing was lost.

**Two modes, because reading parallelizes and deleting coverage is a decision.** `scan` writes only proposals and runs
unattended; `apply` changes tests and is interactive only — it refuses an `auto` token or an unattended context
outright: `ERROR: /test-sweep apply is interactive-only — removing coverage is a human decision. Run it directly.` A bare
`/test-sweep` runs `apply` when proposals exist and otherwise says to scan first.

Read first: the project's testing rules (its `.claude/rules/api.md` and `.claude/rules/storybook.md`, or equivalents),
[standards/testing.md](../../standards/testing.md) (what makes a surviving assertion discriminate), and
[agents/developer.md](../../agents/developer.md) § Testing Standards (the mutation protocol the apply gates enforce).
Project inputs, script exit codes and every verdict line are in [references/scripts.md](references/scripts.md).

## Arguments

- `scan` | `apply` — the mode.
- `suite:rspec|storybook|both` — default `both`.
- `top:N` — rspec candidates taken from each of the two rankings (default 25). Tagged files, repeated descriptions, and
  every story-census flag are candidates regardless.
- `--dry-run` — scan only: build the candidates, write the first group's prompt and one placeholder proposal, call no
  agent.
- `--max-groups N` — scan only: stop after N agent groups (a trial run).

## Scan — unattended, no sanctioned write route

Run from the project checkout, detached (a full scan is tens of groups at minutes each):

```bash
mkdir -p tmp
rm -f tmp/test-sweep-scan.done
nohup zsh -c 'bash ~/.claude/skills/test-sweep/scripts/sweep-scan.sh --repo "$PWD" > tmp/test-sweep-scan.out 2>&1; echo "EXIT=$?" > tmp/test-sweep-scan.done' >/dev/null 2>&1 &
disown
```

Trial first with `--dry-run --max-groups 1`, then `--max-groups 1` for one real group, before a full run. Exit `3` in the
`.done` file is a refused call; `LOCKED` (exit `2`) is another scan in flight.

Read [references/scan.md](references/scan.md) for what the scan reads, the ranking rules that nominate candidates, how
the headless invocation is kept read-only, the output files, the lock, and the resumability test (`--force` re-scans).
Each group's agent re-derives every count from the file, finds the lowest layer that owns each mechanism, and picks one
disposition:

- `retire` — every assertion is already pinned at the owning layer, which the proposal names as `target`; with no owner
  to name it is `keep`.
- `consolidate` — a repeated matrix moves to the surface that owns it; each consumer keeps one wiring case.
- `detag` — a play-less story file takes the render-only tag only when a play already in the gate mounts each of its
  exports with the same render, args and fixture; the proposal names the sibling in `target` and maps every export to
  its covering play, and a file with one unmounted export is `keep`.
- `hoist-ddl` — an rspec example pinning presence, uniqueness, or a foreign key that `db/schema.rb` already enforces
  becomes a one-line schema assertion.
- `keep` — the cost or repetition holds for a reason, stated in the evidence.

Each proposal says whether it is `mechanical` (a deletion or move with a named survivor and no open question) or a
judgment item, carries the `mutation` each deleted routing arm's survivor must redden against, and counts
`examples_removed` gross (every example deleted or folded away, whether or not a copy is added back; the added-back
count is `--hoisted` at apply time).

## Apply — interactive only

1. **Growth rate and summary.** Run `baseline-series.sh --repo . --suite rspec` and report its `SLOPE` as the growth
   rate, with its `WINDOW` (the last 30 days, one record per commit on HEAD's first-parent history; `--days N` changes
   it) and its `CLEAN`/`DIRTY-FALLBACK` line (a commit rests on a dirty-tree count only when it has no clean record; a
   batch's post-change count is dirty until it is committed and re-measured), then `sweep-scan.sh --summary`. The scan's
   `CANDIDATES` line is in `tmp/test-sweep-scan.out`. Read a proposal's full `report` only when its line needs it; a
   proposal whose report says a command was denied is a weak read — delete it and let the next scan redo it.
2. **One batch per kind.** Present each kind's mechanical proposals as a numbered list (`slug — file — evidence —
   estimated seconds — examples removed`) and one AskUserQuestion per batch, recommended action first. **Freeze the slug
   list at presentation time** and execute exactly that list — a selector evaluated later picks up proposals a
   still-running scan wrote after the approval ([standards/linear-workflow.md](../../standards/linear-workflow.md) § A
   batch approval covers the presented set). Before executing, re-check each approved proposal is still current:
   `bash ~/.claude/skills/test-sweep/scripts/sweep-scan.sh --repo . --check-current tmp/test-sweep-proposals/<slug>.json`
   must print `CURRENT`; a `STALE` proposal is dropped from the batch and re-scanned.
3. **Execute the approved batch, then gate it once.** Capture the baseline count **once**, before the first edit: rspec
   from `~/.claude/scripts/suite-baseline-cache.sh lookup rspec` (record one if it misses, per the project's rspec
   reference); storybook from the test-storybook count, or the census `EXPORTS` when the ledger counts exports. Make
   every change in the batch — delegate to a `developer` agent with the proposals' paths — and write the **consolidation
   ledger** into the commit message or PR body: one line per removed `it` description or story export, the quoted name
   exactly as the proposal's `removed` spells it and the survivor that now pins it after the arrow:

   ```text
   - "<removed description>" → <survivor file or description>
   ```

   Measure the post count once, on the same suite, after the last edit, then run one gate for the whole batch —
   `sweep-apply.sh` sums `examples_removed` and `--hoisted` across the proposals and unions their `removed` names:

   ```bash
   bash ~/.claude/skills/test-sweep/scripts/sweep-apply.sh \
     --proposal tmp/test-sweep-proposals/<slug-a>.json --proposal tmp/test-sweep-proposals/<slug-b>.json \
     --baseline-count <before the batch> --post-count <after the batch> [--hoisted <added>] --ledger <ledger file>
   ```

   Name every approved proposal with its own `--proposal`, exactly the frozen list; `--hoisted` may repeat. A `REFUSED`
   line names the gate: a count that moved by more than the batch claimed is a second, unplanned removal, by less a
   removal that did not happen; `--hoisted` summing to more than the `examples_removed` of the batch's `consolidate` and
   `hoist-ddl` proposals is refused (`hoisted-gate`), since only those kinds add anything back and never more than they
   removed; a ledger name that is not an exact quoted entry, a removed list shorter than `examples_removed`, a missing
   `--ledger`, a proposal that is a judgment item, a dry-run placeholder, a `keep`, or one removing examples with no
   `target` or no `mutation` is refused outright. Fix the change, never the numbers.
4. **The two proofs the script prints.** `STEP broken-assertion` — break one relocated assertion in the survivor
   deliberately, confirm it fails, restore it. `STEP mutation` — for every deleted routing arm, apply the recorded
   mutation to the implementation and confirm the survivor reddens; a survivor that stays green was never pinning the
   arm, and the deletion is reverted. Both follow the developer agent's mutation protocol: copy the file aside under
   `tmp/`, mutate with the Edit tool, restore by copying back.
5. **Move each executed proposal** to `tmp/test-sweep-proposals/applied/`, so a resumed session does not re-present it
   and the next scan skips it until its files change.
6. **Judgment items** (`mechanical: false`) are filed, never executed here, and **never filed `specified`**: `specified`
   makes an issue pickable by `/auto` unattended, and a judgment item is an open decision about what the suite should
   cover. File one issue per item, or per group sharing a governing rule, through the filing recipe
   ([standards/linear-filing.md](../../standards/linear-filing.md)) with the routing label `needs decision`. The body
   carries the proposal's evidence, the survivor, the mutation, and the governing rule. Move the filed proposal to
   `applied/` too.

The apply session reads the proposals under `tmp/test-sweep-proposals/`, `tmp/test-sweep-scan.out`, and
`tmp/test-sweep-scan.log`; the reaper keeps those and the scan's `.tsv`/`.txt` tables for 30 days.

**Report**, in this order: the growth rate (`SLOPE` per commit and per week — `-` when the points are too few or too
close — `WINDOW`, `CLEAN`/`DIRTY-FALLBACK`, points, span); what the scan covered (the `CANDIDATES` line, proposals by
kind); what was applied (per proposal: examples removed, estimated seconds, survivor, both proofs); what was filed
(issue ids); what was kept and why, in one line each.

## Cadence

Monthly is the intended rhythm: often enough that a redundant arm is caught while its author still remembers why it
exists, rarely enough that each scan's cost buys a real batch. Run `scan` by hand once a month.

**Automation (opt-in, not auto-installed):** `/loop 30d /test-sweep scan` is the only supported automation, and it needs
a session that stays alive for the whole interval. A cloud `/schedule` routine is not an option: it cannot see the
timings ledger in the git common dir, the last run's junit, or the storybook junit. Document it; never install it
silently.

## What this skill must NOT do

- **No deletion without both gates and both proofs.** A green suite after a deletion is not evidence; the count
  arithmetic, the ledger, the broken assertion, and the mutation are.
- **No unattended apply.** The scan is the only unattended half; it edits nothing and runs no suite, and the invocation,
  not its prompt, is what keeps it from trying — it has no sanctioned write route (`references/scan.md` § The deep
  pass).
- **No cut by age or by speed alone.** A slow test that pins a mechanism nothing else pins is `keep`; slowness only
  nominates.
- **No rule edits.** A sweep that finds a rule generating redundant arms says so in the report and files it; changing
  the rule is a separate decision.
- **No `specified` on a judgment item.** It would hand an open coverage decision to the unattended fleet.

## Error handling

- **`NO-TIMINGS`** → the ledger does not exist yet; run the full rspec suite once through the project's runner, or sweep
  `suite:storybook`.
- **`NO-JUNIT`, `NO-JUNIT … (empty)`, `WARN junit-subset`, `WARN junit-no-testcases`** → the census still runs; `SLOW`
  rows and storybook `estimated_seconds` are unavailable (the scan prints `WARN … no storybook timings`). Regenerate the
  report with a full, unfiltered `pnpm test-storybook-exec` redirected to a log. `junit-subset` means the junit's
  testcase count differs from the census `EXPORTS`: a filtered run's report, or exports added or removed since the last
  full run.
- **`NO-BASELINES`** → no suite-baseline cache yet; record a full run through `suite-baseline-cache.sh`.
- **A group logs `FAILED`** → read `tmp/test-sweep-proposals/raw/group-<id>.json.err`; re-running the scan picks the
  group's candidates up.
- **`LOCKED`** → another scan is running; wait for it, or `--force-unlock` when its pid is dead.
- **Exit 3** → a call was refused; proposals already written stand.
- **`STALE <slug> …` from `--check-current`** → a candidate or target file changed since the proposal was measured;
  drop it from the batch and re-scan.
- **`REFUSED <gate>` from `sweep-apply.sh`** → exit `1`; nothing is printed as a step until every gate passes.
