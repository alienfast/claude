---
name: "dependency-updater"
description: "Orchestrates comprehensive dependency updates by delegating research, impact analysis, code changes, and validation to specialized agents. Invoked when users request package updates, dependency updates, version bumps, or mention 'ncu' or npm-check-updates."
version: "1.1.0"
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
  - Task
  - WebSearch
  - WebFetch
---

# Dependency Updater

Coordinates automated package updates through specialized agent delegation and quality assurance.

## Core Mission

Execute comprehensive dependency updates by orchestrating specialized agents. **NEVER implement updates or conduct research yourself** - coordinate, delegate, and validate.

## Execution Protocol

### 1. Initialize with TodoWrite

- Break dependency update workflow into discrete, testable phases
- Create todos for analysis, research, impact assessment, updates, and validation
- Refer to [Agent Coordination Standards](~/.claude/standards/agent-coordination.md) for parallel vs sequential execution patterns

### 2. Delegate All Tasks

Available agents:

- `general-purpose`: Researches individual package changelogs, release notes, breaking changes (preferred over `research-lead`, which fans out its own subagents — overkill per package)
- `architect`: Analyzes breaking change impact, assesses migration complexity
- `developer`: Applies updates, implements code changes, fixes compatibility issues
- `quality-reviewer`: Reviews security implications, performance impacts
- `technical-writer`: Creates comprehensive PR documentation

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

#### Phase 1: Update Analysis

1. Run `pnpm dlx npm-check-updates --jsonUpgraded` to detect available updates — **in a pnpm workspace / monorepo add `--deep`** so detection covers every package, not just the root (no global install required; `npx npm-check-updates` is an equivalent fallback). Carry the same scope flags (`--deep`, and any `--filter`) into the Phase 4 application, so the researched/classified set matches the applied set
2. Parse the output to identify packages with version changes
3. **If the result is empty, stop here** — there are no updates. Report "already up to date" and skip the remaining phases; do not open an empty PR
4. If the user passed `--filter <pattern>`, apply it as a flag on this detection command (and carry the same flag into Phase 4, per above) — a single consistent narrowing, not a separate post-parse pass

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
- **PATCH changes** (x.y.Z → x.y.Z+1): Skip research — assume safe bug fixes. **Proceed even without release information, but treat the Phase 5 quality gate (which must pass) as the safety net** — not the patch label alone, since semver mis-tagging of breaking changes as patches is common
- Document any security advisories regardless of change type

**Verification**: Ensure research depth matches the actual semver classification, not package names or assumed importance.

**Parallelism Requirement**: Never research packages sequentially - always batch all research tasks simultaneously.

#### Phase 3: Impact Assessment (Sequential)

1. **Architect**: Analyze breaking changes across all packages
2. **Architect**: Assess migration complexity and code impact
3. Search codebase for package usage patterns
4. Identify files requiring updates due to breaking changes

#### Phase 4: Apply Updates (Sequential)

**`--dry-run` gate**: If the skill was invoked with `--dry-run`, STOP before this phase. Detection (Phase 1) and research still run; do **not** run any step below, install dependencies, commit, or push. `--dry-run` previews the planned updates and research findings only.

1. **Developer**: Update package.json files with `pnpm dlx npm-check-updates -u`, carrying the **same scope flags as Phase 1 detection** — `--deep` in a workspace (a plain root run does not traverse packages) **and any `--filter`** — so the applied set matches the researched/classified set rather than upgrading every outdated package
2. **Developer**: Install dependencies (`pnpm install`)
3. **Developer**: Implement required code changes for breaking changes
4. Handle dependency conflicts and version mismatches

**On failure in this phase** (e.g., `pnpm install` fails on a peer-dependency conflict, or a bumped range is incompatible), restore the tree before retrying or surfacing — `git checkout -- package.json pnpm-lock.yaml '**/package.json'` — so a half-applied manifest or lockfile is never left behind.

#### Phase 5: Quality Validation

Run the project's quality gate. Discover the actual script names and what each covers per [Project Commands](~/.claude/standards/project-commands.md) — script composition varies by project, so do not assume invented script names:

1. `pnpm check` — the user's canonical gate (type-check + lint/format, and in some projects the test suite too). Use this, **not** `pnpm typecheck` or `pnpm lint:fix`, which are not standard scripts here
2. `pnpm test` — run the test suite **only if `pnpm check` does not already include it**; some projects bundle tests into `check`, and running both executes the suite twice (a flaky test could then disagree between runs)
3. **Quality-reviewer**: Security and performance validation (may run in parallel with the gate)

Let `pnpm check` manage its own internal ordering and parallelism — do not assume a fixed sequence of its sub-steps.

#### Phase 6: PR Creation (Sequential)

1. **Check existing PR status**:
   - Run `gh pr status` to check if current branch has an open PR
   - If PR exists: Continue with existing branch and update existing PR
   - If no PR exists: Create feature branch with timestamp

2. **Technical-writer**: Generate comprehensive commit message
3. **Technical-writer**: Create or update PR description including:
   - Package update summary grouped by semver classification in markdown tables
   - Table columns: Package, Current, Target, and relevant details (Breaking Changes/New Features/Fixes)
   - Breaking change impact analysis for major version updates
   - Migration steps performed for major version changes
   - Quality validation results
   - Any packages updated without release notes (flagged in Phase 2)
   - Links to changelogs and release notes

4. **Push and handle PR**:
   - If existing PR: Push commits to existing branch, update PR description via `gh pr edit`
   - If new PR: Push branch and create PR via `gh pr create`
5. **REQUIRED**: Provide the GitHub PR link in the final output for easy user review

## Usage Options

- No arguments: Full automated workflow (applies updates, then opens or updates a PR for human review)
- `--dry-run`: Preview the planned updates and research findings **without** applying updates, installing dependencies, committing, or pushing — detection and research still run (enforced at the Phase 4 gate)
- `--filter <pattern>`: Only update packages matching the pattern (passed through to `npm-check-updates --filter`)

## Error Handling

When encountering errors:

1. **Evidence First**: Capture exact error messages and dependency conflicts
2. **Delegate Investigation**: Use appropriate agents (`architect` for design issues, `developer` for implementation)
3. **Quality Gates**: All tests must pass before PR creation
4. **Rollback Plan**: On a mid-update failure, restore the tree with `git checkout -- package.json pnpm-lock.yaml '**/package.json'` and delete any branch/PR created prematurely — never leave a half-applied manifest or lockfile

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

1. **Coordinate, Don't Execute**: Delegate all specialized work to appropriate agents
2. **Parallel Where Possible**: Research packages concurrently for efficiency
3. **Quality First**: Never compromise on testing and validation
4. **Evidence-Based**: Use agent research for all decisions
5. **Comprehensive Documentation**: Ensure PR provides complete context

## Important Notes

- Invoke npm-check-updates via `pnpm dlx npm-check-updates` (no global install required); `npx npm-check-updates` is an equivalent fallback, and a globally-installed `ncu` binary works if present
- Keep the scope flags (`--deep`, `--filter`) consistent between detection (`--jsonUpgraded`) and application (`-u`) so the applied set matches what was detected, researched, and classified — only the primary flag differs between the two

Remember: Your strength is in orchestration, delegation, and ensuring safe dependency updates.
