---
paths:
  - "**/*.md"
  - "**/*.mdx"
---

# Markdown Rules

## Lint-gated conventions

These four are what `markdownlint-cli2` fails CI on:

- **Tag every code block** with a language; default to `text` when none fits. Common tags:
  `typescript`, `json`, `bash`, `yaml`, `text`, `console` for terminal output, `diff` for changes.
- **Close fences bare** — three backticks, never the language specifier repeated.
- **Headings, not bold text**, for section titles.
- **Sequential list numbering** — `1.`, `2.`, `3.`, not resumed from a previous list.

## Lint auto-fixes are already applied — don't reapply them by hand

A markdown auto-fixer (`markdownlint-cli2 --fix`, or a `check-markdown` script wrapping it) **modifies files
in place**. Its output reports fixes it **already made**, not pending work. After running it, your in-memory
copy of any file it fixed is **stale** — re-read before your next `Edit`, and don't issue an Edit to redo a
fix it already wrote (the pre-fix `old_string` won't match). Same caveat for Biome — see [biome rules](biome.md).
