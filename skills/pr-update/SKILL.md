---
name: PR Title and Description Generator
version: "1.0.0"
description: "Generate or update GitHub Pull Request titles and descriptions based on actual code changes in the final state. Use when the user mentions updating, generating, or writing PR descriptions, PR titles, pull request summaries, or says 'update the PR'. Analyzes git diff to determine what's actually in the code (not just commit history) and creates comprehensive, accurate PR documentation."
---

# PR Title and Description Generator

Generate or update a PR title and description based on the actual changes in the current branch.

## Core Principle

**Document ONLY what exists in the final state of the code, not the development history.**

If a feature was added in one commit and removed in another, it should NOT be in the PR description. Always verify features exist in `HEAD` before documenting them.

## Analysis Process

### 1. Identify Current Branch and PR

```bash
git branch --show-current
gh pr view --json number,title,url
```

### 2. Analyze Final State Changes

```bash
# Get commit count
git log main..HEAD --oneline | wc -l

# Get file change summary
git diff main...HEAD --stat

# Identify major areas of change
git diff main...HEAD --name-only | cut -d/ -f1 | sort | uniq -c | sort -rn
```

### 3. Verify What's Actually in the Code

**CRITICAL**: For each area of apparent change, verify if it's in the final state:

```bash
# Check if a feature is in final code
git show HEAD:path/to/file.ts | grep -q "feature_name" && echo "PRESENT" || echo "REMOVED"

# Example: Check for authentication plugin
git show HEAD:cloud/database/src/SqlDatabase.ts | grep "authentication_plugin"

# Example: Check if a function exists
git show HEAD:src/utils.ts | grep -A10 "function myFunction"
```

**If a feature doesn't appear in the final state, DO NOT include it in the PR description.**

### 4. Categorize Changes by Impact

Organize changes into categories based on what's actually present:

- **Infrastructure Changes**: Cloud resources, deployments, architecture
- **Developer Experience**: Tooling, documentation, local development setup
- **CI/CD**: Pipeline changes, automation workflows
- **Breaking Changes**: API changes, configuration requirements, migration needs
- **Dependencies**: Package updates that remain in final package.json/lock files
- **Documentation**: New or updated docs (verify files exist)

### 5. Document Only Present Changes

For each change area:

1. **Verify existence**: Run `git show HEAD:path/to/file` to confirm
2. **Link to files**: Use markdown links with relative paths from repo root
   - Files: `[filename.ts](path/to/filename.ts)`
   - Specific lines: `[filename.ts:42](path/to/filename.ts#L42)`
   - Line ranges: `[filename.ts:42-51](path/to/filename.ts#L42-L51)`
3. **Include code snippets**: For configuration changes, show actual values
4. **Provide context**: Explain why the change was made, not just what changed

## Quality Verification Checklist

Before finalizing the description, verify:

- [ ] Every feature mentioned exists in `git show HEAD:path/to/file`
- [ ] No references to features that were added then removed during development
- [ ] All file links use relative paths from repo root (not absolute paths)
- [ ] Configuration examples reflect actual current state in HEAD
- [ ] Breaking changes are clearly marked with "Breaking Changes" section
- [ ] Testing sections describe actual tests that currently pass
- [ ] Code snippets are from actual files in HEAD, not from memory

## PR Title Formats

See [resources/title-patterns.md](resources/title-patterns.md) for comprehensive title format examples and patterns.

Quick reference:

- Infrastructure: "Enterprise [resource] with [key feature] and [secondary feature]"
- Features: "Add [feature] with [benefit]"
- Bug Fixes: "Fix [specific issue] in [area]"
- Refactoring: "Refactor [area] to [improvement]"

Avoid vague titles like "PR deployment", "Various fixes", or "Update code".

## Description Structure

For detailed templates, see:

- [templates/feature.md](templates/feature.md) - Feature additions
- [templates/bugfix.md](templates/bugfix.md) - Bug fixes
- [templates/infrastructure.md](templates/infrastructure.md) - Infrastructure changes

Use this general template structure:

```markdown
## Summary

[1-2 sentence overview of what this PR accomplishes and why]

## [Major Category 1 - e.g., Infrastructure Changes]

### [Subcategory - e.g., Cloud SQL Enterprise Plus]

**[Feature Name]:**
- [Implementation detail verified in HEAD]
- [Configuration detail with actual values]
- [Benefit or impact]

**Implementation:**
- File: [link to main file](path/to/file.ts)
- Configuration: [link to config](path/to/config.yaml)

**Stack Commands:**
- `./stack command_name` - Description

**Documentation:**
- [Link to relevant docs](doc/path/to/doc.md)

[Repeat structure for each major category]

## Breaking Changes

### [Area Affected]
- **What changed**: [Specific change]
- **Migration**: [Steps to migrate]
- **Impact**: [Who/what is affected]

## Dependencies

- Updated `package-name` to version X.Y.Z
- Added `new-package` for [specific purpose]
- Removed `old-package` (no longer needed)

## Testing

**[Test Category]:**
- ✅ [Specific test that validates the change]
- ✅ [Another specific test]
- ✅ [Integration test description]

**[Another Test Category]:**
- ✅ [Test description]

## Cost Impact

[If applicable - infrastructure cost changes]

**Production:**
- Current: $X/month
- Planned: $Y/month (with optimization Z)
- Benefit: [SLA/performance/reliability improvements]

**[Environment]:**
- Base: $X/month (shared infrastructure)
- Per-[unit]: +$Y/month

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## Verification Workflow

For step-by-step examples of how to analyze and verify PR changes, see [resources/analysis-workflow.md](resources/analysis-workflow.md).

You can also use the verification script:

```bash
# Check if a feature exists in final state
./scripts/verify-feature.sh path/to/file.ts "feature_name"

# Check if a file exists
./scripts/verify-feature.sh packages/api/README.md ""
```

## Important Rules

1. **Verify before documenting** - Always use `git show HEAD:file` to confirm features exist in final state
2. **Never mention removed features** - If a commit added something but it was later removed or reverted, don't include it
3. **Focus on outcomes, not process** - Describe the result, not the development journey
4. **Link to actual code** - Every major feature should have a file reference that users can click
5. **Be specific** - "Add MySQL native password authentication" not "Update database config"
6. **Test your claims** - If you say "CI runs connectivity checks", verify the CI file actually shows that
7. **Use present tense** - "Adds X", "Implements Y", not "Added X", "Implemented Y"
8. **Quantify when possible** - "3x performance improvement", "99.99% SLA", "$460/month cost"

## Common Mistakes to Avoid

### ❌ Documenting Removed Features

```
# Commit history shows:
# - Commit A: Add feature X
# - Commit B: Remove feature X
# Final state: No feature X

# WRONG: "Added feature X"
# RIGHT: Don't mention feature X at all
```

### ❌ Vague Descriptions

```
# WRONG: "Updated database configuration"
# RIGHT: "Set default_authentication_plugin to mysql_native_password for Cloud SQL Proxy v2 compatibility"
```

### ❌ Missing Verification

```
# WRONG: Assume a feature exists because you saw it in commit messages
# RIGHT: git show HEAD:path/to/file.ts | grep "feature_name"
```

### ❌ Broken Links

```
# WRONG: [config.ts](/Users/kross/project/src/config.ts)
# RIGHT: [config.ts](src/config.ts)
```

## After Generating Description

Update the PR using GitHub CLI:

```bash
gh pr edit <number> --title "Your Title Here" --body "$(cat <<'EOF'
[Your full description here]
EOF
)"
```

Confirm the update was successful:

```bash
gh pr view <number>
```
