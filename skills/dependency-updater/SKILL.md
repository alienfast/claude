---
name: "dependency-updater"
description: "Run a dependency update end to end — per-package research scaled to semver, apply the whole set at once, fix what the quality gate reports, ship through /finish on a Linear issue labelled `dependencies`, after re-measuring earlier runs' holds and pins. Flags: `--worktree`/`--in-place`, `--merge`/`--pr`, `--dry-run`, `--filter`. Use when the user asks for package or dependency updates, version bumps, or mentions ncu."
version: "1.3.0"
allowed-tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash(pnpm:*)
  - Bash(npx:*)
  - Bash(gh:*)
  - Bash(git:*)
  - Bash(linear-cli:*)
  - Task
  - Skill
  - AskUserQuestion
  - EnterWorktree
  - WebSearch
  - WebFetch
---

# Dependency Updater

Applies package updates as one batch, then converges on a green quality gate.

## Core Mission

Execute dependency updates safely and quickly. Delegate the two things that genuinely need it — **parallel per-package
research**, and **substantive migration work** behind a breaking change — and run the rest yourself.

**Do not delegate the mechanical steps.** `ncu -u`, `pnpm install`, and the quality gate are single commands; handing
them to a `developer` agent costs a context spin-up and a report round-trip (`~/.claude/CLAUDE.md` § Delegation). Spend
the agents on research breadth and on real migration work, nowhere else.

## Autonomy

**Phase 0's two questions are the only interaction. After that the run is unattended** — no plan to approve, no
per-package confirmation, no ship prompt. Every delegated skill is invoked with its `auto` token
(`skills/full/SKILL.md` § Auto mode) so its own prompt sites resolve to documented defaults.

The run stops early for exactly three reasons, each with a report rather than a question: nothing to update (Phase 1),
the gate still red after two fix rounds (Phase 4), or a non-passing `/quality-review` verdict (Phase 5). The worktree
and branch hold the work either way.

## Execution Protocol

### 1. Initialize the run

Track the phases as you go (setup, recall, detection, research, apply, gate-and-fix, ship, cleanup) so a long run
reports where it is and nothing is skipped. Before dispatching a
parallel batch, enumerate each agent's write targets — [standards/agent-coordination.md](../../standards/agent-coordination.md)
§ Write-target exclusivity.

### 2. Delegate Selectively

Two agents earn their cost on most runs; the others are exceptions, dispatched only on a specific trigger:

- `general-purpose` — **routine.** One per package needing research, all in a single parallel batch (not
  `research-lead`, which fans out its own subagents — overkill per package).
- `developer` — **routine when the gate is red.** A real migration behind a breaking change, carrying that package's
  research.
- `technical-writer` — **once, at ship time.** The update summary reused by the completion comment and the PR.
- `architect` — **exception only.** A MAJOR bump removed something with no drop-in replacement and the call is a design
  decision. Never as a routine pre-flight: predicting breakage buys a guess the gate replaces with facts one command
  later.
- `quality-reviewer` — **exception only.** An advisory or research finding names a concrete risk in code this repo
  actually calls. Not a standing pass over a lockfile diff.

Each delegation names the task, the package details and research findings, the compatibility and breaking-change
requirements, and the quality gates that mean success.

### 3. Dependency Update Workflow

#### Phase 0: Workspace and finish mode — ASK FIRST, before any other work

**Every run gets a Linear issue.** A dependency update is shippable work that lands on a branch and gets reviewed, so it
is tracked like any other — and the issue is what makes `/finish` usable for the commit, push, PR, and state transitions.

1. **Resolve the team once per repo, then remember it.** Read `git config --get dependencyUpdater.team` first. On a
   miss, derive it from an issue ID in context or from the branch via `~/.claude/scripts/detect-issue-id.sh`; failing
   that, `linear-cli teams list -o json` — one team means use it, several means ask. Never guess. Persist with
   `git config dependencyUpdater.team <KEY>` (local git config: per-repo, machine-scoped, never committed — the same
   mechanism `reflect.keeper` uses).
2. **Pass `-` for the state and let the helper resolve it. Never hardcode a state name** — names differ per team, and a
   wrong one fails the create. On `-`, `linear-create-child.sh` reads the team's statuses and picks Backlog, falling
   back to Planned/Todo. An omitted `--state` lands on Triage, which is why the `linear-create-state-guard.sh` hook
   refuses a raw `linear-cli issues create` without one.

   ```bash
   ~/.claude/scripts/linear-create-child.sh - <team> - "Dependency updates — <YYYY-MM-DD>" <body-file> dependencies
   ```

   Parent `-` because a dependency update is standalone. The sixth positional is the label: `dependencies` goes on every
   issue this skill files — the tracking issue included, so an abandoned run surfaces in the next run's recall — and it
   is a **workspace-level issue label** (`linear-cli labels create dependencies -t issue`, once per workspace). Exit 2
   means filed-but-unlabelled: attach with `~/.claude/scripts/linear-add-label.sh <ID> dependencies`, never
   `issues update -l`, which replaces the whole label set. The body carries the detected package set once Phase 1 has
   run, or a one-line placeholder when filing first.

