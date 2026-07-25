# Project Commands Standard

Read `package.json`'s `scripts` before reaching for a tool directly, and run the project script when
one exists. Scripts carry the config paths, pre/post steps, environment setup, ordering, and flags
the team relies on — invoking the underlying tool bypasses all of it and produces results that
disagree with CI.

| Task | Use | Not |
|---|---|---|
| Type checking | `pnpm check-types` | `tsc` |
| Linting | `pnpm check` / `pnpm lint` | `eslint`, `biome` |
| Markdown | `pnpm check-markdown` | `markdownlint` |
| Tests | `pnpm test` | `jest`, `vitest` |
| Build | `pnpm build` | tool-specific build commands |

Direct invocation is correct only when no script covers what you need — a one-off flag, a single
file, a diagnostic run.

## Auto-fixing checkers apply changes as they report them

`pnpm check` typically fans out to write-mode variants (`biome check --write`, `markdownlint-cli2 --fix`)
that mutate files in place, so their output describes fixes **already applied**, not a TODO list.
Re-read before editing a file one of them touched, and never hand-edit to redo a fix it already
wrote. Full guidance auto-injects at edit time — see [biome rules](../rules/biome.md) and
[markdown rules](../rules/markdown.md).
