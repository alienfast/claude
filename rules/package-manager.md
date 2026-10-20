---
paths:
  - "**/package.json"
  - "**/package-lock.json"
  - "**/yarn.lock"
  - "**/pnpm-lock.yaml"
  - "**/pnpm-workspace.yaml"
  - "**/.ncurc.cjs"
  - "**/renovate.json"
---

# Package Manager Rules

## Tool selection

- Follow the project's package manager (check for `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`); default to pnpm
  for new projects; never commit `package-lock.json` or `yarn.lock` in a pnpm project.
- Use project scripts over direct tool invocation ([Project Commands](../standards/project-commands.md) owns the
  command table). `pnpm audit`, not `npm audit`.

## Dependencies

- Check existing dependencies before adding one. In a workspace, add to the specific package, not the root.
- Never downgrade a dependency to fix an issue without explicit approval. When a dependency looks broken, check its
  current API at the installed version first.
- Classify every change by semver type and match research depth to it ([Semver Standards](../standards/semver.md)).

## The lockfile is the pin

- `pnpm-lock.yaml` records exact versions and integrity hashes for every dependency, direct and transitive, and a frozen
  install reproduces that tree. Caret ranges in `package.json` matter only when the lockfile is re-resolved.
- Blanket exact pins add nothing on top of a frozen install, cover no transitive dependency (where most compromises
  land), and in large graphs can enlarge the tree by defeating dedup ("Pinning Is Futile", arXiv 2502.06662). Caret is
  the default; an exact pin is for churn-prone majors that must move together, not for defense.
- Never hand-edit a lockfile, not to change a version, a tarball URL, or to resolve a merge conflict. Change
  `package.json` or the workspace config and let the tool regenerate it. A conflicted lockfile is a non-event: take
  either side, delete the file, reinstall, and don't mention it in summaries.

## Supply-chain defaults (pnpm 12 baseline)

`packageManager: pnpm@12.x` (the release `~/.claude/package.json` pins), a `minimumReleaseAge` cooldown, an `allowBuilds`
allow-list so only vetted packages run install scripts, and `blockExoticSubdeps` in monorepos. Don't reproduce values
from memory: [standardize-tooling](../skills/standardize-tooling/SKILL.md) reads them from the canonical configs.

- **Keep every expression of the cooldown aligned.** `minimumReleaseAge` in `pnpm-workspace.yaml` enforces at
  resolution; Renovate's `minimumReleaseAge` must match or it opens PRs pnpm refuses; ncu (22+) inherits the window and
  the exclude list from `pnpm-workspace.yaml` when `.ncurc` sets no `cooldown`, so never add one back. A first-party scope
  you publish yourself goes in `minimumReleaseAgeExclude`; trusted publishing covers its risk, waiting does not.
- A frozen install re-validates each locked version's age (pnpm 11.1.3+). `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` means
  a too-fresh version reached the lockfile some other way: regenerate under policy or let it age; never drop the flag.
- `packageManager` is an exact version with corepack's `+sha512.<hex>` suffix. `ncu -u` bumps the field and strips the
  hash; restore it (`corepack use pnpm@<v>`) or a production image's `corepack enable pnpm` loses its only integrity
  check silently.
- `packageManager` and the lockfile change together. pnpm 12 prepends a self-management document to `pnpm-lock.yaml`
  (two YAML documents split by a bare `---`; the project's `importers:` are in the last one, so a lockfile parser must
  read the last document), and a `packageManager` bump without `pnpm install` fails every frozen install with
  `ERR_PNPM_FROZEN_LOCKFILE_WITH_OUTDATED_LOCKFILE`. Any CI step that installs pnpm by version must equal
  `packageManager`.
- A `packageManager` pin younger than `minimumReleaseAge` fails every install with
  `ERR_PNPM_NO_MATURE_MATCHING_VERSION` (a security-update PR does exactly this). Admit it with version-scoped
  `minimumReleaseAgeExclude` entries, `pnpm@<v>` plus one `@pnpm/exe.<platform>@<v>` per platform the error lists; a
  versioned glob is rejected, and an unversioned `@pnpm/exe.*` is a standing exemption to remove once the release has
  aged.
- Config lives in `pnpm-workspace.yaml`: `allowBuilds` (a name→boolean map), `overrides`, `packageExtensions`,
  `patchedDependencies`. An unrecognized key fails the install with `ERR_PNPM_UNRECOGNIZED_WORKSPACE_SETTINGS`.

## Peer-resolution unity with `packageExtensions`

pnpm bakes a package's resolved peers into its resolution key and every ancestor's, so one optional peer present in
several versions forks an unrelated subgraph (two copies of a context provider, say), and no type check sees it. Remove
the coordinate rather than the version spread: declare the optional peer as an `optionalDependencies` entry on the
package that declares it, under `packageExtensions` (`dependencies` would be stripped again by `autoInstallPeers`).
Prefer this over an `overrides` pin, which drags every consumer onto one version. Nothing tracks that entry's version
(ncu reads `package.json`; Renovate has no manager for it), so state the choice in a comment, and add no version
selector unless some versions genuinely must be exempt, since a selector reopens the hole outside it.

## Patches

`patchedDependencies` makes a frozen install need the patch files on disk, so a Dockerfile installing from a partial
copy must copy `patches/` first. `ERR_PNPM_UNUSED_PATCH` means a patch matches no installed package: retarget it in the
same change, or delete it only after confirming the new version no longer reaches the defect. The error says the patch is
unmatched, not that the defect is gone.

## Non-interactive installs (agent and CI shells)

`pnpm install` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` when it must purge `node_modules` (a hoist
change, a workspace restructure, a package-manager major) and no TTY can confirm. Run `CI=true pnpm install` so the
purge proceeds (equivalently `confirmModulesPurge: false` in `pnpm-workspace.yaml`). `CI=true` also implies
`--frozen-lockfile`, so after an intentional `package.json` change use `CI=true pnpm install --no-frozen-lockfile`.
