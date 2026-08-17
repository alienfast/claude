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
