# PR Title and Description Generator

Version: 1.0.0

Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state.

## Usage

This skill is automatically triggered when you mention:

- "update the PR"
- "generate PR description"
- "write PR title"
- "update pull request"

## Core Principle

**Document ONLY what exists in the final state of the code, not the development history.**

Always verify features exist in `HEAD` before documenting them. If a feature was added and then removed during development, it should NOT appear in the PR description.

## Structure

```
pr-update/
├── SKILL.md              # Main skill instructions
├── README.md             # This file
├── resources/            # Extended documentation
│   ├── analysis-workflow.md   # Step-by-step verification examples
│   └── title-patterns.md      # Comprehensive title format guide
├── templates/            # PR description templates
│   ├── feature.md             # Template for feature PRs
│   ├── bugfix.md              # Template for bug fix PRs
│   └── infrastructure.md      # Template for infrastructure PRs
└── scripts/              # Helper scripts
    └── verify-feature.sh      # Verify features exist in HEAD
```

## Resources

### [resources/analysis-workflow.md](resources/analysis-workflow.md)

Step-by-step examples showing how to:

- Analyze PR scope and identify changed areas
- Verify infrastructure changes exist
- Check documentation structure
- Verify CI/CD changes
- Validate developer tooling updates

### [resources/title-patterns.md](resources/title-patterns.md)

Comprehensive guide to PR title formats including:

- Infrastructure changes
- Feature additions
- Bug fixes
- Refactoring
- Performance improvements
- Documentation updates
- Anti-patterns to avoid

## Templates

### [templates/feature.md](templates/feature.md)

Complete template for feature PRs including:

- Feature overview and justification
- User experience before/after
- API changes and examples
- Configuration requirements
- Testing strategy
- Security considerations
- Rollout plan

### [templates/bugfix.md](templates/bugfix.md)

Complete template for bug fix PRs including:

- Problem description and symptoms
- Root cause analysis
- Solution explanation
- Code before/after comparison
- Impact analysis
- Regression tests
- Monitoring and rollback plan

### [templates/infrastructure.md](templates/infrastructure.md)

Complete template for infrastructure PRs including:

- Infrastructure overview and architecture
- Resource configuration
- Deployment steps and stack commands
- High availability and disaster recovery
- Security and compliance
- Cost impact analysis
- Performance benchmarks

## Scripts

### [scripts/verify-feature.sh](scripts/verify-feature.sh)

Bash script to verify features exist in the final state of HEAD.

**Usage**:

```bash
# Check if a function exists
./scripts/verify-feature.sh src/utils.ts "function myFunction"

# Check for a configuration value
./scripts/verify-feature.sh config/database.ts "authentication_plugin"

# Check if a file exists at all
./scripts/verify-feature.sh packages/api/README.md ""
```

**Returns**:

- Exit code 0: Feature found in HEAD
- Exit code 1: Feature NOT found in HEAD

## Quality Checklist

Before finalizing any PR description, verify:

- Every feature mentioned exists in `git show HEAD:path/to/file`
- No references to features that were added then removed
- All file links use relative paths from repo root
- Configuration examples reflect actual current state
- Breaking changes clearly marked
- Testing sections describe actual passing tests
- Code snippets are from actual files in HEAD

## Development

To update this skill:

1. Edit `SKILL.md` for core instructions (keep under 500 lines)
2. Add detailed examples to `resources/` for progressive disclosure
3. Create new templates in `templates/` for specific PR types
4. Add helper scripts to `scripts/` for automation
5. Update this README to reflect changes
6. Increment version in `SKILL.md` frontmatter following semver

## Version History

- **1.0.0** (2025-10-22): Initial structured release with resources, templates, and scripts
