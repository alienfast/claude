# React Standards

## Modern Patterns

- **Components**: Function components only
- **State**: `useState` (local), `useReducer` (complex), `use()` for promises
- **Performance**: `React.memo()`, `useMemo()`, `useCallback()` when needed
- **Composition**: Prefer over inheritance, compound patterns (Card.Header, Card.Body)
- **Imports**: Prefer to import React functions as a named import and use them directly e.g. `useMemo` instead of `React.useMemo`

## Hooks & Data Patterns

```typescript
// Custom hook
function useAuth() {
  const [user, setUser] = useState<User | null>(null)
  return { user, login, logout }
}
```

## Performance

- **Code splitting**: react `lazy()` + Suspense for routes
- **Lists**: Virtual scrolling for 1000+ items
- **Cleanup**: Remove listeners in `useEffect` cleanup
- **Bundle**: Dynamic imports for heavy components

## React Code Quality Checklist

- ✅ Implements TypeScript interfaces for all props
- ✅ Includes comprehensive test coverage
