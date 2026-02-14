# Standards Quick Reference

Core principles (anti-patterns, decision thresholds, autonomy) are defined in [CLAUDE.md](../CLAUDE.md). This file indexes the individual standards.

## Available Standards

These standards apply universally across all contexts:

- [Agent Coordination](agent-coordination.md) - Parallel vs sequential execution patterns
- [Git](git.md) - Commit messages, PR descriptions, multi-session safety
- [Problem-Solving](problem-solving.md) - When to ask vs. proceed, anti-patterns for workarounds
- [Project Commands](project-commands.md) - Command discovery and usage
- [Semantic Versioning](semver.md) - Version classification, compatibility rules, update strategies
- [Technical Debt Prevention](technical-debt-prevention.md) - No backups, no duplicates, modify in place
- [Version-Aware Planning](version-aware-planning.md) - Research and planning based on actual dependency versions

## Migrated to Path-Specific Rules

These have been moved to `~/.claude/rules/` for path-based application:

- TypeScript → `rules/typescript.md` (applied to `**/*.ts`, `**/*.tsx`)
- React → `rules/react.md` (applied to `**/*.tsx`, `**/*.jsx`)
- Markdown → `rules/markdown.md` (applied to `**/*.md`, `**/*.mdx`)
- Package Manager → `rules/package-manager.md` (applied to `**/package.json`)

## Migrated to Skills

These have been merged into their corresponding skills:

- Deprecations → `skills/deprecation-handler/resources/standards.md`
