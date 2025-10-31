# Technical Debt Prevention Standards

**CRITICAL**: These are non-negotiable rules. Claude MUST follow these to prevent technical debt accumulation.

## Core Principle

**We OWN our code. We MOVE FORWARD. We DO NOT accumulate debt.**

- This is private code, not a public library
- Breaking changes are GOOD when they improve the code
- Compatibility layers are FORBIDDEN unless explicitly requested
- Technical debt is the enemy of maintainability

## File Management Rules

### 1. NEVER Create Backup Files

```bash
# FORBIDDEN - Never do this
mv script.sh script.sh.backup
cp config.json config.json.old
cp implementation.ts implementation.v2.ts
```

**Instead**: Use git. Delete the old. Replace with the new.

### 2. ALWAYS Modify Existing Files

When asked to update a script, function, or configuration:

```bash
# WRONG - Creating a duplicate
Write new-script.sh  # While old-script.sh exists

# CORRECT - Modify in place
Edit script.sh
```

**Rule**: If the functionality is the same, MODIFY the existing file. Period.

### 3. Delete Aggressively

- Unused code? DELETE IT
- Old implementation? DELETE IT
- Deprecated function? DELETE IT
- Empty directories? DELETE THEM

Git preserves history. We don't need file-based archaeology.

### 4. No "Just In Case" Code

```typescript
// FORBIDDEN
function oldImplementation() { /* keeping for compatibility */ }
function newImplementation() { /* the actual code */ }

// CORRECT
function implementation() { /* the only code */ }
```

## Code Modification Rules

### 1. Breaking Changes Are Welcome

```typescript
// Don't do this
function doThing(param: string, legacyParam?: string) {
  const value = legacyParam || param; // Supporting old callers
}

// Do this
function doThing(param: string) {
  // Just use the new signature, fix all callers
}
```

### 2. Refactor Fearlessly

- Need to rename? Rename EVERYWHERE
- Need to restructure? Restructure COMPLETELY
- Need to change signatures? Change and FIX ALL CALLERS

### 3. No Parallel Implementations

**NEVER** have:
- `utils.js` and `utils-new.js`
- `v1/` and `v2/` directories (unless explicitly versioned APIs)
- `processData()` and `processDataImproved()`

**ALWAYS** have:
- One implementation
- One truth
- One place

## Decision Tree

When asked to modify code:

```
Is there an existing file that does this?
├─ YES → MODIFY that file
│   ├─ Will changes break other code?
│   │   ├─ YES → Fix the other code too
│   │   └─ NO → Proceed
│   └─ Delete any old versions
└─ NO → Create NEW file
    └─ Ensure it doesn't duplicate existing functionality
```

## Anti-Patterns (NEVER DO THESE)

### 1. The "Safe" Duplicate

```bash
# ANTI-PATTERN
"I'll create lint-v2.sh to be safe, keeping lint.sh around"
```

**Why it's wrong**: Creates confusion, maintenance burden, and debt
**Correct approach**: Modify lint.sh directly

### 2. The "Compatibility" Layer

```javascript
// ANTI-PATTERN
export { newFunction };
export { newFunction as oldFunction }; // for compatibility
```

**Why it's wrong**: Encourages continued use of old patterns
**Correct approach**: Rename everywhere, remove old references

### 3. The "Archive" Directory

```bash
# ANTI-PATTERN
mkdir archived-code
mv old-implementation.js archived-code/
```

**Why it's wrong**: Git is the archive
**Correct approach**: Delete the file, commit the deletion

### 4. The "Temporary" File

```bash
# ANTI-PATTERN
cp config.json config.json.tmp
# work on config.json.tmp
# forget to clean up
```

**Why it's wrong**: Temporary files become permanent debt
**Correct approach**: Modify directly or use git stash

## Enforcement Checklist

Before completing ANY code modification task:

- [ ] Did I modify existing files instead of creating duplicates?
- [ ] Did I delete all old/unused code?
- [ ] Did I fix all breaking changes throughout the codebase?
- [ ] Did I avoid creating any "backup" or "old" files?
- [ ] Did I refuse to add compatibility layers?
- [ ] Is there exactly ONE implementation of each feature?

## Examples of Correct Behavior

### Scenario 1: Update a script

```bash
# User: "Update the build script to use new flags"
# CORRECT: Edit build.sh directly
# WRONG: Create build-new.sh or build-v2.sh
```

### Scenario 2: Refactor a module

```typescript
// User: "Refactor the auth module to use JWT"
// CORRECT: Modify auth.ts, update all imports
// WRONG: Create auth-jwt.ts alongside auth.ts
```

### Scenario 3: Breaking change needed

```javascript
// User: "Change the API to return arrays instead of objects"
// CORRECT: Change the API, fix all consumers
// WRONG: Add a 'format' parameter to support both
```

## The Prime Directive

**When in doubt, DELETE.**

- Deletion is reversible (git)
- Duplication is technical debt
- Moving forward requires letting go of the past
- The best code is no code
- The second best code is maintained code
- The worst code is duplicated code

## Remember

Every file you create is a maintenance burden.
Every line you duplicate is a future bug.
Every compatibility layer is a confession of failure.

**Be bold. Be decisive. Move forward.**