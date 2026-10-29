# Converge to the standardized-tooling target

This is the per-attribute remediation guide. For each target attribute it gives the **detection signal**
(from `scripts/detect-state.sh`), the **live source** to read the canonical config from, the apply steps, and
the non-obvious gotchas. Publishing-only attributes (tsdown, `auto`, OIDC, Actions) live in
[publishing.md](publishing.md).

## Read-live rule

The house configs evolve (Biome 2.5.x, pnpm 12.x, markdownlint-cli2 0.23.x, TypeScript 7.x, jscpd 5.x, …). **Read the
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
| `.jscpd.json`, `.claude/rules/check-clones.mjs`, `tools/scripts/merge-jscpd-baseline.mjs`, `tools/scripts/nodeRuntime.ts`, the two `tools/scripts/*.test.ts`, the `.gitattributes` line, the `prepare` registration | `basefund/…` at the same paths; `bfp-control-panel/…` for the no-CI, TypeScript-only adaptation and its `tools/scripts/vitest.config.ts` |
| `.jscpd-baseline.json` | **never copied** — generated from the target's own tree by `node .claude/rules/check-clones.mjs --update` |
| `renovate.json`, `.github/workflows/renovate.yml` | `basefund/…` at the same paths; `basefund-control-panel/…` for the single-package, no-Docker, no-CircleCI reduction |
| `.claude/update.sh` | `basefund/.claude/update.sh` (the frame); `basefund-control-panel/.claude/update.sh` for a Vercel-deployed app's tool block |
| tsdown, `auto`, OIDC workflow, `publishConfig` | see [publishing.md](publishing.md) |

## pnpm 12 + workspace + supply-chain cooldown + allow-builds

**Met when** `PACKAGE_MANAGER=pnpm`, `PACKAGE_MANAGER_PIN` is `pnpm@12.*`, `HAS_PNPM_WORKSPACE=true`, and
`HAS_COOLDOWN=true`.

**Source** — `basefund/pnpm-workspace.yaml` (monorepo: `registries`, `publicHoistPattern`, `overrides`,
`blockExoticSubdeps`) or `gltfjsx/pnpm-workspace.yaml` (single-package: just `minimumReleaseAge`,
`minimumReleaseAgeExclude`, `allowBuilds`). Match the target's shape (`IS_MONOREPO`).

### Apply

- Delete everything in `LEFTOVER_PM_FILES` (`yarn.lock`, `.yarnrc.yml`, `.yarn/`, `package-lock.json`, `.eslintcache`).
- Set `packageManager: "pnpm@12.x"` in `package.json` to a real 12 release older than the project's
  `minimumReleaseAge`, keeping corepack's `+sha512.<hex>` suffix — the house pin is the one
  `~/.claude/package.json` carries. Any pnpm ≥ 10 self-manages and auto-fetches the pinned 12, so the
  migration runs on an older machine.
- Create `pnpm-workspace.yaml` adapted from the source: `minimumReleaseAge: 10080` (7 days),
  `minimumReleaseAgeExclude: ['@alienfast/*']`, and an `allowBuilds:` name→boolean map (pnpm 11 replaced
  pnpm 10's `onlyBuiltDependencies` list). Seed `allowBuilds` with the obvious native builders the target
  actually has (`sharp`, `esbuild`, …) — do **not** copy basefund's full list blindly.
- Run `pnpm install`, then add only what pnpm reports as "ignored build scripts" via `pnpm approve-builds`.

### Gotchas

- `allowBuilds` is an allow-list, not a blanket — approve only what install reports, with intent.
- **Moving an 11 project to 12** (measured on 12.12.1, 2026-10): `pnpm-lock.yaml` becomes two YAML documents —
  pnpm's self-management document first, with its own `importers` and `snapshots`, the project lockfile last —
  so anything that parses the lockfile must read the **last** document, or a scan from the first `snapshots:`
  runs on into the project's `packages:`. Changing `packageManager` without regenerating the lockfile fails
  every frozen install with `ERR_PNPM_FROZEN_LOCKFILE_WITH_OUTDATED_LOCKFILE`; a pin younger than
  `minimumReleaseAge` fails every install with `ERR_PNPM_NO_MATURE_MATCHING_VERSION`; an unknown or misspelled
  `pnpm-workspace.yaml` key fails the install with `ERR_PNPM_UNRECOGNIZED_WORKSPACE_SETTINGS`; and an existing
  pnpm-11 `node_modules` is reused without a purge. `ncu -u` bumps the pin and strips the `+sha512` suffix —
  restore it (`corepack use pnpm@<v>`), or a `corepack enable pnpm` image build loses its only integrity check.
- Registry sub-branch: if `ALIENFAST_REGISTRY=github`, the target consumes `@alienfast/*` from GitHub
  Packages — mirror basefund's `registries: { '@alienfast': https://npm.pkg.github.com/ }` and inject the
  token at install time (Docker `pnpm_config_//…` env, CI `pnpm config set` from `$GITHUB_TOKEN`, dev user
  `~/.npmrc`). Move the scope→registry mapping out of the project's existing `.npmrc` (or the `.yarnrc.yml`
  `npmScopes` block) into `pnpm-workspace.yaml registries:`, then **delete the committed `.npmrc`** — the
  `.yarnrc.yml` is already removed as a pnpm leftover, but `.npmrc` is not, and pnpm ≥ 11.5.3 ignores
  env-var auth in a committed `.npmrc` anyway (GHSA-3qhv-2rgh-x77r). If `ALIENFAST_REGISTRY=npm` (resolves
  from public npm), no registry config is needed.
