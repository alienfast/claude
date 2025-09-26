# React Standards

## Modern Patterns (React 19+)

- **Components**: Function components only (class components deprecated)
- **State**: `useState` (local), `useReducer` (complex state), `useActionState` (form actions)
- **Data fetching**: `use()` hook for promises (React 19+), custom hooks for data fetching
- **Performance**: `memo()`, `useMemo()`, `useCallback()` when needed
- **Composition**: Prefer over inheritance, compound patterns (Card.Header, Card.Body)
- **Imports**: Named imports only - `import { useState, useEffect } from 'react'`
- **Legacy imports**: ALWAYS replace `import * as React from 'react'` and `import React from 'react'` with named imports when encountered

## Custom Hooks Best Practices

- **Naming**: Always prefix with `use` if calling other hooks
- **Purpose-specific**: Name hooks after their purpose (e.g., `useChatRoom`, `useAuth`)
- **No lifecycle hooks**: Avoid generic hooks like `useMount` - be specific about dependencies
- **Function stability**: Wrap returned functions with `useCallback` for performance

```typescript
// ✅ Good: Purpose-specific custom hook
function useAuth() {
  const [user, setUser] = useState<User | null>(null)

  const login = useCallback(async (credentials) => {
    // login logic
  }, [])

  const logout = useCallback(() => {
    // logout logic
  }, [])

  return { user, login, logout }
}

// ✅ Good: Data fetching hook with cleanup
function useData(url: string) {
  const [data, setData] = useState(null)

  useEffect(() => {
    if (!url) return

    let ignore = false
    fetch(url)
      .then((response) => response.json())
      .then((json) => {
        if (!ignore) setData(json)
      })

    return () => {
      ignore = true
    }
  }, [url])

  return data
}
```

## Effect Dependencies & Performance

- **Dependencies**: Always include all dependencies in `useEffect` arrays
- **Functions in effects**: Define functions inside `useEffect` to avoid `useCallback`
- **Objects in effects**: Create objects inside `useEffect` to avoid `useMemo`
- **No dependency suppression**: Never suppress `exhaustive-deps` linter warnings

```typescript
// ✅ Good: Function defined inside effect
useEffect(() => {
  function createOptions() {
    return { serverUrl: 'localhost:1234', roomId }
  }

  const connection = createConnection(createOptions())
  connection.connect()
  return () => connection.disconnect()
}, [roomId]) // Only roomId needed as dependency

// 🔴 Avoid: Chaining effects for state updates
// Use state reducers or calculate during render instead
```

## Modern State Management

- **Local state**: `useState` for simple values
- **Complex state**: `useReducer` for state with multiple sub-values
- **Form actions**: `useActionState` for form submissions (React 19+)
- **Context**: Use with `useContext` for shared state, split contexts by concern

## Performance & Code Splitting

- **Code splitting**: `lazy()` + `Suspense` for route-based splitting
- **Lists**: Virtual scrolling for 1000+ items (react-window)
- **Cleanup**: Always cleanup subscriptions, timers, and event listeners
- **Bundle optimization**: Dynamic imports for heavy components

## Anti-Patterns to Avoid

- 🔴 Class components (use function components)
- 🔴 Generic lifecycle hooks (`useMount`, `useUnmount`)
- 🔴 Higher-order hooks or passing hooks as props
- 🔴 Suppressing dependency linter warnings
- 🔴 Chaining effects to update interdependent state
- 🔴 Creating objects/functions in dependency arrays without memoization
- 🔴 `forwardRef` (deprecated in React 19+, use `ref` prop directly)
- 🔴 Legacy React imports (`import * as React` or `import React`) - use named imports

## Code Quality Checklist

- ✅ TypeScript interfaces for all props and state
- ✅ Custom hooks for reusable stateful logic
- ✅ Proper dependency arrays in all effects
- ✅ Cleanup functions for side effects
- ✅ Meaningful component and hook names
- ✅ Error boundaries for error handling
