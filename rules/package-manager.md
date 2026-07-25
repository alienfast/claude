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

## Lockfiles

- Never hand-edit a generated lockfile (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`) — not to change a version, a registry/tarball URL, or to resolve a merge conflict. They carry integrity hashes the tool computed; a hand-edit leaves resolution/integrity state the package manager never verified.
- To change what resolves: edit `package.json` / workspace config and run the package manager (`pnpm install`, `pnpm add`, `pnpm update <pkg>`) — let it regenerate the lockfile.
- To discard unwanted lockfile changes or fix a conflict: delete the lockfile and reinstall, don't edit entries by hand.

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

Classify every dependency change by semver type and match research depth to it — see
[Semver Standards](../standards/semver.md), which owns the depth table and the security carve-out.