- The `ALIENFAST_REGISTRY` signal reads the *current* package manager's registry config and lockfiles
  (`.npmrc`, `.yarnrc.yml`, `yarn.lock`, …), not just `pnpm-lock.yaml` — so it is correct **before** the pnpm
  migration, when no `pnpm-lock.yaml` exists yet.

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

**Met when** `HAS_CHECK_SUITE=true`, `HAS_NPM_RUN_ALL=true`, `HAS_MADGE=true`, `HAS_MADGERC=true` (the clone gate's own
lane is the next section).

**Source** — `basefund/package.json` (turbo-based `check-types`/`test`) or `gltfjsx/package.json` (single:
`tsc --noEmit`, `vitest run`); `.madgerc` from `gltfjsx/.madgerc`.

### Apply

Add `npm-run-all2` (the maintained fork of `npm-run-all`, which the detector still accepts; replace an `npm-run-all`
entry with it — same `run-p` flags) + `madge` and the script suite, adapting `check-circular`'s extensions and src dirs
to the target (`./src` single-package; `./apps/*/src ./packages/*/src …` monorepo):

```json
"check": "run-p -c --aggregate-output check-types check-biome check-circular check-clones check-markdown test test-tools",
"check-biome": "biome check --write",
"check-circular": "madge --circular --extensions ts <src dirs> --ts-config ./tsconfig.json",
"check-clones": "node .claude/rules/check-clones.mjs --self-test && node .claude/rules/check-clones.mjs",
"check-markdown": "markdownlint-cli2 --fix \"**/*.md\"",
"check-types": "tsc --noEmit",
"test": "vitest run",
"test-tools": "vitest run --config tools/scripts/vitest.config.ts"
```

### Gotchas

- Add `.madgerc` with `{ "detectiveOptions": { "ts": { "skipTypeImports": true }, "tsx": { "skipTypeImports": true } } }` —
  madge flags type-only import cycles by default; this makes `check-circular` report only real **runtime** cycles. The `tsx`
  entry is not optional: `.tsx` files use their own detective, so with `ts` alone their type-only imports still count as edges.
- **TypeScript 7 breaks `--ts-config <path>`.** madge reads a tsconfig *path* through `ts.sys.readFile`, which TS 7 no longer
  exports, so `check-circular` dies with `TypeError: Cannot read properties of undefined (reading 'readFile')`. Dropping the flag
  is safe only when the target has no `compilerOptions.paths`: otherwise every aliased import is silently skipped and madge still
  prints "No circular dependency found!". With `paths`, pass them as a `tsConfig` **object** through madge's JS API (which never
  calls `ts.sys`) and fail on unresolved imports — basefund-control-panel's `scripts/check-circular.mjs` is a worked example.
- Do not add a separate `build:ide` tsc script — point `.vscode/tasks.json` at the `check-types` script instead.
- `BUNDLER` is a root-level signal; in a monorepo each publishable package decides tsdown vs not on its own.

## Clone gate (jscpd)

**Met when** `HAS_JSCPD=true`, `HAS_JSCPD_BASELINE=true`, `HAS_CHECK_CLONES=true` and `HAS_JSCPD_MERGE_DRIVER=true`.

