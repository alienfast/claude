---
name: triage
description: Revalidate a team's Linear pool against the code as it stands NOW — never against calendar age — and dispose of what the check finds. Cancel what no longer applies (with the commit or issue as evidence), close what shipped under its own id, mark duplicates, narrow what partly shipped or re-file the remainder as a linked child, certify by research where the evidence in hand clears the spec quality bar, park vague business-filed requests on the filer with pointed questions, flag certified specs whose named subjects drifted for regroom, and wire collision edges for everything certified or narrowed. Two modes: `scan` runs the read-only deep pass unattended over the whole pool through headless agents and writes one proposal per issue; `apply` is the interactive session that turns proposals into writes, batched by verdict. Stage order Planned, then Backlog, then the Triage inbox last; resumable across runs through a per-issue revalidation marker. Use when the user says 'triage', 'triage scan', 'triage apply', 'triage the backlog', 'revalidate the backlog', 'clean up the backlog', 'what's stale', 'process the triage inbox', 'is BF-123 still valid', or invokes /triage.
argument-hint: "[scan|apply] [team:KEY] [stage:planned|backlog|triage] [lane:uncertified|certified|both] [ISSUE-ID ...]"
---

# Triage — Revalidate the Pool Against the Code

An issue goes stale because the code moved, not because time passed. A request filed in March against a surface that shipped in June is done; one filed yesterday against a mutation a sibling renamed this morning is already drifted. This skill reads every issue against the tree as it stands now and disposes of it on that evidence. **Never cancel, close, or de-prioritize on age**, and never on priority-plus-inactivity: an unprioritized Backlog issue with no comments is the normal state of a valid issue here.

It is the pool-level sibling of two skills and reimplements neither: `/spec` grooms one issue through a human interview, and `/auto-prep` audits the *certified* pool for fleet safety. What neither does is read the *uncertified* pool against the code — and re-read certified specs for decay — which is this skill's whole job.

**Two modes, because reading is cheap to parallelize and deciding is not.** `scan` is read-only and runs unattended: it covers the whole pool through headless agents and writes a proposal per issue. `apply` is interactive: every write that changes a state, a label, or a description is a human decision, so it refuses an `auto` token or an unattended context outright: `ERROR: /triage apply is interactive-only — dispositions are human decisions. Run it directly.` A bare `/triage` runs `apply` when proposals exist and otherwise says to scan first.

