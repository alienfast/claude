---
name: triage
description: Revalidate a team's Linear pool against the code as it stands NOW — never against calendar age — and dispose of what the check finds. Cancel what no longer applies (with the commit or issue as evidence), close what shipped under its own id, mark duplicates, narrow what partly shipped or re-file the remainder as a linked child, certify by research where the evidence in hand clears the spec quality bar, park vague business-filed requests on the filer with pointed questions, flag certified specs whose named subjects drifted for regroom, and wire collision edges for everything certified or narrowed. Sweeps stage by stage — Planned, then Backlog, then the Triage inbox last — least-recently-revalidated first, resumable across runs through a per-issue revalidation marker, with a script pass covering the whole pool every run. Interactive-only. Use when the user says 'triage', 'triage the backlog', 'revalidate the backlog', 'clean up the backlog', 'what's stale', 'process the triage inbox', 'is BF-123 still valid', or invokes /triage.
argument-hint: "[team:KEY] [stage:planned|backlog|triage] [lane:uncertified|certified|both] [limit:N] [ISSUE-ID ...]"
---

# Triage — Revalidate the Pool Against the Code

An issue goes stale because the code moved, not because time passed. A request filed in March against a surface that shipped in June is done; one filed yesterday against a mutation a sibling renamed this morning is already drifted. This skill reads every issue against the tree as it stands now and disposes of it on that evidence. **Never cancel, close, or de-prioritize on age**, and never on priority-plus-inactivity: an unprioritized Backlog issue with no comments is the normal state of a valid issue here.

It is the pool-level sibling of two skills and reimplements neither: `/spec` grooms one issue through a human interview, and `/auto-prep` audits the *certified* pool for fleet safety. What neither does is read the *uncertified* pool against the code — and re-read certified specs for decay — which is this skill's whole job. Every disposition it applies is a human decision, so it is **interactive-only** and refuses any `auto` token or unattended context outright: `ERROR: /triage is interactive-only — dispositions are human decisions. Run it directly.`

