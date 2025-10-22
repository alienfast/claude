# React Component Quick Reference

This file provides quick copy-paste templates for common React patterns.

## Basic Component Template

```typescript
import { useState } from 'react'

interface ComponentNameProps {
  requiredProp: string
  optionalProp?: number
  onAction?: (data: DataType) => void
}

export function ComponentName({
  requiredProp,
  optionalProp = defaultValue,
  onAction,
}: ComponentNameProps) {
  const [state, setState] = useState<StateType>(initialValue)

  return (
    <div>
      {/* Component JSX */}
    </div>
  )
}
```

## Data Fetching Component

```typescript
import { useState, useEffect } from 'react'

interface DataComponentProps {
  id: string
}

interface DataType {
  // Define your data structure
}

export function DataComponent({ id }: DataComponentProps) {
  const [data, setData] = useState<DataType | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<Error | null>(null)

  useEffect(() => {
    if (!id) return

    let ignore = false
    setLoading(true)

    fetch(`/api/endpoint/${id}`)
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
        }
      })

    return () => {
      ignore = true
    }
  }, [id])

  if (loading) return <div>Loading...</div>
  if (error) return <div>Error: {error.message}</div>
  if (!data) return <div>No data found</div>

  return <div>{/* Render data */}</div>
}
```

## Custom Hook Template

```typescript
import { useState, useEffect, useCallback } from 'react'

interface UseCustomHookOptions {
  initialValue?: DataType
  onError?: (error: Error) => void
}

export function useCustomHook(param: string, options: UseCustomHookOptions = {}) {
  const [data, setData] = useState<DataType | null>(options.initialValue ?? null)
  const [loading, setLoading] = useState(false)

  const doSomething = useCallback(() => {
    // Action logic
  }, [/* dependencies */])

  useEffect(() => {
    // Effect logic with cleanup
    return () => {
      // Cleanup
    }
  }, [param])

  return { data, loading, doSomething }
}
```

## Form Component with useReducer

```typescript
import { useReducer } from 'react'

interface FormState {
  field1: string
  field2: string
  submitted: boolean
}

type FormAction =
  | { type: 'UPDATE_FIELD1'; payload: string }
  | { type: 'UPDATE_FIELD2'; payload: string }
  | { type: 'SUBMIT' }
  | { type: 'RESET' }

function formReducer(state: FormState, action: FormAction): FormState {
  switch (action.type) {
    case 'UPDATE_FIELD1':
      return { ...state, field1: action.payload }
    case 'UPDATE_FIELD2':
      return { ...state, field2: action.payload }
    case 'SUBMIT':
      return { ...state, submitted: true }
    case 'RESET':
      return { field1: '', field2: '', submitted: false }
    default:
      return state
  }
}

export function FormComponent() {
  const [state, dispatch] = useReducer(formReducer, {
    field1: '',
    field2: '',
    submitted: false,
  })

  return (
    <form>
      {/* Form implementation */}
    </form>
  )
}
```

## Memoized Component

```typescript
import { memo, useCallback } from 'react'

interface MemoComponentProps {
  data: ComplexData
  onAction: (id: string) => void
}

export const MemoComponent = memo(function MemoComponent({
  data,
  onAction
}: MemoComponentProps) {
  const handleClick = useCallback(() => {
    onAction(data.id)
  }, [data.id, onAction])

  return (
    <div onClick={handleClick}>
      {/* Component content */}
    </div>
  )
})
```

## Compound Component Pattern

```typescript
interface ParentProps {
  children: React.ReactNode
}

function Parent({ children }: ParentProps) {
  return <div className="parent">{children}</div>
}

interface ChildProps {
  children: React.ReactNode
}

function Child({ children }: ChildProps) {
  return <div className="child">{children}</div>
}

Parent.Child = Child

export { Parent }

// Usage:
// <Parent>
//   <Parent.Child>Content</Parent.Child>
// </Parent>
```

## Effect with Cleanup

```typescript
import { useEffect } from 'react'

export function ComponentWithCleanup() {
  useEffect(() => {
    // Setup subscription/listener
    const subscription = subscribeToData()

    // Cleanup function
    return () => {
      subscription.unsubscribe()
    }
  }, [])

  return <div>{/* Component content */}</div>
}
```

## Conditional Rendering

```typescript
interface ConditionalProps {
  isVisible: boolean
  data?: DataType
  children: React.ReactNode
}

export function ConditionalComponent({ isVisible, data, children }: ConditionalProps) {
  // Early return pattern
  if (!isVisible) return null
  if (!data) return <div>No data available</div>

  return (
    <div>
      {/* Main content */}
      {children}
    </div>
  )
}
```