The issue lands in Backlog, unassigned. **Claiming it — assignee AND state together — happens below, and differs by
mode.** Do not use `linear-set-state.sh` to claim: it sets state only, leaving the issue In Progress and unassigned.

Then two questions, asked **before** Phase 1 detection, together in one `AskUserQuestion` call. Asked every run, never
inferred; flags skip the prompt when the caller already decided (`--worktree` / `--in-place`, `--merge` / `--pr`):

1. **Isolated worktree, or in place?** Offer worktree as the default: the update rewrites `package.json`, the lockfile,
   and possibly source files, and in a checkout shared by concurrent sessions that is exactly the blast radius
   `standards/git.md` warns about. It also makes Phase 3's apply-everything-then-fix approach cheap to abandon.
2. **Finish as `merge` or `pr`?** `merge` lands the branch on its source branch and removes the worktree; `pr` opens a
   pull request for human review and leaves the branch pushed.

**`merge` requires worktree mode** — `finish-detect-mode.sh` exits 2 for `merge` outside a `/start wt` worktree. If the
user picks in-place, offer only `pr`. Never silently downgrade a `merge` request.

Then set up the workspace per [references/workspace.md](references/workspace.md): worktree mode runs `/start`'s own
`start-wt-setup.sh` → `EnterWorktree` → `start-wt-verify.sh --claim` (never `Skill(start … interactive)`, never a
hand-rolled `git worktree add`; a `FAILED-CHECK` baseline stops the run); in-place mode claims the issue with one
`issues update --assignee me --state "In Progress"` and finishes `pr` only.

**`--dry-run` files nothing and creates nothing.** Ask neither question and skip the rest of this phase — keep step 1's
team resolution, which recall needs. Detection, research and recall still run (recall is read-only), and the report
names what a real run would have created and which prior deferrals it would have lifted.

#### Phase 0.5: Recall prior deferrals — before detecting anything

Read [references/deferrals.md](references/deferrals.md) § Phase 0.5 and run it: list the open `dependencies` issues
(terminal states dropped by name), stop on an abandoned run's open tracking issue, re-measure every lift condition by
executing its recorded `Check`, and classify each as **cleared** (joins the apply set; closed in Phase 5 after the gate),
**still blocked** (hold re-applied in Phase 3, no re-research, one dated comment), or **needs work** (left for its own
pickup). A `--filter` narrows what may lift, not what is recalled.

#### Phase 1: Update Analysis

1. Run `pnpm dlx npm-check-updates --jsonUpgraded` (no global install required; `npx npm-check-updates` is an equivalent
   fallback). **Check for a repo ncu config first** — `.ncurc.*`, or an `ncu` key in `package.json`. One that sets
   `workspaces: true` (with `root: true`) already traverses every workspace package, and it usually pins `packageFile`
   too, which makes `--deep` a hard error (`Cannot specify both --packageFile and --deep`, exit 1). Only a repo with
   **no** config needs `--deep`, and a config's `reject` list is a deliberate hold with its reason written beside it, not
   something to route around. Whatever scope the detection ran with — the config alone, or `--deep`, plus any
   `--filter` — is carried unchanged into Phase 3, so the researched/classified set matches the applied set.
2. Parse the output to identify packages with version changes.
3. **If the result is empty, stop here** — report "already up to date" and skip the remaining phases; never open an
   empty PR.
4. `--filter <pattern>` is applied as a flag on this detection command (and carried into Phase 3) — one consistent
   narrowing, not a post-parse pass.
5. **Cross-reference against Phase 0.5.** A bump a *still blocked* deferral covers is applied at the held range in
   Phase 3 and not researched in Phase 2; one whose lift condition *cleared* is applied at ncu's target and its issue
   goes on the Phase 5 closing list. A package with no deferral is new work and gets the full Phase 1.5 → 2 treatment.

#### Phase 1.5: Semver Classification

