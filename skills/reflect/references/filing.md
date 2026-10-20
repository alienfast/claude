# Filing `propose` items as a Linear issue

Read this at `/reflect` Step 6 once the items to file are known — every `propose` item in an unattended run, or the
ones the user chose interactively. The general recipe is [standards/linear-filing.md](../../../standards/linear-filing.md);
this file carries what is specific to a reflection filing.

## 1. Resolve the team

Derive it from the worked issue's ID prefix (`PL-13` → `PL`) — the issue ID already in context, or
`~/.claude/scripts/detect-issue-id.sh` from the branch. If no issue/team resolves (a standalone reflection in a
non-issue context), **skip filing** — surface the diffs only and record `Filed: none — <reason>`; never guess a team.

## 2. Build the body

Into a unique tmp file — `mkdir -p tmp`, then `body_file=$(mktemp -u tmp/reflect-improvement-XXXXXX)` (`-u`: name only,
no file created — the Write tool refuses a pre-existing file it has not Read. No suffix — BSD `mktemp` only substitutes
a template that ends in the `X`s). Shape:

```text
Filed by /reflect after working <ISSUE-ID>. These config/process improvements were
proposed (not auto-applied — apply-now edits already landed in the working tree).

## Proposals
- [ ] **<target file>** — <one-line observation>
      <ready-to-paste diff in a fenced diff block>
- [ ] ...
```

- **Title, observations and any acceptance line enumerate the same scope the diff changes.** A count in the title and
  an acceptance line naming a subset both read as the filing's scope, so anything the diff additionally changes ships
  unannounced — and an implementer who trusts the prose carries the omission into their plan. Count what the diff
  changes and make the prose match.
- **A proposal that asks the keeper for a decision rather than offering a diff** takes `standards/issue-spec.md` § The
  Problem is a story: the observation told in time order with its actors and the stake in their units, then
  `## Options` lettered and named by outcome, recommendation first, with the measurements under `## Evidence`. An
  inventory of mechanisms has to be retold as a story before it can be decided.
- **Write the proposed config text self-contained** — mechanism, date, magnitude — with no team-local vocabulary: no
  team-prefixed issue IDs and no team-local label or state names inside the diff's prose (test fixtures replaying real
  history exempt). The issue body and the eventual commit message are the provenance home for IDs; the keeper strips
  them at adjudication otherwise.
