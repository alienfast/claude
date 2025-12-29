---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---

# React Rules

## Modern Patterns (React 19+)

- **Components**: Function components only (class components deprecated)
- **State**: `useState` (local), `useReducer` (complex state), `useActionState` (form actions)
- **Data fetching**: `use()` hook for promises (React 19+), custom hooks for data fetching
- **Performance**: `memo()`, `useMemo()`, `useCallback()` when needed
- **Composition**: Prefer over inheritance, compound patterns (Card.Header, Card.Body)
- **Imports**: Named imports only - `import { useState, useEffect } from 'react'`
- **Legacy imports**: ALWAYS replace `import * as React from 'react'` and `import React from 'react'` with named imports

## Custom Hooks Best Practices

- **Naming**: Always prefix with `use` if calling other hooks
- **Purpose-specific**: Name hooks after their purpose (e.g., `useChatRoom`, `useAuth`)
- **No lifecycle hooks**: Avoid generic hooks like `useMount` - be specific about dependencies
- **Function stability**: Wrap returned functions with `useCallback` for performance

## Effect Dependencies & Performance

- **Dependencies**: Always include all dependencies in `useEffect` arrays
- **Functions in effects**: Define functions inside `useEffect` to avoid `useCallback`
- **Objects in effects**: Create objects inside `useEffect` to avoid `useMemo`
- **No dependency suppression**: Never suppress `exhaustive-deps` linter warnings

## Anti-Patterns to Avoid

- ❌ Class components (use function components)
- ❌ Generic lifecycle hooks (`useMount`, `useUnmount`)
- ❌ Higher-order hooks or passing hooks as props
- ❌ Suppressing dependency linter warnings
- ❌ Chaining effects to update interdependent state
- ❌ Creating objects/functions in dependency arrays without memoization
- ❌ `forwardRef` (deprecated in React 19+, use `ref` prop directly)
- ❌ Legacy React imports (`import * as React` or `import React`) - use named imports
