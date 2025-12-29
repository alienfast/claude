---
paths:
  - "**/package.json"
  - "**/package-lock.json"
  - "**/yarn.lock"
  - "**/pnpm-lock.yaml"
---

# Package Manager Rules

## Tool Selection

- Follow existing project's package manager (check for `yarn.lock`, `package-lock.json`, `pnpm-lock.yaml`)
- Default to Yarn (modern) for new projects
- Never commit `package-lock.json` if project uses Yarn

## Dependencies

- Check existing dependencies before adding new ones
- In workspaces: add packages to specific workspace projects, not root
- Do not downgrade a dependency to fix an issue without explicit user approval
- When debugging and you think there is a problem with a dependency, check the latest APIs of the dependency based on the version currently being used

## Command Usage

- Use project scripts over direct tool invocation
- Prefer `yarn typecheck` over `npx tsc --noEmit`
- Use `yarn npm audit` instead of `npm audit`

## Version Management

- Follow semantic versioning for all version-related decisions
- Apply semver classification when updating dependencies
- Use appropriate version ranges based on compatibility requirements

### Semver Quick Reference

| Change Type | Version Bump | Examples |
|-------------|--------------|----------|
| Breaking changes | MAJOR (X.0.0) | Removed APIs, changed signatures, renamed exports |
| New features | MINOR (x.Y.0) | Added methods, new optional parameters |
| Bug fixes | PATCH (x.y.Z) | Fixed bugs, performance improvements |
