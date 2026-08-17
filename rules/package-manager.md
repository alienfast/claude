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
- A merge-conflicted lockfile is a non-event, every time: clear the conflict whichever way is cheapest (checkout either side — the choice is immaterial), then delete the file and reinstall so the package manager regenerates it from `package.json`. Don't reason about which side to "base" the merge on, and don't call the resolution out in summaries or completion comments — it's routine, not a decision.

## Supply-chain defaults

The house baseline, applied to new projects and to any project being converged: **pnpm 11**
(`packageManager: pnpm@11.x`), a `minimumReleaseAge` cooldown in `pnpm-workspace.yaml` so a
freshly-published version can't be installed the moment it lands, an `allowBuilds` allow-list so only vetted
packages run install scripts, and `blockExoticSubdeps` in monorepos to reject non-registry (git/tarball)
transitive deps. Don't reproduce the values from memory — [standardize-tooling](../skills/standardize-tooling/SKILL.md)
reads them live from the canonical configs and applies whatever a project is missing.

## Command Usage

- Use project scripts over direct tool invocation — see [Project Commands](../standards/project-commands.md), which owns the command table
- Use `pnpm audit` instead of `npm audit`

### Non-interactive installs (agent/CI shells)

`pnpm install` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` when it needs to purge `node_modules` (a
hoist-pattern change, a workspace restructure, switching package managers) and there is no TTY to confirm. Run it
as `CI=true pnpm install` so the purge proceeds unattended (equivalently, set `confirmModulesPurge: false` in
`pnpm-workspace.yaml`, which is where house pnpm settings live — the old `.npmrc` home was migrated away).

Caveat: `CI=true` also implies `--frozen-lockfile`, so if you intentionally changed `package.json` deps a plain
`CI=true pnpm install` then fails with `ERR_PNPM_OUTDATED_LOCKFILE`. Use `CI=true pnpm install --no-frozen-lockfile`
to both auto-purge and update the lockfile.

## Version Management

Classify every dependency change by semver type and match research depth to it — see
[Semver Standards](../standards/semver.md), which owns the depth table and the security carve-out.
