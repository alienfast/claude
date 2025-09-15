# Git Standards

## Commit Messages and PR Descriptions

### CI Build Prevention

**CRITICAL**: Never include the phrase "skip ci" (or variations like `[skip ci]`, `[ci skip]`) in:

- Commit messages
- PR titles
- PR descriptions
- Any text that could be merged into the main branch

**Why**: When PRs are merged, commit messages become part of the main branch history. If any commit message contains "skip ci", it will prevent CI builds from running on the main branch.

### Safe Alternatives

Instead of mentioning CI skipping behavior, use these alternatives:

❌ **Don't write:**

- "Fixed linting issues (skip ci was used during development)"
- "Updated docs, originally committed with [skip ci]"
- "Minor changes that previously had ci skip"

✅ **Write instead:**

- "Fixed linting issues"
- "Updated documentation"
- "Minor formatting changes"

### Commit Message Guidelines

- Use imperative mood ("Add feature" not "Added feature")
- Keep first line under 50 characters
- Separate subject from body with blank line
- Focus on what and why, not how
- Avoid referencing CI behavior in commit messages

### PR Guidelines

- Summarize the overall change, not individual commit details
- Focus on the business value and technical impact
- Avoid mentioning development workflow details like CI skipping
- Use clear, descriptive titles that explain the change's purpose

## Branch Protection

These standards help ensure:

- Main branch always has functioning CI
- Clean, professional commit history
- No accidental CI bypasses in production code
