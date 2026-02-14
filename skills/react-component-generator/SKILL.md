# React Component Generator

---

name: "react-component-generator"
description: "Generates React components following established conventions. Use when creating new React components, hooks, or when refactoring existing components to match standards."
version: "1.0.0"
---

## Skill Purpose

Generate React components and hooks that follow modern React patterns (React 19+), TypeScript best practices, and established codebase conventions. This skill ensures consistency, type safety, and adherence to performance best practices.

## When to Invoke

- Creating new React function components
- Building custom hooks for reusable logic
- Refactoring class components to function components
- Converting legacy React code to modern patterns
- Ensuring components follow TypeScript and React standards

## Component Generation Workflow

### Step 1: Gather Requirements

Ask the user for:

1. **Component name** (e.g., UserProfile, ProductCard)
2. **Component type** (standard component, form, data display, etc.)
3. **Props** (what data does it receive?)
4. **State needs** (local state, complex state, form state?)
5. **Side effects** (API calls, subscriptions, timers?)
6. **Styling approach** (if applicable to project)

### Step 2: Create TypeScript Interface

```typescript
// Define props interface
interface ComponentNameProps {
  // Required props
  requiredProp: string

  // Optional props with default values
  optionalProp?: number

  // Event handlers
  onAction?: (data: DataType) => void

  // Children if needed
  children?: React.ReactNode
}
```

### Step 3: Generate Component Structure

```typescript
import { useState, useEffect, useCallback } from 'react'

interface ComponentNameProps {
  // Props interface here
}

export const ComponentName = ({
  requiredProp,
  optionalProp = defaultValue,
  onAction,
}: ComponentNameProps) => {
  // State declarations
  const [state, setState] = useState<StateType>(initialValue)

  // Effects with proper dependencies
  useEffect(() => {
    // Effect logic here

    return () => {
      // Cleanup logic
    }
  }, [dependencies])

  // Event handlers with useCallback
  const handleEvent = useCallback((param: ParamType) => {
    // Handler logic
    onAction?.(data)
  }, [onAction])

  // Render
  return (
    <div>
      {/* Component JSX */}
    </div>
  )
}
```

### Step 4: Apply Pattern-Specific Guidelines

#### For Simple Components

```typescript
interface GreetingProps {
  name: string
  greeting?: string
}

export const Greeting = ({ name, greeting = 'Hello' }: GreetingProps) => {
  return <div>{greeting}, {name}!</div>
}
```

#### For Components with Local State

```typescript
import { useState } from 'react'

interface CounterProps {
  initialValue?: number
  onCountChange?: (count: number) => void
}

export const Counter = ({ initialValue = 0, onCountChange }: CounterProps) => {
  const [count, setCount] = useState(initialValue)

  const increment = () => {
    const newCount = count + 1
    setCount(newCount)
    onCountChange?.(newCount)
  }

  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={increment}>Increment</button>
    </div>
  )
}
```

#### For Components with Complex State

```typescript
import { useReducer } from 'react'

interface FormState {
  name: string
  email: string
  submitted: boolean
}

type FormAction =
  | { type: 'UPDATE_NAME'; payload: string }
  | { type: 'UPDATE_EMAIL'; payload: string }
  | { type: 'SUBMIT' }
  | { type: 'RESET' }

function formReducer(state: FormState, action: FormAction): FormState {
  switch (action.type) {
    case 'UPDATE_NAME':
      return { ...state, name: action.payload }
    case 'UPDATE_EMAIL':
      return { ...state, email: action.payload }
    case 'SUBMIT':
      return { ...state, submitted: true }
    case 'RESET':
      return { name: '', email: '', submitted: false }
    default:
      return state
  }
}

export const ContactForm = () => {
  const [state, dispatch] = useReducer(formReducer, {
    name: '',
    email: '',
    submitted: false,
  })

  return (
    <form>
      {/* Form implementation */}
    </form>
  )
}
```

#### For Components with Effects

```typescript
import { useState, useEffect } from 'react'

interface UserDataProps {
  userId: string
}

interface User {
  id: string
  name: string
  email: string
}

export const UserData = ({ userId }: UserDataProps) => {
  const [user, setUser] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<Error | null>(null)

  useEffect(() => {
    if (!userId) return

    let ignore = false
    setLoading(true)

    fetch(`/api/users/${userId}`)
      .then((response) => response.json())
      .then((data) => {
        if (!ignore) {
          setUser(data)
          setLoading(false)
        }
      })
      .catch((err) => {
        if (!ignore) {
          setError(err)
          setLoading(false)
        }
      })

    return () => {
      ignore = true
    }
  }, [userId])

  if (loading) return <div>Loading...</div>
  if (error) return <div>Error: {error.message}</div>
  if (!user) return <div>No user found</div>

  return (
    <div>
      <h2>{user.name}</h2>
      <p>{user.email}</p>
    </div>
  )
}
```

## Custom Hook Generation

### When to Create a Hook

Create a custom hook when:

- Logic needs to be reused across multiple components
- State and effects are coupled and belong together
- Component logic becomes complex and needs extraction

### Hook Structure

