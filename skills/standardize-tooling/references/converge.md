# Converge to the standardized-tooling target

This is the per-attribute remediation guide. For each target attribute it gives the **detection signal**
(from `scripts/detect-state.sh`), the **live source** to read the canonical config from, the apply steps, and
the non-obvious gotchas. Publishing-only attributes (tsdown, `auto`, OIDC, Actions) live in
[publishing.md](publishing.md).

## Read-live rule

The house configs evolve (Biome 2.5.x, pnpm 11.x, markdownlint-cli2 0.22.x, TypeScript 6.x, …). **Read the
current file from the source checkout, copy it, then adapt** — never reproduce a config from memory or from
this document. This doc tells you *which* file is canonical and *how* to adapt it; the bytes come from the
live checkout. If a needed source checkout is absent, stop and tell the user rather than inventing config.

## Source-of-truth map

`~/projects/basefund` is primary (monorepo, consumes the private `@alienfast` GitHub Packages registry, not
npm-published). `~/projects/gltfjsx` is the single-package + published + tsdown worked example.
`~/projects/vite-plugin-i18next-loader` is the OIDC release template.

| Concern | Canonical source (read live) |
| --- | --- |
| `pnpm-workspace.yaml` — registries, hoist, overrides, `blockExoticSubdeps` (monorepo) | `basefund/pnpm-workspace.yaml` |
| `pnpm-workspace.yaml` — cooldown + `allowBuilds` only (single-package shape) | `gltfjsx/pnpm-workspace.yaml` |
| `biome.jsonc` — monorepo, with `overrides` | `basefund/biome.jsonc` |
| `biome.jsonc` — single-package, with `vcs` block | `gltfjsx/biome.jsonc` |
| `.markdownlint-cli2.jsonc` | `basefund/.markdownlint-cli2.jsonc` (or `gltfjsx` for the `MD041`-off badge case) |
| `.ncurc.cjs` | `basefund/.ncurc.cjs` (`workspaces: true`) or `gltfjsx/.ncurc.cjs` (single) |
| `.madgerc` (`skipTypeImports`) | `gltfjsx/.madgerc` |
| `check`/`check-*` scripts | `basefund/package.json` (turbo) or `gltfjsx/package.json` (single) |
| `.vscode/settings.json`, `extensions.json` | `gltfjsx/.vscode/` (cleanest) or `basefund/.vscode/` |
| `.vscode/tasks.json` → `check-types` | `gltfjsx/.vscode/tasks.json` (single) or `basefund/.vscode/tasks.json` (mono matchers) |
| tsdown, `auto`, OIDC workflow, `publishConfig` | see [publishing.md](publishing.md) |

## pnpm 11 + workspace + supply-chain cooldown + allow-builds

**Met when** `PACKAGE_MANAGER=pnpm`, `PACKAGE_MANAGER_PIN` is `pnpm@11.*`, `HAS_PNPM_WORKSPACE=true`, and
`HAS_COOLDOWN=true`.

**Source** — `basefund/pnpm-workspace.yaml` (monorepo: `registries`, `publicHoistPattern`, `overrides`,
`blockExoticSubdeps`) or `gltfjsx/pnpm-workspace.yaml` (single-package: just `minimumReleaseAge`,
`minimumReleaseAgeExclude`, `allowBuilds`). Match the target's shape (`IS_MONOREPO`).

### Apply

- Delete everything in `LEFTOVER_PM_FILES` (`yarn.lock`, `.yarnrc.yml`, `.yarn/`, `package-lock.json`, `.eslintcache`).
- Set `packageManager: "pnpm@11.x"` in `package.json` to a real recent 11 release. pnpm 10 self-manages and
  auto-fetches the pinned 11, so the migration runs even on a pnpm-10 machine.
