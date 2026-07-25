# Standards Quick Reference

Core principles (autonomy, decision thresholds, workaround anti-patterns) are summarized in [CLAUDE.md](../CLAUDE.md) and detailed in [problem-solving.md](problem-solving.md). This file indexes the individual standards.

## Available Standards

These standards apply universally across all contexts:

- [Agent Coordination](agent-coordination.md) - Interface contracts, write-target exclusivity, background-agent recovery
- [Git](git.md) - Commit messages, PR descriptions, multi-session safety
- [Problem-Solving](problem-solving.md) - When to ask vs. proceed, anti-patterns for workarounds
- [Project Commands](project-commands.md) - Command discovery and usage
- [Semantic Versioning](semver.md) - Version classification, compatibility rules, update strategies
- [Technical Debt Prevention](technical-debt-prevention.md) - No backups, no duplicates, modify in place
- [Linear Workflow](linear-workflow.md) - Terminal states, dependency resolution rules
- [Issue Spec](issue-spec.md) - Certified-spec template, quality bar, and the `specified` label contract
- [Lifecycle Tags](lifecycle-tags.md) - Final-line status tags for Linear-lifecycle skills
- [Deprecation Handling](deprecation-handling.md) - Proactively update deprecated code; migration patterns and anti-patterns
- [Version-Aware Planning](version-aware-planning.md) - Research and planning based on actual dependency versions
- [GitHub Actions](github-actions.md) - SHA-pinning third-party actions; avoid the annotated-tag-object-SHA trap

## Path-Specific Rules

File-type conventions live in [`~/.claude/rules/`](../rules/) and are auto-injected by `paths:` glob
when you edit a matching file — read them there, not here:

| Rule | Applies to |
|---|---|
| [comments.md](../rules/comments.md) | every file type |
| [typescript.md](../rules/typescript.md) | `**/*.ts`, `**/*.tsx` |
| [react.md](../rules/react.md) | `**/*.tsx`, `**/*.jsx` |
| [markdown.md](../rules/markdown.md) | `**/*.md`, `**/*.mdx` |
| [biome.md](../rules/biome.md) | JS/TS/JSON in Biome projects |
| [env-vars.md](../rules/env-vars.md) | `**/*.ts`, `**/*.tsx`, `**/*.mts` |
| [package-manager.md](../rules/package-manager.md) | `**/package.json`, lockfiles |
