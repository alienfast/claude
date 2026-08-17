---
paths:
  - "**/*.md"
  - "**/*.mdx"
---

# Markdown Rules

## Lint-gated conventions

`markdownlint-cli2` gates on a husky pre-commit hook and `pnpm check` — no CI job runs it. Two rules reach
that gate, and neither has an autofix, so you have to fix them yourself:

- **Tag every code block** with a language (MD040); default to `text` when none fits. Common tags:
  `typescript`, `json`, `bash`, `yaml`, `text`, `console` for terminal output, `diff` for changes.
- **Headings, not bold text**, for section titles (MD036).

`--fix` repairs the rest silently — both `check-markdown` scripts run it, so these never fail anything and
never need a hand-edit:

- **Sequential list numbering** (MD029) — `1.`, `2.`, `3.`, not resumed from a previous list.

House style, not a lint rule: **close fences bare** — three backticks, never the language specifier repeated.

## Lint auto-fixes are already applied — don't reapply them by hand

`markdownlint-cli2 --fix` (and any `check-markdown` script wrapping it) **modifies files in place**, so its
output is a record of fixes already made. Full rule — stale in-memory copies, re-reading before your next
`Edit` — in [biome rules](biome.md).
