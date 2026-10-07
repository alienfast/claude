---
name: test-sweep
description: Periodic audit of a project's test suites for cost and redundancy — ranks rspec files by recorded seconds and seconds-per-example, ranks story files by export count and by shared-mechanism story names repeated across files, and proposes one disposition per candidate (retire, consolidate, detag, hoist-ddl) with the governing rule and the estimated seconds. Two modes like /triage: `scan` runs unattended through headless agents with no sanctioned write route (`--restricted` drops every inherited allow rule, the deny list closes the write-shaped commands, and the residual is `git diff/log/show --output=<file>`, which the prefix allow-list cannot exclude), writing one JSON proposal per candidate; `apply` is the interactive session that executes mechanical proposals as one batch under the consolidation-ledger gates (baseline example-count arithmetic, an exact-name ledger, one deliberately-broken relocated assertion, a mutation proof for every deleted routing arm) and files judgment items as `needs decision` Linear issues, never `specified`. Never installed on a schedule by itself — `/loop` is the only supported automation. Use when the user says 'test sweep', 'sweep the tests', 'what tests are slow', 'which stories are redundant', 'test-sweep scan', 'test-sweep apply', or invokes /test-sweep.
argument-hint: "[scan|apply] [suite:rspec|storybook|both] [top:N] [--dry-run] [--max-groups N]"
---

# Test Sweep — Audit the Suites for Cost and Redundancy

Test suites here only grow. Every rule that asks for a missing arm adds one, and nothing ever flags the arm that re-runs a matrix another layer already pins — a request spec walking a policy spec's clauses again, a consumer's story re-running a shared dialog's rejection path. This skill measures where the time goes, reads the costliest and most-repeated tests against the layer that owns each mechanism, and removes the copies under gates that prove nothing was lost.

**Two modes, because reading parallelizes and deleting coverage is a decision.** `scan` writes only proposals and runs unattended; `apply` changes tests and is interactive only — it refuses an `auto` token or an unattended context outright: `ERROR: /test-sweep apply is interactive-only — removing coverage is a human decision. Run it directly.` A bare `/test-sweep` runs `apply` when proposals exist and otherwise says to scan first.

Read first: the project's testing rules (basefund: `.claude/rules/api.md`, `.claude/rules/storybook.md`), [standards/testing.md](../../standards/testing.md) (what makes a surviving assertion discriminate), and [agents/developer.md](../../agents/developer.md) § Testing Standards (the mutation protocol the apply gates enforce).

## Arguments

- `scan` | `apply` — the mode.
- `suite:rspec|storybook|both` — default `both`.
- `top:N` — rspec candidates taken from each of the two rankings (default 25). Tagged files, repeated descriptions, and every story-census flag are candidates regardless.
- `--dry-run` — scan only: build the candidates, write the first group's prompt and one placeholder proposal, call no agent.
- `--max-groups N` — scan only: stop after N agent groups (a trial run).

## Project inputs

The defaults below are basefund's. A row's last column says whether another project can change it and how; a convention row cannot be changed through the scripts.

