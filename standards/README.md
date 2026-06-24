# Standards Quick Reference

Core principles (autonomy, decision thresholds, workaround anti-patterns) are summarized in [CLAUDE.md](../CLAUDE.md) and detailed in [problem-solving.md](problem-solving.md). This file indexes the individual standards.

## Available Standards

These standards apply universally across all contexts:

- [Agent Coordination](agent-coordination.md) - Parallel vs sequential execution patterns
- Commenting → moved to [rules/comments.md](../rules/comments.md) — auto-injected on every file edit, all file types (default to no comments; size to the reader; new files get a WHY docblock)
- [Git](git.md) - Commit messages, PR descriptions, multi-session safety
- [Problem-Solving](problem-solving.md) - When to ask vs. proceed, anti-patterns for workarounds
- [Project Commands](project-commands.md) - Command discovery and usage
- [Semantic Versioning](semver.md) - Version classification, compatibility rules, update strategies
- [Technical Debt Prevention](technical-debt-prevention.md) - No backups, no duplicates, modify in place
- [Linear Workflow](linear-workflow.md) - Terminal states, dependency resolution rules
- [Lifecycle Tags](lifecycle-tags.md) - Final-line status tags for Linear-lifecycle skills
- [Deprecation Handling](deprecation-handling.md) - Proactively update deprecated code; migration patterns and anti-patterns
- [Version-Aware Planning](version-aware-planning.md) - Research and planning based on actual dependency versions

## Migrated to Path-Specific Rules

These have been moved to `~/.claude/rules/` for path-based application:

- TypeScript → `rules/typescript.md` (applied to `**/*.ts`, `**/*.tsx`)
- React → `rules/react.md` (applied to `**/*.tsx`, `**/*.jsx`)
- Markdown → `rules/markdown.md` (applied to `**/*.md`, `**/*.mdx`)
- Package Manager → `rules/package-manager.md` (applied to `**/package.json`)
