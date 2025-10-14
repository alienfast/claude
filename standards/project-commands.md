# Project Commands Standard

## Overview

Projects often define custom scripts in package.json that wrap standard tools with project-specific configurations. Always prefer these project commands over running tools directly.

## Command Discovery

Before running generic commands, check for project-specific scripts:

1. Read package.json scripts section
2. Use project commands over generic tools

## Common Patterns

### Type Checking

- ✓ PREFER: `yarn check-types` (if available)
- ✗ AVOID: `tsc` directly

### Linting

- ✓ PREFER: `yarn check` or `yarn lint` (if available)
- ✗ AVOID: `eslint` directly

### Markdown Linting

- ✓ PREFER: `yarn check-markdown` (if available)
- ✗ AVOID: `markdownlint` directly

### Testing

- ✓ PREFER: `yarn test` or project-specific test scripts
- ✗ AVOID: `jest` or test runners directly

### Build

- ✓ PREFER: `yarn build`
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
