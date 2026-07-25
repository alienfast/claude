# Deprecation Handling

## New code never uses a deprecated API

Use the replacement named in the deprecation notice. Where several alternatives exist, take the most
stable and best-documented one. Compiler and lint output is the detection surface — a deprecation
warning in `pnpm check` is a finding, not noise.

## Existing code gets fixed on contact

Update deprecated usage in any file you touch, even when it is unrelated to the change you came for.
This is explicitly in scope and must not be classified as churn.

- **Simple deprecations** — renamed functions, moved import paths, changed config keys — fix now, in
  the same commit.
- **Architectural deprecations** that need real refactoring — file a separate issue, and leave a
  one-line pointer at the site per [rules/comments.md](../rules/comments.md). Record what blocks the
  migration (a dependency, a breaking change, an unfinished upgrade), not a restatement of the
  deprecation.

## Priority

| Level | Cases |
|---|---|
| **Immediate** | Security vulnerabilities; APIs removed in the next major; performance-critical paths |
| **When touching the file** | Direct replacements, import path changes, deprecated config options |
| **Plan as separate work** | Anything needing architectural change or broad refactoring |
| **Monitor** | Distant sunset dates, style-only deprecations |

## The four evasions

None of these count as handling a deprecation:

1. **Pinning or downgrading** a dependency to avoid the migration.
2. **Suppressing the warning** — `@ts-ignore`, an eslint-disable, a silenced console — without
   fixing the call.
3. **Conditional imports** that keep the old API alive on some paths. Migrate every call site;
   a partial migration is the deprecation plus a branch.
4. **"It still works."** True and irrelevant — it works until the major that removes it.

These are the deprecation-specific forms of the workaround anti-patterns in
[Problem-Solving Standards](problem-solving.md). Detecting versions accurately is
[Version-Aware Planning](version-aware-planning.md).
