# Claude Skills Directory

This directory contains reusable Claude Skills that can be invoked during conversations to handle complex, multi-step workflows.

## Table of Contents

- [Overview](#overview)
- [When to Use Skills vs Commands](#when-to-use-skills-vs-commands)
- [Skills in This Directory](#skills-in-this-directory)
- [Creating New Skills](#creating-new-skills)
- [Best Practices](#best-practices)
- [Skill Scopes](#skill-scopes)
- [Resources](#resources)

## Overview

**Claude Skills** are specialized prompts that extend Claude's capabilities for complex, domain-specific tasks. They provide structured workflows, decision frameworks, and best practices for recurring tasks.

### How Skills Work

Skills use a **progressive disclosure** model with three tiers of loading:

1. **Tier 1 (Always Loaded)**: `SKILL.md` frontmatter (name, description, version) - always visible to Claude
2. **Tier 2 (Loaded on Invocation)**: `SKILL.md` content - loaded when skill is invoked
3. **Tier 3 (Loaded on Demand)**: Supporting files in `resources/`, `templates/`, `scripts/` - loaded only when referenced

This approach keeps Claude's context efficient while providing deep expertise when needed.

### How Skills Differ from Commands and Agents

| Feature | Skills | Commands | Agents |
|---------|--------|----------|--------|
| **Purpose** | Multi-step workflows with decision logic | Simple task execution | Specialized personas for specific roles |
| **Complexity** | High (orchestration, delegation) | Low to Medium (single operation) | Variable (focused expertise) |
| **Invocation** | Skill tool or user trigger phrases | `/command` syntax | Explicit task delegation |
| **Context** | Loaded progressively on demand | Expanded immediately | Available when invoked |
| **Examples** | Dependency updates, PR generation | Code formatting, file operations | Research, architecture, implementation |

## When to Use Skills vs Commands

### Use a Skill When

- Task requires multiple sequential or parallel steps
- Need decision-making logic and branching workflows
- Requires orchestration across multiple tools or agents
- Benefits from progressive context loading (templates, resources)
- Has clear quality gates and validation requirements
- Will be reused across multiple projects

**Example Scenarios**:

- Comprehensive dependency updates with research, analysis, and validation
- PR title/description generation with verification and formatting
- Database migration workflows with rollback planning
- Security audit processes with multiple validation steps

### Use a Command When

- Task is a single operation or simple sequence
- No complex decision logic required
- Doesn't need supporting resources or templates
- Quick, focused action (formatting, cleanup, search)

**Example Scenarios**:

- Format code with specific linter
- Run test suite
- Search codebase for patterns
- Generate simple boilerplate

### Keep as a Command (Don't Convert to Skill)

- Simple tool wrappers (e.g., `yarn lint`)
- Single-file operations
- Tasks that don't benefit from progressive disclosure
- Operations that work well as slash commands

## Skills in This Directory

### dependency-updater

**Version**: 1.0.0

**Description**: Orchestrates comprehensive dependency updates by delegating research, impact analysis, code changes, and validation to specialized agents.

**When Invoked**:

- User requests "update dependencies"
- User mentions "ncu" or "npm-check-updates"
- User asks to "upgrade packages" or "bump versions"

**Key Features**:

- Parallel package research (10-20 concurrent subagents)
- Semantic versioning classification
- Breaking change analysis and migration
- Quality validation (tests, linting, TypeScript)
- Comprehensive PR generation

**Structure**:

- Main workflow in `SKILL.md`
- References `~/.claude/standards/semver.md` for version classification
- Uses multiple agent types (research-subagent, architect, developer, quality-reviewer, technical-writer)

### pr-update

**Version**: 1.0.0

**Description**: Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state.

**When Invoked**:

- User says "update the PR"
- User asks to "generate PR description"
- User mentions "write PR title"
- User requests "pull request summary"

**Key Features**:

- Analyzes git diff to determine actual changes (not just commit history)
- Verifies features exist in final code state
- Creates comprehensive, accurate PR documentation
- Multiple templates for different PR types

**Structure**:

- Main workflow in `SKILL.md`
- `resources/title-patterns.md` - PR title format examples
- `resources/analysis-workflow.md` - Step-by-step verification examples
- `templates/feature.md` - Feature addition template
- `templates/bugfix.md` - Bug fix template
- `templates/infrastructure.md` - Infrastructure change template
- `scripts/verify-feature.sh` - Feature verification script
- `scripts/analyze-pr.sh` - PR analysis automation

## Creating New Skills

### Directory Structure

Each skill requires:

```text
skills/
  your-skill-name/
    SKILL.md              # Required: Main skill definition
    README.md             # Optional: User-facing documentation
    resources/            # Optional: Reference materials
    templates/            # Optional: Reusable templates
    scripts/              # Optional: Helper scripts
```

### SKILL.md Frontmatter Requirements

Every `SKILL.md` must start with YAML frontmatter:

```yaml
---
name: "Your Skill Name"
description: "What the skill does and when it's invoked. Include trigger phrases users might say."
version: "1.0.0"
allowed-tools: ["Bash", "Read", "Write"]  # Optional: restrict available tools
---
```

**Frontmatter Fields**:

- `name` (required): Human-readable skill name (title case)
- `description` (required): What + when the skill is used, including trigger phrases
- `version` (required): Semantic version (1.0.0)
- `allowed-tools` (optional): Whitelist of tools this skill can use

### Naming Conventions

**Skill Directory Names**:

- Use kebab-case: `dependency-updater`, `pr-update`, `database-migration`
- Prefer gerund form (action-oriented): `updating-dependencies`, `generating-prs`
- Be specific and descriptive: `graphql-schema-updater` not `schema-tool`

**Skill Names (in frontmatter)**:

- Use title case: "Dependency Updater", "PR Title and Description Generator"
- Can be more descriptive than directory name
- Should match the workflow purpose

### Description Best Practices

Write descriptions in **third person** that explain:

1. **What** the skill does (capabilities)
2. **When** it's invoked (trigger phrases and scenarios)

**Good Examples**:

```yaml
description: "Orchestrates comprehensive dependency updates by delegating research, impact analysis, code changes, and validation to specialized agents. Invoked when users request package updates, dependency updates, version bumps, or mention 'ncu' or npm-check-updates."
```

```yaml
description: "Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state. Use when the user mentions updating, generating, or writing PR descriptions, PR titles, pull request summaries, or says 'update the PR'."
```

**Poor Examples**:

```yaml
# Too vague
description: "Updates dependencies"

# Missing when/triggers
description: "Handles package version management and updates"

# First person (wrong voice)
description: "I help you update your dependencies"
```

### File Organization Patterns

**resources/**: Reference materials loaded on demand

- Markdown files with detailed examples
- Decision matrices and flowcharts
- Best practices and anti-patterns
- Example: `resources/title-patterns.md`, `resources/analysis-workflow.md`

**templates/**: Reusable output templates

- Structured formats for generated content
- Multiple variants for different scenarios
- Example: `templates/feature.md`, `templates/bugfix.md`

**scripts/**: Helper automation scripts

- Bash/Python scripts for verification or analysis
- Should be referenced from main SKILL.md
- Example: `scripts/verify-feature.sh`, `scripts/analyze-pr.sh`

**README.md**: User-facing documentation (optional)

- How to use the skill
- Examples and common scenarios
- Not loaded by Claude automatically

## Best Practices

### Keep SKILL.md Under 500 Lines

- Main workflow should be concise and scannable
- Move detailed examples to `resources/`
- Move templates to `templates/`
- Move scripts to `scripts/`
- Link to supporting files from main SKILL.md

### Use Progressive Disclosure

Don't load everything upfront:

- **Tier 1**: Frontmatter (name, description, version) - always visible
- **Tier 2**: Main SKILL.md content - loaded on invocation
- **Tier 3**: Supporting files - loaded only when referenced

Example from pr-update:

```markdown
## PR Title Formats

See [resources/title-patterns.md](resources/title-patterns.md) for comprehensive title format examples.

Quick reference:
- Infrastructure: "Enterprise [resource] with [key feature]"
- Features: "Add [feature] with [benefit]"
```

### Test Across Models

Skills should work with:

- Claude Opus (primary - efficient compared to sonnet 4.5 - complex reasoning)
- Claude Haiku (efficiency-focused)

Test that your skill:

- Provides clear instructions
- Handles model limitations gracefully
- Works with different context window sizes

### Version Tracking

Use semantic versioning:

- **1.0.0**: Initial stable release
- **1.1.0**: New features, backward compatible
- **2.0.0**: Breaking changes to skill interface

Update version when:

- Changing skill behavior significantly
- Modifying frontmatter structure
- Adding/removing required steps
- Changing invocation triggers

### Documentation Standards

- Use clear, imperative language
- Provide concrete examples
- Include verification steps
- Document error handling
- Link to external standards (e.g., `~/.claude/standards/semver.md`)

### Quality Gates

Every skill should define:

- Success criteria (checklist format)
- Validation requirements
- Error handling procedures
- Rollback plans (when applicable)

Example from dependency-updater:

```markdown
## Quality Standards

Each phase must meet:

- ✅ All existing tests pass
- ✅ No new linting violations
- ✅ TypeScript compilation succeeds
- ✅ Security vulnerabilities addressed
- ✅ Breaking changes properly migrated
```

## Skill Scopes

Skills can exist at three levels:

### Personal Skills

**Location**: `~/.claude/skills/`

**Scope**: Available to you across all projects

**Use Cases**:

- Personal workflow preferences
- Cross-project automation
- Reusable patterns you use frequently

**Examples**: dependency-updater, pr-update

### Project Skills

**Location**: `<project>/.claude/skills/`

**Scope**: Available only within that project

**Use Cases**:

- Project-specific workflows
- Domain-specific operations
- Team-shared processes

**Examples**: Project-specific deployment, custom test workflows

### Plugin Skills

**Location**: Claude Skills Marketplace

**Scope**: Published, community-maintained skills

**Use Cases**:

- Industry-standard workflows
- Popular framework integrations
- Shared best practices

**Examples**: (As marketplace develops in late 2025)

### Precedence Rules

When multiple skills have the same name:

1. Project skills (`.claude/skills/`) - highest priority
2. Personal skills (`~/.claude/skills/`)
3. Plugin skills (marketplace) - lowest priority

## Resources

### Official Documentation

- [Claude Skills Documentation](https://docs.anthropic.com/claude/docs/skills) - Official skill creation guide
- [Claude Agent SDK](https://docs.anthropic.com/claude/docs/agent-sdk) - Technical reference
- [Progressive Disclosure Best Practices](https://docs.anthropic.com/claude/docs/progressive-disclosure) - Context optimization

### Example Skills

- [dependency-updater](dependency-updater/SKILL.md) - Complex orchestration with agent delegation
- [pr-update](pr-update/SKILL.md) - Git analysis with verification and templates

### Related Standards

Referenced by skills in this directory:

- [~/.claude/standards/semver.md](../standards/semver.md) - Semantic version classification
- [~/.claude/standards/git.md](../standards/git.md) - Git commit and PR conventions
- [~/.claude/standards/agent-coordination.md](../standards/agent-coordination.md) - Parallel vs sequential execution

### Community Resources

- [Claude Skills Marketplace](https://claude.com/skills) - Browse and share skills (coming late 2025)
- [Skills Examples Repository](https://github.com/anthropics/claude-skills-examples) - Community examples
- [Skills Best Practices Guide](https://docs.anthropic.com/claude/guides/skills-best-practices) - Advanced patterns

---

**Need Help?**

- Review existing skills in this directory for patterns
- Check official documentation for latest features
- Test your skill with different scenarios before committing
- Version your skills to track changes over time