```typescript
import { useState, useEffect, useCallback } from 'react'

interface UseDataOptions {
  initialValue?: DataType
  onError?: (error: Error) => void
}

export const useData = (url: string, options: UseDataOptions = {}) => {
  const [data, setData] = useState<DataType | null>(options.initialValue ?? null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<Error | null>(null)

  const refetch = useCallback(() => {
    if (!url) return

    let ignore = false
    setLoading(true)
    setError(null)

    fetch(url)
      .then((response) => response.json())
      .then((json) => {
        if (!ignore) {
          setData(json)
          setLoading(false)
        }
      })
      .catch((err) => {
        if (!ignore) {
          setError(err)
          setLoading(false)
          options.onError?.(err)
        }
      })

    return () => {
      ignore = true
    }
  }, [url, options.onError])

  useEffect(() => {
    refetch()
  }, [refetch])

  return { data, loading, error, refetch }
}
```

### Hook Naming

- **Always prefix with `use`** if the hook calls other React hooks
- **Be purpose-specific**: `useAuth`, `useChatRoom`, `useProductData`
- **Avoid generic names**: Not `useMount`, `useUnmount`, `useLifecycle`

### Hook Best Practices

1. **Wrap returned functions with `useCallback`** for performance
2. **Include all dependencies** in effect arrays
3. **Provide cleanup functions** for subscriptions, timers, listeners
4. **Define functions inside effects** to avoid extra `useCallback` dependencies
5. **Create objects inside effects** to avoid extra `useMemo` dependencies

## Import Patterns

### Always Use Named Imports

```typescript
// ✅ Correct
import { useState, useEffect, useCallback } from 'react'

// 🔴 Never use (legacy pattern)
import * as React from 'react'
import React from 'react'
```

### Replace Legacy Imports

When encountering legacy imports, always replace with named imports:

```typescript
// Old code
import * as React from 'react'
const [state, setState] = React.useState(0)

// New code
import { useState } from 'react'
const [state, setState] = useState(0)
```

## Performance Optimization

### When to Use `memo()`

```typescript
import { memo } from 'react'

interface ExpensiveComponentProps {
  data: ComplexData
  onAction: (id: string) => void
}

export const ExpensiveComponent = memo(function ExpensiveComponent({
  data,
  onAction
}: ExpensiveComponentProps) {
  // Component implementation
})
```

Use `memo()` when:

- Component renders frequently with same props
- Component is computationally expensive
- Props are stable (primitives or memoized objects/functions)

### When to Use `useCallback()`

```typescript
const handleClick = useCallback((id: string) => {
  // Handler logic
  onItemClick?.(id)
}, [onItemClick])
```

Use `useCallback()` when:

- Passing callbacks to memoized child components
- Function is used as effect dependency
- Function is expensive to recreate

### When to Use `useMemo()`

```typescript
const sortedData = useMemo(() => {
  return data.sort((a, b) => a.name.localeCompare(b.name))
}, [data])
```

Use `useMemo()` when:

- Calculation is expensive
- Value is used as effect dependency
- Value is passed to memoized component

## Quality Checklist

Before completing component generation, verify:

- ✅ **TypeScript interfaces** defined for all props and state
- ✅ **Named imports** used (not `import React from 'react'`)
- ✅ **Proper dependency arrays** in all `useEffect`, `useCallback`, `useMemo`
- ✅ **Cleanup functions** for side effects (subscriptions, timers, listeners)
- ✅ **Custom hooks** extracted for reusable stateful logic
- ✅ **Event handlers** use `useCallback` when passed to children or used as dependencies
- ✅ **Error handling** implemented for async operations
- ✅ **Loading states** for async data fetching
- ✅ **Optional chaining** used for optional callbacks (`onAction?.()`)
- ✅ **No suppressed linter warnings** (especially `exhaustive-deps`)

## Anti-Patterns

See [React Rules](../../rules/react.md) for the complete anti-patterns list. All rules apply when generating components.

## Common Patterns

### Compound Components

```typescript
interface CardProps {
  children: React.ReactNode
  className?: string
}

const Card = ({ children, className }: CardProps) => {
  return <div className={className}>{children}</div>
}

interface CardHeaderProps {
  children: React.ReactNode
}

const CardHeader = ({ children }: CardHeaderProps) => {
  return <div className="card-header">{children}</div>
}

interface CardBodyProps {
  children: React.ReactNode
}

const CardBody = ({ children }: CardBodyProps) => {
  return <div className="card-body">{children}</div>
}

Card.Header = CardHeader
Card.Body = CardBody

export { Card }

// Usage:
// <Card>
//   <Card.Header>Title</Card.Header>
//   <Card.Body>Content</Card.Body>
// </Card>
```

### Error Boundaries

```typescript
import { Component, ReactNode } from 'react'

interface ErrorBoundaryProps {
  children: ReactNode
  fallback?: ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
  error?: Error
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false }
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    console.error('Error caught by boundary:', error, errorInfo)
  }

  render() {
    if (this.state.hasError) {
      return this.props.fallback ?? <div>Something went wrong.</div>
    }

    return this.props.children
  }
}
```

Note: Error Boundaries are one of the few legitimate uses of class components, as React doesn't yet provide a hook-based alternative.

## Final Verification

After generating a component:

1. **Run linter**: Ensure code passes all linting rules
2. **Check TypeScript**: Verify no type errors
3. **Review dependencies**: Confirm all effect dependencies are included
4. **Test cleanup**: Verify cleanup functions exist for side effects
5. **Verify imports**: Ensure named imports are used

## Additional Resources

For detailed rationale and advanced patterns, refer to:

- `/Users/kross/.claude/standards/react.md` - Complete React standards
- Project-specific component examples in the codebase
- React 19 documentation for latest features
