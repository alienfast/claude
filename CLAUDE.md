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
- [Package Manager](~/.claude/standards/package-manager.md) - Dependencies, scripts, lockfiles
- [React](~/.claude/standards/react.md) - Component patterns, hooks, styling
- [Semantic Versioning](~/.claude/standards/semver.md) - Version classification, compatibility rules, update strategies
- [TypeScript](~/.claude/standards/typescript.md) - Types, interfaces, configuration

## Usage

Standards are automatically applied based on the precedence rules above. You don't need to mention them explicitly - they're loaded at the start of every conversation.

## Process Management

**Storybook Cleanup**: If Claude starts Storybook (`yarn storybook`) for testing or development purposes, Claude MUST stop the process when done. Do not leave Storybook running in the background unless the user explicitly requests it to remain running.

## Important Instruction Reminders

Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (\*.md) or README files. Only create documentation files if explicitly requested by the User.
NEVER leave temporary files behind, always clean up.
NEVER modify generated or build artifact files such as `src/generated/` or `dist` directories - these will be regenerated with build or gen commands.
ALWAYS apply deprecation standards when writing or modifying code - avoid deprecated APIs and proactively update them when encountered.