**Source** — `basefund/.jscpd.json`, `basefund/.claude/rules/check-clones.mjs`, `basefund/tools/scripts/merge-jscpd-baseline.mjs`,
`nodeRuntime.ts`, `merge-jscpd-baseline.test.ts`, `check-clones-base.test.ts`, the `.gitattributes` line and the `prepare`
registration; `bfp-control-panel` holds the same files adapted to a target with no CI runner and no Ruby, plus the
`tools/scripts/vitest.config.ts` a repo without a root vitest config needs. The lane's docblock is the full contract — the
fingerprint baseline, the re-pairing filter, the accepted false greens — and is read, not summarized here.

### Apply

- Add `jscpd` and `execa` (the tests spawn `git` and `node` through it) to the root devDependencies, caret ranges. Copy
  `.jscpd.json` and adapt it: `format`/`formatsExts` to the target's languages (basefund scans TS and Ruby; a TS-only
  target drops `ruby` and the `formatsExts` entry), `pattern` to its source roots, `ignore` to its build outputs — keep
  `.claude/worktrees/**` and `tmp/**`, `minLines: 10` and the import-line `ignorePattern`.
- Copy `check-clones.mjs` to `.claude/rules/check-clones.mjs` — the same path, because the merge driver's conflict message,
  the rule prose and the script's own `UPDATE_COMMAND` all spell it. Adapt the base resolution to the target's CI:
  basefund resolves CircleCI (the open PR's target through GitHub, else `CHECK_CLONES_BASE_REVISION`); a target with no
  CI runner keeps only the local resolution (`start.source-branch`, else the default branch) and deletes
  `lookupPrTarget`, `resolvePreviousBuild`, `resolveCiBase` and their three constants, as bfp-control-panel did; a GitHub
  Actions target would read `GITHUB_BASE_REF` and has no worked example yet. Rewrite the docblock's environment list and
  parity paragraph to match. When the config drops a format, drop that format's fixtures from the self-test too
  (`rubyBlock`, the `.rb`/`.rake` entries of `BASE_TREE`, `PLANTS` and `PLANTED_PAIRS`, the success line) — the
  self-test copies the real `.jscpd.json`, so a planted copy in an unscanned format is never reported and the self-test
  fails.
- Copy the merge driver, `nodeRuntime.ts` and the two tests into `tools/scripts/`. Adapt the merge test's `prepare`
  assertion to whatever ends the target's `prepare` (basefund: `husky`; bfp: `tools/stack-slot ensure`) and its expected
  driver list (basefund registers two drivers). Drop the base test's CI `describe` blocks with the CI code, and
  rewrite its "green on the target's own build" arm as a local one (on the merged tree nothing is changed against the
  base, so the re-pairing is accepted). Wire the tests in: a `projects` entry on the root vitest config where one exists
  (basefund), else `tools/scripts/vitest.config.ts` with `root` set to its own directory and a `test-tools` script
  passing `--config` (bfp); `tools/` is not a workspace, so the turbo `test` task never reaches it.
- `.gitattributes`: `/.jscpd-baseline.json merge=jscpd-baseline`. `prepare`: prepend the two
  `git config --replace-all merge.jscpd-baseline.{name,driver} … || true;` registrations, unchained, ahead of whatever
  else runs there (copy the driver command verbatim from basefund's `prepare`: it falls back to `git merge-file` when the
  script is missing). `.gitignore`: `/.merge_file_*` and `/.jscpd-baseline.json.staged-*`. Biome: exclude
  `.jscpd-baseline.json` from `files.includes`, with the one-line reason (the tests compare it byte for byte).
- Then, in this order: `pnpm install` (registers the driver, installs the platform binary), `biome check --write`,
  `node .claude/rules/check-clones.mjs --self-test`, `node .claude/rules/check-clones.mjs --update` (the first baseline),
  `node .claude/rules/check-clones.mjs` (green, `judged against …`), `pnpm test-tools`.

### Gotchas

- The cooldown applies to jscpd like anything else: on 2026-10-24 `^5.4.1` resolved to 5.4.1 because 5.4.2 was four
  days old. A later jscpd can re-key every fingerprint; a red listing most of the tree's clones on a version bump is a
  re-keyed baseline, regenerated with `--update` in the same change.
- The baseline is generated per target, never copied: it records that tree's clones as they stand. Later `--update`
  runs list each pair the committed baseline lacked; the first one has nothing to diff against and lists nothing, so
  read the first recording through jscpd's JSON reporter (the SKILL's follow-up names the command) before committing it.
- Vendored or synced source inside the scan (bfp's `packages/*/src`) is a choice to make explicitly: scanning it catches a
  copy of a vendored component into the app, at the cost that every re-sync lands upstream's new clones as fresh
  fingerprints — the sync skill's gate then records them (bfp's `sync-shared` gate, step 7). Excluding it is the quieter
  choice and misses that copy.
