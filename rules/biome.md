---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.json"
  - "**/*.jsonc"
---

# Biome Rules

Applies only when the project uses Biome — a `biome.json` / `biome.jsonc` is present. If it lints with
ESLint/Prettier instead, ignore this and follow that toolchain.

## Auto-fixes are already applied — don't reapply them by hand

When the project's check runs Biome in write mode (e.g. a `check` / `check-biome` script that calls
`biome check --write`), it **modifies files in place** as it reports. Formatting, **import organization**, and
**object key sorting** are auto-fix categories: after a `--write` run they are **already done on disk**.
Biome's diagnostics about those categories describe fixes it **already made**, not pending work.

So do **not** announce "Biome wants the keys sorted / imports organized — fixing" and issue an `Edit` to redo
it. The `old_string` in your context is the **pre-fix** text; disk is **post-fix**, so the Edit fails to match
— a wasted round trip on every auto-fixable finding.

## Re-read before editing a file you just checked

After running an auto-fixing checker, your in-memory copy of any file it fixed is **stale** — re-read before
your next `Edit`. The re-read is also how you see what's *actually* still flagged: `biome check --write`
applies only safe fixes, so a rule whose fix is **unsafe** stays reported even though it advertises one. Same
caveat for markdown — see [markdown rules](markdown.md).

## Only hand-fix what survived the write

Hand-edits are for whatever `--write` left behind — judge by what the re-read still shows, not by whether a
fix exists: genuine errors with no fix (e.g. `noDefaultExport`) and unsafe-fixable rules Biome won't apply
automatically. Don't disable a rule to make a finding go away; fix the code (see
[Problem-Solving Standards](../standards/problem-solving.md)).
