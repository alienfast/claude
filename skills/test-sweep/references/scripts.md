# Project inputs, scripts and verdict lines

Read this when running any `test-sweep` script by hand, overriding a project input, or decoding a verdict line.

## Project inputs

The defaults are the house layout (a Rails API under `apps/api` plus Storybook). A row's last column says whether
another project can change it and how; a convention row cannot be changed through the scripts.

| Input | Default | How it resolves | Override |
|---|---|---|---|
| Rails app | `apps/api` | spec paths in the timings ledger are relative to it | `--api-dir` (scan and ranker) |
| rspec timings ledger | `<git common dir>/rspec-file-times.tsv` | `git -C <repo> rev-parse --path-format=absolute --git-common-dir`; written by the API's CI runner, `path<TAB>seconds`, the most recent run's per-file time — one sample, so seconds are an order-of-magnitude figure | none (the ledger's location is the contract) |
| Last run's junit | `apps/api/test-reports/rspec/junit_w*.xml` | per-worker, `<testcase file="./spec/…" time="…">`; only the newest run's contiguous shards are read | `--junit-dir` on `rank-rspec-files.sh` (the scan does not forward it) |
| Slow DB-strategy tags | `:truncation`, `:unfenced_user_email` | a describe/context/it header carrying `:tag` or `tag: true`; comments do not count | `--tags` on `rank-rspec-files.sh` (the scan does not forward it) |
| Baseline series | `<git common dir>/suite-baselines/rspec/*.json` | `~/.claude/scripts/suite-baseline-cache.sh`'s store; `summary` = `rspec: N examples / …`; the last 30 days (by `recorded_at`), complete runs whose commit is on HEAD's first-parent history, one record per commit (the clean one — its `key` equals the commit's tree — else the latest dirty-tree one), ordered by that history | `--suite`, `--days` |
| Storybook junit | `tmp/storybook-junit.xml` | written by a full, unfiltered `pnpm test-storybook-exec` (redirect it to a log); a `pnpm check` that cache-hits does not rewrite it; absent, empty, or a report whose testcase count differs from the current exports (a filtered run's, or a stale one) means census only | `--junit`, `--slow` (scan and census) |
| Story file conventions | `*.behavior.stories.tsx`, `*.stories.shared.tsx`, the `render-only` tag, `…Blocked`/`…Granted`/`…Refused`/`…LandsOn` export prefixes | fixed in `story-census.sh` | none (fixed convention) |
| Governing rules | `.claude/rules/api.md`, `.claude/rules/storybook.md` | cited by section in every proposal | a project's committed `.claude/test-sweep-rules.md`, else `tmp/test-sweep-rules.md`, appended to every group's prompt under "Project rules" when present |

## Exit codes

`0` success; `1` the input is absent or a gate refused (rank: no timings ledger; census: no story files;
baseline-series: no cache or no usable record in the window; sweep-scan: no candidates could be built, or
`--check-current` found a stale proposal; sweep-apply: a gate refused); `2` a usage or environment error (sweep-scan
also `2` on `LOCKED`; sweep-apply also `2` for a proposal that is not JSON); sweep-scan alone exits `3` when a call was
refused. Each script prints one verdict per line; `--help` prints its usage.

## Verdict lines

| Script | Verdict lines |
|---|---|
| [rank-rspec-files.sh](../scripts/rank-rspec-files.sh) `--repo DIR [--top N]` | `TIMINGS <tsv> rows=N recorded=<mtime>`, `JUNIT … shards=w0..wN` or `NO-JUNIT …`, `STALE <n>` (ledger rows naming a deleted spec, not ranked), `RANK <seconds> <examples\|-> <s/example\|-> <path>` longest first, `TAGGED <path>`, `REPEAT "<it description>" <files…>`; `NO-TIMINGS <tsv>` when the ledger is absent |
| [story-census.sh](../scripts/story-census.sh) `--repo DIR` | `FILES N EXPORTS N BEHAVIOR_FILES N PLAYS N NOPLAY_FILES N TAGGED N`, `BIG`, `SHARED`, `HELPER`, `DETAG-CANDIDATE`, `MATRIX`, `JUNIT <path> <mtime>` (mtime is information only), `NO-JUNIT <path>` or `NO-JUNIT <path> (empty)`, `WARN junit-subset tests=<n> exports=<m> — differs from the current tree (a filtered run, or exports added/removed since the last full run) — regenerate with a full pnpm test-storybook-exec` (no SLOW rows follow), `WARN junit-no-testcases`, `SLOW <seconds> <file>` |
| [baseline-series.sh](../scripts/baseline-series.sh) `--repo DIR --suite rspec [--days N]` | `SERIES <recorded_at> <examples> <commit>` one per commit in first-parent order, oldest first, `SKIPPED N <reason>` (no-count-or-date, incomplete-workers, not-first-parent, outside-window, duplicate-commit), `CLEAN <n> DIRTY-FALLBACK <m>` (commits resting on a clean record versus only a dirty-tree one), `WINDOW <from> <to> <commits>`, `SLOPE per-commit=<examples/commit> per-week=<examples/week> points=N span=<first commit>..<last commit>` (`-` for a figure with fewer than two distinct x values; `per-week` is also `-` with fewer than 3 points or a first-to-last commit span under a day); `NO-BASELINES <dir>` when there is no cache |
| [sweep-scan.sh](../scripts/sweep-scan.sh) | `CANDIDATES N current=N to-scan=N groups=N`, `WARN …` (no rspec timings, no story files, no storybook timings), `GROUP <id> ok\|FAILED\|REFUSED …`, `DRY-RUN …`, `SCAN-DONE proposals=<this run's> groups=N failed=N cost=$N` or `NOTHING-TO-SCAN`, `LOCKED <holder>`; `--check-current F` prints `CURRENT <slug>` or `STALE <slug> <why>`; `--summary` prints `PROPOSALS N seconds=N examples=N`, `KIND <kind> N mechanical=N seconds=N`, one line per non-keep proposal, `COST groups=N failed=N cost=$N` |
| [sweep-apply.sh](../scripts/sweep-apply.sh) `--proposal F [--proposal F …] --baseline-count N --post-count N [--hoisted N …] --ledger F` | `PROPOSAL …` per proposal, `REFUSED <gate> <detail>` (gates: proposal-shape, mechanical-gate, placeholder-gate, kind-gate, target-gate, mutation-gate, hoisted-gate, ledger-gate, count-gate), `BATCH …`, `PASS count-gate`, `PASS ledger-gate`, `STEP mutation <slug> …`, `STEP broken-assertion <slug> …`, `GATES-PASSED <slug>` |
