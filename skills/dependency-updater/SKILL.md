---
name: "dependency-updater"
description: "Runs dependency updates end to end: parallel per-package research scaled to semver, applies the whole set at once, then fixes what the quality gate actually reports. Files a Linear issue to track the run, then asks up front whether to work in an isolated worktree and whether to finish by merge or PR, shipping through /finish and removing its own worktree when done. Invoked when users request package updates, dependency updates, version bumps, or mention 'ncu' or npm-check-updates."
version: "1.2.0"
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

Execute dependency updates safely and quickly. Delegate the two things that genuinely need it — **parallel
per-package research**, and **substantive migration work** behind a breaking change — and run the rest yourself.

**Do not delegate the mechanical steps.** `ncu -u`, `pnpm install`, and the quality gate are single commands;
handing them to a `developer` agent costs a context spin-up and a report round-trip to run something the
orchestrator can run directly (`~/.claude/CLAUDE.md` § Delegation: do not delegate what finishes in a handful
of tool calls). Spend the agents on research breadth and on real migration work, nowhere else.

## Autonomy

**Phase 0's two questions are the only interaction. After that the run is unattended** — no plan to approve,
no per-package confirmation, no ship prompt. Every delegated skill is invoked with its `auto` token so its
own prompt sites resolve to documented defaults rather than asking.

The run stops early for exactly three reasons, and each stops with a report rather than a question: nothing to
update (Phase 1 found no upgrades), the gate still red after two fix rounds (Phase 4), or a non-passing
`/quality-review` verdict (Phase 5). Those are outcomes to surface, not decisions to delegate back — the
worktree and branch hold the work either way.

## Execution Protocol

### 1. Initialize with TodoWrite

- Break dependency update workflow into discrete, testable phases
- Create todos for setup, detection, research, apply, gate-and-fix, ship, and cleanup
- Before dispatching a parallel batch, enumerate each agent's write targets — see [Agent Coordination Standards](~/.claude/standards/agent-coordination.md) § Write-target exclusivity

### 2. Delegate Selectively

Two agents earn their cost on most runs; the other two are exceptions, dispatched only on a specific trigger:

- `general-purpose` — **routine.** One per package needing research, all in a single parallel batch (preferred over `research-lead`, which fans out its own subagents — overkill per package)
- `developer` — **routine when the gate is red.** Implements a real migration behind a breaking change, carrying that package's research
- `technical-writer` — **once, at ship time.** Composes the update summary reused by the completion comment and the PR
- `architect` — **exception only.** A MAJOR bump removed something with no drop-in replacement and the call is a design decision, not a substitution. Never as a routine pre-flight: predicting breakage costs a full agent to produce a guess the gate replaces with facts one command later
- `quality-reviewer` — **exception only.** An advisory or research finding names a concrete risk in code this repo actually calls. Not a standing pass over a lockfile diff

**Delegation Format:**

```md
Task for [agent]: [Specific update task]
Context: [Package update details and research findings]
Requirements:

- [Compatibility requirement]
- [Breaking change handling]

Acceptance: [Quality gates to verify success]
```

### 3. Dependency Update Workflow

#### Phase 0: Workspace and finish mode — ASK FIRST, before any other work

**Every run gets a Linear issue.** A dependency update is shippable work that lands on a branch and gets
reviewed, so it is tracked like any other — and the issue is what makes `/finish` usable for the commit,
push, PR, and state transitions instead of a hand-rolled git/gh path.

1. **Resolve the team once per repo, then remember it.** Read `git config --get dependencyUpdater.team`
   first. On a miss, derive it from an issue ID in context or from the branch via
   `~/.claude/scripts/detect-issue-id.sh`; failing that, `linear-cli teams list -o json` — one team means
   use it, several means ask. Never guess. Persist whatever you resolved with
   `git config dependencyUpdater.team <KEY>` so no later run repeats the question. This is local git
   config: per-repo, machine-scoped, never committed — the same mechanism `reflect.keeper` and
   `start.wt-source-branch` use.