| Input | basefund default | How it resolves | Override |
|---|---|---|---|
| Rails app | `apps/api` | spec paths in the timings ledger are relative to it | `--api-dir` (scan and ranker) |
| rspec timings ledger | `<git common dir>/rspec-file-times.tsv` | `git -C <repo> rev-parse --path-format=absolute --git-common-dir`; written by `apps/api/ci`'s `run_rspec`, `path<TAB>seconds`, the most recent run's per-file time — one sample, so seconds are an order-of-magnitude figure | none (the ledger's location is the contract) |
| Last run's junit | `apps/api/test-reports/rspec/junit_w*.xml` | per-worker, `<testcase file="./spec/…" time="…">`; only the newest run's contiguous shards are read | `--junit-dir` on `rank-rspec-files.sh` (the scan does not forward it) |
| Slow DB-strategy tags | `:truncation`, `:unfenced_user_email` | a describe/context/it header carrying `:tag` or `tag: true`; comments do not count | `--tags` on `rank-rspec-files.sh` (the scan does not forward it) |
| Baseline series | `<git common dir>/suite-baselines/rspec/*.json` | `~/.claude/scripts/suite-baseline-cache.sh`'s store; `summary` = `rspec: N examples / …`; the last 30 days (by `recorded_at`), complete runs whose commit is on HEAD's first-parent history, one record per commit (the clean one — its `key` equals the commit's tree — else the latest dirty-tree one), ordered by that history | `--suite`, `--days` |
| Storybook junit | `tmp/storybook-junit.xml` | written by a full, unfiltered `pnpm test-storybook-exec` (redirect it to a log); a `pnpm check` that cache-hits does not rewrite it; absent, empty, or a report whose testcase count differs from the current exports (a filtered run's, or a stale one) means census only | `--junit`, `--slow` (scan and census) |
| Story file conventions | `*.behavior.stories.tsx`, `*.stories.shared.tsx`, the `render-only` tag, `…Blocked`/`…Granted`/`…Refused`/`…LandsOn` export prefixes | fixed in `story-census.sh` | none (basefund convention) |
| Governing rules | `.claude/rules/api.md`, `.claude/rules/storybook.md` | cited by section in every proposal | a project's committed `.claude/test-sweep-rules.md`, else `tmp/test-sweep-rules.md`, appended to every group's prompt under "Project rules" when present |

## Scripts and what they print

Each script prints one verdict per line; `--help` prints its usage. **Exit codes:** `0` success; `1` the input is absent or a gate refused (rank: no timings ledger; census: no story files; baseline-series: no cache or no usable record in the window; sweep-scan: no candidates could be built, or `--check-current` found a stale proposal; sweep-apply: a gate refused); `2` a usage or environment error (sweep-scan also `2` on `LOCKED`; sweep-apply also `2` for a proposal that is not JSON); sweep-scan alone exits `3` when a call was refused.

| Script | Verdict lines |
|---|---|
| [rank-rspec-files.sh](scripts/rank-rspec-files.sh) `--repo DIR [--top N]` | `TIMINGS <tsv> rows=N recorded=<mtime>`, `JUNIT … shards=w0..wN` or `NO-JUNIT …`, `STALE <n>` (ledger rows naming a deleted spec, not ranked), `RANK <seconds> <examples\|-> <s/example\|-> <path>` longest first, `TAGGED <path>`, `REPEAT "<it description>" <files…>`; `NO-TIMINGS <tsv>` when the ledger is absent |
| [story-census.sh](scripts/story-census.sh) `--repo DIR` | `FILES N EXPORTS N BEHAVIOR_FILES N PLAYS N NOPLAY_FILES N TAGGED N`, `BIG`, `SHARED`, `HELPER`, `DETAG-CANDIDATE`, `MATRIX`, `JUNIT <path> <mtime>` (mtime is information only), `NO-JUNIT <path>` or `NO-JUNIT <path> (empty)`, `WARN junit-subset tests=<n> exports=<m> — differs from the current tree (a filtered run, or exports added/removed since the last full run) — regenerate with a full pnpm test-storybook-exec` (no SLOW rows follow), `WARN junit-no-testcases`, `SLOW <seconds> <file>` |
| [baseline-series.sh](scripts/baseline-series.sh) `--repo DIR --suite rspec [--days N]` | `SERIES <recorded_at> <examples> <commit>` one per commit in first-parent order, oldest first, `SKIPPED N <reason>` (no-count-or-date, incomplete-workers, not-first-parent, outside-window, duplicate-commit), `CLEAN <n> DIRTY-FALLBACK <m>` (commits resting on a clean record versus only a dirty-tree one), `WINDOW <from> <to> <commits>`, `SLOPE per-commit=<examples/commit> per-week=<examples/week> points=N span=<first commit>..<last commit>` (`-` for a figure with fewer than two distinct x values; `per-week` is also `-` with fewer than 3 points or a first-to-last commit span under a day); `NO-BASELINES <dir>` when there is no cache |
| [sweep-scan.sh](scripts/sweep-scan.sh) | `CANDIDATES N current=N to-scan=N groups=N`, `WARN …` (no rspec timings, no story files, no storybook timings), `GROUP <id> ok\|FAILED\|REFUSED …`, `DRY-RUN …`, `SCAN-DONE proposals=<this run's> groups=N failed=N cost=$N` or `NOTHING-TO-SCAN`, `LOCKED <holder>`; `--check-current F` prints `CURRENT <slug>` or `STALE <slug> <why>`; `--summary` prints `PROPOSALS N seconds=N examples=N`, `KIND <kind> N mechanical=N seconds=N`, one line per non-keep proposal, `COST groups=N failed=N cost=$N` |
| [sweep-apply.sh](scripts/sweep-apply.sh) `--proposal F [--proposal F …] --baseline-count N --post-count N [--hoisted N …] --ledger F` | `PROPOSAL …` per proposal, `REFUSED <gate> <detail>` (gates: proposal-shape, mechanical-gate, placeholder-gate, kind-gate, target-gate, mutation-gate, hoisted-gate, ledger-gate, count-gate), `BATCH …`, `PASS count-gate`, `PASS ledger-gate`, `STEP mutation <slug> …`, `STEP broken-assertion <slug> …`, `GATES-PASSED <slug>` |

## Scan — unattended, no sanctioned write route

Run from the project checkout, detached (a full scan is tens of groups at minutes each):

```bash
mkdir -p tmp
rm -f tmp/test-sweep-scan.done
nohup zsh -c 'bash ~/.claude/skills/test-sweep/scripts/sweep-scan.sh --repo "$PWD" > tmp/test-sweep-scan.out 2>&1; echo "EXIT=$?" > tmp/test-sweep-scan.done' >/dev/null 2>&1 &
disown
```

Trial first with `--dry-run --max-groups 1`, then `--max-groups 1` for one real group, before a full run. Exit `3` in the `.done` file is a refused call; `LOCKED` (exit `2`) is another scan in flight.

**What it reads.** `rank-rspec-files.sh` (the timings ledger, the last run's junit, the spec tree) and `story-census.sh` (the story files from git, never a tree walk, so nested worktrees are not counted). Both outputs land in the project's `tmp/` as `test-sweep-rspec-rank.txt` and `test-sweep-story-census.txt`, and the agents read them there. `baseline-series.sh` is not a candidate source; it is the growth-rate figure the apply report carries.

**Ranking rules.** rspec candidates are the top N files by the most recent run's per-file seconds, the top N by seconds per example (fixture-heavy files hide below the seconds cut), every file carrying a slow DB-strategy tag, and every `it` description repeated under two or more top-level spec directories. The ledger keeps one run's time per file, so the seconds ranking is a noisy sample — agents are told to prefer seconds per example and the file's own junit. Story candidates are every file with ten or more exports, every story name shared by three or more behavior files, every helper defined at top level in three or more `*.stories.shared.tsx` files, every file with four or more exports sharing a `…Blocked`/`…Granted`/`…Refused`/`…LandsOn` prefix, and every play-less, untagged spec file whose behavior sibling exists (a play is a `play:` key or a `play(` call). A file flagged several ways is one candidate with all its reasons; a SHARED, HELPER, or REPEAT group is one candidate spanning its files.

**The deep pass.** Candidates are chunked five to a group within one suite, and each group runs one headless `claude -p` with structured output ([scripts/proposal.schema.json](scripts/proposal.schema.json)); the prompt is [scripts/scan-prompt.md](scripts/scan-prompt.md). **Read-only is enforced by the invocation, not by the prompt, and it leaves no sanctioned write route:** `--restricted` makes the run ignore the user, project and local settings files — without it `--allowedTools` only adds to the allow rules those files carry (`rm`, `mv`, `bundle exec rspec`, `pnpm`, `./tools/ci`), and a headless `mv` ran with no denial — `--strict-mcp-config` loads no MCP server, the tools are `Bash,Read,Grep,Glob`, Bash is limited to an allow-list of read commands (`git log|show|diff|ls-files|rev-parse|blame`, `jq`, `cat`, `ls`, `grep`, `head`, `tail`, `wc`; content search goes through the Grep tool, since `rg --pre` and `git grep -O` run commands), and an explicit `--disallowedTools` list denies write-shaped Bash (`rm`, `mv`, `bundle exec`, `pnpm`, `./tools/ci`, `git stash|restore|checkout`, `tee`). The residual is `git diff|log|show --output=<file>`, which writes a file and which a prefix allow-list cannot exclude. The prompt tells the agent to re-derive every count from the file rather than trust the census, find the lowest layer that owns each mechanism, and pick one disposition:

- `retire` — every assertion is already pinned at the owning layer, which the proposal names as `target`; with no owner to name it is `keep`.
- `consolidate` — a repeated matrix moves to the surface that owns it; each consumer keeps one wiring case.
- `detag` — a play-less story file whose behavior sibling carries the tests takes the render-only tag.
- `hoist-ddl` — an rspec example pinning presence, uniqueness, or a foreign key that `db/schema.rb` already enforces becomes a one-line schema assertion.
- `keep` — the cost or repetition holds for a reason, stated in the evidence.

Each proposal says whether it is `mechanical` (a deletion or move with a named survivor and no open question) or a judgment item, and carries the `mutation` each deleted routing arm's survivor must redden against. `examples_removed` is **gross**: every example or story deleted or folded away, whether or not a copy is added back elsewhere (a consolidate that moves 3 and drops 1 is `examples_removed: 4`, `--hoisted 3`). `estimated_seconds` is an order-of-magnitude figure, and `null` for storybook when no full junit report exists.

**Outputs.** `tmp/test-sweep-proposals/<slug>.json` per candidate, the raw agent output under `raw/`, the candidate, todo and group tables suite-scoped as `tmp/test-sweep-candidates-<suite>.tsv`, `tmp/test-sweep-todo-<suite>.tsv` and `tmp/test-sweep-groups-<suite>.txt`, and per-group cost and duration in `tmp/test-sweep-scan.log`. The scan's stdout (`tmp/test-sweep-scan.out`) is the only place the `CANDIDATES` line lives.

**One scan at a time.** The scan holds `tmp/test-sweep-scan.lock` for its whole run and a second scan refuses with `LOCKED pid=… run=… alive=<0|1>`. When the holder is not running (a crash), `--force-unlock` clears the lock; it refuses while the holder's pid is alive. Each run's id is `<timestamp>-<pid>`.

**Resumable.** A candidate is skipped when its proposal — pending, or under `applied/` — records a sha and `git log <sha>..HEAD` is empty for **both** the candidate's files and the proposal's `target` file; `--force` re-scans. A `target` is free text: each whitespace token of it is reduced to the substrings shaped like a path through a file extension (`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+`; whatever follows the extension — `:14-20`, `[1:2]`, `'s`, `::Foo`, `#<export>` — or precedes the path is dropped by construction), and each such path that resolves to a tracked file (as written, then under the Rails app) joins the watched files, while one that does not (a description, a survivor not written yet, an extensionless name such as `db/schema`) is skipped, so currency then rests on the candidate files alone; a `git ls-files` failure while resolving is `STALE`, never a skip; a proposal with no sha or no watched file at all is stale. A failed group writes nothing, so the next run picks its candidates up. A refused call (the session limit answers `is_error: true`) stops the run with exit 3; re-run after the reset the message names. A dry run's placeholder (`placeholder: true`) goes to `test-sweep-proposals/dry-run/`, where neither resumability nor apply reads it, and `sweep-apply.sh` refuses it anyway.

## Apply — interactive only

1. **Growth rate and summary.** Run `baseline-series.sh --repo . --suite rspec` and report its `SLOPE` as the growth rate, with its `WINDOW` (the last 30 days, one record per commit on HEAD's first-parent history; `--days N` changes it) and its `CLEAN`/`DIRTY-FALLBACK` line (a commit rests on a dirty-tree count only when it has no clean record; a batch's post-change count is dirty until it is committed and re-measured), then `sweep-scan.sh --summary`. The scan's `CANDIDATES` line is in `tmp/test-sweep-scan.out`. Read a proposal's full `report` only when its line needs it; a proposal whose report says a command was denied is a weak read — delete it and let the next scan redo it.
2. **One batch per kind.** Present each kind's mechanical proposals as a numbered list (`slug — file — evidence — estimated seconds — examples removed`) and one AskUserQuestion per batch, recommended action first. **Freeze the slug list at presentation time** and execute exactly that list — a selector evaluated later picks up proposals a still-running scan wrote after the approval ([standards/linear-workflow.md](../../standards/linear-workflow.md) § A batch approval covers the presented set). Before executing, re-check each approved proposal is still current: `bash ~/.claude/skills/test-sweep/scripts/sweep-scan.sh --repo . --check-current tmp/test-sweep-proposals/<slug>.json` must print `CURRENT`; a `STALE` proposal is dropped from the batch and re-scanned.
3. **Execute the approved batch, then gate it once.** Capture the baseline count **once**, before the first edit: rspec from `~/.claude/scripts/suite-baseline-cache.sh lookup rspec` (record one if it misses, per the project's rspec reference); storybook from the test-storybook count, or the census `EXPORTS` when the ledger counts exports. Make every change in the batch — delegate to a `developer` agent with the proposals' paths — and write the **consolidation ledger** into the commit message or PR body: one line per removed `it` description or story export, in this shape, the quoted name exactly as the proposal's `removed` spells it and the survivor that now pins it after the arrow:

   ```text
   - "<removed description>" → <survivor file or description>
   ```

   Measure the post count once, on the same suite, after the last edit, then run one gate for the whole batch — `sweep-apply.sh` sums `examples_removed` and `--hoisted` across the proposals and unions their `removed` names:

   ```bash
   bash ~/.claude/skills/test-sweep/scripts/sweep-apply.sh \
     --proposal tmp/test-sweep-proposals/<slug-a>.json --proposal tmp/test-sweep-proposals/<slug-b>.json \
     --baseline-count <before the batch> --post-count <after the batch> [--hoisted <added>] --ledger <ledger file>
   ```

   Name every approved proposal with its own `--proposal`, exactly the frozen list; `--hoisted` may repeat. A `REFUSED` line names the gate: a count that moved by more than the batch claimed is a second, unplanned removal, by less a removal that did not happen; `--hoisted` summing to more than the `examples_removed` of the batch's `consolidate` and `hoist-ddl` proposals is refused (`hoisted-gate`), since only those kinds add anything back and never more than they removed; a ledger name that is not an exact quoted entry, a removed list shorter than `examples_removed`, a missing `--ledger`, a proposal that is a judgment item, a dry-run placeholder, a `keep`, or one removing examples with no `target` or no `mutation` is refused outright. Fix the change, never the numbers.
4. **The two proofs the script prints.** `STEP broken-assertion` — break one relocated assertion in the survivor deliberately, confirm it fails, restore it. `STEP mutation` — for every deleted routing arm, apply the recorded mutation to the implementation and confirm the survivor reddens; a survivor that stays green was never pinning the arm, and the deletion is reverted. Both follow the developer agent's mutation protocol: copy the file aside under `tmp/`, mutate with the Edit tool, restore by copying back.
5. **Move each executed proposal** to `tmp/test-sweep-proposals/applied/`, so a resumed session does not re-present it and the next scan skips it until its files change.
6. **Judgment items** (`mechanical: false`) are filed, never executed here, and **never filed `specified`**: `specified` makes an issue pickable by `/auto` unattended, and a judgment item is an open decision about what the suite should cover. File one issue per item, or per group of items sharing a governing rule, through the filing recipe ([standards/linear-workflow.md](../../standards/linear-workflow.md) § Every Agent Filing Takes the Filing Recipe — search first, `linear-create-child.sh`, class labels and a priority) with the routing label `needs decision`. The body carries the proposal's evidence, the survivor, the mutation, and the governing rule. Move the filed proposal to `applied/` too.

The apply session reads the proposals under `tmp/test-sweep-proposals/`, `tmp/test-sweep-scan.out`, and `tmp/test-sweep-scan.log`; the reaper keeps those and the scan's `.tsv`/`.txt` tables for 30 days.

**Report**, in this order: the growth rate (`SLOPE` per commit and per week — `-` when the points are too few or too close — `WINDOW`, `CLEAN`/`DIRTY-FALLBACK`, points, span); what the scan covered (the `CANDIDATES` line, proposals by kind); what was applied (per proposal: examples removed, estimated seconds, survivor, both proofs); what was filed (issue ids); what was kept and why, in one line each.

## Cadence

Monthly is the intended rhythm: often enough that a redundant arm is caught while its author still remembers why it exists, rarely enough that each scan's cost buys a real batch. Run `scan` by hand once a month.

**Automation (opt-in, not auto-installed):** `/loop 30d /test-sweep scan` is the only supported automation, and it needs a session that stays alive for the whole interval. A cloud `/schedule` routine is not an option: it cannot see the timings ledger in the git common dir, the last run's junit, or the storybook junit. Document it; never install it silently.

## What this skill must NOT do

- **No deletion without both gates and both proofs.** A green suite after a deletion is not evidence; the count arithmetic, the ledger, the broken assertion, and the mutation are.
- **No unattended apply.** The scan is the only unattended half; it edits nothing and runs no suite, and the invocation, not its prompt, is what keeps it from trying: it has no sanctioned write route — `--restricted` drops every inherited allow rule, the deny list closes the write-shaped commands, and the residual is `git diff/log/show --output=<file>`, which the prefix allow-list cannot exclude.
- **No cut by age or by speed alone.** A slow test that pins a mechanism nothing else pins is `keep`; slowness only nominates.
- **No rule edits.** A sweep that finds a rule generating redundant arms says so in the report and files it; changing the rule is a separate decision.
- **No `specified` on a judgment item.** It would hand an open coverage decision to the unattended fleet.

## Error handling

- **`NO-TIMINGS`** → the ledger does not exist yet; run the full rspec suite once through the project's runner, or sweep `suite:storybook`.
- **`NO-JUNIT`, `NO-JUNIT … (empty)`, `WARN junit-subset`, `WARN junit-no-testcases`** → the census still runs; `SLOW` rows and storybook `estimated_seconds` are unavailable (the scan prints `WARN … no storybook timings`). Regenerate the report with a full, unfiltered `pnpm test-storybook-exec` redirected to a log. `junit-subset` means the junit's testcase count differs from the census `EXPORTS`: a filtered run's report, or exports added or removed since the last full run.
- **`NO-BASELINES`** → no suite-baseline cache yet; record a full run through `suite-baseline-cache.sh`.
- **A group logs `FAILED`** → read `tmp/test-sweep-proposals/raw/group-<id>.json.err`; re-running the scan picks the group's candidates up.
- **`LOCKED`** → another scan is running; wait for it, or `--force-unlock` when its pid is dead.
- **Exit 3** → a call was refused; proposals already written stand.
- **`STALE <slug> …` from `--check-current`** → a candidate or target file changed since the proposal was measured; drop it from the batch and re-scan.
- **`REFUSED <gate>` from `sweep-apply.sh`** → exit `1`; nothing is printed as a step until every gate passes.
