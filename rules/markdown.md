---
paths:
  - "**/*.md"
  - "**/*.mdx"
---

# Markdown Rules

## Critical Rules (Prevent CI Failures)

### Always Include Language in Code Blocks

````markdown
<!-- Wrong -->
```
code here
```

<!-- Correct -->
```javascript
code here
```
````

**Default to `text` if unsure about the language.**

### Code Block Closing Syntax

**IMPORTANT**: Code blocks ALWAYS close with just three backticks (` ``` `), NOT with the language specifier repeated.

````markdown
<!-- Wrong -->
```text
some content
```text

<!-- Correct -->
```text
some content
```
````

### Use Proper Headings (Not Bold Text)

```markdown
<!-- Wrong -->
**Section Title**

<!-- Correct -->
### Section Title
```

### Use Sequential List Numbering

```markdown
<!-- Wrong -->
4. Item
5. Item

<!-- Correct -->
1. Item
2. Item
```

## Common Language Specifiers

- `javascript`, `typescript`, `json`, `bash`, `yaml`, `text`
- `python`, `ruby`, `go`, `rust`, `html`, `css`, `sql`
- `console` for terminal output, `diff` for file changes

## Lint auto-fixes are already applied — don't reapply them by hand

A markdown auto-fixer (`markdownlint-cli2 --fix`, or a `check-markdown` script wrapping it) **modifies files
in place**. Its output reports fixes it **already made**, not pending work. After running it, your in-memory
copy of any file it fixed is **stale** — re-read before your next `Edit`, and don't issue an Edit to redo a
fix it already wrote (the pre-fix `old_string` won't match). Same caveat for Biome — see [biome rules](biome.md).
