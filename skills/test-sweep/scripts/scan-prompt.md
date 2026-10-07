# Test sweep deep pass

You are running the deep pass of the /test-sweep skill: a READ-ONLY audit of test files for cost and redundancy at HEAD. Working directory: the project checkout. Do NOT edit files, do NOT run any test suite, and do NOT write to Linear. Facts only; the apply session makes every change.

Record `git rev-parse --short=10 HEAD` first; it goes into the output's `sha`.

Candidates in this group (slug, suite, files, and why the census flagged it):
{{CANDIDATES}}

The census that flagged them is a survey, not an inventory. Its outputs are in `{{OUT}}`:

- `{{OUT}}/test-sweep-rspec-rank.txt` — `RANK <seconds> <examples|-> <s/example|-> <spec path>` (paths relative to `{{API_DIR}}`), `TAGGED <spec path>` (carries a slow DB-strategy tag), `REPEAT "<it description>" <files>` (one description under two or more top-level spec dirs). The seconds are the most recent run's per-file time, one noisy sample (a file moved from 60 s to 19 s between consecutive runs): treat `estimated_seconds` as an order-of-magnitude figure, and when ranking candidates against each other prefer s/example and the file's own timings in the last run's junit under `{{API_DIR}}/test-reports/rspec/` over the seconds column. Examples and s/example come from that junit.
- `{{OUT}}/test-sweep-story-census.txt` — totals, `BIG`, `SHARED <StoryName> <count> <files>`, `HELPER <name> <count> <files>`, `DETAG-CANDIDATE <file> sibling=<file>`, `MATRIX <file> <prefix> <count>`, and `SLOW <seconds> <file>` (per file, at most the slowest few) when a full storybook junit report exists. A `WARN junit-subset` or `NO-JUNIT` line means there are no storybook timings.
- `{{JUNIT}}` (relative to the checkout) — the storybook junit, one `<testcase classname=… name=… time=…>` per story: the per-story source for storybook `estimated_seconds`.

**Re-derive every count you report by reading the files.** A grep census misses a story built by a factory, an example generated in a loop, a matrix spelled with a different prefix, and a helper re-declared under another name; a repeated `it` description can be two genuinely different assertions. Your `examples_removed` is checked against a real before/after suite count at apply time, so a count copied from the census that the file does not bear out fails the gate.

## The questions, per candidate

1. **What does the file pin, and where else is it pinned?** Name the mechanism each expensive or repeated example exercises (the policy clause, the dialog's rejection path, the uniqueness index). Find the lowest layer that owns that mechanism — the policy spec for an authorization matrix, the shared dialog's own behavior file for its rejection arms, `db/schema.rb` for a NOT NULL, unique index, or foreign key — and say whether that layer already pins every arm this file repeats. Quote the surviving example or story by name.
2. **Why is it slow?** For an rspec file high on seconds or seconds-per-example, read its `let!`/`before` setup and its metadata: a truncation strategy, a per-example fixture graph, a sleep or a real timeout, a loop over many records. Say whether the cost is intrinsic to what it tests or incidental to how it is set up. Incidental setup cost with no redundancy is not a disposition here — say so in `report` and use `keep`.
3. **Pick one disposition.**
   - `retire` — delete examples or stories whose every assertion is already pinned at the owning layer. Name the owner in `target`; a retire with no surviving owner to name is `keep`.
   - `consolidate` — the file (or each file of a SHARED / REPEAT / HELPER group) re-runs a matrix the owning surface should hold once: move the matrix there, keep one wiring case per consumer. For a HELPER group, the target is the one shared module every copy should import.
   - `detag` — a story file with no play functions whose behavior sibling carries the tests: tag it render-only so the test run skips it while it still renders and snapshots. Verify that no story in the file runs a play, including one supplied by a shared factory or story builder the file imports.
   - `hoist-ddl` — an rspec example pinning presence, uniqueness, or a foreign key that `db/schema.rb` already enforces moves to a one-line schema assertion. Quote the schema line.
   - `keep` — the cost or repetition holds for a reason. Say the reason in `evidence`.
4. **Mechanical or judgment.** `mechanical: true` only when the change is a deletion or move with no open question: the survivor already exists and is named, the arms being removed are byte-for-byte the same mechanism, and no reviewer could argue coverage was lost. Anything needing a decision about what the suite should cover — a consolidation that changes which layer owns a matrix, a retire whose owner covers most but not all arms — is `mechanical: false`; the apply session files it as a `needs decision` Linear issue and never executes it.
5. **The proof the apply session owes.** For every deleted routing arm (an example or story that exists to show the code chose A over B), write in `mutation` the one-line change to the implementation that the surviving assertion must redden against — file, symbol, and the swap. A survivor that stays green against that mutation was never pinning the arm, and the deletion is unsafe. The apply gate refuses a proposal that removes examples without a `target` and a `mutation`.

## Governing rules to cite

Cite the rule file and section heading that licenses the disposition in `governing_rule`. The basefund defaults below are used unless a `## Project rules` section follows this prompt; then cite that section's rules instead:

- `.claude/rules/api.md` § "The policy spec owns the arm matrix — a surface spec pins routing, one allow and one deny per operation" — a request or mutation spec pins one wiring case per surface, never the policy's clause matrix again.
- `.claude/rules/api.md` § "A data migration that writes through the live model runs validations written against a later schema", the lead-in "A migration spec retires once its migration has shipped." — a spec for a migration already inside a release tag pins nothing the schema does not.
- `.claude/rules/storybook.md` § "A matrix over one mount is one play, not one export per case" — exports that differ only in mock data over one mounted component fold into one play.
- `.claude/rules/storybook.md` § "A shared mechanism is pinned once, at its own stories" — a shared dialog's or hook's arms live in its own behavior file; each consumer pins one wiring case.
- `.claude/rules/storybook.md` § "Taking a render-only story out of the gate: `tags: ['render-only']`" — what a `detag` changes and what it leaves running.
- `.claude/rules/storybook.md` § "Moving a story must hold the counts identical" and § "A change that adds or removes exports declares a ledger instead" — the ledger every removal needs.

Read each section before citing it; if a heading above does not exist in this checkout, cite the section that does govern the case and say in `report` that the named one was missing. Never cite a section you did not read.

## Fields

- `slug` — exactly as listed above. One record per listed candidate, none for anything else.
- `file` — the file that loses tests (for a group, the first one the change edits); `target` — where the surviving assertion lives (file plus example or export name).
- `estimated_seconds` — for rspec, the file's recorded seconds times the share of its examples removed (from the RANK row; an order-of-magnitude figure); for storybook, the summed `time` of the removed stories' testcases in `{{JUNIT}}`, or `null` when that file is absent, empty, or the census printed `WARN junit-subset` (a subset run's times are not the suite's).
- `examples_removed` — GROSS examples or story exports deleted or folded away, re-derived, whether or not a copy is added back elsewhere; the apply gate separately counts what is added back as `hoisted`. A consolidate that moves 3 examples to the owning surface and drops 1 is `examples_removed: 4`. `removed` — every `it` description or export name deleted or folded, one entry per removed example, which the apply session's consolidation ledger must name beside its survivor.
- `evidence` — the one line a human reads in a batch dialog: the measured count and the code fact that decides it.
- `report` — the full markdown write-up: what you re-derived and how it differs from the census, the matrix and where it is already pinned, the survivor, the ledger lines, and any risk.