2. **Pass `-` for the state and let the helper resolve it. Never hardcode a state name.** Names differ per
   team — these projects use `Planned` where Linear's default template says `Todo` — and a hardcoded name
   fails the create outright (`State 'Todo' not found for team`), then costs a round of flailing at the
   CLI. `linear-create-child.sh` already does this lookup for you on `-`: it reads
   `linear-cli statuses list -t <TEAM> -o json` and picks the team's Backlog, falling back to
   Planned/Todo. That is also why `-` is not "team default" — an omitted `--state` lands on Triage, which
   is why the `linear-create-state-guard.sh` hook refuses a raw `linear-cli issues create` without one.

   ```bash
   ~/.claude/scripts/linear-create-child.sh - <team> - "Dependency updates — <YYYY-MM-DD>" <body-file>
   ```

   Parent `-` because a dependency update is standalone, not a child. The body carries the detected
   package set once Phase 1 has run, or a one-line placeholder when filing first.
The issue lands in Backlog, unassigned. **Claiming it — assignee AND state together — happens below, and
differs by mode.** Do not reach for `linear-set-state.sh` here: it sets state only, so using it to "claim"
leaves the issue In Progress and unassigned, which reads to the team as unowned work already underway.

Then two questions, asked **before** Phase 1 detection runs, together in one `AskUserQuestion` call.
They are asked every run and never inferred. Flags skip the prompt when the caller already decided:
`--worktree` / `--in-place`, and `--merge` / `--pr`.

1. **Isolated worktree, or in place?** Offer worktree as the default: the update rewrites `package.json`,
   the lockfile, and possibly source files, and in a checkout shared by concurrent sessions that is
   exactly the blast radius `standards/git.md` warns about. It is also what makes Phase 3's
   apply-everything-then-fix approach cheap to abandon.
2. **Finish as `merge` or `pr`?** `merge` lands the branch on its source branch and removes the
   worktree; `pr` opens a pull request for human review and leaves the branch pushed.

**`merge` requires worktree mode** — `finish-detect-mode.sh` exits 2 for `merge` outside a `/start wt`
worktree. If the user picks in-place, offer only `pr`. Do not silently downgrade a `merge` request.

**Worktree mode**: call `/start`'s own setup script, not `/start`.

1. `~/.claude/scripts/start-wt-setup.sh <ISSUE-ID>` — the same script `/start` Step 0 runs. It does the
   worktree create/attach under the repo lock, the tamper-evident identity stamp, the session-start dirty
   baseline, and the digest pre-fetch, and emits `KEY=value` lines (`WT_DIR`, `BRANCH`, `ISSUE_STATE`,
   `ASSIGNEE`, …) on stdout. Read those and carry them forward. Never hand-roll `git worktree add`: it
   skips the stamp and the lock, which is the corruption the locked create exists to prevent.
2. `EnterWorktree(path=<WT_DIR>)` so this session's edits land in the worktree.
3. `~/.claude/scripts/start-wt-verify.sh <WT_ABS> <ISSUE-ID> --claim` — the same script `/start` Step 0
   sub-step 3 runs, and **the step that actually claims the issue**: cwd confirm → baseline verify →
   claim (assignee *and* In Progress in one `linear-cli issues update`) → source-branch probe → baseline
   `pnpm check`. `--claim` is required and has no default.

   Branch on the first line of stdout: `VERIFIED` continues; any `FAILED-*` stops the run and is
   reported verbatim. `FAILED-CHECK` matters most here — it means the tree was **already red before any
   dependency changed**, so every later failure would be unattributable. Stop and say so rather than
   bumping on top of a broken baseline.

**Do not invoke `Skill(skill: "start", args: "... interactive")` for this.** That token's halt is a genuine
terminal state: it emits `INTERACTIVE-READY` as the session's single lifecycle tag and opens the worktree in
a new VS Code window for a human to drive. Both are wrong mid-run — this skill continues working and its
terminal tag comes from `/finish` at the end. The setup script gives the identical worktree without the
handoff.

**In-place mode**: there is no verify script on this path, so claim the issue yourself with the same single
command `/start` Step 3 uses — assignee and state in one call, never one without the other:

```bash
linear-cli issues update <ISSUE-ID> --assignee me --state "In Progress"
```

Then work the current branch. Finish is `pr` only.

**`--dry-run` files nothing and creates nothing.** Ask neither question and skip this phase entirely —
a preview that leaves a Linear issue and a worktree behind has already failed to be a preview. Detection
and research still run, and the report names what a real run would have created.

#### Phase 1: Update Analysis

