---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---

# React Rules

## Modern Patterns (React 19+)

- **Components**: Arrow function components: `const X = () =>`. Class components deprecated.
- **State**: `useState` (local), `useReducer` (complex state), `useActionState` (form actions)
- **Data fetching**: `use()` hook for promises (React 19+), custom hooks for data fetching
- **Composition**: Prefer over inheritance, compound patterns (Card.Header, Card.Body)
- **Imports**: Named imports only - `import { useState, useEffect } from 'react'`
- **Legacy imports**: ALWAYS replace `import * as React from 'react'` and `import React from 'react'` with named imports

## Naming Conventions

- **Handler naming**: `handleX` for internal event handlers, `onX` for callback prop names
- **Hook naming**: Always prefix with `use` if calling other hooks
- **Purpose-specific hooks**: Name after purpose (e.g., `useChatRoom`, `useAuth`), not lifecycle (`useMount`)

## Memoization

Use memoization only when there is a measured performance need or a specific technical requirement:

- **`memo()`**: Wrap with named function expression for DevTools: `export const X = memo(function X(...) { })`
- **`useCallback`**: Only when passing to `memo()` children, used as hook dependencies, or returned from custom hooks. Do NOT wrap handlers passed to plain DOM elements or non-memo components.
- **`useMemo`**: Only for expensive computations (>1ms), stabilizing props for `memo()` children, or values used as hook dependencies. Do NOT use for trivial calculations.
- **State updater functions**: Use updater form in `useCallback` (`setItems(prev => [...prev, item])`) to avoid including state in dependency arrays
- **Incomplete memoization chain**: If a component is wrapped with `memo()`, ALL props passed to it must be stable (memoized or primitive). Memoizing some props but not all silently breaks `memo()`.

## Effect Dependencies

- **Dependencies**: Always include all dependencies in `useEffect` arrays
- **Functions in effects**: Define functions inside `useEffect` to avoid `useCallback`
- **Objects in effects**: Create objects inside `useEffect` to avoid `useMemo`
- **No dependency suppression**: Never suppress `exhaustive-deps` linter warnings

## Anti-Patterns

- ❌ Class components (use function components)
- ❌ Generic lifecycle hooks (`useMount`, `useUnmount`)
- ❌ Higher-order hooks or passing hooks as props
- ❌ Suppressing dependency linter warnings
- ❌ Chaining effects to update interdependent state
- ❌ Creating objects/functions in dependency arrays without memoization
- ❌ `forwardRef` (deprecated in React 19+, use `ref` prop directly)
- ❌ Legacy React imports (`import * as React` or `import React`) - use named imports
- ❌ Wrapping every handler with `useCallback` — only when child is `memo()` or function is a dependency
