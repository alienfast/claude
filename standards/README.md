# Standards Quick Reference

This file provides a quick reference for core principles across all standards. For details, see individual standard files.

## Core Principles (Always Apply)

### 1. Move Forward, Not Around

- ✅ Proper solutions over workarounds
- ✅ Fix root causes, not symptoms
- ✅ Improve code quality with every change
- ❌ No shortcuts without explicit approval
- ❌ Technical debt should decrease, not increase

### 2. Ask When Genuinely Uncertain

- **Stop and ask** when root cause is unclear after investigation
- **Stop and ask** when multiple valid solutions have significant trade-offs
- **Stop and ask** after 2+ failed solution attempts
- **Stop and ask** when business/product decisions are needed
- Present options with clear recommendation for moving forward
- Don't ask based on file counts or scope - ask based on genuine uncertainty

### 3. Never Compromise on Quality

- ❌ No dependency downgrades to avoid issues
- ❌ No error suppression to bypass problems
- ❌ No `any` types to skip type checking
- ❌ No disabled linter rules without justification
- ❌ No skipped tests to ship faster
- ❌ No partial migrations without strategy

### 4. Delegate Complexity

- Use agent delegation for complex multi-step tasks (>5 steps, multiple domains)
- Preserve context window for coordination
- Track progress with TodoWrite
- Parallel execution for independent tasks
- Self-invoke `/do` pattern when appropriate

### 5. Respect the Codebase

- Follow existing patterns and conventions
- Update deprecations when touching files
- Maintain or improve test coverage
- Document architectural decisions
- Use modern APIs and patterns

### 6. Proceed With Confidence

You have autonomy to:

- Make architectural improvements
- Create new abstractions that improve code quality
- Change database schemas when necessary
- Update APIs and interfaces
- Modify build/deployment configurations
- Refactor across many files

**Don't ask permission for good engineering decisions.**

## When in Doubt

1. Check if similar code exists in the codebase (follow that pattern)
2. Check relevant standard file for guidance
3. If still uncertain and trade-offs are significant, stop and ask
4. If proceeding, prefer the solution that improves long-term maintainability

## Anti-Pattern Red Flags

If you're about to suggest any of these, stop and reconsider:

- "Let's downgrade this dependency..."
- "Let's ignore this error for now..."
- "Let's use `any` here to bypass..."
- "Let's disable this rule..."
- "Let's skip testing this part..."
- "Let's just patch this instead of refactoring..."
- "Let's pin to the old version..."
- "Let's migrate only part of the code..."

These are signals to either investigate deeper or ask for direction.

## Available Standards

- [Problem-Solving](problem-solving.md) - When to ask vs. proceed, anti-patterns for workarounds
- [Agent Coordination](agent-coordination.md) - Parallel vs sequential execution patterns
- [Deprecations](deprecations.md) - Handling deprecated APIs, types, and modules
- [Git](git.md) - Commit messages, PR descriptions, CI considerations
- [Markdown](markdown.md) - Linting requirements, code block formatting
- [Package Manager](package-manager.md) - Dependencies, scripts, lockfiles
- [Project Commands](project-commands.md) - Command discovery and usage
- [React](react.md) - Component patterns, hooks, styling
- [Semantic Versioning](semver.md) - Version classification, compatibility rules, update strategies
- [TypeScript](typescript.md) - Types, interfaces, configuration
- [Version-Aware Planning](version-aware-planning.md) - Research and planning based on actual dependency versions
