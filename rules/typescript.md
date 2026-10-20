---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript Rules

## Import extensions

All relative imports carry the extension of the file they name, `.ts` / `.tsx`, not `.js`. The shared
`@alienfast/tsconfig` bases enable this (`allowImportingTsExtensions: true`, alongside `noEmit`), and the build tooling
(tsdown, native `tsc`) consumes the `.ts` form directly.

```typescript
import { UserService } from './services/user.ts'
import type { User } from './types/user.ts'
```

A project that does not set `allowImportingTsExtensions` (an older repo, or one emitting JS via `tsc`) needs the `.js`
specifier instead. Check the tsconfig before converting a repo either way.

## Import order

Biome's `organizeImports` owns import order (on house-wide, alphabetical by specifier), so don't hand-sort; type-only
imports land wherever their specifier sorts.

## Type definitions

`interface` for object shapes that may be extended and for public contracts; `type` for unions, intersections,
primitives and computed types. Public functions carry explicit return types; prefer a specific signature over `Function`.

## Escape hatches need a reason

`any`, `@ts-ignore`, non-null `!` and `as` casts tell the compiler to stop checking. Reach for a type guard or an
assertion function instead; validating external data is the case they exist for. When one is genuinely unavoidable, the
justification goes in the code, and [Problem-Solving Standards](../standards/problem-solving.md) governs whether it is
allowed at all.

## Adding a parameter: prefer required over optional-with-a-default

When a new parameter selects between behaviors and you cannot name one value right for every existing call site, make
it required. A default answers for every existing caller and nothing flags the one it answers wrongly: omitting a
defaulted parameter is not a type error, and no Biome rule inspects call sites for inherited defaults. Required makes
`tsc` enumerate the call sites, the audit you would otherwise do by hand and could not prove complete; fixing them all is
the expected cost ([Technical Debt Prevention](../standards/technical-debt-prevention.md) § Breaking Changes Are
Welcome). A default is right only when the parameter is additive and holds for every existing caller by construction
(an opt-in `signal`, a `dryRun` flag). A defaulted selector that was right for its new call site and wrong for a
pre-existing sibling has survived a full review cycle; making it required is what forced every call site to be read.

## A structural parameter type does not prevent a wrong value

Changing `qty: number` to `arg: { qty: number }` does not stop a caller passing the wrong field: the excess-property
check fires only on a fresh object literal, never on a variable, so `f({ qty: x.otherField })` and `f(x)` both compile.
Two things help, neither a signature-only edit: brand the field at its source (`type Qty = number & { readonly __qty:
unique symbol }`, which has to reach the producing type and is only as strong as the one cast that mints it), or remove
the choice from the call site by taking the whole object and letting the callee reach for its own field. Before
asserting that a type change makes a mistake impossible, write the mistake and run `tsc --noEmit` on it.

## Generated code

- After a codegen run rewrites generated TypeScript, the IDE's language server still serves the old types until it
  reloads, so `ide_diagnostics` on the next edit can describe the previous schema: phantom nullability errors, or silence
  on a field that just became nullable. Re-reading your file fixes nothing; the project's type check
  (`pnpm check-types`) is authoritative. Never silence one of these with `?.`, `!` or a guard.
- Anything that must decorate generated output (a banner, an injected key) is emitted by a generator plugin, never by a
  post-write hook: the generator compares plugin output against the file on disk and skips the write, hooks included,
  when they match, so a hook neither fires on a current tree nor restores what someone strips.

## File organization

- Directories are kebab-case; files are PascalCase for React components and camelCase for everything else. A directory
  that exists to hold one named module takes that module's name.
- A file is named after its primary export. A file whose primary export is a hook is `useX.ts` (`useX.tsx` if it renders
  JSX); a provider or utility module that also exports a hook is named after the provider or the concept.
- A directory earns its existence at three or more files or real sub-structure; a single file, or a component with its
  one `.graphql`, lives in the parent. Strip prefixes the path already carries (`domains/debt/series/form/`, not
  `domains/debt/series/debt-series-form/`).
- No generic `components/` bucket inside a domain or package; organize by concept. A framework's own private-folder
  convention (Next.js `_components/` under a route) is a scoping mechanism, not a bucket.
- Variant components (`Add`/`Edit`/`Create` of one entity) share an extracted body; two files that differ only in
  mutation wiring are one body not yet extracted.
