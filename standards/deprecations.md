# Deprecation Handling

This standard ensures that deprecated APIs, types, functions, and modules are properly handled across all code development and maintenance activities.

## For New Code

### Rules

- **NEVER** use deprecated APIs, types, functions, or modules
- Always check documentation and IDE warnings for deprecation notices
- Use the latest recommended alternatives provided in deprecation messages
- When multiple alternatives exist, choose the most stable and well-documented option

### Verification Steps

- Review TypeScript compiler warnings during development
- Check ESLint/linting output for deprecation rules
- Verify IDE deprecation indicators (strikethrough, warnings)
- Consult official migration guides for major framework updates

## For Existing Code

### Proactive Updates

- **Identify deprecations** when modifying files that contain deprecated usage
- **Update deprecated usage** when touching a file, even if unrelated to the main change
- **Prioritize security-related deprecations** that could pose risks
- **Document** when deprecation updates would require significant refactoring beyond the current scope

### Update Strategy

- Fix simple deprecations immediately (e.g., renamed functions, updated import paths)
- For complex deprecations requiring architectural changes, create separate tasks
- When touching legacy code, update obvious deprecations in the same commit
- Use migration guides and official upgrade documentation

## Detection Methods

### Automated Tools

- Enable deprecation warnings in TypeScript configuration
- Use ESLint rules that flag deprecated usage
- Run dependency audit tools to identify deprecated packages
- Enable IDE deprecation highlighting and warnings

### Manual Checks

- Review framework migration guides when upgrading versions
- Check package.json for deprecated dependencies using `npm outdated` or similar
- Monitor console warnings in development environment
- Review official change logs and breaking change announcements

## Common Deprecation Categories

### API Changes

- Function signature changes
- Renamed methods or properties
- Removed parameters or return types

### Framework Updates

- React lifecycle methods → hooks
- Vue 2 composition patterns → Vue 3 Composition API
- Angular directive syntax changes

### Package Dependencies

- Deprecated npm packages
- Security-vulnerable versions
- Packages with better modern alternatives

### Language Features

- Deprecated JavaScript features
- TypeScript configuration options
- Node.js API changes

## Priority Levels

### Immediate (Fix Now)

- Security vulnerabilities in deprecated code
- Breaking changes in next major version
- Performance-critical deprecated APIs

### High (Fix When Touching File)

- Deprecated functions with direct replacements
- Simple import path changes
- Deprecated configuration options

### Medium (Plan for Future)

- Complex architectural changes required
- Deprecated patterns requiring significant refactoring
- Non-critical deprecations with long sunset timelines

### Low (Monitor)

- Deprecations with distant sunset dates
- Optional optimizations
- Style-only deprecations

## Documentation Requirements

When encountering deprecations that cannot be immediately fixed:

1. **Add inline comments** explaining why the deprecated code remains
2. **Create tasks** for future refactoring if significant work is required
3. **Document alternatives** and migration paths for future reference
4. **Note any blockers** preventing immediate updates (dependencies, breaking changes, etc.)

## Examples

### Good: Immediate Fix

```typescript
// Before (deprecated)
React.createClass({ ... })

// After (modern)
class MyComponent extends React.Component { ... }
// or
const MyComponent = () => { ... }
```

### Good: Documented Complex Case

```typescript
// TODO: Migrate to new API when v3 migration is complete
// Current usage of deprecated method due to dependency on legacy system
// See: https://docs.example.com/migration-guide
legacyApi.deprecatedMethod()
```

### Bad: Ignoring Deprecation

```typescript
// eslint-disable-next-line deprecation/deprecation
deprecatedFunction() // No explanation or plan for migration
```
