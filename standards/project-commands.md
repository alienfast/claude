# Project Commands Standard

## Overview

Projects often define custom scripts in package.json that wrap standard tools with project-specific configurations. Always prefer these project commands over running tools directly.

## Command Discovery

Before running generic commands, check for project-specific scripts:

1. Read package.json scripts section
2. Use project commands over generic tools

## Common Patterns

### Type Checking

- ✓ PREFER: `pnpm check-types` (if available)
- ✗ AVOID: `tsc` directly

### Linting

- ✓ PREFER: `pnpm check` or `pnpm lint` (if available)
- ✗ AVOID: `eslint` directly

### Markdown Linting

- ✓ PREFER: `pnpm check-markdown` (if available)
- ✗ AVOID: `markdownlint` directly

### Auto-fixing checkers apply changes as they report them

`pnpm check` typically fans out to write-mode variants (`biome check --write`, `markdownlint-cli2 --fix`) that
**mutate files in place**. Their diagnostic output describes fixes **already applied** — formatting, import
organization, key sorting — not a TODO list. Two consequences:

- After running one, your in-memory view of any file it changed is **stale**. Re-read before editing it.
- Never hand-edit to satisfy a fix the tool already wrote — the Edit is built from pre-fix text and fails to
  match. Only hand-fix diagnostics the tool reports as **not auto-fixable**.

The auto-injected `rules/biome.md` and `rules/markdown.md` carry this same guidance at edit time.

### Testing

- ✓ PREFER: `pnpm test` or project-specific test scripts
- ✗ AVOID: `jest` or test runners directly

### Build

- ✓ PREFER: `pnpm build`
- ✗ AVOID: Tool-specific build commands

## Discovery Process

When entering a new project or before running a command:

```bash
# Check available scripts
cat package.json | jq '.scripts'
```

If jq is not available:

```bash
# Alternative: read package.json directly
cat package.json
```

Use the project's defined scripts to ensure consistent behavior with the team's workflow.

## Rationale

Project scripts often include:

- Correct tool configurations
- Pre/post processing steps
- Environment setup
- Multiple tools in sequence
- Project-specific flags and options

Using project scripts ensures you're running commands exactly as the team intends.
