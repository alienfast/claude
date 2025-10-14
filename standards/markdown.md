# Markdown Standards

## Linting

- **ALWAYS** run the project's markdown linting command after creating or modifying ANY markdown file
- Common commands to check for:
  - `yarn check-markdown`
  - `npm run check-markdown`
  - `markdownlint`
- Fix ALL linting errors before considering the task complete
- Never leave markdown files with linting errors

## Process

1. Create or modify markdown file
2. Immediately run the linting command
3. Fix any errors reported
4. Verify the linting passes with no errors

## Common Linting Rules

- Add language specifiers to fenced code blocks (e.g., ` ```bash `, ` ```typescript `, ` ```text `)
- Maintain consistent heading hierarchy
- Ensure proper spacing around headings and lists
- Follow the project's specific markdown style guide if present

## When to Apply

- Creating new `.md` files
- Editing existing `.md` files
- Before committing markdown changes
- As part of code review

This is a critical step that must not be skipped or forgotten.
