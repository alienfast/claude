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

- [Agent Coordination](~/.claude/standards/agent-coordination.md) - Parallel vs sequential execution patterns
- [Git](~/.claude/standards/git.md) - Commit messages, PR descriptions, CI considerations
- [Package Manager](~/.claude/standards/package-manager.md) - Dependencies, scripts, lockfiles
- [React](~/.claude/standards/react.md) - Component patterns, hooks, styling
- [TypeScript](~/.claude/standards/typescript.md) - Types, interfaces, configuration

## Usage

When working on your code, I automatically apply these standards based on the precedence rules above.
You don't need to mention them - they're loaded at the start of every conversation.

## Research Delegation

Choose the optimal research strategy based on task complexity and independence requirements.

### Research Strategy Decision Tree

**Simple Independent Queries** → Direct parallel research-subagents

- Single-topic investigations
- Independent fact-finding tasks
- Queries that can be answered separately

**Complex Synthesis Tasks** → research-lead coordination

- Multi-perspective analysis requiring integration
- Tasks needing strategic planning and coordination
- Conflicting information requiring expert judgment

**Mixed Tasks** → Hybrid approach (research-lead + parallel subagents)

### Delegation Patterns

#### Parallel Execution (Independent Tasks)

```text
✅ DO: Use single message with multiple Task tool calls
```

**Example - Parallel Research:**

```md
[Multiple Task tool calls in single message]
Task 1 for research-subagent: [Independent research topic A]
Task 2 for research-subagent: [Independent research topic B]
Task 3 for research-subagent: [Independent research topic C]
```

#### Coordinated Research (Complex Synthesis)

```text
✅ DO: Use research-lead for coordination and synthesis
```

**Example - Coordinated Research:**

```md
Task for research-lead: [Complex multi-perspective research objective]
Context: [Why this research matters to the current goal]
Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
Acceptance: [How to verify research completeness]
```

### Performance Optimization

- **Independent tasks**: Use parallel execution to reduce research time by 60-80%
- **Interdependent tasks**: Use research-lead to coordinate and synthesize
- **Batch tool calls**: Always use single message with multiple Task calls for parallel execution
- **Follow coordination patterns**: Apply [Agent Coordination](~/.claude/standards/agent-coordination.md) standards for optimal performance

This ensures both optimal performance and research quality based on task characteristics.