1. Run `pnpm dlx npm-check-updates --jsonUpgraded` to detect available updates — **in a pnpm workspace / monorepo add `--deep`** so detection covers every package, not just the root (no global install required; `npx npm-check-updates` is an equivalent fallback). Carry the same scope flags (`--deep`, and any `--filter`) into the Phase 3 application, so the researched/classified set matches the applied set
2. Parse the output to identify packages with version changes
3. **If the result is empty, stop here** — there are no updates. Report "already up to date" and skip the remaining phases; do not open an empty PR
4. If the user passed `--filter <pattern>`, apply it as a flag on this detection command (and carry the same flag into Phase 3, per above) — a single consistent narrowing, not a separate post-parse pass

#### Phase 1.5: Semver Classification

**CRITICAL**: Properly classify ALL version changes according to [Semantic Versioning Standards](~/.claude/standards/semver.md) before proceeding. Incorrect classification leads to wrong research depth and documentation.

**Reference**: Follow the comprehensive semver classification rules in `~/.claude/standards/semver.md` which includes:

- Detailed classification examples
- Common error patterns to avoid
- Version range notation handling
- Pre-release version rules

**Quick Classification:**

- **MAJOR** (X.y.z → X+1.y.z): Breaking changes, incompatible API changes
- **MINOR** (x.Y.z → x.Y+1.z): New functionality, backward compatible
- **PATCH** (x.y.Z → x.y.Z+1): Bug fixes, backward compatible

**Process:**

1. Apply semver standards for parsing and classification
2. Group packages by classification: MAJOR, MINOR, PATCH
3. Verify classification matches semver standards before delegating

#### Phase 2: Parallel Research (Independent Tasks)

**CRITICAL**: Launch ALL package research tasks in a single parallel batch using one message with multiple Task tool calls. Target 10-20 parallel `general-purpose` research agents for maximum efficiency.

Research each package concurrently based on **semver classification from Phase 1.5**:

- **MAJOR changes** (X.y.z → X+1.y.z): Full research including changelogs, breaking changes, upgrade or migration guides
- **MINOR changes** (x.Y.z → x.Y+1.z): Minimal research — check for new features and deprecated APIs only. **If release notes aren't found, proceed but flag the package in the PR as "updated without release notes"** so the human reviewer knows it was not verified against a changelog
- **PATCH changes** (x.y.Z → x.y.Z+1): Skip research — assume safe bug fixes. **Proceed even without release information, but treat the Phase 4 quality gate (which must pass) as the safety net** — not the patch label alone, since semver mis-tagging of breaking changes as patches is common
- Document any security advisories regardless of change type

**Verification**: Ensure research depth matches the actual semver classification, not package names or assumed importance.

**Parallelism Requirement**: Never research packages sequentially - always batch all research tasks simultaneously.

#### Phase 3: Apply Everything At Once

**`--dry-run` gate**: If the skill was invoked with `--dry-run`, STOP before this phase. Detection (Phase 1) and research still run; do **not** run any step below, install dependencies, commit, or push. `--dry-run` previews the planned updates and research findings only.

**Apply the whole set in one shot, then find out what broke.** Do not stage packages one at a time and do not
predict the blast radius first — the quality gate reports actual failures in one run, with file and symbol,
which is strictly better evidence than a pre-flight analysis of what *might* break. This mirrors how the
update is done by hand, and it is safe because the work is committed nowhere yet: `git diff` shows everything,
and in worktree mode the whole tree is disposable.

1. `pnpm dlx npm-check-updates -u`, carrying the **same scope flags as Phase 1 detection** — `--deep` in a workspace (a plain root run does not traverse packages) **and any `--filter`** — so the applied set matches the researched/classified set rather than upgrading every outdated package
2. `pnpm install`
3. Go straight to the Phase 4 gate. Migration work is driven by what it reports, not by a pre-flight prediction

**If `pnpm install` itself fails** (a peer-dependency conflict, an incompatible bumped range), that is the one
failure the gate cannot diagnose because the tree never resolved. Restore the manifests and re-apply in two
halves to isolate the offender — a single bisect step usually names it. Restore by file copy from the `tmp/`
pre-flight copies (root `package.json`, `pnpm-lock.yaml`, each workspace `package.json`, taken before step 1):
never `git checkout`/`git restore` (see standards/git.md, "Working Tree Protection" — the hook blocks them, and
run from a script they destroy uncommitted work unguarded), and never `git stash` (the stash stack is shared
across every worktree — same standard, "Safe Commands").

#### Phase 4: Quality Validation

