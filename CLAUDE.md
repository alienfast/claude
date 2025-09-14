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

## Research Delegation

When encountering research tasks, always delegate to the research-lead agent rather than conducting research yourself.

### Auto-Delegation Triggers

**ALWAYS delegate to research-lead when encountering:**

- Tasks starting with: "Research", "Investigate", "Analyze", "Understand", "Study"
- Multi-step information gathering requiring synthesis
- Questions needing multiple perspectives or sources
- Understanding existing systems, architectures, or implementations
- Market research, competitive analysis, or trend investigation

### Delegation Pattern

```text
❌ DON'T: Start researching yourself
✅ DO: Use Task tool with research-lead agent
```

**Example Format:**

```md
Task for research-lead: [Specific research objective]
Context: [Why this research matters to the current goal]
Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
Acceptance: [How to verify research completeness]
```

This ensures consistent, high-quality research across all projects and conversations.
