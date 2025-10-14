# Markdown Standards

## Linting

Check for project-specific markdown linting commands after creating or modifying markdown files:

1. Look for `check-markdown` or similar in package.json scripts
2. Run the project's linting command if available
3. Address any linting errors before completing the task

See [Project Commands Standard](./project-commands.md) for command discovery process.

## Common Linting Rules

- Add language specifiers to fenced code blocks (e.g., ` ```bash `, ` ```typescript `, ` ```text `)
- Maintain consistent heading hierarchy
- Ensure proper spacing around headings and lists
- Follow the project's specific markdown style guide if present

## When to Apply

- Creating new `.md` files
- Editing existing `.md` files
- Before committing markdown changes
