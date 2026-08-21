# Claude Skills Directory

This directory contains reusable Claude Skills that can be invoked during conversations to handle complex, multi-step workflows.

## Table of Contents

- [Overview](#overview)
- [When to Use Skills vs Commands](#when-to-use-skills-vs-commands)
- [Skills in This Directory](#skills-in-this-directory)
- [Creating New Skills](#creating-new-skills)
- [Best Practices](#best-practices)
- [Skill Scopes](#skill-scopes)
- [Resources](#resources)

## Overview

**Claude Skills** are specialized prompts that extend Claude's capabilities for complex, domain-specific tasks. They provide structured workflows, decision frameworks, and best practices for recurring tasks.

### How Skills Work

Skills use a **progressive disclosure** model with three tiers of loading:

1. **Tier 1 (Always Loaded)**: `SKILL.md` frontmatter (name and description) - always visible to Claude
2. **Tier 2 (Loaded on Invocation)**: `SKILL.md` content - loaded when skill is invoked
3. **Tier 3 (Loaded on Demand)**: Supporting files in `resources/`, `templates/`, `scripts/` - loaded only when referenced

This approach keeps Claude's context efficient while providing deep expertise when needed.

### How Skills Differ from Commands and Agents

| Feature | Skills | Commands | Agents |
|---------|--------|----------|--------|
| **Purpose** | Multi-step workflows with decision logic | Simple task execution | Specialized personas for specific roles |
| **Complexity** | High (orchestration, delegation) | Low to Medium (single operation) | Variable (focused expertise) |
| **Invocation** | Skill tool or user trigger phrases | `/command` syntax | Explicit task delegation |
| **Context** | Loaded progressively on demand | Expanded immediately | Available when invoked |
| **Examples** | Dependency updates, PR generation | Code formatting, file operations | Research, architecture, implementation |

## When to Use Skills vs Commands

### Use a Skill When

- Task requires multiple sequential or parallel steps
- Need decision-making logic and branching workflows
- Requires orchestration across multiple tools or agents
- Benefits from progressive context loading (templates, resources)
- Has clear quality gates and validation requirements
- Will be reused across multiple projects

**Example Scenarios**:

- Comprehensive dependency updates with research, analysis, and validation
- PR title/description generation with verification and formatting
- Database migration workflows with rollback planning
- Security audit processes with multiple validation steps

### Use a Command When

- Task is a single operation or simple sequence
- No complex decision logic required
- Doesn't need supporting resources or templates
- Quick, focused action (formatting, cleanup, search)

**Example Scenarios**:

- Format code with specific linter
- Run test suite
- Search codebase for patterns
- Generate simple boilerplate

### Keep as a Command (Don't Convert to Skill)

- Simple tool wrappers (e.g., `pnpm lint`)
- Single-file operations
- Tasks that don't benefit from progressive disclosure
- Operations that work well as slash commands

## Skills in This Directory

### dependency-updater

**Version**: 1.2.0

**Description**: Orchestrates comprehensive dependency updates by delegating research, impact analysis, code changes, and validation to specialized agents.

**When Invoked**:

- User requests "update dependencies"
- User mentions "ncu" or "npm-check-updates"
- User asks to "upgrade packages" or "bump versions"

**Key Features**:

- **Phase 0's two questions are the only interaction** — where to work (isolated worktree vs in place) and how to finish (`merge` vs `pr`). Everything after runs unattended; `--worktree`/`--in-place` and `--merge`/`--pr` skip even those
- Files a tracking Linear issue every run, then builds the worktree via `start-wt-setup.sh` + `EnterWorktree` — deliberately NOT `/start … interactive`, whose halt is a terminal state that hands off to a human and opens an editor window
- **Applies the whole update set at once, then fixes what the gate reports** — no per-package staging and no speculative impact analysis; the worktree makes a bad batch cheap to abandon
- Delegation is selective: `general-purpose` for parallel research, `developer` for real migrations, `technical-writer` once at ship. `architect` and `quality-reviewer` are exception-only, never a routine pre-flight pass
- Research depth follows semver — MAJOR full, MINOR skim, PATCH none, with the gate as the safety net for mis-tagged patches
- Ships through `/quality-review auto` → `/finish merge|pr auto` (the verdict is required — `/finish auto` refuses to ship unreviewed), then removes its own worktree on the `pr` path (`merge` self-cleans)

**Structure**:

- Main workflow in `SKILL.md`
- References `~/.claude/standards/semver.md` for version classification
- Uses multiple agent types (research-subagent, architect, developer, quality-reviewer, technical-writer)

### pr-update

**Version**: 1.0.0

**Description**: Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state.

**When Invoked**:

- User says "update the PR"
- User asks to "generate PR description"
- User mentions "write PR title"
- User requests "pull request summary"

**Key Features**:

- Analyzes git diff to determine actual changes (not just commit history)
- Verifies features exist in final code state
- Creates comprehensive, accurate PR documentation
- Multiple templates for different PR types

**Structure**:

- Main workflow in `SKILL.md`
- `resources/title-patterns.md` - PR title format examples
- `resources/analysis-workflow.md` - Step-by-step verification examples
- `templates/feature.md` - Feature addition template
- `templates/bugfix.md` - Bug fix template
- `templates/infrastructure.md` - Infrastructure change template
- `scripts/verify-feature.sh` - Feature verification script
- `scripts/analyze-pr.sh` - PR analysis automation

### next

**Description**: Suggest the best next issue to work on. Considers current cycle, dependency graph, triage status, and what's unblocked.

**When Invoked**:

- User says "what's next" or "next issue"
- User invokes `/next`
- Delegated from `/finish` after completing an issue

**Key Features**:

- 5-tier candidate ranking: certified reflection > assigned to you > newly unblocked > sibling of the just-completed issue > everything else workable
- Within a tier: Planned/Todo drains fully before Backlog (Urgent included), then Urgent, then `security`/`bug`, then priority
- Works standalone (fresh day/week) or post-finish (with just-completed context)
- Respects triage decisions as highest-signal indicators
- Analyzes transitive unblocking from dependency graph, not just direct blockers

**Structure**:

- Self-contained workflow in `SKILL.md`
- Uses `linear-deps-graph.sh` for the dependency graph, an `api` active-cycle filter, and `linear-cli issues list`

### auto-prep

**Description**: Prepare a team's certified backlog for a fleet of parallel `/loop /auto` sessions — label honesty audit, collision-edge wiring, ranked-pool validation, fleet sizing.

**When Invoked**:

- User says "auto-prep", "fleet prep", or "prep the backlog for auto"
- Before launching multiple parallel `/loop /auto` sessions

**Key Features**:

- Audits `specified` labels for unattended-shippability; de-labels or flags decision-gated, human-dependent, and run-attended/solo issues
- Wires minimal `blocks` chains between file-colliding certified candidates (the only dependency signal `/next` observes)
- Repairs `/reflect` filing labels (`reflection`/`keeper`) and dedupes duplicate filings
- Validates the result through `next-candidates.sh` and recommends a parallel-session count from the independent-lane analysis

**Structure**:

- Self-contained workflow in `SKILL.md`
- Complements `/quality-review`'s same-batch collision wiring by covering overlap across previously filed siblings (beyond the single dedup-adjacent edge `/quality-review` wires per filed item)

### fleet-launch

**Description**: Launch a fleet of parallel `/loop /auto` sessions as background agents in `claude agents`, staggered so each session's first pick sees the previous one's claim, with an optional time budget that winds the fleet down cleanly. The middle bookend: `/auto-prep` → `/fleet-launch` → `/fleet-retro`.

**When Invoked**:

- User says "launch the fleet", "spawn 5 auto loops", or "start the fleet for 10 hours"
- After `/auto-prep` has groomed the backlog and recommended a session count

**Key Features**:

- Count defaults to the recommendation `/auto-prep` persists to `tmp/fleet-recommendation.json`; an explicit count is the user's quota throttle
- Staggers dispatches on worktree appearance (the claim stamp), not a blind timer — the next session launches the moment the previous one's pick is excluded from ranking
- A duration writes `tmp/fleet-deadline.json`; `/auto` checks it before each pick (never mid-issue), so at the deadline sessions finish in-flight work and end their loops with `NO-CANDIDATES`
- Ending a running fleet early is `/fleet-stop` — a thin wrapper over the same script's `stop` form, which writes an already-passed deadline so in-flight work finishes and no new picks happen

**Structure**:

- All logic in `~/.claude/scripts/fleet-launch.sh`; `SKILL.md` dispatches and narrates
- Deadline contract shared with `skills/auto/SKILL.md` Step 2's fleet-deadline gate

### fleet-forecast

**Description**: Estimate — explicitly not a plan — of what a fleet of parallel `/loop /auto` sessions would ship over a time horizon: simulates the certified backlog draining across N sessions as blockers resolve and unblock their dependents. Read-only; nothing is launched or written.

**When Invoked**:

- User says "fleet forecast", "what would a fleet run look like", "what order would issues run", "how many hours to burn the Planned issues"
- Between `/auto-prep` (which grooms and sizes) and `/fleet-launch`, to see the projected drain's shape

**Key Features**:

- Greedy list-scheduling simulation: each free session picks the top-ranked available candidate (stage-first — Backlog only when nothing Planned/Todo is available), ships it after its estimated duration, and resolves its `blocks` edges; clean in-flight blockers are assumed to finish within one mean issue duration
- `STAGE` line answers "hours to burn Planned/Todo and when Backlog picks begin"; `POOL-DRAINED` shows certified runway shorter than the horizon; `STRANDED`/`UNREACHED` separate keeper-action gaps from capacity/horizon gaps
- Hours-per-issue calibrated from `tmp/fleet-metrics-history.jsonl` (recent fleets' session-hours ÷ shipped), estimate-point weighted; sessions/horizon default from `tmp/fleet-recommendation.json`
- Eligibility mirrors `fleet-blockers.sh` gate rules; wave-1 picks are cross-checked against `next-candidates.sh`, which stays the pick-time authority — divergence is narrated, never edited away

**Structure**:

- Workflow in `SKILL.md`; simulation in `~/.claude/scripts/fleet-forecast.py` (fixture-testable via `--fixture`; regression suite `fleet-forecast.test.sh`)
- Routes stranded-blocker remedies to `/auto-prep`'s FOCUS audit rather than re-deriving them

### fleet-retro

**Description**: Post-mortem on a finished fleet of parallel `/loop /auto` sessions — measures where the capacity went, reconciles the shipped ledger, audits what the run filed, then applies the fixes you approve. The bookend to `/auto-prep`.

**When Invoked**:

- User says "fleet retro", "review the fleet run", "how did the fleet do", or "post-mortem the auto run"
- After a fleet of parallel `/loop /auto` sessions finishes

**Key Features**:

- Measures every session through `scripts/fleet-metrics.py` on a fixed schema, so successive retros are comparable and drift is visible
- Reads subagent transcripts, where permission blocks and stalls actually land — invisible to the parent session, which sees only a slow `Agent` call
- Flags silent loop death (no `ScheduleWakeup`), unrecorded ships (Step 4 never ran), blind-sleep burn, classifier blocks, and shipped-without-a-commit
- Audits the issues the run *filed* — duplicates from phrase-shaped dedup searches, `Triage` strandings, certification gaps
- Distinguishes a compliance failure from a rule gap, and prefers a mechanical guard when prose has already lost

**Structure**:

- Workflow in `SKILL.md`; measurement in `~/.claude/scripts/fleet-metrics.py` (`--json` for machine use)
- Routes the config-improvement half to `/reflect` rather than reimplementing its batching and filing

### quality-review

**Description**: Adversarial implementation review with triage and fix loop, tiered by role. Hard-gates on `pnpm check`, delegates initial discovery to the quality-reviewer agent (opus/xhigh) for categorized findings, then loops triage/fix/re-review — small fixes applied directly by the orchestrator, substantive ones via sonnet-tier developer dispatches, re-reviews and confirmations on the lighter quality-verifier agent — until convergence (no new substantive findings — prose-only and mechanical fixes do not block it; 5-cycle soft ceiling, extended once in auto mode when the findings trend is decreasing).

**When Invoked**:

- User says "review my work", "check this implementation", "adversarial review"
- User invokes `/quality-review`
- Delegated from `/start` after implementation completes

**Key Features**:

- Working Application Contract enforcement (`pnpm check` gate)
- Categorized findings (Critical/High/Medium/Nice-to-Have/Approved)
- Parallel domain-scoped reviewers for large changes
- Mandatory re-review after every substantive fix, dispatched to the quality-verifier agent with the fix delta as an inline diff; converges when no new substantive findings surface — prose-only and mechanical findings from any cycle, the initial review included, are fixed directly by the orchestrator and verified by their own lanes without consuming a cycle (an all-prose/mechanical batch skips the re-review entirely), and after cycle 2 new Mediums are filed as deferred items instead of re-arming the loop (5-cycle soft ceiling)
- Deferred-items triage (`fix-now` / `defer-as-issue` / `note-only`); auto-applies safe fixes, files ticket-worthy ones as sub-issues, records the rest as dropped
- Standalone or delegated invocation; auto-detects scope from `git diff`
- Optional Linear issue context for requirement-conformance checks

**Structure**:

- Self-contained workflow in `SKILL.md`
- Delegates to `quality-reviewer` (initial review), `quality-verifier` (re-reviews and confirmations), and `developer` (substantive fixes, sonnet-tier) agents; mechanical and prose fixes are applied by the orchestrator directly
- Uses `linear-cli issues get` for requirement context when an issue is resolvable

### reflect

**Description**: Continuous-improvement reflection on the just-finished session. Captures generalizable lessons (thrashing, silently-worked-around skills, repeated corrections) and reconciles config that has drifted from reality, then auto-applies the small/safe shared-config edits and proposes the larger ones — reusing `/quality-review`'s triage discipline under its own lane names (`apply-now` / `propose` / `drop`), pointed at the config layer.

**When Invoked**:

- Invoked by `/fleet-retro` as its batched `/reflect fleet` step — the only scheduled surface; otherwise manual
- User says "reflect", "reflect on this session", "what did we learn"
- User invokes `/reflect` (session) or `/reflect sweep [project-path]`

**Key Features**:

- Two directions: **Add** (new lesson → rule/note) and **Reconcile** (config contradicts reality → fix the stale line)
- Three modes: **session** (reflect on this session in context), **sweep** (audit a project's `CLAUDE.md`/rules against the actual codebase + cross-file dedup; manual or scheduled), and **fleet** (batched reflection over a finished fleet run's evidence; invoked by `/fleet-retro`)
- Targets **shared, team-visible config** (`CLAUDE.md` / `rules/` / `standards/` / skills); memory is last resort
- Adversarial verify gate drops anything not generalizable, already-covered, or that wouldn't have helped — "zero improvements" is a success
- Auto-applies only additive/clarifying edits to the working tree; **commits only one scoped case** — project-scoped edits inside a `/start wt` worktree, check-gated and staged by name, so they ride the issue merge. User-level `~/.claude` edits are never committed; the explicit-commit step stays the review gate

**Structure**:

- Self-contained workflow in `SKILL.md` (routing table, triage gates, noise guard)
- Delegates verification (session) and config-vs-codebase audit (sweep) to agents
- Routes per `~/.claude/CLAUDE.md` "Where Knowledge Goes"; references `~/.claude/standards/problem-solving.md`

### keeper

**Description**: The keeper's interactive pickup for config work autonomous runs cannot ship — adjudicates both `/reflect` review queues in one pass: the uncommitted local `~/.claude` edits left for review, and every `keeper`-labeled Linear issue workspace-wide. Applies the fixes that hold up, returns recommendations for the rest, and commits and pushes the accepted set (the invocation is the skill-scoped grant — `standards/git.md` § Named exceptions).

**When Invoked**:

- User says "keeper", "process the keeper queue", "review the keeper batches", "what's waiting on me"
- User invokes `/keeper`
- Interactive-only — never from `/auto`, a fleet, or any unattended flow

**Key Features**:

- One adjudication standard for both queues: evidence scoped to what was measured, correct placement per the "Where Knowledge Goes" routing, no contradiction/duplication, house-style proportion, and a higher bar for anything that changes unattended `/auto` behavior
- Three verdicts per item: apply / reject (with the recommendation that would make it acceptable) / needs-you (genuine trade-offs surface as questions, never guesses)
- Partial batches apply immediately — accepted items ship now; an issue stays open only while items wait on the user, otherwise Done with a per-item verdict comment
- Never reverts or stashes rejected local edits (multi-session safety); defers files whose shape reads as another session's mid-edit WIP
- Project-repo targets are flagged for issue/PR routing, never edited cross-repo
- Gates each item on its sibling regression suite and markdownlint before commit; one commit per keeper issue, one for accepted local edits

**Structure**:

- Self-contained workflow in `SKILL.md`
- Uses the linear skill's raw-hatch label query (workspace-wide), `linear-context.sh` digests, and `linear-post.sh` for verdict comments
- The bookend to `/reflect`: reflect files the queues, keeper drains them

### standardize-tooling

**Description**: Converge a TypeScript project's dev tooling onto the house conventions — pnpm 11 (supply-chain cooldown, allow-builds, `@alienfast` registry), Biome (no ESLint/Prettier), markdownlint-cli2, madge, the standardized parallel `check` suite, tsdown for libraries, and OIDC token-less `auto` releases for published packages — then gate on `pnpm check`. Adaptive and idempotent: detects current state and applies only the gaps.

**When Invoked**:

- User says "standardize tooling", "update tooling", or "apply house tooling conventions"
- User asks to migrate a project to pnpm / Biome / tsdown, or off yarn/npm + ESLint/Prettier + tsup
- User invokes `/standardize-tooling`

**Key Features**:

- Declares a target end-state and converges the delta — not a fixed-order recipe
- `scripts/detect-state.sh` emits `KEY=value` gap signals (package manager, linter, bundler, single-vs-mono, registry, published)
- Reads canonical configs **live** from `~/projects/basefund` (primary), `gltfjsx`, and `vite-plugin-i18next-loader` — never frozen snapshots, so it can't go stale
- Adapts to single-package vs monorepo and public-npm vs private `@alienfast` GitHub Packages registry
- Gates on `pnpm check`; lists manual follow-ups (npmjs Trusted Publisher, stale secret deletion) separately

**Structure**:

- Workflow in `SKILL.md`; `scripts/detect-state.sh` for state detection
- `references/converge.md` — source-of-truth map + per-attribute apply steps and gotchas
- `references/publishing.md` — tsdown, `auto`, and OIDC trusted publishing (loaded only when published)
- Hands off full dependency refreshes to `/dependency-updater` and CLAUDE.md to `/init`

## Creating New Skills

### Directory Structure

Each skill requires:

```text
skills/
  your-skill-name/
    SKILL.md              # Required: Main skill definition
    README.md             # Optional: User-facing documentation
    resources/            # Optional: Reference materials
    templates/            # Optional: Reusable templates
    scripts/              # Optional: Helper scripts
```

### SKILL.md Frontmatter Requirements

Every `SKILL.md` must start with YAML frontmatter:

```yaml
---
name: your-skill-name
description: "What the skill does and when it's invoked. Include trigger phrases users might say."
version: "1.0.0"  # Optional: most workflow skills in this repo omit it
allowed-tools: ["Bash", "Read", "Write"]  # Optional: restrict available tools
---
```

**Frontmatter Fields**:

- `name` (required): kebab-case, identical to the directory name — the harness surfaces this field as the skill's `/name` identity, so a title-case name registers as `/Fleet Forecast` among `/fleet-*` siblings
- `description` (required): What + when the skill is used, including trigger phrases
- `version` (optional): Semantic version (1.0.0); most workflow skills in this repo omit it
- `allowed-tools` (optional): Whitelist of tools this skill can use

### Naming Conventions

**Skill Directory Names**:

- Use kebab-case: `dependency-updater`, `pr-update`, `database-migration`
- Prefer gerund form (action-oriented): `updating-dependencies`, `generating-prs`
- Be specific and descriptive: `graphql-schema-updater` not `schema-tool`

**Skill Names (in frontmatter)**:

- Identical to the directory name, kebab-case — every skill in this directory does this, and the frontmatter `name` is what the harness registers as the invocation/display identity

### Description Best Practices

Write descriptions in **third person** that explain:

1. **What** the skill does (capabilities)
2. **When** it's invoked (trigger phrases and scenarios)

**Good Examples**:

```yaml
description: "Orchestrates comprehensive dependency updates by delegating research, impact analysis, code changes, and validation to specialized agents. Invoked when users request package updates, dependency updates, version bumps, or mention 'ncu' or npm-check-updates."
```

```yaml
description: "Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state. Use when the user mentions updating, generating, or writing PR descriptions, PR titles, pull request summaries, or says 'update the PR'."
```

**Poor Examples**:

```yaml
# Too vague
description: "Updates dependencies"

# Missing when/triggers
description: "Handles package version management and updates"

# First person (wrong voice)
description: "I help you update your dependencies"
```

### File Organization Patterns

**resources/**: Reference materials loaded on demand

- Markdown files with detailed examples
- Decision matrices and flowcharts
- Best practices and anti-patterns
- Example: `resources/title-patterns.md`, `resources/analysis-workflow.md`

**templates/**: Reusable output templates

- Structured formats for generated content
- Multiple variants for different scenarios
- Example: `templates/feature.md`, `templates/bugfix.md`

**scripts/**: Helper automation scripts

- Bash/Python scripts for verification or analysis
- Should be referenced from main SKILL.md
- Example: `scripts/verify-feature.sh`, `scripts/analyze-pr.sh`

**Policy in markdown, machinery in scripts.** A skill's markdown carries decisions, routing, and prompts. Multi-line procedural bash belongs in a tested script — skill-local `scripts/` or the shared `~/.claude/scripts/` — with a verdict-line stdout contract: the first line is the verdict and the skill branches on it (see `~/.claude/scripts/wt-baseline.sh` — `CLEAN`/`CONTAMINATED`/`FAILED` — and `start-wt-verify.sh`). Inline bash the model must re-emit verbatim is a transcription-drift surface: more than a few lines, or any duplication across skills, means extract to a script. Scripts are not just length management.

**README.md**: User-facing documentation (optional)

- How to use the skill
- Examples and common scenarios
- Not loaded by Claude automatically

## Best Practices

### Keep SKILL.md Under 500 Lines

- Main workflow should be concise and scannable
- Move detailed examples to `resources/`
- Move templates to `templates/`
- Move scripts to `scripts/`
- Link to supporting files from main SKILL.md

### Use Progressive Disclosure

Don't load everything upfront:

- **Tier 1**: Frontmatter (name and description) - always visible
- **Tier 2**: Main SKILL.md content - loaded on invocation
- **Tier 3**: Supporting files - loaded only when referenced

Example from pr-update:

```markdown
## PR Title Formats

See [resources/title-patterns.md](resources/title-patterns.md) for comprehensive title format examples.

Quick reference:
- Infrastructure: "Enterprise [resource] with [key feature]"
- Features: "Add [feature] with [benefit]"
```

### Test Across Models

Skills should work with:

- Opus (the default — orchestration, implementation, review)
- Sonnet (research, writing, and any skill pinned to it)
- Haiku (narrow classification skills only; it does not support the `effort` parameter)

Test that your skill:

- Provides clear instructions
- Handles model limitations gracefully
- Works with different context window sizes

### Version Tracking

Use semantic versioning:

- **1.0.0**: Initial stable release
- **1.1.0**: New features, backward compatible
- **2.0.0**: Breaking changes to skill interface

Update version when:

- Changing skill behavior significantly
- Modifying frontmatter structure
- Adding/removing required steps
- Changing invocation triggers

### Documentation Standards

- Use clear, imperative language
- Provide concrete examples
- Include verification steps
- Document error handling
- Link to external standards (e.g., `~/.claude/standards/semver.md`)

### Quality Gates

Every skill should define:

- Success criteria (checklist format)
- Validation requirements
- Error handling procedures
- Rollback plans (when applicable)

Example from dependency-updater:

```markdown
## Quality Standards

Each phase must meet:

- ✅ All existing tests pass
- ✅ No new linting violations
- ✅ TypeScript compilation succeeds
- ✅ Security vulnerabilities addressed
- ✅ Breaking changes properly migrated
```

## Skill Scopes

Skills can exist at three levels:

### Personal Skills

**Location**: `~/.claude/skills/`

**Scope**: Available to you across all projects

**Use Cases**:

- Personal workflow preferences
- Cross-project automation
- Reusable patterns you use frequently

**Examples**: dependency-updater, pr-update

### Project Skills

**Location**: `<project>/.claude/skills/`

**Scope**: Available only within that project

**Use Cases**:

- Project-specific workflows
- Domain-specific operations
- Team-shared processes

**Examples**: Project-specific deployment, custom test workflows

### Plugin Skills

**Location**: Claude Skills Marketplace

**Scope**: Published, community-maintained skills

**Use Cases**:

- Industry-standard workflows
- Popular framework integrations
- Shared best practices

**Examples**: (As marketplace develops in late 2025)

### Precedence Rules

When multiple skills have the same name:

1. Project skills (`.claude/skills/`) - highest priority
2. Personal skills (`~/.claude/skills/`)
3. Plugin skills (marketplace) - lowest priority

## Resources

### Official Documentation

- [Claude Skills Documentation](https://docs.anthropic.com/claude/docs/skills) - Official skill creation guide
- [Claude Agent SDK](https://docs.anthropic.com/claude/docs/agent-sdk) - Technical reference
- [Progressive Disclosure Best Practices](https://docs.anthropic.com/claude/docs/progressive-disclosure) - Context optimization

### Example Skills

- [dependency-updater](dependency-updater/SKILL.md) - Complex orchestration with agent delegation
- [pr-update](pr-update/SKILL.md) - Git analysis with verification and templates

### Related Standards

Referenced by skills in this directory:

- [~/.claude/standards/semver.md](../standards/semver.md) - Semantic version classification
- [~/.claude/standards/git.md](../standards/git.md) - Git commit and PR conventions
- [~/.claude/standards/agent-coordination.md](../standards/agent-coordination.md) - Cross-agent interface contracts, write-target exclusivity, background-agent recovery

### Community Resources

- [Claude Skills Marketplace](https://claude.com/skills) - Browse and share skills (coming late 2025)
- [Skills Examples Repository](https://github.com/anthropics/claude-skills-examples) - Community examples
- [Skills Best Practices Guide](https://docs.anthropic.com/claude/guides/skills-best-practices) - Advanced patterns

---

**Need Help?**

- Review existing skills in this directory for patterns
- Check official documentation for latest features
- Test your skill with different scenarios before committing
- Version your skills to track changes over time