Read first: [skills/linear/SKILL.md](../linear/SKILL.md) (gotchas #6, #9, #13, #15, #20 bite here), [standards/issue-spec.md](../../standards/issue-spec.md) (quality bar, template, collision edges), [standards/linear-workflow.md](../../standards/linear-workflow.md) (claims, stage order, filing recipe).

## Arguments

- `team:KEY` — defaults to `$LINEAR_TEAM`; refuse to run with neither.
- `stage:planned|backlog|triage` — restrict the sweep to one stage. Default is all three in the fixed order **Planned → Backlog → Triage** (`standards/linear-workflow.md` § Stage Priorities): the inbox is the least important stage and is processed last, never first.
- `lane:uncertified|certified|both` — default `both`. Within a stage, the certified lane runs first (those issues are what a fleet picks next, so their decay costs the most), then the uncertified lane.
- `limit:N` — the deep-pass attention cap per run, default 15; `limit:0` lifts it. Sizing from the first BF run (2026-09-22): a cap of 30 took seven parallel Explore agents, about ten minutes, and roughly 830k agent tokens. The script pass always covers the whole pool regardless.
- `ISSUE-ID ...` — targeted mode: revalidate exactly these issues, any stage, any lane, no cap.

## Step 1 and 2: The script pass — pool fetch and per-issue facts

Run the bundled script from the project checkout, in the background (it takes about 1.6 seconds per unmarked issue and is near-instant for marked ones; a 600-issue pool is 15 minutes cold):

```bash
mkdir -p tmp
zsh ~/.claude/skills/triage/scripts/triage-cheap-pass.sh --team <KEY> >| tmp/triage-run.log 2>&1
```

It paginates the raw API (`linear-cli issues list` returns at most 50 rows silently, and a `first:250` cap truncates a 500-issue Backlog just as silently), fetching every issue whose state *type* is triage, backlog, or unstarted, with description, comments, relations, and creator. Then for each issue it computes:

- **Claim.** Assigned to anyone but the viewer → `claimed`, dropped from every disposition (assignment is a claim); the count is reported.
- **Marker and baseline.** The newest comment starting `triage-revalidated:` (Step 6's format). Its sha is the baseline; without one, `createdAt` is.
- **Subjects.** With a marker, the marker's own `subjects=` list — the previous deep pass curated it, which beats re-deriving. Without one, every slash-bearing token that resolves on disk, plus files that backticked identifiers resolve to after normalizing (line locators stripped; a bare `Name.ext` resolved by path; `Class#method`, `A::B::C` searched by their last segment; a dotted GraphQL path by its head token). An identifier resolving to more than 10 files is too generic and dropped; an issue keeps at most 15 subject files, explicit paths first. Measured before those caps: 191 of 589 issues carried more than 40 subject files and the changed-since test fired on 493, discriminating nothing.
- **Changed since baseline** — `git log <marker sha>..HEAD -- <subjects>`, or `--since=<createdAt>` without a marker.
- **Commit-subject test.** A commit whose **subject line** leads with the issue's id is the shipped signal; a body-only mention is almost always the commit that *filed* it (measured on BF: 1 subject hit against 101 body mentions over 346 uncertified issues). A hit already adjudicated by an earlier run (an ancestor of the marker sha) is not re-flagged.

Each issue gets one class: `claimed`, `unchanged` (marker present, subjects intact, no commits since — **the only skip**), `shipped?`, `drifted` (a named subject no longer resolves: rename or removal), `touched` (commits on the subjects since the baseline), `no-subjects` (business-filed, never auto-skipped), or `never-revalidated`. The script prints the coverage line — `pool N unclaimed · skipped unchanged K · candidates M · never revalidated R` — the per-stage counts, and each stage's queue heads, and writes `tmp/triage-cheap.ndjson` plus **`tmp/triage-head.sha`, the sha every marker of this run must carry** (Step 6). Read its output rather than re-deriving the numbers.

While it runs, pre-fetch the Linear digests for the issues that will be in the attention set (`~/.claude/scripts/linear-context.sh <ID> >| tmp/triage-digest-<ID>.md`); with no markers yet that is the first `limit` issues in stage order, which the Step 3 ordering makes predictable.

## Step 3: Deep pass on the attention set

Order: stage (Planned, Backlog, Triage), then lane (certified first), then no-marker-first with oldest `createdAt` first, then marker date. **`shipped?` issues jump the queue whatever their stage** — they are cheap to confirm and the highest-value finds (the first run's two were a released fix still sitting in Triage and a comment-only commit that only looked like one). Take issues up to `limit`, `drifted` and `touched` ahead of the rest within the cap.

For each, the question is the one a project's planning rules put at pickup — is the stated defect or request still real — answered **before** anyone plans a fix, with three possible answers: **stale** (gone), **accurate**, or **understated** (real, and larger than filed). Delegate read-only explorations, **three to six issues sharing an area per Explore agent**, all agents in one parallel batch, each handed file paths rather than inlined text:

```text
Task for Explore agent (read-only, medium): revalidate these <N> issues against HEAD. Do not edit files or write to Linear.
Issues: <ID — title, filed <date> by <creator>, lane, labels> …
For each: read tmp/triage-digest-<ID>.md and `jq -c 'select(.id=="<ID>")' tmp/triage-cheap.ndjson` (subjects, unresolved, changed, shipped_subject, body_mentions).
1. Re-locate every subject by SYMBOL, never by line: a zero-hit grep is a rename signal as often as a removal — settle it with `git log -S<symbol>` and name the commit and its issue id.
2. Verdict against HEAD: STALE (gone or shipped: name the commit or issue), ACCURATE (quote the code fact), UNDERSTATED (say how). For a certified issue read each Success Criterion / Must Have against HEAD: still binding, already satisfied, or naming a subject that no longer resolves.
3. A subject-line commit hit: say what the commit actually changed and whether the issue's own comments record a deferral — a comment-only commit is not shipped.
4. Business-language request naming no code: enumerate candidate surfaces by MECHANISM (the mutation submitted, the record minted, the route rendered) and by label, read each candidate's contract, and say which one the request most plausibly means, what it does today, and whether it is satisfied / partly satisfied / untouched. If the code cannot disambiguate, list the 1–3 questions the filer must answer.
5. An `epic`-labelled issue: revalidate by its children — list each child and its state (`issues get <ID> -o json | jq .children`, plus `relations list` reading both .relations[] and .inverseRelations[]) and say whether the description still describes the open ones.
6. Duplicates: one `linear-cli search issues "<token>"` per distinctive single word from the title (never a phrase), keep hits whose state NAME is not Done/Canceled/Duplicate/Ready for Release, name any open issue that is the same defect — and any same-file or same-mechanism overlap as a collision rather than a duplicate.
Report per issue: Verdict (one evidence line) · Subjects (resolved / renamed / removed, with commit + issue id) · Criteria still binding (certified only) · Recommended disposition (cancel | ship-close | duplicate-of | narrow | certify | hand-to-spec | ask-filer | keep | regroom) · Duplicate and collision candidates. Facts only; no fix proposals.
```

Save each report to `tmp/triage-deep-<group>.md` as it arrives, so the disposition batches assemble from files rather than from context.

## Step 4: Dispositions — batched by verdict, one approval per batch

Group results by verdict and present each group as a numbered list — `ID — title — verdict — one evidence line` — then one AskUserQuestion per group (at most four questions per call, so two calls for a full run) with the recommended action first. The user corrects a stance; they never adjudicate an unweighted list. **When the filer is the viewer, ask the filer's questions in the dialog too** — the first run certified an issue in-run that way instead of parking it.

- **Cancel** — the request no longer applies or was satisfied by *other* work. Post the evidence comment first (`~/.claude/scripts/linear-post.sh comment <ID> tmp/triage-<id>.md`, naming the commit or issue that resolved it, with plain issue URLs for mentions — gotcha #20), then `~/.claude/scripts/linear-set-state.sh Canceled <IDs>` as one verified batch. Never a cancel without an evidence line.
- **Ship-close** — the issue's *own* implementation shipped under its id and the state never moved (an "Implementation Complete" comment on an issue still in Triage is the shape). `git tag --contains <sha>` decides: in a release tag → `linear-set-state.sh Done`; on main but unreleased → `Ready for Release`. Never Cancel a shipped issue.
- **Duplicate** — `linear-cli relations add <DUP> <CANONICAL> -r duplicate` (first argument is the one being absorbed, and Linear moves it to the Duplicate state on its own — gotcha #15; read the state back with `issues get <DUP> --no-cache` and set it explicitly only if it did not land). Copy any detail the duplicate carries that the canonical lacks onto the canonical as a comment, and cross-comment both. Before absorbing into a *certified* canonical, test that the canonical's description reaches the absorbed subject (`/auto-prep` § Step 3's scope test); if it does not, wire `related` instead and list the pair for `/spec`.
- **Narrow** — part shipped, a remainder stands. Same problem → rewrite the description in the canonical template with the filed text preserved under `## Original request`, through `linear-post.sh description` after a `--no-cache` re-read. Different problem → file it as a linked child (`~/.claude/scripts/linear-create-child.sh <ID> <TEAM> Backlog "<title>" <body-file> [label] [priority]`, never a raw create) and cancel the original with a comment pointing at the child.
- **Certify** — the research in hand answers every item of issue-spec.md's quality bar with no product judgment left open. Draft the spec to `tmp/triage-spec-<id>.md` and present the **delta** for explicit approval; that approval is the signoff `/spec` requires. On approval: description via `linear-post.sh`; `~/.claude/scripts/linear-add-label.sh <ID> specified` (exit 2 is *unconfirmed*, not failed — gotcha #17); `human` when the work is console or production operations; `simple` when the risk-low semantics hold and no `security`/`human`/`epic` label is present; then Step 5's edges, then a certification comment carrying the marker. **State is the batch's one question:** an inbox issue lands in Backlog by default — the human curates Planned (keeper ruling 2026-08-15) — with Planned offered for anything the user says belongs to the release.
- **Hand to /spec** — valid, and the gap is product judgment (a fork between complete outcomes, a policy call, an issue that must be split). No write beyond the marker; the report lists the one question.
- **Ask the filer** — the code cannot disambiguate a vague request even after the translation. Post a comment addressed to the filer by name with at most three pointed questions and what each candidate surface does today, then `linear-add-label.sh <ID> 'needs decision'` so no fleet ranking reaches it. State unchanged.
- **Keep** — valid, not yet certifiable, nothing to change. The marker is the only write.
- **Regroom** (certified) — split by what moved. Subjects renamed with the defect intact → keep `specified`; the marker records the new names. A criterion now satisfied, a census that moved, a mechanism-exclusion the code falsified → `~/.claude/scripts/linear-remove-label.sh <ID> specified` with a comment naming what changed, listed for `/spec`. A **purely factual correction** — a pointer to an issue now in the Duplicate state, a checkbox the code proves satisfied, a clause a shipped sibling made false — may be applied here when the user approves the exact delta in the dialog, the same signoff bar as Certify; anything needing judgment stays `/spec`'s. Defect gone entirely → Cancel or Ship-close, whatever the label.
- **Epic** — an epic with open children stays open even when its own brief shipped (the house auto-closes it when every child is terminal); a stale brief is a regroom note, not a cancel.

Never touch In Progress, In Review, or any assignee.

## Step 5: Collision edges for everything certified, narrowed, or filed

Certification is what makes an issue fleet-pickable, and the deep pass has just read the code, so wire now, per [issue-spec.md § Certification includes collision edges](../../standards/issue-spec.md): `blocks` only for a prerequisite, a same-method collision, or a deliberate increment (`linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`, blocker first); `related` for a shared file, spec, locale, or mechanism; nothing for no overlap. Never wire `blocks` behind an uncertified, `needs decision`, or non-head `solo` blocker — use `related` plus a comment. When the partner already sits in a chain, read both `.relations[]` and `.inverseRelations[]` (gotcha #22) and attach at the **tail**. Verify each `blocks` edge with `linear-cli relations list <BLOCKED>` and, for a certified dependent, its absence from `~/.claude/scripts/next-candidates.sh --team <KEY> --limit 200`. Collisions the deep pass surfaced on *kept* issues get their `related` edge in the same batch.

Stale edges surface here too: a blocker already in `Done`, `Canceled`, `Duplicate`, or `Ready for Release` is resolved (the ranking's `TERMINAL_STATES`), so an issue that reads blocked only by such is not — say so rather than repeating Linear's UI framing.

## Step 6: Marker, then report

Post one marker comment on every issue the deep pass **considered and left in the pool** — keep, narrow, certify, hand-to-spec, ask-the-filer, regroom — via `linear-post.sh comment`. Not on `unchanged` skips, not on cancels, ship-closes, or duplicates. Fixed first line, so the script can parse it by prefix:

```text
triage-revalidated: <sha from tmp/triage-head.sha> <YYYY-MM-DD> verdict=<keep|narrowed|certified|spec|filer|regroom> subjects=<comma-separated paths, or none>
<one to three lines of what was checked and why the verdict holds>
```

**The sha is the one the deep pass measured, never HEAD at post time.** The branch moved under the first run between measurement and posting; a HEAD-at-post-time sha would have hidden those commits from the next run's changed-since test. **The `subjects=` list is what the next run's fast path reads**, so make it the curated set the deep pass validated — the files the issue is actually about, not the generic-identifier spread. Build the bodies from a TSV (`id, verdict, subjects, note`) in one zsh loop; write bodies to `tmp/triage-marker-<ID>.md` and post each. Two zsh cautions that bit the first run: `${id,,}` is bash-only (`${id:l}` lowercases in zsh), and `issues get -o json` returns `labels` as `{nodes: […]}` — read labels back with `[.labels | .. | objects | .name? | select(. != null)]`.

Do not store the marker anywhere local — a `tmp/` ledger is invisible to the next machine and to the team.

Then report, in this order:

1. **Coverage** — the script's line, plus what the next run starts on (the queue head per stage) and how many runs at this cap finish the pool.
2. **Dispositions applied**, grouped: canceled and ship-closed (with the resolving commit or release), duplicates, narrowed (and any child filed), certified (state landed in, labels, edges wired with a one-line reason), regroom flags (label removed or kept), related edges wired.
3. **Waiting on people** — ask-the-filer issues with the filer's name, and the hand-to-/spec list with each one's open question.
4. **Found in passing** — issues outside the attention set that the deep pass judged stale or duplicate; they are next run's first candidates, not this run's writes.
5. **Milestones** — when a stage or lane came back fully revalidated, say so on its own line: `Planned: every issue revalidated at <sha>.`

## What this skill must NOT do

- **No age-based or priority-based closes.** Staleness is measured against the code; "no update in 30 days" and "P4 with no activity" are not evidence of anything.
- **No `stalled` label for staleness** — it is `/auto`'s pipeline-failure marker.
- **No implementation planning** in a certified draft — WHAT, never HOW (`standards/issue-spec.md`).
- **No persistent claims** — no assignee writes, no In Progress, no branches.
- **No bare `issues update -l`, no raw `issues create`, no `issues list` for the pool** — the helpers exist because each of those silently loses data.
- **No unattended run.** `auto` token or no human → refuse before the first write.

## Error Handling

- **`linear-cli auth status` logged out** → `linear-cli auth oauth`, stop.
- **No team resolvable** → stop with the `team:KEY` usage line.
- **The script exits 2 (`page without pageInfo`)** → the query errored; it prints the raw envelope. Fix the cause before classifying an empty pool as drained (gotcha #6: `length` on `null` prints `0` at exit 0).
- **`linear-set-state.sh` exit non-zero mid-batch** → issues already verified stand; report which did not transition and stop the batch.
- **`linear-add-label.sh` exit 2** → the write may have landed; re-read with `--no-cache` before repeating it, and report certification as unconfirmed rather than failed.
- **Explore agent unavailable** → run the deep pass on Linear context and the script's git facts alone, and say so before the first disposition batch.
