---
paths:
  - "**/package.json"
  - "**/package-lock.json"
  - "**/yarn.lock"
  - "**/pnpm-lock.yaml"
---

# Package Manager Rules

## Tool Selection

- Follow existing project's package manager (check for `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`)
- Default to pnpm for new projects
- Never commit `package-lock.json` or `yarn.lock` if project uses pnpm

## Dependencies

- Check existing dependencies before adding new ones
- In workspaces: add packages to specific workspace projects, not root
- Do not downgrade a dependency to fix an issue without explicit user approval
- When debugging and you think there is a problem with a dependency, check the latest APIs of the dependency based on the version currently being used

## Command Usage

- Use project scripts over direct tool invocation
- Prefer `pnpm typecheck` over `npx tsc --noEmit`
- Use `pnpm audit` instead of `npm audit`

### Non-interactive installs (agent/CI shells)

`pnpm install` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` when it needs to purge `node_modules` (a
hoist-pattern change, a workspace restructure, switching package managers) and there is no TTY to confirm. Run it
as `CI=true pnpm install` so the purge proceeds unattended (equivalently, set `confirm-modules-purge=false` in
`.npmrc`).

Caveat: `CI=true` also implies `--frozen-lockfile`, so if you intentionally changed `package.json` deps a plain
`CI=true pnpm install` then fails with `ERR_PNPM_OUTDATED_LOCKFILE`. Use `CI=true pnpm install --no-frozen-lockfile`
to both auto-purge and update the lockfile.

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
