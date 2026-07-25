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

## Instruction & Doc Files

The same "git is the archive, one source of truth" rules govern CLAUDE.md, `rules/`, `standards/`, and skill docs:

- **State the ideal, not the history.** Write the procedure as it should be followed now. No "was removed", "no longer", "used to", "previously", or version pins narrating change — git holds that. (The `memory/` log is the deliberate exception: dated entries are its purpose.)
- **Single-source the specifics.** State the rule and link to the standard that owns the details; don't re-list its commands or alternatives. Duplication drifts. This extends to tools: to reproduce a tool's derived or stateful behavior (env-var derivation, resource/slot allocation, multi-step state transitions), point at the tool's own flag or command rather than hand-deriving the recipe in prose — a manual recipe accumulates subtle bugs from interacting subsystems (ordering, scoping, persistence, idempotency) that are easy to verify individually and easy to miss in combination. Reserve hand-rolled recipes for genuine gaps where no equivalent invocation exists.
- **Verify mechanism claims against source, not memory.** When writing or restoring prose that describes how something actually works — why a failure occurs, what a function/controller does, what a script reads — trace the current source before writing the claim; don't reconstruct it from memory or plausible inference. Confidently-wrong mechanism prose is worse than no documentation, because agents trust and act on rule/doc content.

## Removing a build or dev tool

When removing or replacing a package manager, linter, formatter, test runner, or bundler, deleting its
config files is not enough. Grep the repo for the old tool's CLI name in **script bodies and string
literals** — `package.json` scripts, helper `.ts`/`.sh` scripts, CI workflows, Dockerfiles. Shelled-out
command strings are invisible to tsc and Biome, so they pass type and lint checks and fail only at runtime.

**Be bold. Be decisive. Move forward.**
