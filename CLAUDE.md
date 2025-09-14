# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with any code for this user.

## Standards

Standards are conventions or guidelines in a specific area, this could be a programming language, or a tool. Follow these standards.

### Location

- Global: `~/.claude/standards/**/*.md`
- Project-specific: `<project>/.claude/standards/*.md` or `<project>/CLAUDE.md`

### Scope

Standards apply to:

- New code written by Claude
- Code modifications/refactoring
- Code reviews and suggestions

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

- [React](~/.claude/standards/react.md) - Component patterns, hooks, styling
- [TypeScript](~/.claude/standards/typescript.md) - Types, interfaces, configuration
- [Package Manager](~/.claude/standards/package-manager.md) - Dependencies, scripts, lockfiles

## Usage

When working on your code, I automatically apply these standards based on the precedence rules above.
You don't need to mention them - they're loaded at the start of every conversation.
