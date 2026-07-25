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
- **Exported prop interfaces**: Name `<ComponentName>Props`, NOT a bare `Props`. A bare `Props` pollutes the importing file's namespace and collides when multiple component prop interfaces are imported. Internal (non-exported) prop interfaces may use `Props` for brevity since they don't cross file boundaries.

```typescript
// ❌ WRONG - bare Props pollutes importing files
export interface Props {
  open: boolean
  onClose: () => void
}

// ✅ CORRECT - prefixed with component name
export interface ChangeNameDialogProps {
  open: boolean
  onClose: () => void
}

// ✅ OK - non-exported interface can stay bare
interface Props {
  open: boolean
}
const ChangeNameDialog = ({ open }: Props) => { ... }
```

## Memoization

Use memoization only when there is a measured performance need or a specific technical requirement:

- **`memo()`**: Wrap with named function expression for DevTools: `export const X = memo(function X(...) { })`
- **`useCallback`**: Only when passing to `memo()` children, used as hook dependencies, or returned from custom hooks. Do NOT wrap handlers passed to plain DOM elements or non-memo components.
- **`useMemo`**: Only for expensive computations (>1ms), stabilizing props for `memo()` children, or values used as hook dependencies. Do NOT use for trivial calculations.
- **State updater functions**: Use updater form in `useCallback` (`setItems(prev => [...prev, item])`) to avoid including state in dependency arrays
- **Incomplete memoization chain**: If a component is wrapped with `memo()`, ALL props passed to it must be stable (memoized or primitive). Memoizing some props but not all silently breaks `memo()`.

### Reviewer guidance: do NOT file standalone memoization cleanups

When reviewing code, **do not surface a finding** (Critical/High/Medium/Nice-to-Have) recommending `useMemo` or `useCallback` purely for referential stability of a value or function passed to a child component that is **not** `memo()`-wrapped. Such cleanups produce code churn without measurable benefit — the child re-renders either way, the memo's recomputation cost roughly equals the inline expression's, and the surrounding handler/prop chain typically isn't memoized either.

A memoization finding is legitimate ONLY when at least one of these holds:

- The child is already `memo()`-wrapped (and the new memo completes the prop-stability chain — all other props must also be stable, otherwise `memo()` is silently broken anyway).
- The value is used as a hook dependency upstream, where identity changes would re-fire the effect/memo unnecessarily.
- The computation is measurably expensive (>1ms — name the measurement or the input scale that justifies the threshold).

Otherwise, mention it in the "Approved" section as a deliberate non-finding ("inline expression is fine here — child is not memoized, no hook dep") rather than as Nice-to-Have. This prevents trivial memoization tickets from being filed as deferred work that the rules above would tell you not to do in the first place.

## Effect Dependencies

- **Dependencies**: Always include all dependencies in `useEffect` arrays
- **Functions in effects**: Define functions inside `useEffect` to avoid `useCallback`
- **Objects in effects**: Create objects inside `useEffect` to avoid `useMemo`
- **No dependency suppression**: Never suppress `exhaustive-deps` linter warnings

## Transitions

- **Catch inside the callback**: `startTransition(async () => { try { await refetch() } catch (e) { ... } })`. Applies to every rejectable promise handed to a transition — Apollo `refetch()`, a `useLazyQuery` execute, a raw `fetch` — not just the one that looks risky.
- **Why**: a rejection inside `useTransition`'s `startTransition` becomes the hook's pending state and is re-thrown DURING RENDER from `useTransition()` itself on the next render, so only the nearest error boundary catches it — never a local try/catch, and never the inline error-state fallback the component uses elsewhere. (The top-level `startTransition` imported from `react` differs: rejections there go to a global error report and reach no boundary.)

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
