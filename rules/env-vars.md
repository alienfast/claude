---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.mts"
---

# Environment Variable Rules

## Never fake-default a required env var

Coalescing or OR-defaulting a *required* environment variable to a placeholder hides misconfiguration behind a silently-broken value. `process.env.DATABASE_URL ?? ''` yields an empty connection string that passes type checks and "loads" fine, then fails confusingly far from the cause. This is the **silent-default-for-required-config** anti-pattern (see [Problem-Solving Standards](../standards/problem-solving.md)) — fail loudly at the point of absence instead.

```ts
// ❌ Wrong — '' is a valid string but an invalid URL; the failure surfaces somewhere else entirely
const url = process.env.DATABASE_URL ?? ''

// ❌ Wrong — hand-rolled and duplicated across the codebase
const secret = process.env.SESSION_SECRET
if (!secret) throw new Error('SESSION_SECRET is not set')

// ✅ Right — one shared assertion: throws a clear error, returns a non-optional string
import { assertEnvVariable } from '@alienfast/common-node'
const secret = assertEnvVariable('SESSION_SECRET')
```

## Use assertEnvVariable for required server vars

`assertEnvVariable(name)` from `@alienfast/common-node` reads `process.env[name]`, throws `Expected to find value for ENV variable <name>` when missing/empty, and returns a narrowed `string`. Prefer it over hand-rolled `if (!x) throw` guards — it removes duplication and gives you the non-optional type for free. Server/Node contexts only (it touches `process.env`).

## Request boundaries may degrade gracefully

Inside a route handler or request path, returning a clear error response (e.g. HTTP 500 "Missing Cin7 configuration") instead of throwing is fine — but still never substitute a fake default and continue as if configured.

## Optional vars need a valid, explicit default

Genuinely optional vars (feature flags, `NODE_ENV`) may be read directly, but the fallback must be a *valid* value with meaningful behavior — never a placeholder standing in for a value the code actually requires.