Run the project's quality gate. Discover the actual script names and what each covers per [Project Commands](~/.claude/standards/project-commands.md) — script composition varies by project, so do not assume invented script names:

1. `pnpm check` — the user's canonical gate (type-check + lint/format, and in some projects the test suite too). Use this, **not** `pnpm typecheck` or `pnpm lint:fix`, which are not standard scripts here
2. `pnpm test` — run the test suite **only if `pnpm check` does not already include it**; some projects bundle tests into `check`, and running both executes the suite twice (a flaky test could then disagree between runs)

Let `pnpm check` manage its own internal ordering and parallelism — do not assume a fixed sequence of its sub-steps.

**The gate's output is the work list.** Fix what it actually reports, in a loop until it is green:

- **Mechanical breakage** — a renamed export, a moved import path, a changed option key. Fix it directly; it is
  a handful of edits and the compiler names every site.
- **A real migration** behind a MAJOR bump — an API whose shape changed, a pattern the package no longer
  supports. Delegate to `developer`, carrying the Phase 2 research for that package (the migration guide is
  usually already in hand). Batch independent packages into one parallel dispatch.
- **A design question** — the new version removed something with no drop-in replacement, so the call is
  architectural rather than a substitution. Only here is `architect` worth its cost, and only for that package.

No routine security or performance review pass: `pnpm audit` plus the advisories Phase 2 already collected
cover the security surface, and a reviewer reading a lockfile diff for performance findings reliably returns
nothing actionable. Escalate to `quality-reviewer` only when an advisory or a research finding names a concrete
risk in code this repo actually calls.

**If the gate stays red after two fix rounds**, stop and surface. The worktree and the branch hold everything;
the honest report is "these N packages updated cleanly, this one needs a decision" — not a third speculative
round. `--filter`-ing the stuck package out and shipping the rest is usually the better next move.

#### Phase 5: Ship (Sequential)

**Technical-writer** composes the update summary once, and it is reused in both routes:

- Package updates grouped by semver classification in markdown tables
- Table columns: Package, Current, Target, and relevant details (Breaking Changes/New Features/Fixes)
- Breaking change impact analysis for major version updates
- Migration steps performed for major version changes
- Quality validation results
- Any packages updated without release notes (flagged in Phase 2)
- Links to changelogs and release notes

**Run `/quality-review` first — `/finish auto` refuses to ship without its verdict.** In autonomous mode a
missing review artifact (`none-found`) aborts with `BLOCKED-ON-REVIEW`, on the rule that unattended runs never
ship unreviewed code. So `Skill(skill: "quality-review", args: "<ISSUE-ID> auto")` before the handoff. On a
manifest-and-lockfile-only diff it converges almost immediately — there is nothing for an adversarial reviewer
to find — so this is cheap in exactly the case it looks redundant, and it is load-bearing in the case that
matters, where a MAJOR migration rewrote source. A non-passing verdict stops the run: report it and leave the
worktree, exactly as the Error Handling abandonment rule prescribes.

**Then hand off to `/finish`**, which owns commit, push, PR creation, and the Linear transitions. Do not
hand-roll `git commit` / `gh pr create`; that path skips the merge serialization and the identity
verification `/finish` performs. **Always pass the `auto` token** — it resolves every prompt site in that
skill to its conservative default (abort rather than override) instead of asking, which is what keeps this
run unattended:

- `Skill(skill: "finish", args: "merge auto")` — merges the branch into its recorded source branch and
  removes the worktree.
- `Skill(skill: "finish", args: "pr auto")` — opens a PR based on the recorded source branch. The issue
  stays In Progress (the PR is open, not shipped) and the worktree is left in place by design, so
  Phase 6 removes it.
- **In-place mode**: `Skill(skill: "finish", args: "pr auto")`. Outside a worktree `/finish pr` targets the
  repo's GitHub default branch and touches no worktree, so the only difference is the PR base and that
  Phase 6 has nothing to clean up.

Pass the summary above as the completion comment body; `/pr-update` owns the PR title and description.

**REQUIRED (both routes)**: provide the PR link, or the merge result, in the final output.

#### Phase 6: Clean up the worktree

Worktree mode only; skip entirely in-place.

- **After `/finish merge`** there is nothing to do — `finish-merge.sh` removes the worktree itself.
  Confirm it did: on failure it prints `Merged successfully, but git worktree remove failed` plus the
  manual command. Surface that rather than assuming the removal happened.
