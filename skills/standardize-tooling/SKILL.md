---
name: standardize-tooling
description: >-
  Converge a TypeScript project's dev tooling onto the house conventions — pnpm 11 (with the supply-chain
  release-age cooldown, allow-builds, and @alienfast registry wiring), Biome for lint/format (no ESLint, no
  Prettier), markdownlint-cli2, madge, the standardized parallel `check` script suite, tsdown (for libraries/CLIs),
  and — if published to npm — `auto` with OIDC token-less trusted publishing and current GitHub Actions — then gate
  on `pnpm check`. Adaptive and idempotent: detects the project's current package manager, linter, bundler,
  single-vs-monorepo layout, and public-vs-private registry, and applies only the gaps. Use when the user says
  "standardize tooling", "migrate to pnpm/Biome/tsdown", "update tooling", "apply house tooling conventions", or
  asks to convert a project off yarn/npm + ESLint/Prettier + tsup.
---

# Standardize Tooling

Bring a TypeScript project to the house dev-tooling **target state** by detecting where it diverges and
converging only the gaps, then gating on a green `pnpm check`. This is not a fixed-order recipe — it is a
target plus a delta.

## Target state (the contract)

A standardized project has all of:

- **pnpm 11** — `packageManager: pnpm@11.x`, a `pnpm-workspace.yaml` with the 7-day supply-chain
  `minimumReleaseAge` cooldown, an `allowBuilds` allow-list, and — if it consumes `@alienfast/*` from GitHub
  Packages — the `registries` mapping with install-time token injection.
- **Biome** for lint and format, with **no ESLint and no Prettier** (and no `lint-staged`).
- **markdownlint-cli2** with the house `.markdownlint-cli2.jsonc`.
- **madge** circular-import check via `.madgerc` (`skipTypeImports: true`).
- The **standardized parallel `check` suite** — `run-p -c --aggregate-output check-types check-biome
  check-circular check-markdown test`.
- **`.ncurc.cjs`** cooldown aligned to pnpm's 7-day window.
- **`.vscode`** wired to the `check-types` task, with **no stale `build:ide` script**.
- **tsdown** as the bundler *if the project builds a library/CLI*.
- *If published to npm:* **`auto`** for releases with **OIDC token-less trusted publishing** and
  **up-to-date GitHub Actions + Node versions**.
- A green **`pnpm check`**.

## Read-live rule

The house configs evolve. **Read the current canonical config files live from the source checkouts and adapt
them** — never reproduce config from memory or freeze a snapshot.

- **`~/projects/basefund`** — primary. Monorepo, consumes the private `@alienfast` GitHub Packages registry,
  not npm-published. Canonical for `pnpm-workspace.yaml`, `biome.jsonc`, `.markdownlint-cli2.jsonc`,
  `.ncurc.cjs`, the `check` suite, and `.vscode/*`.
- **`~/projects/gltfjsx`** — single-package + published + tsdown + OIDC worked example. Canonical for the
  single-package shapes, `.madgerc`, `tsdown.config.ts`, and `publishConfig`.
- **`~/projects/vite-plugin-i18next-loader`** — the OIDC `auto` release-workflow template (basefund isn't published).

If a needed source checkout is absent, **stop and tell the user** — do not invent config from memory.

## Guardrails

- **Idempotent** — re-running on an already-standardized project is a no-op. Every step is gated on a
  detection signal; skip what is already met.
- **Never auto-commit.** Apply edits to the working tree and leave committing to the user. If on the default
  branch, create a working branch first (see `~/.claude/standards/git.md`).
- **Auto-fixers mutate files in place.** `biome check --write` and `markdownlint-cli2 --fix` reformat on
  every run, and `pnpm check` re-sorts `package.json`. Re-read any file after a check run before hand-editing it.
- **Tooling deps only.** Add/replace just the toolchain dependencies. Hand off any full app-dependency
  refresh to `/dependency-updater`.

## Workflow

### 1. Detect

Run the probe against the target (default: current directory) and read the `KEY=value` signals:

```bash
bash ~/.claude/skills/standardize-tooling/scripts/detect-state.sh [target-dir]
```

Key signals: `PACKAGE_MANAGER`, `PACKAGE_MANAGER_PIN`, `LEFTOVER_PM_FILES`, `IS_MONOREPO`,
`HAS_ESLINT`, `HAS_PRETTIER`, `HAS_LINT_STAGED`, `HAS_BIOME`, `BUNDLER`, `ALIENFAST_REGISTRY`,
`IS_PUBLISHED`, `HAS_AUTO`, `HAS_OIDC_WORKFLOW`, `HAS_CHECK_SUITE`, `HAS_BUILD_IDE_SCRIPT`,
`HAS_MADGE`/`HAS_MADGERC`, `HAS_MARKDOWNLINT`, `HAS_COOLDOWN`, `HAS_NCURC`, `VSCODE_TASKS_CHECK_TYPES`.

### 2. Compute the gap

Compare the signals against the target state. Build the list of attributes not yet met. If every attribute is
met, report "already standardized" and stop — nothing to do.

### 3. Converge

For each gap, read its canonical config live from the source checkout and adapt it to the target. Follow
[references/converge.md](references/converge.md) for the source-of-truth map and the per-attribute apply
steps + gotchas. If `IS_PUBLISHED=true`, also follow [references/publishing.md](references/publishing.md) for
tsdown, `auto`, and OIDC.

Order only where a real dependency forces it; otherwise order does not matter:

- Write `pnpm-workspace.yaml` (and registry wiring) **before** `pnpm install`.
- Write `biome.jsonc` **before** running `biome check` / `pnpm check`.
- Approve native builds (`pnpm approve-builds`) **after** the first `pnpm install` reports them.

### 4. Gate

Run `pnpm check` and fix what it surfaces; re-read auto-fixed files and hand-fix only what survives. Loop
until it is green. Disable a Biome/lint rule only when it conflicts with an intentional codebase pattern,
with a one-line documented reason — never to silence a real finding.

### 5. Summarize

Report what converged and what was already met. List the **manual follow-ups** separately — the skill cannot
do these:

- Configure the npmjs **Trusted Publisher** for the package (GitHub Actions; org/repo; workflow filename).
- Delete now-unused `GH_TOKEN` / `NPM_TOKEN` repo secrets.
- Optionally run `/dependency-updater` for a full app-dependency refresh, and `/init` to create/update CLAUDE.md.
