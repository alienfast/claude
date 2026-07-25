---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript Rules

## Import extensions

All relative imports carry a `.js` extension, including in `.ts` files — ESM resolution and the build
tooling both require it.

```typescript
import { UserService } from './services/user.js'
import type { User } from './types/user.js'
```

## Import order

1. Node.js built-ins
2. External dependencies
3. Internal modules (absolute imports)
4. Relative imports
5. Type-only imports last

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