- Create `pnpm-workspace.yaml` adapted from the source: `minimumReleaseAge: 10080` (7 days),
  `minimumReleaseAgeExclude: ['@alienfast/*']`, and an `allowBuilds:` name→boolean map (pnpm 11 replaced
  pnpm 10's `onlyBuiltDependencies` list). Seed `allowBuilds` with the obvious native builders the target
  actually has (`sharp`, `esbuild`, …) — do **not** copy basefund's full list blindly.
- Run `pnpm install`, then add only what pnpm reports as "ignored build scripts" via `pnpm approve-builds`.

### Gotchas

- `allowBuilds` is an allow-list, not a blanket — approve only what install reports, with intent.
- Registry sub-branch: if `ALIENFAST_REGISTRY=github`, the target consumes `@alienfast/*` from GitHub
  Packages — mirror basefund's `registries: { '@alienfast': https://npm.pkg.github.com/ }` and inject the
  token at install time (Docker `pnpm_config_//…` env, CI `pnpm config set` from `$GITHUB_TOKEN`, dev user
  `~/.npmrc`). Do **not** commit an `.npmrc` with env-var auth — pnpm ≥ 11.5.3 ignores it (GHSA-3qhv-2rgh-x77r).
  If `ALIENFAST_REGISTRY=npm` (resolves from public npm), no registry config is needed.

## Biome (no ESLint, no Prettier)

**Met when** `HAS_BIOME=true` and `HAS_ESLINT=false` and `HAS_PRETTIER=false` and `HAS_LINT_STAGED=false`.

**Source** — `basefund/biome.jsonc` (monorepo, `overrides`) or `gltfjsx/biome.jsonc` (single-package, `vcs` block).

### Apply

- Add `biome.jsonc` extending `@alienfast/biome-config/base`. Add `/react` **only** if the target has real
  JSX/TSX source.
- Include a `vcs: { enabled: true, clientKind: "git", useIgnoreFile: true }` block and a `files.includes`
  exclude list (`!dist`, `!coverage`, test fixtures, `!**/*.svg`). SVGs are assets — their embedded `<style>`
  trips the CSS rules.
- Set `correctness.noUnresolvedImports: off` (the house uses `.ts` import extensions via
  `allowImportingTsExtensions`; `tsc` still catches broken imports).
- Delete `eslint.config.*` / `.eslintrc*`, `.prettierignore`, the `prettier` package.json field, the
  `lint-staged` block, and the eslint / typescript-eslint / prettier / lint-staged devDependencies.
- Run `biome check --write`. Expect a large but behavior-preserving first reformat, and `.js`→`.ts` import
  extension normalization if `allowImportingTsExtensions` is on.

### Gotchas

- **Fix the findings Biome surfaces — do not blanket-disable.** Disable a rule only when it conflicts with an
  intentional codebase pattern, each with a one-line documented reason (e.g. `noStaticOnlyClass` for
  curry-driven utility classes; `noExcessiveNestedTestSuites` for intentionally nested suites — both real in
  `gltfjsx/biome.jsonc`; `noLeakedRender` / `noDefaultExport` overrides in `basefund/biome.jsonc`).
- `biome check --write` mutates files in place (formatting, import organization, key sorting are already
  done on disk). Re-read before hand-editing; only fix what the re-read still flags.

## Standardized check suite + madge

**Met when** `HAS_CHECK_SUITE=true`, `HAS_NPM_RUN_ALL=true`, `HAS_MADGE=true`, `HAS_MADGERC=true`.

**Source** — `basefund/package.json` (turbo-based `check-types`/`test`) or `gltfjsx/package.json` (single:
`tsc --noEmit`, `vitest run`); `.madgerc` from `gltfjsx/.madgerc`.

### Apply

Add `npm-run-all` + `madge` and the script suite, adapting `check-circular`'s extensions and src dirs to the
target (`./src` single-package; `./apps/*/src ./packages/*/src …` monorepo):

```json
"check": "run-p -c --aggregate-output check-types check-biome check-circular check-markdown test",
"check-biome": "biome check --write",
"check-circular": "madge --circular --extensions ts <src dirs> --ts-config ./tsconfig.json",
"check-markdown": "markdownlint-cli2 --fix \"**/*.md\"",
"check-types": "tsc --noEmit",
"test": "vitest run"
```

### Gotchas

- Add `.madgerc` with `{ "detectiveOptions": { "ts": { "skipTypeImports": true } } }` — madge flags
  type-only import cycles by default; this makes `check-circular` report only real **runtime** cycles.
- Do not add a separate `build:ide` tsc script — point `.vscode/tasks.json` at the `check-types` script instead.
- `BUNDLER` is a root-level signal; in a monorepo each publishable package decides tsdown vs not on its own.

## Markdown lint

**Met when** `HAS_MARKDOWNLINT=true`.

**Source** — `basefund/.markdownlint-cli2.jsonc` (or `gltfjsx` for the badge case).

### Apply

Add `markdownlint-cli2` + `.markdownlint-cli2.jsonc` (`MD013`/`MD024`/`MD060` off; ignore `node_modules`,
`CHANGELOG.md`, generated/fixture dirs). Add `MD041: false` only if the README leads with badges before its
first H1 (gltfjsx's case).

## ncu cooldown alignment

**Met when** `HAS_NCURC=true`.

**Source** — `basefund/.ncurc.cjs` (`workspaces: true`) or `gltfjsx/.ncurc.cjs` (single).

### Apply

Add `.ncurc.cjs`: `cooldown: (n) => n.startsWith('@alienfast/') ? 0 : '168h'`, `packageManager: 'pnpm'`,
`root: true`. Keep `168h` aligned to pnpm's `minimumReleaseAge` 7-day window so `ncu` never suggests an
update the install would refuse.

## .vscode

**Met when** `HAS_VSCODE=true` and `VSCODE_TASKS_CHECK_TYPES=true` and `HAS_BUILD_IDE_SCRIPT=false`.

**Source** — `gltfjsx/.vscode/` (cleanest single-package) or `basefund/.vscode/` (monorepo problem matchers).

### Apply

Copy `settings.json` (Biome default formatter + format-on-save, markdownlint fix-on-save, tab size 2,
LF / UTF-8 / final-newline), `extensions.json` (`biomejs.biome`, `DavidAnson.vscode-markdownlint`,
`vitest.explorer`, `yoavbls.pretty-ts-errors`), and `tasks.json` pointing at the `check-types` npm script.
Drop any yarn-era `eslint.nodePath` / `.yarn` search excludes, and remove a stale `build:ide` script if present.

## engines.node (cross-cutting)

Set `engines.node` to the target's **actual** dependency floor (e.g. `sharp` needs `^18.17 || ^20.3 || >=21`),
not a stale `>=16`. tsdown reads `engines.node` as its build target, so this also shapes the bundle.