Read first: [skills/linear/SKILL.md](../linear/SKILL.md) (gotchas #6, #9, #13, #15, #20 bite here), [standards/issue-spec.md](../../standards/issue-spec.md) (quality bar, template, collision edges), [standards/linear-workflow.md](../../standards/linear-workflow.md) (claims, stage order, filing recipe).

## Arguments

- `scan` | `apply` — the mode. `scan` may be launched detached and left running for hours; `apply` reads what it produced.
- `team:KEY` — defaults to `$LINEAR_TEAM`; refuse to run with neither.
- `stage:planned|backlog|triage` — restrict to one stage. Default is all three in the fixed order **Planned → Backlog → Triage** (`standards/linear-workflow.md` § Stage Priorities): the inbox is the least important stage and comes last.
- `lane:uncertified|certified|both` — default `both`; within a stage the certified lane comes first (a fleet picks those next, so their decay costs the most).
- `ISSUE-ID ...` — targeted mode for a handful of issues: the deep pass runs in-session on Explore agents (Step 3's prompt file) instead of through the scan, then apply proceeds as usual.

## Step 1 and 2: The script pass — pool fetch and per-issue facts

Run the bundled script from the project checkout, in the background (about 1.6 seconds per unmarked issue, near-instant for marked ones; a 600-issue pool is 15 minutes cold):

```bash
mkdir -p tmp
zsh ~/.claude/skills/triage/scripts/triage-cheap-pass.sh --team <KEY> >| tmp/triage-run.log 2>&1
```

It paginates the raw API (`linear-cli issues list` returns at most 50 rows silently, and a `first:250` cap truncates a 500-issue Backlog just as silently), fetching every issue whose state *type* is triage, backlog, or unstarted, with description, comments, relations, and creator. For each issue it computes:

- **Claim.** Assigned to anyone but the viewer → `claimed`, dropped from every disposition (assignment is a claim); the count is reported.
- **Marker and baseline.** The newest comment starting `triage-revalidated:` (Step 5's format). Its sha is the baseline; without one, `createdAt` is.
- **Subjects.** With a marker, the marker's own `subjects=` list — the previous deep pass curated it. Without one, every slash-bearing token that resolves on disk, plus files that backticked identifiers resolve to after normalizing (line locators stripped; a bare `Name.ext` resolved by path; `Class#method` and `A::B::C` searched by their last segment; a dotted GraphQL path by its head token). An identifier resolving to more than 10 files is dropped as generic; an issue keeps at most 15 subject files, explicit paths first. Measured before those caps: 191 of 589 issues carried more than 40 subject files and the changed-since test fired on 493.
- **Changed since baseline** — `git log <marker sha>..HEAD -- <subjects>`, or `--since=<createdAt>` without a marker.
- **Commit-subject test.** A commit whose **subject line** leads with the issue's id is the shipped signal; a body-only mention is almost always the commit that *filed* it (measured on BF: 1 subject hit against 101 body mentions over 346 uncertified issues). A hit already adjudicated by an earlier run (an ancestor of the marker sha) is not re-flagged.

Each issue gets one class: `claimed`, `unchanged` (marker present, subjects intact, no commits since — **the only skip**), `shipped?`, `drifted` (a named subject no longer resolves), `touched` (commits on the subjects since the baseline), `no-subjects` (business-filed, never auto-skipped), or `never-revalidated`. The script prints the coverage line — `pool N unclaimed · skipped unchanged K · candidates M · never revalidated R` — the per-stage counts and each stage's queue heads, and writes `tmp/triage-cheap.ndjson` plus `tmp/triage-head.sha`. Read its output rather than re-deriving the numbers.

## Step 3: Scan — the unattended deep pass

```bash
rm -f tmp/triage-scan.done
nohup zsh -c 'zsh ~/.claude/skills/triage/scripts/triage-scan.sh --out tmp --stage all --lane certified --group-size 5 --concurrency 6 > tmp/triage-scan-certified.out 2>&1; echo "EXIT=$?" > tmp/triage-scan.done' >/dev/null 2>&1 &
disown
```

The scan orders candidates by stage, then lane, then subject area, then stale-signal (`shipped?`, `drifted`, `touched` first), chunks them five to a group, fetches any missing digest (`linear-context.sh`), and runs one headless `claude -p` per group with structured output ([scripts/proposal.schema.json](scripts/proposal.schema.json)), read-only tools, and an allow-list of read commands — the prompt is [scripts/scan-prompt.md](scripts/scan-prompt.md), the same questions Step 3 asked when it ran in-session: re-locate every subject by symbol, verdict against HEAD with the code fact, criteria still binding for a certified issue, the shipped discriminator (a comment-only commit is not shipped; an implementation that shipped under the issue's own id with the state never moved is `ship-close`), the business-language translation by mechanism, epics by their children, and one search per distinctive title token for duplicates and collisions. Each record carries the sha the agent measured, curated `subjects` (3 to 8 paths the next script pass reads), the one-line `evidence` a dialog shows, and the full `report`.

**Tiers.** Certified-lane groups run on the light model (`--model-light`, default sonnet); any light record flagged `escalate` or with a disposition other than `keep` is re-run in a full-model group (`--model-full`, default opus). Uncertified groups run on the full model. With both set to the same model the escalation pass is skipped. Measured 2026-09-22 on BF: a two-issue sonnet group took 100 seconds and $2.91, both confident keeps with file-level evidence; a five-issue group amortizes the fixed per-run overhead better.

**Resumable and safe to re-run.** An issue with a proposal file is skipped (`--force` re-scans); `unchanged` and `claimed` rows are never scanned; a failed group leaves no proposals, so the next invocation picks its issues up. `--max-groups 1 --ids A,B` is the trial run. Progress and per-group cost go to `tmp/triage-scan.log`, with group ids prefixed by the run's start time so two lanes' rows do not collide; `triage-scan.sh --summary` prints the counts by disposition and the non-keep lists with evidence. Two lanes may run concurrently at a lower `--concurrency` each. **A refused call stops the run** (exit 3): the account's session limit answers `is_error` with a message naming its reset time, and a refused call still bills the context it loaded — measured at about $2 per group, 28 groups' worth on the first full scan before this guard existed. Re-run both lanes after the reset; everything written before it stands.

**In-session variant** (targeted mode, or a small run): dispatch Explore agents yourself with the same prompt file, three to six issues sharing an area per agent, handing over file paths rather than inlined text, and write each report to `tmp/triage-deep-<group>.md`. Sizing from the first BF run: 30 issues took seven agents, ten minutes, and about 830k agent tokens.

## Step 4: Apply — dispositions from proposals, batched by verdict

Start from `triage-scan.sh --summary`. **Keeps and hand-to-spec listings need no approval** — their only write is the marker (`scripts/triage-apply-markers.sh`, which posts from the proposals and files each one under `applied/`) — so post those first, and repeat that pass as scan batches land. Then present each remaining verdict group as a numbered list (`ID — title — verdict — evidence line`, drawn from the proposal files) and one AskUserQuestion per group, at most four questions per call, recommended action first. The user corrects a stance; they never adjudicate an unweighted list. **Freeze the id list at presentation time and hand the applier exactly that list.** A selector evaluated at apply time ("every opus cancel proposal") also picks up proposals that landed after the approval — the first apply session canceled four unapproved issues that way and had to revert them. **When the filer is the viewer, ask the filer's questions in the dialog too.** Read a proposal's full `report` only when a line needs it. A proposal whose report says a command was denied, or that carries no questions for an ask-filer, is a weak read: delete the file and let the next scan re-read the issue.

- **Cancel** — the request no longer applies or was satisfied by *other* work. Post the evidence comment first (`~/.claude/scripts/linear-post.sh comment <ID> tmp/triage-<id>.md`, naming the commit or issue that resolved it, with plain issue URLs for mentions — gotcha #20), then `~/.claude/scripts/linear-set-state.sh Canceled <IDs>` as one verified batch. Never a cancel without an evidence line.
- **Ship-close** — the issue's *own* implementation shipped under its id and the state never moved. `git tag --contains <sha>` decides: in a release tag → `linear-set-state.sh Done`; on main but unreleased → `Ready for Release`. Never Cancel a shipped issue.
- **Duplicate** — `linear-cli relations add <DUP> <CANONICAL> -r duplicate` (first argument is the one being absorbed, and Linear moves it to the Duplicate state on its own — gotcha #15; read the state back with `issues get <DUP> --no-cache` and set it explicitly only if it did not land). Copy any detail the duplicate carries that the canonical lacks onto the canonical as a comment, and cross-comment both. Before absorbing into a *certified* canonical, test that the canonical's description reaches the absorbed subject (`/auto-prep` § Step 3's scope test); if it does not, wire `related` instead and list the pair for `/spec`.
- **Narrow** — part shipped, a remainder stands. Same problem → rewrite the description in the canonical template with the filed text preserved under `## Original request`, through `linear-post.sh description` after a `--no-cache` re-read. Different problem → file it as a linked child (`~/.claude/scripts/linear-create-child.sh <ID> <TEAM> Backlog "<title>" <body-file> [label] [priority]`, never a raw create) and cancel the original with a comment pointing at the child.
- **Certify** — its own pass, after the other batches: each candidate needs a drafted spec and per-issue approval of the **delta** (what the draft says that the filed text did not), which is the signoff `/spec` requires. On approval: description via `linear-post.sh`; `~/.claude/scripts/linear-add-label.sh <ID> specified` (exit 2 is *unconfirmed*, not failed — gotcha #17); `human` when the work is console or production operations; `simple` when the risk-low semantics hold and no `security`/`human`/`epic` label is present; then Step 5's edges and a certification comment. **State is the batch's one question:** an inbox issue lands in Backlog by default — the human curates Planned (keeper ruling 2026-08-15). A long candidate list may instead go to `/spec` in bulk.
- **Ask the filer** — post a comment addressed to the filer by name with the proposal's questions (at most three) and what each candidate surface does today, then `linear-add-label.sh <ID> 'needs decision'` so no fleet ranking reaches it. State unchanged.
- **Regroom** (certified) — subjects renamed with the defect intact → keep `specified`; the marker records the new names. A criterion now satisfied, a census that moved, a mechanism-exclusion the code falsified → `~/.claude/scripts/linear-remove-label.sh <ID> specified` with a comment naming what changed, listed for `/spec`. A **purely factual correction** — a pointer to an issue now in the Duplicate state, a checkbox the code proves satisfied, a clause a shipped sibling made false — may be applied here when the user approves the exact delta in the dialog (keeper decision 2026-09-22), the same bar as Certify; anything needing judgment stays `/spec`'s. Defect gone entirely → Cancel or Ship-close, whatever the label.
- **Epic** — stays open with open children even when its own brief shipped (the house auto-closes it when every child is terminal); a stale brief is a regroom note.

Never touch In Progress, In Review, or any assignee. After a proposal is applied, move its file to `tmp/triage-proposals/applied/` so a resumed apply session does not re-present it.

## Step 5: Collision edges, marker, report

**Edges** for everything certified, narrowed, or filed — and every collision the scan surfaced on a kept issue — per [issue-spec.md § Certification includes collision edges](../../standards/issue-spec.md): `blocks` only for a prerequisite, a same-method collision, or a deliberate increment (`linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`, blocker first); `related` for a shared file, spec, locale, or mechanism; nothing for no overlap. Never wire `blocks` behind an uncertified, `needs decision`, or non-head `solo` blocker. When the partner already sits in a chain, read both `.relations[]` and `.inverseRelations[]` (gotcha #22) and attach at the **tail**. A blocker already in `Done`, `Canceled`, `Duplicate`, or `Ready for Release` is resolved (the ranking's `TERMINAL_STATES`).

**Marker** — one **standalone** comment on every issue apply considered and left in the pool (keep, narrow, certify, hand-to-spec, ask-filer, regroom); not on `unchanged` skips, cancels, ship-closes, or duplicates. It must be its own comment with this exact first line, because the script pass parses the comment body by prefix — a marker folded into a certification comment is invisible to it:

```text
triage-revalidated: <the proposal's sha> <YYYY-MM-DD> verdict=<keep|narrowed|certified|spec|filer|regroom> subjects=<the proposal's curated paths, comma-separated, or none>
<one to three lines of what was checked and why the verdict holds>
```

**The sha is the one the agent measured, never HEAD at post time** — the branch moved under the first run between measurement and posting. Build the bodies from the proposals in one zsh loop and post each with `linear-post.sh comment`. Two zsh cautions that bit the first run: `${id,,}` is bash-only (`${id:l}` lowercases in zsh), and `issues get -o json` returns `labels` as `{nodes: […]}` — read labels back with `[.labels | .. | objects | .name? | select(. != null)]`. Do not store the marker anywhere local — a `tmp/` ledger is invisible to the next machine and to the team.

**Report**, in this order: coverage (the script pass's line, what the scan covered, what remains unproposed); dispositions applied, grouped (canceled and ship-closed with the resolving commit or release, duplicates, narrowed, certified with labels and edges, regroom flags, related edges); waiting on people (ask-the-filer issues by filer, the hand-to-/spec list with each one's open question); found in passing; milestones (`Planned: every issue revalidated at <sha>.`).

## What this skill must NOT do

- **No age-based or priority-based closes.** Staleness is measured against the code; "no update in 30 days" and "P4 with no activity" are not evidence of anything.
- **No `stalled` label for staleness** — it is `/auto`'s pipeline-failure marker.
- **No implementation planning** in a certified draft — WHAT, never HOW (`standards/issue-spec.md`).
- **No persistent claims** — no assignee writes, no In Progress, no branches.
- **No bare `issues update -l`, no raw `issues create`, no `issues list` for the pool** — the helpers exist because each of those silently loses data.
- **No unattended apply.** The scan is the only unattended half; it writes nothing to Linear.

## Error Handling

- **`linear-cli auth status` logged out** → `linear-cli auth oauth`, stop.
- **No team resolvable** → stop with the `team:KEY` usage line.
- **The script pass exits 2 (`page without pageInfo`)** → the query errored; it prints the raw envelope. Fix the cause before classifying an empty pool as drained (gotcha #6: `length` on `null` prints `0` at exit 0).
- **A scan group logs `FAILED`** → read `tmp/triage-proposals/raw/group-<n>-<model>.json.err`; a rate limit or a permission refusal inside the headless run is the usual cause. Re-running the scan picks the group's issues up again.
- **`linear-set-state.sh` exit non-zero mid-batch** → issues already verified stand; report which did not transition and stop the batch.
- **`linear-add-label.sh` exit 2** → the write may have landed; re-read with `--no-cache` before repeating it, and report certification as unconfirmed rather than failed.
