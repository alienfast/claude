# The scan — unattended deep pass internals

Read this when launching, resuming, or debugging `/test-sweep scan`. The script is
[scripts/sweep-scan.sh](../scripts/sweep-scan.sh); the prompt is [scripts/scan-prompt.md](../scripts/scan-prompt.md);
the output schema is [scripts/proposal.schema.json](../scripts/proposal.schema.json).

## What it reads

`rank-rspec-files.sh` (the timings ledger, the last run's junit, the spec tree), `story-census.sh` (the story files
from git, never a tree walk, so nested worktrees are not counted) and `clone-census.sh` (one jscpd run over the checkout,
with the project's `.jscpd.json` and `.jscpd-baseline.json` when present). The outputs land in the project's `tmp/` as
`test-sweep-rspec-rank.txt`, `test-sweep-story-census.txt` and `test-sweep-clone-census.txt`, and the agents read them
there; the raw jscpd report is kept beside them as `test-sweep-clone-report.json`. `baseline-series.sh` is not a
candidate source; it is the growth-rate figure the apply report carries.

## Ranking rules

rspec candidates are the top N files by the most recent run's per-file seconds, the top N by seconds per example
(fixture-heavy files hide below the seconds cut), every file carrying a slow DB-strategy tag, and every `it` description
repeated under two or more top-level spec directories. The ledger keeps one run's time per file, so the seconds ranking
is a noisy sample — agents are told to prefer seconds per example and the file's own junit. Story candidates are every
file with ten or more exports, every story name shared by three or more behavior files, every helper defined at top
level in three or more `*.stories.shared.tsx` files, every file with four or more exports sharing a
`…Blocked`/`…Granted`/`…Refused`/`…LandsOn` prefix, and every play-less, untagged spec file whose behavior sibling exists
(a play is a `play:` key or a `play(` call). Clone-pair candidates are, per suite, the top N file pairs by duplicated
lines among jscpd's cross-file clones whose two files are test files of that suite (`*_spec.rb`; `*.stories.tsx` and
`*.stories.shared.tsx`; `*.spec.ts`), every block the pair shares folded into one candidate whose line ranges the census
lists under it. A same-file clone, a pair with a non-test file, and — where a baseline is committed — a pair the baseline
does not carry are not candidates. The e2e suite exists through this source alone. A file flagged several ways is one
candidate with all its reasons; a SHARED, HELPER, REPEAT or clone-pair group is one candidate spanning its files.

## The deep pass

Candidates are chunked five to a group within one suite, and each group runs one headless `claude -p` with structured
output. **Read-only is enforced by the invocation, not by the prompt, and it leaves no sanctioned write route:**
`--restricted` makes the run ignore the user, project and local settings files — without it `--allowedTools` only adds to
the allow rules those files carry (`rm`, `mv`, `bundle exec rspec`, `pnpm`, `./tools/ci`), and a headless `mv` runs with
no denial — `--strict-mcp-config` loads no MCP server, the tools are `Bash,Read,Grep,Glob`, Bash is limited to an
allow-list of read commands (`git log|show|diff|ls-files|rev-parse|blame`, `jq`, `cat`, `ls`, `grep`, `head`, `tail`,
`wc`; content search goes through the Grep tool, since `rg --pre` and `git grep -O` run commands), and an explicit
`--disallowedTools` list denies write-shaped Bash (`rm`, `mv`, `bundle exec`, `pnpm`, `./tools/ci`, `git
stash|restore|checkout`, `tee`). The residual is `git diff|log|show --output=<file>`, which writes a file and which a
prefix allow-list cannot exclude.

The prompt tells the agent to re-derive every count from the file rather than trust the census, find the lowest layer
that owns each mechanism, and pick one disposition (defined in SKILL.md § Scan). Each proposal says whether it is
`mechanical` (a deletion or move with a named survivor and no open question) or a judgment item, and carries the
`mutation` each deleted routing arm's survivor must redden against. `examples_removed` is **gross**: every example or
story deleted or folded away, whether or not a copy is added back elsewhere (a consolidate that moves 3 and drops 1 is
`examples_removed: 4`, `--hoisted 3`). `estimated_seconds` is an order-of-magnitude figure, and `null` for storybook
when no full junit report exists.

## Outputs

`tmp/test-sweep-proposals/<slug>.json` per candidate, the raw agent output under `raw/`, the candidate, todo and group
tables suite-scoped as `tmp/test-sweep-candidates-<suite>.tsv`, `tmp/test-sweep-todo-<suite>.tsv` and
`tmp/test-sweep-groups-<suite>.txt`, the three census files and the jscpd report named above, and per-group cost and
duration in `tmp/test-sweep-scan.log`. The scan's stdout
(`tmp/test-sweep-scan.out`) is the only place the `CANDIDATES` line lives.

## One scan at a time

The scan holds `tmp/test-sweep-scan.lock` for its whole run and a second scan refuses with `LOCKED pid=… run=…
alive=<0|1>`. When the holder is not running (a crash), `--force-unlock` clears the lock; it refuses while the holder's
pid is alive. Each run's id is `<timestamp>-<pid>`.

## Resumable

A candidate is skipped when its proposal — pending, or under `applied/` — records a sha and `git log <sha>..HEAD` is
empty for **both** the candidate's files and the proposal's `target` file; `--force` re-scans. A `target` is free text:
each whitespace token of it is reduced to the substrings shaped like a path through a file extension
(`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+`; whatever follows the extension — `:14-20`, `[1:2]`, `'s`, `::Foo`, `#<export>` — or
precedes the path is dropped by construction), and each such path that resolves to a tracked file (as written, then
under the Rails app) joins the watched files, while one that does not (a description, a survivor not written yet, an
extensionless name such as `db/schema`) is skipped, so currency then rests on the candidate files alone; a `git ls-files`
failure while resolving is `STALE`, never a skip; a proposal with no sha or no watched file at all is stale. A failed
group writes nothing, so the next run picks its candidates up. A refused call (the session limit answers `is_error:
true`) stops the run with exit 3; re-run after the reset the message names. A dry run's placeholder (`placeholder: true`)
goes to `test-sweep-proposals/dry-run/`, where neither resumability nor apply reads it, and `sweep-apply.sh` refuses it
anyway.
