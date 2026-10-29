---
name: standardize-tooling
description: >-
  Converge a TypeScript project's dev tooling onto the house conventions — pnpm 12, Biome (no ESLint/Prettier),
  markdownlint-cli2, madge, the jscpd clone gate, the parallel `check` suite, self-hosted Renovate (basefund's config and
  workflow), the project `.claude/update.sh`, tsdown for libraries, `auto` with OIDC publishing — then gate on `pnpm check`.
  Idempotent; applies only the gaps. Use when the user says 'standardize tooling', 'migrate to pnpm/Biome/tsdown', 'apply
  house tooling conventions', 'add renovate', or asks to convert off yarn/npm + ESLint/Prettier + tsup.
---

# Standardize Tooling

Bring a TypeScript project to the house dev-tooling **target state** by detecting where it diverges and
converging only the gaps, then gating on a green `pnpm check`. This is not a fixed-order recipe — it is a
target plus a delta.

## Target state (the contract)

A standardized project has all of:

- **pnpm 12** — `packageManager: pnpm@12.x`, a `pnpm-workspace.yaml` with the 7-day supply-chain
  `minimumReleaseAge` cooldown, an `allowBuilds` allow-list, and — if it consumes `@alienfast/*` from GitHub
  Packages — the `registries` mapping with install-time token injection.
- **Biome** for lint and format, with **no ESLint and no Prettier** (and no `lint-staged`).
- **markdownlint-cli2** with the house `.markdownlint-cli2.jsonc`.
- **madge** circular-import check via `.madgerc` (`skipTypeImports: true`).
- The **jscpd clone gate** — `jscpd` with the house `.jscpd.json`, a committed `.jscpd-baseline.json` of content
  fingerprints generated from the target's own tree, the `check-clones` lane (`.claude/rules/check-clones.mjs`, read
  live from basefund and adapted to the target's CI and languages), the baseline's `merge=jscpd-baseline` driver
  (`tools/scripts/merge-jscpd-baseline.mjs` + `.gitattributes`, registered by the root `prepare`), and their tests in a
  node-only `test-tools` vitest lane.
- The **standardized parallel `check` suite** — a `run-p -c --aggregate-output` lane set (`npm-run-all2`) covering at
  least check-types, check-biome, check-circular, check-clones, check-markdown, test and test-tools; read the current
  lanes live from basefund's `check-unlocked` script (its `check` is a lock wrapper around it).
- **`.ncurc.cjs`** cooldown aligned to pnpm's 7-day window.
- **Renovate**, self-hosted — `renovate.json` adapted from basefund's (`config:recommended`, a 7-day `minimumReleaseAge`
  equal to pnpm's cooldown, `@alienfast/**` exempt, one weekly batch with majors, an immediate `security updates` batch,
  the workflow's own Renovate pin looked up on npm, replacements off, holds mirroring the target's `.ncurc.cjs` rejects)
  and `.github/workflows/renovate.yml` running as the org's `basefund-renovate` GitHub App on the same 4-hourly cron.
- **`.claude/update.sh`** in the house shape — runs `~/.claude/update.sh` (which owns the `~/.claude` pull), then the
  project's own tool checks, then `lint_and_fix "pnpm check-biome && pnpm check-markdown"`; it no longer pulls `~/.claude`
  itself.
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
  `.ncurc.cjs`, the `check` suite, the clone gate (`.jscpd.json`, `.claude/rules/check-clones.mjs`,
  `tools/scripts/merge-jscpd-baseline.mjs` and their tests), `renovate.json` + `.github/workflows/renovate.yml`,
  `.claude/update.sh`, and `.vscode/*`. `~/projects/bfp-control-panel` is the worked example of the clone gate adapted to
  a target with no CI runner and TypeScript only; `~/projects/basefund-control-panel` is that adaptation plus Renovate
  and the update script on a single-package Vercel app.
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
`HAS_MADGE`/`HAS_MADGERC`, `HAS_JSCPD`/`HAS_JSCPD_BASELINE`/`HAS_CHECK_CLONES`/`HAS_JSCPD_MERGE_DRIVER`,
`HAS_MARKDOWNLINT`, `HAS_COOLDOWN`, `HAS_NCURC`, `HAS_RENOVATE_CONFIG`/`HAS_RENOVATE_WORKFLOW`,
`HAS_PROJECT_UPDATE_SH`/`UPDATE_SH_RUNS_GLOBAL`/`UPDATE_SH_PULLS_CLAUDE`/`UPDATE_SH_LINTS`, `VSCODE_TASKS_CHECK_TYPES`.

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
- Generate `.jscpd-baseline.json` (`node .claude/rules/check-clones.mjs --update`) **after** `pnpm install` (the
  driver registration in `prepare` and the jscpd binary both come from it) and **after** the first `biome check --write`,
  since the fingerprints are over the tokens as written.

### 4. Gate

Run `pnpm check` and fix what it surfaces; re-read auto-fixed files and hand-fix only what survives. Loop
until it is green. Disable a Biome/lint rule only when it conflicts with an intentional codebase pattern,
with a one-line documented reason — never to silence a real finding.

### 5. Summarize

Report what converged and what was already met. List the **manual follow-ups** separately — the skill cannot
do these:

- Configure the npmjs **Trusted Publisher** for the package (GitHub Actions; org/repo; workflow filename).
- Delete now-unused `GH_TOKEN` / `NPM_TOKEN` repo secrets.
- Wire Renovate in GitHub: add the repo to the `basefund-renovate` App installation, set the `RENOVATE_APP_CLIENT_ID`
  variable and `RENOVATE_APP_PRIVATE_KEY` secret, create the `security` label, then dispatch the workflow at
  `dry_run: lookup` ([references/converge.md](references/converge.md) § Renovate names each). An unattended session is
  refused these writes.
- Optionally run `/dependency-updater` for a full app-dependency refresh, and `/init` to create/update CLAUDE.md.
- Commit `.jscpd-baseline.json` with the gate, and read what it records before doing so: every pair is a clone the
  tree carries today, accepted as it stands rather than consolidated. The first `--update` prints no pair listing (it
  lists only what a committed baseline lacked), so list them with the JSON reporter —
  `pnpm exec jscpd --config .jscpd.json --reporters json --output tmp/jscpd-report` — and summarize by directory
  pair; on bfp-control-panel 550 of 620 pairs touched a test or story file and none crossed `apps/` and `packages/`.
