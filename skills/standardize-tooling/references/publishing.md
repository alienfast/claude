# Publishing: tsdown + auto + OIDC trusted publishing

Read this only when the target is published to npm (`IS_PUBLISHED=true`). It covers the bundler (tsdown) and
the release path (`auto` + OIDC token-less trusted publishing + up-to-date GitHub Actions). basefund is not
published, so the canonical sources here are `~/projects/gltfjsx` and `~/projects/vite-plugin-i18next-loader`
— read them live and adapt.

## Source-of-truth map

| Concern | Canonical source (read live) |
| --- | --- |
| `tsdown.config.ts` | `gltfjsx/tsdown.config.ts` |
| `.mjs`/`.d.mts` `bin`/`exports`/`engines` | `gltfjsx/package.json` |
| `auto` config (`setRcToken: false`) | `gltfjsx/package.json` or `vite-plugin-i18next-loader/package.json` |
| OIDC release workflow (single-job) | `gltfjsx/.github/workflows/release.yml` |
| OIDC release workflow (multi-job, reusable actions) | `vite-plugin-i18next-loader/.github/workflows/build.yml` |

## tsdown (if the package bundles a library/CLI)

**Met when** `BUNDLER=tsdown`. Migrate when `BUNDLER=tsup`.

### Apply

Run `npx tsdown-migrate`, then clean up against tsdown's defaults:

- `clean: true` is the default — drop an explicit `clean`.
- Code-splitting is always on — drop `splitting`.
- `dts` is auto-enabled from `package.json` `types` — drop explicit `dts` unless overriding.
- Output is `.mjs` / `.d.mts` — **update `bin` and `exports`/`types` accordingly** (e.g. `"bin":
  "./dist/cli.mjs"`, `"exports": { ".": { "import": "./dist/index.mjs", "types": "./dist/index.d.mts" } }`).

### Gotchas

- The shebang and the executable bit are handled automatically — drop any `chmod` step.
- There is no `tsdown-node`.
- tsdown reads `engines.node` as its build target — set it to the real dependency floor (see
  [converge.md](converge.md)).

## auto for release management

**Met when** `HAS_AUTO=true`.

### Apply

Configure `auto` in `package.json` with the npm plugin set to publish token-less:

```json
"auto": {
  "plugins": [
    ["npm", { "setRcToken": false }],
    "all-contributors",
    "first-time-contributor",
    "released"
  ]
}
```

`setRcToken: false` makes `npm publish` run without writing a token to `.npmrc`, so the npm CLI uses OIDC and
emits automatic provenance. Add `"release": "auto shipit"` to scripts and `"publishConfig": { "access": "public" }`.

## OIDC token-less trusted publishing

**Met when** `HAS_OIDC_WORKFLOW=true`.

### Apply

In the release workflow:

- Set the `permissions:` block: `id-token: write` (OIDC) + `contents: write` + `pull-requests: write` +
  `issues: write` (auto's plugins).
- Use the **built-in** `GITHUB_TOKEN` (`env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`) — drop any `GH_TOKEN`
  PAT and remove `NPM_TOKEN`.
- Pin the runner Node to 24 (npm ≥ 11.5.1 is required for OIDC; `gltfjsx/release.yml` pins `24.18.0` for an
  unrelated `http.Agent` fix — copy its rationale comment only if the same regression applies).
- **Bump GitHub Actions + Node versions** while here (`actions/checkout`, `actions/setup-node`,
  `pnpm/action-setup`, `git-auto-commit-action`, etc.) to current majors. If any are SHA-pinned, resolve the
  new pins per `~/.claude/standards/github-actions.md`.

### Manual prerequisite — flag it to the user

A Trusted Publisher must be configured on npmjs.com for the package: select GitHub Actions, set org/repo, and
the **workflow filename** (e.g. `release.yml`, not the workflow's `name:` field). Without it the OIDC publish
fails. Surface this in the final summary, alongside deleting the now-unused `GH_TOKEN` / `NPM_TOKEN` repo secrets.
