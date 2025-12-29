---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript Rules

## Core Principles

- **Type Safety First**: Leverage TypeScript's type system to catch errors at compile time
- **Explicit Over Implicit**: Prefer explicit type annotations when they improve code clarity
- **Consistency**: Follow existing codebase patterns and project conventions

## Type Definitions

### Interfaces vs Types

- Use `interface` for object shapes that may be extended
- Use `type` for unions, intersections, primitives, and computed types
- Prefer `interface` for public APIs and extensible contracts

```typescript
// ✅ Good - interface for extensible objects
interface User {
  id: string
  name: string
}

// ✅ Good - type for unions and computed types
type Status = 'pending' | 'approved' | 'rejected'
type UserWithStatus = User & { status: Status }
```

## Import/Export Conventions

### File Extensions

- All relative imports must include `.js` extensions for ESM compatibility
- Use explicit extensions even in TypeScript files for build tool compatibility

```typescript
// ✅ Good
import { UserService } from './services/user.js'
import type { User } from './types/user.js'

// ❌ Bad
import { UserService } from './services/user'
```

### Import Organization

1. Node.js built-ins
2. External dependencies
3. Internal modules (absolute imports)
4. Relative imports
5. Type-only imports last

## Runtime Safety

### Type Guards

- Implement type guards for external data validation
- Use assertion functions for invariants
- Prefer user-defined type guards over `any` assertions

```typescript
// ✅ Good - type guard
function isUser(obj: unknown): obj is User {
  return typeof obj === 'object' && obj !== null && 'id' in obj && 'name' in obj
}
```

## Anti-Patterns to Avoid

- ❌ Using `any` without justification
- ❌ Disabling TypeScript errors with `@ts-ignore`
- ❌ Non-null assertions (`!`) without certainty
- ❌ Casting with `as` instead of type guards
- ❌ Missing return type annotations on public functions
- ❌ Using `Function` type instead of specific function signatures
