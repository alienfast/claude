# TypeScript Standards

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

### Naming Conventions

- PascalCase for types, interfaces, enums, and classes
- camelCase for variables, functions, and methods
- SCREAMING_SNAKE_CASE for constants
- Prefix interfaces with `I` only if needed to distinguish from classes

```typescript
// ✅ Good
interface UserConfig {
  apiKey: string
  retryCount: number
}

type DatabaseConnection = {
  host: string
  port: number
}

const MAX_RETRY_ATTEMPTS = 3
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

```typescript
// ✅ Good import order
import { readFile } from 'fs/promises'
import express from 'express'
import { config } from '@/config.js'
import { validateUser } from '../utils/validation.js'
import type { User, UserConfig } from './types.js'
```

## Strict Mode Configuration

### Required tsconfig.json Settings

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true
  }
}
```

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

// ✅ Good - assertion function
function assertIsString(value: unknown): asserts value is string {
  if (typeof value !== 'string') {
    throw new Error('Expected string')
  }
}
```

### Error Handling

- Use discriminated unions for error states
- Avoid throwing errors in pure functions when possible
- Prefer Result types for operations that can fail

```typescript
// ✅ Good - Result type pattern
type Result<T, E = Error> = { success: true; data: T } | { success: false; error: E }

async function fetchUser(id: string): Promise<Result<User>> {
  try {
    const user = await api.getUser(id)
    return { success: true, data: user }
  } catch (error) {
    return { success: false, error: error as Error }
  }
}
```

## Documentation

### JSDoc Requirements

- Document all public APIs
- Include parameter and return type descriptions
- Add `@example` blocks for complex functions
- Use `@deprecated` for obsolete code

````typescript
/**
 * Processes user data and returns normalized result
 * @param rawUser - Raw user data from external API
 * @param options - Processing configuration options
 * @returns Promise resolving to processed user data
 * @throws {ValidationError} When user data is invalid
 * @example
 * ```typescript
 * const user = await processUser(rawData, { normalize: true });
 * ```
 */
async function processUser(rawUser: unknown, options: ProcessOptions): Promise<User> {
  // implementation
}
````

## Utility Types

### Prefer Built-in Utility Types

- Use TypeScript's built-in utility types when appropriate
- Create custom utility types for domain-specific needs

```typescript
// ✅ Good - using built-in utilities
type PartialUser = Partial<User>
type UserEmail = Pick<User, 'email'>
type CreateUserRequest = Omit<User, 'id' | 'createdAt'>

// ✅ Good - custom utility for domain needs
type NonEmptyArray<T> = [T, ...T[]]
```

## Build and Compilation

### Project Commands

- NEVER use global `tsc` command
- Always use project's designated package manager
- Use project-specific TypeScript version

```bash
# ✅ Good
yarn build
yarn typecheck
yarn tsc

# ❌ Bad
tsc
npx tsc
```

## Code Quality Checklist

Before submitting TypeScript code, ensure:

- ✅ Follows TypeScript strict mode requirements
- ✅ All types are explicitly defined or properly inferred
- ✅ No `any` types without justification
- ✅ Uses project-standard imports with proper extensions
- ✅ Passes all ESLint and TypeScript compiler checks
- ✅ Type guards implemented for runtime validation
- ✅ JSDoc documentation for public APIs
- ✅ Proper error handling with typed errors
- ✅ Consistent naming conventions followed
- ✅ No unused imports or variables
- ✅ Generic types parameterized appropriately

## Common Anti-Patterns to Avoid

- ❌ Using `any` without justification
- ❌ Disabling TypeScript errors with `@ts-ignore`
- ❌ Non-null assertions (`!`) without certainty
- ❌ Casting with `as` instead of type guards
- ❌ Overly complex type definitions
- ❌ Missing return type annotations on public functions
- ❌ Using `Function` type instead of specific function signatures