Classify ALL version changes per [standards/semver.md](../../standards/semver.md) before proceeding — the classification
sets research depth (that standard's § Research depth is set by the classification), and misclassification means wrong
depth and wrong documentation. MAJOR (X.y.z → X+1.y.z) breaking; MINOR (x.Y.z → x.Y+1.z) new functionality,
backward-compatible; PATCH (x.y.Z → x.y.Z+1) fixes. Group packages by classification and verify it against the
standard before delegating.

#### Phase 2: Parallel Research (Independent Tasks)

Launch ALL package research in a single parallel batch — one message with multiple Task calls, 10–20 `general-purpose`
agents. Never research packages sequentially. Depth follows the Phase 1.5 classification:

- **MAJOR** — full research: changelogs, breaking changes, upgrade or migration guides.
- **MINOR** — minimal: new features and deprecated APIs only. If release notes aren't found, proceed but flag the package
  in the PR as "updated without release notes" so the reviewer knows it was not verified against a changelog.
- **PATCH** — skip research; assume safe bug fixes. Proceed even without release information — the Phase 4 gate is the
  safety net, not the patch label, since mis-tagged breaking changes are common.
- Document any security advisories regardless of change type.

**A package covered by a still-open `dependencies` issue is not researched again** — the issue is the research and Phase
0.5 re-measured it. The one exception is the advisory sweep, which always covers the whole set
(`references/deferrals.md`).

#### Phase 3: Apply Everything At Once

**`--dry-run` gate**: STOP before this phase. Nothing below runs — no install, commit, or push.

**Apply the whole set in one shot, then find out what broke.** Do not stage packages one at a time and do not predict
the blast radius first — the gate reports actual failures in one run, with file and symbol, which is strictly better
evidence than a pre-flight analysis. Safe because nothing is committed yet: `git diff` shows everything, and in worktree
mode the whole tree is disposable.

1. `pnpm dlx npm-check-updates -u`, with the **same scope as Phase 1 detection** (config alone, or `--deep`, **and any
   `--filter`**). Then re-apply every hold Phase 0.5 confirmed *still blocked*: edit those ranges back to the held
   version in **every** manifest that declares them, before step 2, so the lockfile resolves once and never records
   the rejected version. Packages whose peers pin each other exactly (`@vitest/browser` ↔ `vitest`) move as one set.
2. `pnpm install`, then **confirm the lockfile actually reconciled**: `git diff --stat pnpm-lock.yaml` is non-empty and
   no importer `specifier:` still shows a range step 1 edited away. pnpm's fast-path cache
   (`node_modules/.pnpm-workspace-state-v1.json`) can answer `Already up to date` and leave every specifier at its
   pre-edit range — delete that one file and re-run `pnpm install`. Do **not** delete `node_modules/.modules.yaml` to
   force it: that triggers the purge prompt an agent shell cannot answer
   (`ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`). A lockfile that disagrees with its manifests reads fine locally and
   fails every `--frozen-lockfile` install downstream.
3. Go straight to the Phase 4 gate. Migration work is driven by what it reports.

**If `pnpm install` itself fails** (a peer conflict, an incompatible bumped range), the tree never resolved, so the gate
cannot diagnose it. Restore the manifests and re-apply in two halves to isolate the offender. Restore by file copy from
the `tmp/` pre-flight copies (root `package.json`, `pnpm-lock.yaml`, each workspace `package.json`, taken before step 1):
never `git checkout`/`git restore` (hook-blocked; from a script they destroy uncommitted work unguarded) and never
`git stash` (the stash stack is shared across every worktree) — `standards/git.md` § Working Tree Protection and § Safe
Commands.

#### Phase 4: Quality Validation

Run the project's quality gate, discovering the actual script names per [standards/project-commands.md](../../standards/project-commands.md):

1. `pnpm check` — the canonical gate (type-check + lint/format, and in some projects the test suite). Not
   `pnpm typecheck` or `pnpm lint:fix`.
2. `pnpm test` — **only if `pnpm check` does not already include it**; running both executes the suite twice, and a flaky
   test could disagree between runs.

Let `pnpm check` manage its own ordering and parallelism.

**The gate's output is the work list.** Fix what it reports, in a loop until green:

- **Mechanical breakage** — a renamed export, a moved import path, a changed option key. Fix directly; the compiler
  names every site.
- **A duplicate-resolution or graph-unity gate** reddening right after the bump — run `pnpm dedupe` before
  investigating. A workspace package that peers the bumped package at `*` keeps its old resolution while the others
  move, leaving two physical copies; only a fork that survives dedupe is worth reading the lockfile for.
- **A real migration** behind a MAJOR bump — delegate to `developer`, carrying the Phase 2 research for that package.
  Batch independent packages into one parallel dispatch.
- **A design question** — the new version removed something with no drop-in replacement. Only here is `architect` worth
  its cost, and only for that package.

No routine security or performance review pass: `pnpm audit` plus Phase 2's advisories cover the security surface, and
a reviewer reading a lockfile diff for performance reliably returns nothing actionable. Escalate to `quality-reviewer`
only when an advisory or research finding names a concrete risk in code this repo actually calls.

**If the gate stays red after two fix rounds**, stop and surface. The worktree and branch hold everything; the honest
report is "these N packages updated cleanly, this one needs a decision". `--filter`-ing the stuck package out and
shipping the rest is usually the better next move — and the stuck package becomes a `dependencies` deferral in Phase 5,
with the gate's own error as the evidence in its lift condition.

#### Phase 5: Ship (Sequential)

**File deferrals first** — every hold, pin, bypass, cooldown-held advisory fix, and surfaced cleanup this run did not take
— per [references/deferrals.md](references/deferrals.md) § Phase 5, so the summary can cite them by id. Each is a
`dependencies` issue whose body carries a `## Lift condition` with an executable `Check`.

**Technical-writer** composes the update summary once, reused in both routes: package updates grouped by semver
classification in markdown tables (Package, Current, Target, relevant details); breaking-change impact analysis and the
migration steps performed for MAJOR bumps; quality validation results; packages updated without release notes (Phase 2's
flag); links to changelogs and release notes; deferrals filed this run, prior deferrals lifted, and prior deferrals
re-verified as still blocked — each by issue id.

**Run `/quality-review` first — `/finish auto` refuses to ship without its verdict** (a missing review artifact aborts
with `BLOCKED-ON-REVIEW`; unattended runs never ship unreviewed code). So `Skill(skill: "quality-review", args:
"<ISSUE-ID> auto")` before the handoff. On a manifest-and-lockfile-only diff it converges almost immediately; it is
load-bearing where a MAJOR migration rewrote source. A non-passing verdict stops the run: report it and leave the
worktree (`references/workspace.md` § Abandoning a worktree run).

**Then hand off to `/finish`**, which owns commit, PR creation (with the push a PR needs), and the Linear transitions.
Never hand-roll `git commit` / `gh pr create`; that skips the merge serialization and identity verification `/finish`
performs. Always pass the `auto` token:

- `Skill(skill: "finish", args: "merge auto")` — merges the branch into its recorded source branch and removes the
  worktree.
- `Skill(skill: "finish", args: "pr auto")` — opens a PR based on the recorded source branch. The issue stays In
  Progress (the PR is open, not shipped) and the worktree is left in place by design, so Phase 6 removes it.
- **In-place mode**: `Skill(skill: "finish", args: "pr auto")`. Outside a worktree `/finish pr` targets the repo's
  default branch and touches no worktree.

Pass the summary as the completion comment body; `/pr-update` owns the PR title and description.

**Then close what this run lifted** — `references/deferrals.md` § Phase 5 — only now, after the gate passed and the
change shipped.

**REQUIRED (both routes)**: the PR link, or the merge result, in the final output.

#### Phase 6: Clean up the worktree

Worktree mode only; skip entirely in place. After `/finish merge`, confirm `finish-merge.sh` removed the worktree (a
`CLEANUP-FAILED:` line means it could not — surface it). After `/finish pr`, remove it yourself per
[references/workspace.md](references/workspace.md) § Phase 6: delete only this run's scratch under `tmp/`, `cd` to the
repo root, `git worktree remove <wt-dir>`; a removal that still refuses means changes this skill did not make — stop and
surface, never force.

## Usage Options

- No arguments: Phase 0 asks where to work and how to finish, then runs the full workflow.
- `--worktree` / `--in-place`: answer Phase 0's first question up front.
- `--merge` / `--pr`: answer Phase 0's second question up front. `--merge` implies `--worktree`; `--merge --in-place` is a
  usage error, not a silent downgrade to `pr`.
- `--dry-run`: preview the planned updates and research findings **without** filing an issue, creating a worktree,
  applying updates, installing, committing, or pushing — detection, research, and recall still run, and the report names
  which prior deferrals would lift.
- `--filter <pattern>`: only update packages matching the pattern (passed through to `npm-check-updates --filter`).

## Error Handling

1. **Evidence first**: capture exact error messages and dependency conflicts.
2. **Delegate investigation**: `architect` for design issues, `developer` for implementation.
3. **Quality gates**: the gate must be green before any PR.
4. **Rollback**: on a mid-update failure, restore the tree from the Phase 3 pre-flight copies (never
   `git checkout`/`git restore`/`git stash`) and delete any branch/PR created prematurely — never leave a half-applied
   manifest or lockfile.
5. **Abandoning a worktree run**: leave the worktree in place and say where it is — `references/workspace.md`
   § Abandoning a worktree run.

## Success Criteria

- All package updates applied; breaking changes resolved with code updates; the gate green; no regression.
- A PR (or merge) with the complete summary.
- Every hold, pin, and bypass this run took is a `dependencies` issue with an executable lift condition.
- Every prior `dependencies` issue was re-measured: lifted and closed, re-held with a dated comment, or named as
  needs-work.
