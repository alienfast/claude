# CLAUDE.md

This file provides global (user-level) guidance to Claude Code (claude.ai/code) when working with any code for this user. This directory (`~/.claude/`) contains the user's global set of agents, commands, and standards that apply to all projects unless overridden by project-specific configurations.

## Date

The year is 2025. Do not limit your searches based on information from only previous years unless explicitly instructed by the user.

## Standards

Standards are conventions or guidelines in a specific area, this could be a programming language e.g. Typescript, or a tool e.g. package manager like yarn. Always apply standards according to the rules in this section.

### Location

- Global: `~/.claude/standards/**/*.md`
- Project-specific: `<project>/.claude/standards/*.md` or `<project>/CLAUDE.md`

### Scope

Standards apply to:

- New code written by Claude
- Code modifications/refactoring
- Code reviews and suggestions
- Tool usage (commands, configurations, workflows)

Standards do not override:

- Existing working code (unless explicitly refactoring)
- Third-party/generated code
- User's explicit instructions

### Precedence Rules

1. Explicit user instruction (highest priority)
2. Project-specific standards (if they exist)
3. Existing codebase conventions
4. Language-specific standards
5. General coding standards (lowest priority)

### Available Standards

- [Problem-Solving](~/.claude/standards/problem-solving.md) - When to ask vs. proceed, anti-patterns for workarounds
- [Agent Coordination](~/.claude/standards/agent-coordination.md) - Parallel vs sequential execution patterns
- [Deprecations](~/.claude/standards/deprecations.md) - Handling deprecated APIs, types, and modules
- [Git](~/.claude/standards/git.md) - Commit messages, PR descriptions, CI considerations
- [Markdown](~/.claude/standards/markdown.md) - Linting requirements, code block formatting
- [Package Manager](~/.claude/standards/package-manager.md) - Dependencies, scripts, lockfiles
- [Project Commands](~/.claude/standards/project-commands.md) - Command discovery and usage
- [React](~/.claude/standards/react.md) - Component patterns, hooks, styling
- [Semantic Versioning](~/.claude/standards/semver.md) - Version classification, compatibility rules, update strategies
- [TypeScript](~/.claude/standards/typescript.md) - Types, interfaces, configuration
- [Version-Aware Planning](~/.claude/standards/version-aware-planning.md) - Research and planning based on actual dependency versions

## Usage

Standards are automatically applied based on the precedence rules above. You don't need to mention them explicitly - they're loaded at the start of every conversation.

## CircleCI

### Organization Details

**alienfast**:

- Organization ID: `738dd131-6ace-4b96-8073-a4a724175e69`
- Slug: `github/alienfast`

When working with CircleCI tools for alienfast projects, use these identifiers as needed.

## Process Management

**Storybook Cleanup**: If Claude starts Storybook (`yarn storybook`) for testing or development purposes, Claude MUST stop the process when done. Do not leave Storybook running in the background unless the user explicitly requests it to remain running.

## Hooks

### Automatic Linting

A global PostToolUse hook (`~/.claude/hooks/lint.sh`) automatically runs linters after Write/Edit operations:

- **Markdown files** (`.md`): Runs `markdownlint --fix` when `.markdownlint.jsonc`, `.markdownlint.json`, or `.markdownlintrc` exists
- **Code files** (`.json`, `.jsonc`, `.gql`, `.ts`, `.tsx`, `.js`, `.mjs`, `.cjs`): Runs `biome check --write` when `biome.jsonc` or `biome.json` exists

The hook only runs if the appropriate config file exists in the project, making it portable across all projects.

## Guidelines