- `--update` after `biome check --write`, always: fingerprints are over the tokens as written, and a clone red that appears
  only on a second `pnpm check` is Biome, running beside the lane, having formatted a copy into a match.
- The lane runs inside `check` where the developer's machine is the whole gate; a target with CI also runs
  `--self-test && node .claude/rules/check-clones.mjs` as its own fail-fast CI step (basefund's shape), since `pnpm check`
  is never invoked as a whole in CI.
- A worktree entered by hand or by `EnterWorktree` records no `start.source-branch`, so the lane judges against the
  default branch; the output names the base either way (`judged against default branch main`).
- **Keep `tools/` out of the app tsconfig.** Neither source repo type-checks `tools/scripts` (their root includes stop at
  `apps/*/src`); a single-package target whose tsconfig includes `**/*.ts` pulls the two suites into the app program, and
  `next build` type-checks that same program, so a red here breaks the deploy. Measured on basefund-control-panel: Next's
  global types make `ProcessEnv.NODE_ENV` required, so the tests' `Record<string, string>` env fails against the JS lane's
  parameter inferred from its `process.env` default, and the lane's inferred result unions never narrow. Add `tools` to the
  root `exclude` and let vitest transpile the suites, as upstream does; the self-test's fixture paths must also sit under
  the target's `.jscpd.json` `pattern` roots (basefund's `apps/…`, `packages/plant/…` → the target's `src/…`, `tools/…`,
  template literals included), or the self-test scans nothing and fails.
- **The default-branch order follows how the target pushes.** Upstream's `resolveLocalBase` asks `origin/HEAD` before the
  local `main`, which is right where `main` is pushed promptly. A repo that pushes `main` lazily (bfp-control-panel) must
  ask the local `main` first: against `origin/main`, everything merged since the last push reads as changed, and the
  next branch off `main` is charged with the clones those merges carried — measured as 48 vendored story pairs from a
  shared-package sync, red on a branch that touched none of them. Flip the order, the `unfiltered` wording and the base
  test's "ahead of a local main" arm together.

## Renovate

**Met when** `HAS_RENOVATE_CONFIG=true` and `HAS_RENOVATE_WORKFLOW=true`.

**Source** — `basefund/renovate.json` and `basefund/.github/workflows/renovate.yml`. One org-owned GitHub App
(`basefund-renovate`) drives every repo it is installed on, and the job is self-hosted on GitHub Actions; the Mend-hosted app
is not used.

### Apply

- Copy `renovate.json` and keep its spine: `config:recommended`, `minimumReleaseAge: "7 days"` (the window
  `pnpm-workspace.yaml` enforces), the `@alienfast/**` exemption, `separateMajorMinor: false` with the `weekly updates` group
  over `*`, the `vulnerabilityAlerts` batch (`security updates`, immediate, `security` label), the
  `ghcr.io/renovatebot/renovate` → npm datasource override that lets the workflow's own `renovate-version` pin clear the
  cooldown, replacements off, the Wednesday schedule and Chicago timezone, `dependencyDashboard: false`.
