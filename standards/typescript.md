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
- Always use project's designated package manager for manual type checks
- Use project-specific TypeScript version

```bash
# ✅ Good - manual checks
yarn build
yarn typecheck
yarn tsc

# ❌ Bad - global tsc
tsc
```

### Automatic Type Checking

Type checking is automatically handled by the global Stop hook (`~/.claude/hooks/typecheck.sh`):

- Runs `npx tsc -b` (for projects with references) or `npx tsc` (standard projects)
- Triggers after all edits in a response are complete
- Only runs when TypeScript files are edited
- Provides immediate type feedback

**Note**: The hook uses `npx tsc` to ensure it uses the project's TypeScript version from `node_modules`. Manual checks should still use project scripts (e.g., `yarn typecheck`) when you need the full suite including circular dependency detection.

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

## Anti-Patterns to Avoid

### ❌ Type Safety Compromises

These workarounds undermine TypeScript's value and should never be suggested without explicit justification:

1. **Excessive `any` Usage**

   ```typescript
   // DON'T: Use 'any' to bypass type errors
   const data: any = fetchData()
   const result: any = data.someMethod()
   ```

   ✅ Instead: Define proper types or use `unknown` with type guards

   ```typescript
   const data: unknown = fetchData()
   if (isValidData(data)) {
     const result = data.someMethod()
   }
   ```

2. **Non-null Assertions Without Verification**

   ```typescript
   // DON'T: Assert non-null without checking
   user.profile!.email // Might be undefined
   config.apiKey! // Might not exist
   ```

   ✅ Instead: Use optional chaining or proper guards

   ```typescript
   user.profile?.email ?? 'default@example.com'

   if (!config.apiKey) {
     throw new Error('API key required')
   }
   const apiKey = config.apiKey
   ```

3. **Type Casting to Resolve Errors**

   ```typescript
   // DON'T: Cast to bypass incompatible types
   const result = (badType as GoodType).method()
   const data = response as ExpectedFormat
   ```

   ✅ Instead: Fix the type definitions or data structure

   ```typescript
   // Option 1: Fix the source types
   function processData(data: GoodType) {
     return data.method()
   }

   // Option 2: Use type guards for runtime validation
   function isExpectedFormat(data: unknown): data is ExpectedFormat {
     return typeof data === 'object' && /* validation */
   }

   if (isExpectedFormat(response)) {
     const data = response
   }
   ```

4. **Suppressing TypeScript Errors**

   ```typescript
   // DON'T: Hide errors without fixing
   // @ts-ignore
   problematicCode()

   // @ts-expect-error
   anotherIssue()
   ```

   ✅ Instead: Fix the underlying type issue

   ```typescript
   // Properly type the function or fix the types
   properlyTypedCode()
   ```

   Exception: Third-party library has broken types (must document and report upstream)

   ```typescript
   // @ts-expect-error - Bug in @types/library-name v1.2.3
   // Reported: https://github.com/DefinitelyTyped/issues/12345
   libraryFunctionWithBrokenTypes()
   ```

5. **Overly Permissive Function Signatures**

   ```typescript
   // DON'T: Use Function type or loose signatures
   function execute(callback: Function) {
     callback()
   }
   ```

   ✅ Instead: Define specific function signatures

   ```typescript
   function execute(callback: (data: string) => void) {
     callback('data')
   }
   ```

### When You Encounter Type Errors

If you face TypeScript errors:

1. **Understand the error** - Read the full error message
2. **Fix the types** - Update type definitions to match reality
3. **Add type guards** - Validate runtime data properly
4. **Never use workarounds** - No `any`, no `as`, no `@ts-ignore` without justification

### Common Patterns

- ❌ Using `any` without justification
- ❌ Disabling TypeScript errors with `@ts-ignore`
- ❌ Non-null assertions (`!`) without certainty
- ❌ Casting with `as` instead of type guards
- ❌ Overly complex type definitions
- ❌ Missing return type annotations on public functions
- ❌ Using `Function` type instead of specific function signatures