- Prefer editing existing files over creating new ones
- Create documentation only when explicitly requested
- Do not modify generated or build artifact files (e.g., `src/generated/`, `dist/`)
- Follow deprecation standards when writing or modifying code
- Linting is automatic via the global hook (see Hooks section above)
- **Do not create git commits unless explicitly requested by the user**
- **Do not assume backward compatibility is required** - when making changes, prioritize moving forward even if it means breaking changes, unless the user specifically requests maintaining compatibility
- **Always move the codebase forward** - when facing obstacles, prefer proper solutions over workarounds, even if they require more work. Present options but recommend the path that improves code quality and maintainability
- **Avoid technical debt** - do not suggest shortcuts, hacks, or temporary fixes without explicit approval. When complexity is encountered, investigate deeper or ask for direction rather than compromising on quality

## Complexity & Decision Thresholds

Claude should stop and ask for direction when encountering **genuine uncertainty**, not based on mechanical rules about file counts or scope.

### Stop and Ask When

#### Uncertainty After Investigation

- Root cause unclear after thorough investigation
- Multiple valid solutions exist with significant trade-offs
- Solution requires choosing between competing design philosophies
- Technical approach would deviate significantly from existing codebase patterns (when unclear if deviation is desired)

#### Stuck After Multiple Attempts

- 2+ attempted solutions have failed
- Each attempt reveals new unexpected complexity
- Problem appears to have deeper architectural issues than initially visible

#### Trade-off Decisions Beyond Technical Scope

- Business logic decisions needed (e.g., how to handle edge cases with user impact)
- Performance vs. maintainability trade-offs with no clear winner
- Security vs. usability decisions
- Cost/infrastructure implications

### Proceed With Confidence When

#### Clear Path Forward Exists

- Solution is obvious from investigation
- Pattern exists in codebase to follow
- Change improves code quality (better abstractions, removes tech debt)
- Error messages provide clear guidance
- Standards explicitly cover the scenario

#### Improvements Are Welcome

- New abstractions/patterns that improve code quality
- Database schema changes that are necessary
- API/interface updates (you have autonomy to evolve these)
- Build/deployment configuration improvements
- Refactoring that enhances maintainability
- Multi-file changes that follow a clear pattern

#### Architectural Changes Are Fine If

- They solve the problem properly
- They improve the codebase
- They follow or establish good patterns
- You can explain the rationale

### Response Format for Complex Situations

When stopping to ask, provide:

1. **What I've tried**: List approaches and outcomes
2. **Why I'm uncertain**: Explain the specific decision point or ambiguity
3. **Options available**:
   - Option A (Proper Solution): [Description] - [Effort estimate] - [Trade-offs]
   - Option B (Alternative): [Description] - [Effort estimate] - [Trade-offs]
4. **Recommendation**: Explicitly state which option moves the codebase forward
5. **Question**: What would you like me to do?

### Key Principle

**Don't ask permission for good engineering decisions.**

If the solution:

- Improves code quality
- Fixes the root cause
- Follows good practices
- Can be clearly explained

Then proceed with confidence, even if it means:

- Touching many files
- Creating new abstractions
- Changing schemas
- Updating interfaces
- Refactoring configurations

## Delegation and Planning

### When to Use `/do` Command Pattern

For complex, multi-step tasks, Claude should adopt the `/do` command pattern even without explicit user invocation:

**Use delegation pattern when:**

- Task involves >5 distinct steps
- Multiple domains (research + architecture + implementation)
- High context window usage expected (>50k tokens)
- Task will take >10 minutes of work
- Quality review across multiple components needed

**Benefits of delegation:**

- Reduces context window exhaustion
- Maintains focus and quality per subtask
- Enables parallel work streams
- Provides clear progress tracking

**Implementation:**

When recognizing a complex task, say:
"This task has multiple complex steps. I'll use a delegation approach similar to `/do` to manage this efficiently."

Then proceed with TodoWrite and agent delegation pattern from the `/do` command.

## Configuration Maintenance

This configuration is reviewed periodically to ensure it remains current with Claude Code capabilities and best practices.

**Last Review**: October 2025
**Next Review**: April 2026 (or when major Claude Code updates occur)

**Review Checklist**:

- Remove outdated patterns as model capabilities improve
- Update standards based on ecosystem changes
- Consolidate redundant instructions
- Add anti-patterns based on observed issues
- Verify all file references are current