- **After `/finish pr`** the worktree is still on disk and is this skill's to remove, because it is the
  one worktree `reap-worktrees.sh` will sit on: the issue stays In Progress and the branch is unmerged,
  which is precisely the ABANDONED-for-resumption shape reap preserves rather than reclaims.

  1. Delete only the scratch files this run created — the Phase 3 rollback copies under `tmp/`.
     **Untracked files make `git worktree remove` refuse**, and `--force` is blocked by the
     git-permissions hook, so clearing them is the only route. Never `rm -rf tmp/` — it also holds
     harness-owned session state and cross-skill handoff artifacts.
  2. `cd` to the repo root first — a worktree cannot be removed while it is the working directory.
  3. `git worktree remove <wt-dir>`.

  Removing it loses nothing: the branch is pushed and the PR is open, so follow-up review fixes are
  done in a fresh checkout or worktree. If the removal still refuses, the tree has changes this skill
  did not make — **stop and surface**, never force.

## Usage Options

- No arguments: Phase 0 asks where to work and how to finish, then runs the full workflow
- `--worktree` / `--in-place`: answer Phase 0's first question up front and skip that prompt
- `--merge` / `--pr`: answer Phase 0's second question up front and skip that prompt. `--merge` implies `--worktree`; `--merge --in-place` is a usage error, not a silent downgrade to `pr`
- `--dry-run`: Preview the planned updates and research findings **without** filing an issue, creating a worktree, applying updates, installing dependencies, committing, or pushing — detection and research still run (Phase 0 is skipped; application is enforced at the Phase 3 gate)
- `--filter <pattern>`: Only update packages matching the pattern (passed through to `npm-check-updates --filter`)

## Error Handling

When encountering errors:

1. **Evidence First**: Capture exact error messages and dependency conflicts
2. **Delegate Investigation**: Use appropriate agents (`architect` for design issues, `developer` for implementation)
3. **Quality Gates**: All tests must pass before PR creation
4. **Rollback Plan**: On a mid-update failure, restore the tree from the copies Phase 3's rollback pre-flight took (never `git checkout`/`git restore`/`git stash` — see standards/git.md, "Working Tree Protection" and "Safe Commands") and delete any branch/PR created prematurely — never leave a half-applied manifest or lockfile
5. **Abandoning a worktree run**: if the run stops before Phase 5, the worktree and its Linear issue both still exist. **Leave the worktree in place** — it holds the only copy of any uncommitted work, and `reap-worktrees.sh` preserves exactly this shape for resumption. Say where it is (`.claude/worktrees/<id-lower>`) and what state the issue is in, so the run can be resumed or the issue Canceled deliberately. Phase 6's removal is for a *completed* run only; a failed run that silently deleted its own worktree would destroy the evidence needed to diagnose it

## Quality Standards

Each phase must meet:

- ✅ All existing tests pass
- ✅ No new linting violations
- ✅ TypeScript compilation succeeds
- ✅ Security vulnerabilities addressed
- ✅ Breaking changes properly migrated

## Success Criteria

Dependency update succeeds when:

- [ ] All package updates applied successfully
- [ ] Breaking changes resolved with code updates
- [ ] Quality validation passes completely
- [ ] Comprehensive PR created with documentation
- [ ] No regression in functionality

## Key Principles

1. **Measure, Don't Predict**: apply the whole set, then let the gate name what broke. A pre-flight analysis of what *might* break costs an agent and is superseded by facts one command later
2. **Delegate Breadth, Not Errands**: agents for parallel research and real migration work; the orchestrator runs the single commands itself
3. **Research Depth Follows Semver**: MAJOR gets the full changelog and migration guide; MINOR a skim; PATCH none — the gate is the safety net for mis-tagged patches
4. **Quality First**: the gate must be green before shipping, and two red rounds is the limit before surfacing
5. **Comprehensive Documentation**: Ensure PR provides complete context

## Important Notes

- Invoke npm-check-updates via `pnpm dlx npm-check-updates` (no global install required); `npx npm-check-updates` is an equivalent fallback, and a globally-installed `ncu` binary works if present
- Keep the scope flags (`--deep`, `--filter`) consistent between detection (`--jsonUpgraded`) and application (`-u`) so the applied set matches what was detected, researched, and classified — only the primary flag differs between the two

Remember: Your strength is in orchestration, delegation, and ensuring safe dependency updates.
