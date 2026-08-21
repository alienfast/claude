---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript Rules

## Import extensions

All relative imports carry the extension of the file they name — `.ts` / `.tsx`, not `.js`. The shared
`@alienfast/tsconfig` bases enable this (`allowImportingTsExtensions: true`, alongside `noEmit`), and the
build tooling (tsdown, native `tsc`) consumes the `.ts` form directly.

```typescript
import { UserService } from './services/user.ts'
import type { User } from './types/user.ts'
```

A project that does not set `allowImportingTsExtensions` — an older repo, or one emitting JS via `tsc` —
needs the `.js` specifier instead. Check the tsconfig before converting a repo either way.

## Import order

1. Node.js built-ins
2. External dependencies
3. Internal modules (absolute imports)
4. Relative imports

Biome's `organizeImports` owns import order — it is on house-wide and sorts alphabetically by specifier,
so don't hand-sort (type-only imports land wherever their specifier sorts, often first and interleaved).

## Type definitions

`interface` for object shapes that may be extended and for public/extensible contracts; `type` for
unions, intersections, primitives, and computed types.

## Escape hatches need a reason

`any`, `@ts-ignore`, non-null `!`, and `as` casts are all ways of telling the compiler to stop
checking. Reach for a type guard or an assertion function instead — validating external data is the
case they exist for. When one is genuinely unavoidable, the justification goes in the code, and
[Problem-Solving Standards](../standards/problem-solving.md) governs when it is allowed at all.

Public functions carry explicit return types. Prefer a specific signature over the bare `Function`
type.

## Adding a parameter: prefer required over optional-with-a-default

When a new parameter *selects between behaviors* and you cannot name one value right for every existing
call site — or would have to open them to find out — make it **required**. A default answers the question
on behalf of every existing caller, and nothing flags the one it answers wrongly: omitting a defaulted
parameter is not a type error under any TypeScript configuration (that is what optional means), and no
Biome rule inspects call sites for inherited defaults — every parameter-adjacent rule it ships constrains
the declaration site. The caller that should have changed keeps compiling, with the behavior you just
decided was incorrect.

Required makes `tsc` enumerate the call sites for you — the audit you would otherwise do by hand and could
not prove complete. Fixing them all is the expected cost, not a reason to reach for the default; see
[Technical Debt Prevention](../standards/technical-debt-prevention.md) § Breaking Changes Are Welcome.

A default is right when the parameter is genuinely additive and holds for every existing caller *by
construction* — an opt-in `signal`, a `dryRun` flag — not just for the callers you happened to open.

Measured 2026-08-19: a halt-message selector shipped as `options?: { provenPerDraft?: boolean }` defaulting
to `true`. That was right for the new call site and wrong for a pre-existing sibling passing a
group-level predicate, which kept compiling and kept telling an operator to hand-void a draft only
collectively implicated. It survived a full adversarial review cycle. Making the parameter required forced
all four call sites to be read and answered — two `true`, two `false`.
