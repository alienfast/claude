# Project Commands Standard

Read `package.json`'s `scripts` before reaching for a tool directly, and run the project script when
one exists. Scripts carry the config paths, pre/post steps, environment setup, ordering, and flags
the team relies on — invoking the underlying tool bypasses all of it and produces results that
disagree with CI.

| Task | Use | Not |
|---|---|---|
| Everything, as one gate | `pnpm check` | running the members individually |
| Type checking | `pnpm check-types` | `tsc`, `pnpm typecheck` (not a house script) |
| Linting/formatting | `pnpm check-biome` | `eslint`, `biome`, `pnpm lint` (not a house script) |
| Markdown | `pnpm check-markdown` | `markdownlint` |
| Tests | `pnpm test` | `jest`, `vitest` |
| Build | `pnpm build` | tool-specific build commands |

`pnpm check` is the aggregate gate, not a linter: the house suite fans it out to
`check-types check-biome check-circular check-markdown test` (see
[standardize-tooling](../skills/standardize-tooling/SKILL.md), which owns the canonical script set).
That fan-out is why "type checking is gated by `pnpm check`" is true even though no gate invokes
`check-types` by name — and why a project whose `check` omits `check-types` is not actually type-gated.

Direct invocation is correct only when no script covers what you need — a one-off flag, a single
file, a diagnostic run.

## Auto-fixing checkers apply changes as they report them

`pnpm check` typically fans out to write-mode variants (`biome check --write`, `markdownlint-cli2 --fix`)
that mutate files in place, so their output describes fixes **already applied**, not a TODO list.
Re-read before editing a file one of them touched, and never hand-edit to redo a fix it already
wrote. Full guidance auto-injects at edit time — see [biome rules](../rules/biome.md) and
[markdown rules](../rules/markdown.md).