- Drop what the target has no manager for: every `customManagers` entry (CircleCI marker pins, Dockerfile Alpine bases,
  Pulumi image pins) and every `packageRules` hold that is basefund's own (graphql, redis, mysql, the bundler pin rule, the
  dockerfile digest rules, traefik and cert-manager). Mirror the target's `.ncurc.cjs` `reject` entries as `allowedVersions`
  rules, each with a description naming what has to move before it lifts; `reject: []` means none. A runtime the target
  pins outside `package.json` (a Vercel project's Node setting, `node-version:` in workflows) keeps the `node` hold with
  the real reason.
- Copy the workflow, keeping: the SHA-pinned actions as they are (basefund's Renovate bumps them, so re-pin per
  `~/.claude/standards/github-actions.md` only on a hand bump), the `renovate-version` pin, the cron, the
  `pull_request_target` rebase-checkbox trigger, `permissions: {}`, the App-token step with its full `permission-*` list (the
  App's grants; a permission the App lacks fails token creation), the repository-cache steps, `RENOVATE_ONBOARDING: 'false'`
  and `RENOVATE_EXIT_CODE_FOR_ERRORS: 'true'`. Drop the Docker Hub host rule and `RENOVATE_DOCKER_MAX_PAGES` on a target that
  builds no images. Point the `notify` job at the target's existing failure-alert channel and secrets: basefund posts through
  `slackapi/slack-github-action`; a repo whose other workflows `curl` `chat.postMessage` with `SLACK_BOT_TOKEN` keeps that
  shape and checks Slack's `ok`, since a 200 with `ok: false` is how a bad token or channel answers.

### Gotchas

- The skill writes the two files; the run needs four things in GitHub that an unattended session is refused (measured
  2026-10-29: the auto-mode classifier denied `gh variable set`, `gh label create` and the installation `PUT`), so they are
  follow-ups unless the user approves them live: the `basefund-renovate` App added to the repo (org settings → GitHub Apps →
  the installation's repository list; it is `repository_selection: selected`), the `RENOVATE_APP_CLIENT_ID` repository
  variable (the same value as basefund's, `gh variable list -R alienfast/basefund`), the `RENOVATE_APP_PRIVATE_KEY` secret
  (the App's private key, never readable back; generate a new one on the App's settings page if nobody holds the PEM), and
  the `security` label. Verify with a `workflow_dispatch` run at `dry_run: lookup` before the first scheduled run.
- `minimumReleaseAge` here and in `pnpm-workspace.yaml` must stay equal, or Renovate opens PRs pnpm refuses
  (`~/.claude/rules/package-manager.md`). The first weekly PR moves `packageManager` to the newest pnpm older than the
  window and keeps the `+sha512` suffix only because the pin carries one; never merge a bare pin.
- Renovate's `github-actions` manager reaches every workflow in the repo, `node-version:` pins included: without the
  `node` hold a Node major lands in the weekly batch while the Vercel runtime stays where the dashboard set it.

## `.claude/update.sh`

**Met when** `HAS_PROJECT_UPDATE_SH=true`, `UPDATE_SH_RUNS_GLOBAL=true`, `UPDATE_SH_LINTS=true` and
`UPDATE_SH_PULLS_CLAUDE=false`.

**Source** — `basefund/.claude/update.sh` (the frame; its Sentry and gcloud blocks are its own).
`basefund-control-panel/.claude/update.sh` holds the Vercel CLI and Application Default Credentials blocks for a
Vercel-deployed app on Cloud SQL. `bfp-control-panel`'s copy still carries the older `~/.claude` pull and links with
`--team`, which Vercel CLI 65 deprecates for `--scope`: take its Vercel block, not its frame or that flag.

### Apply

The script is what `/update` runs and what a `SessionStart` hook may run on every session, so it is three parts and nothing
slow or interactive:

1. `"$HOME/.claude/update.sh"` — the global script pulls `~/.claude` itself (`--ff-only`, then re-runs from the pulled
   version) and converges pnpm, Claude Code, plugins, skills and the CLI tools. Delete any project copy of the origin check
   and `git -C ~/.claude pull`: it predates the global script's own pull and now only duplicates it with stale messages.
2. Project tools, each a check that warns and continues (`set -e` is on, so a failing install is `|| echo "⚠️ …"`): what a
   developer needs for *this* app that nothing else installs — a Vercel CLI install, login check and repo link for a
   Vercel-deployed app; an ADC check for a Cloud SQL connector; `brew_ensure` for a CLI the app's skills shell out to.
   Sign-ins are TTY-gated, so print the exact command instead of prompting; the `/update` skill collects every ⚠️ for the
   user.
3. `source "$HOME/.claude/lib/lint.sh"`, `lint_and_fix "pnpm check-biome && pnpm check-markdown"`, the restart notice.

### Gotchas

- No `pnpm install` here: the global script already converges pnpm, and an install on every session start would race a
  worktree's.
- `#!/bin/bash` and bash-3.2-clean (`~/.claude/rules/bash.md`): macOS runs it on `/bin/bash`.
- A `SessionStart` hook in `.claude/settings.json` that runs it (`./.claude/update.sh 2>&1 || true`) is the target's own
  choice, not part of the house shape; basefund has none.

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

Add `.ncurc.cjs` with `packageFile: './package.json'`, `packageManager: 'pnpm'`, `root: true` and, for a monorepo,
`workspaces: true` — and **no `cooldown`**: ncu ≥ 22 inherits `minimumReleaseAge` and `minimumReleaseAgeExclude` from
`pnpm-workspace.yaml` when the rc sets none (it prints `Using minimumReleaseAge from pnpm-workspace.yaml`), and a
hand-written `cooldown` overrides that inheritance and drifts from the install gate. Basefund's live file carries the
one-line reason as a comment, plus per-package `reject` entries that are its own; copy the shape, not the rejects.

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
