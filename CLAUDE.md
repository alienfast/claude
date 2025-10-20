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
