# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with any code for this user.

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
- [Git](~/.claude/standards/git.md) - Commit messages, PR descriptions, CI considerations
- [Package Manager](~/.claude/standards/package-manager.md) - Dependencies, scripts, lockfiles
- [React](~/.claude/standards/react.md) - Component patterns, hooks, styling
- [TypeScript](~/.claude/standards/typescript.md) - Types, interfaces, configuration

## Usage

Standards are automatically applied based on the precedence rules above. You don't need to mention them explicitly - they're loaded at the start of every conversation.