- Reference the originating issue by its plain Linear URL (`linear-cli issues get <ID> -o json | jq -r '.url'`) so it
  renders as a mention — a bare `<ISSUE-ID>` written through the API stays dead text (linear skill gotcha #20). Do
  **not** parent-link — a config improvement is standalone, not a child of the feature that surfaced it. The body
  certifies via the trusted-pipeline carve-out in `standards/issue-spec.md` — observation = problem, diff = outcome,
  checkboxes = criteria — so filing self-certifies without an interview.
- **When a proposal's text describes code that landed under an issue — usually the originating one — record it as a
  checkable precondition, not just a link.** A session-mode run mid-issue precedes `/finish`'s commit and merge, so the
  code may not be on the source branch yet and there may be no merge SHA to cite; even in fleet mode the precondition
  line beats a SHA (stable across rebases, readable). Its own line in the body:

  ```text
  Precondition: this text describes code landed under <ORIGIN-ID>. Before editing, confirm it is in this tree —
  `git log --oneline | grep -q '<ORIGIN-ID>'` — and if absent, `git merge <source-branch>` first (merge, never
  rebase: a rebase detaches the stamped baseline and /finish refuses, exit 4).
  ```

  Grep the issue ID, not a `Merge <ID>` subject: `finish-merge.sh` creates a merge commit only when the source branch
  moved during the worktree's life, so the landed work often appears solely as its own `<ORIGIN-ID>: <summary>` line.
  A worktree cut for this proposal forks from the main checkout's HEAD at pick time, which in a parallel fleet routinely
  predates that merge, and nothing flags it. Without this line every present-tense claim in the proposal is false
  against the tree the implementer is editing.

## 3. Dedup, then file

Run step 5's per-target-file token searches BEFORE creating (reuse the results for edge wiring). An OPEN hit whose body
describes the same defect against the same target absorbs the batch item: do NOT create a twin — append the proposal
(evidence and diff) as a comment on the existing issue (`~/.claude/scripts/linear-post.sh comment`) and record it as
`Filed: <ID> (existing — evidence appended)`. Two reflections in one fleet window hit the same friction routinely, and
post-create edge wiring cannot un-file a twin. Then file, capturing the exit code — pass `--keeper` iff **≥1 proposal
targets the user-level `~/.claude` repo** (any target outside the project — `~/.claude/CLAUDE.md`, `~/.claude/rules/`,
`standards/`, `skills/`, `scripts/`):

```bash
new_id=$(~/.claude/scripts/linear-file-improvement.sh [--keeper] <team> "<title>" "$body_file"); rc=$?
```

The helper creates one standalone issue — status `Backlog` (unattended filings never enter the curated Planned release
scope; the human plans), unassigned, labels `specified` + `reflection` (created if missing; `specified` is the
certification that makes it `/auto`-eligible, `reflection` is what makes `/next` rank it ahead of product work) — and
echoes the identifier. With `--keeper` it attaches `keeper` **instead of** `specified`, filing uncertified: `/auto`
ships project repos only, so a certified `~/.claude` issue produces a zero-commit false ship or a re-declined pick in
every fresh session. Uncertified, `/auto` ignores it everywhere, while `keeper` hides it from every machine whose
`git -C ~/.claude config reflect.keeper` is not `true` and boosts it on the keeper's for interactive pickup. Title e.g.
`Continuous improvement from <ISSUE-ID>: <N> proposal(s)`. A `reflection`-only attach failure is a WARN within exit 0.

## 4. Branch on `rc` for the `Filed:` line, then continue to step 5

Never block the reflection or the enclosing `/full` on filing.

- `0` → `Filed: <new_id>` (filed and certified; for a `--keeper` batch: filed uncertified and keeper-gated).
- `2` → `Filed: <new_id> (label not attached)` — filed, but the load-bearing label (`specified`; `keeper` for a
  `--keeper` batch) could not attach; surface the helper's WARN so the user can fix it.
- `1` (or empty `new_id`) → `Filed: none — <reason>`; surface the `propose` diffs as before.

## 5. Wire the filed issue's collision edges

`standards/issue-spec.md` § Certification includes collision edges: filing hands the pool a pickable issue, so
sequencing against open siblings must already be mechanical. `<new-ID>` below is the identifier step 3 captured — that
capture ran in its own Bash call and shell state does not survive across invocations, so a literal `"$new_id"` here
sends an empty identifier; substitute the resolved identifier.

For each **distinct target file** in the batch (cap at ~5 searches on a large batch — the first five distinct targets
in body order), search on a distinctive token: a distinctive basename (`issue-spec.md`, `next-candidates.sh`) directly;
a generic basename every skill or project shares (`SKILL.md`, `CLAUDE.md`, `README.md`) needs a substitute — the skill's
directory name (`spec` for `skills/spec/SKILL.md`), the full repo-relative path for a nested `README.md`
(`skills/README.md`), or the project name for a project `CLAUDE.md` or a repo-root `README.md`. One token per call,
never a composed phrase — `search issues` matches a contiguous token, and the JSON payload
(`linear-cli search issues "<token>" -o json`) carries only `{id, identifier, priority, state, title}`, no description,
while matches are frequently on body text. So split hits by `state`. For each OPEN hit, `linear-cli issues get <ID>
-o json` to read its body and judge overlap against the **full repo-relative path** of the target, never the basename
alone. A TERMINAL hit (Done/Canceled) is prior art, not noise: when its title names the same file or mechanism, fetch
it and cite it in the filed body — `Prior art: <ID> (Done) — <what its fix covered>; filing anyway because <what still
fails>` — because an unattributed re-file of shipped work hides the one question that matters: did the old fix regress,
or never cover this path? Cap total `issues get` fetches at ~10 per batch; best-effort. Per OPEN hit that overlaps:

- the hit is a prerequisite of this filing or both edit the same region of a method body (not merely the same file, nor
  disjoint branches of one long method), the hit is itself `specified`, and this filing is a non-keeper (`specified`)
  filing → `linear-cli relations add <existing-open-ID> <new-ID> -r blocks` (existing blocks new — the
  no-discernible-order default — because `next-candidates.sh` hides blocked issues, which is what prevents concurrent
  pickup);
- same file or same method in different regions, or a prerequisite/same-method hit that is uncertified, `needs
  decision`, or `solo` (a blocker that will never ship unattended), or this filing is a `--keeper` batch → `-r related`
  plus a comment naming the file — a `related` partner in flight soft-de-ranks this issue, while `blocks` behind a
  blocker that never ships unattended would strand it invisibly;
- shares only a mechanism → `-r related` plus a comment naming the mechanism;
- no overlap → nothing.

Runs on the `--keeper` path too, and on `rc=2` (a human fixing the label later must not inherit a certified-but-unwired
issue). Skipped only on `rc=1`. **On the `--keeper` path the same-file edge is always `related`, never `blocks`**: a
keeper batch certifies nothing, so neither side is fleet-pickable and there is nothing to serialize —
`next-candidates.sh` drops blocked issues *before* its keeper boost, so a `blocks` edge would hide the batch from the
keeper's own `/next`. Best-effort: a failed search, fetch, or `relations add` never blocks the reflection — note the
miss in the `Filed:` line (`<new-ID> (collision edge to <ID> not wired — add manually)`).
