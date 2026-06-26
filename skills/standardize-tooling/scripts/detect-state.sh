#!/usr/bin/env bash
# Probe a TARGET TypeScript project and print KEY=value gap signals the standardize-tooling
# workflow branches on. Read-only: it inspects files, never mutates. Run from anywhere:
#   detect-state.sh [target-dir]   (default: current directory)
#
# Each signal answers "is this target attribute already met?" so the workflow converges only the gaps.
set -euo pipefail

TARGET="${1:-$PWD}"
PKG="$TARGET/package.json"

if [[ ! -f "$PKG" ]]; then
  echo "ERROR: no package.json at $TARGET" >&2
  exit 1
fi

# Read a dotted package.json path (e.g. scripts.check); prints empty string when absent.
field() {
  node -e '
    const p = require(process.argv[1]);
    let v = p;
    for (const k of process.argv[2].split(".")) v = v == null ? undefined : v[k];
    process.stdout.write(v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
  ' "$PKG" "$1"
}

# True when a dependency name is present in either dependencies or devDependencies.
has_dep() {
  node -e '
    const p = require(process.argv[1]);
    const all = { ...(p.dependencies||{}), ...(p.devDependencies||{}) };
    process.exit(process.argv[2] in all ? 0 : 1);
  ' "$PKG" "$1"
}

# First glob match that exists, else "".
first_glob() { local f; for f in "$@"; do [[ -e "$f" ]] && { echo "$f"; return; }; done; echo ""; }

emit() { echo "$1=$2"; }

emit TARGET "$TARGET"

# --- Package manager ---------------------------------------------------------
pm="unknown"
if [[ -f "$TARGET/pnpm-lock.yaml" ]] || [[ "$(field packageManager)" == pnpm@* ]]; then pm="pnpm"
elif [[ -f "$TARGET/yarn.lock" ]]; then pm="yarn"
elif [[ -f "$TARGET/package-lock.json" ]]; then pm="npm"; fi
emit PACKAGE_MANAGER "$pm"
emit PACKAGE_MANAGER_PIN "$(field packageManager)"

# Leftover non-pnpm artifacts that the pnpm migration should delete.
leftovers=""
for f in yarn.lock .yarnrc.yml .yarn package-lock.json .eslintcache; do
  [[ -e "$TARGET/$f" ]] && leftovers="$leftovers $f"
done
emit LEFTOVER_PM_FILES "${leftovers# }"

# --- Workspace shape ---------------------------------------------------------
is_mono="false"
if { [[ -f "$TARGET/pnpm-workspace.yaml" ]] && grep -qE '^\s*packages:' "$TARGET/pnpm-workspace.yaml"; } \
   || [[ -n "$(field workspaces)" ]]; then is_mono="true"; fi
emit IS_MONOREPO "$is_mono"
emit HAS_PNPM_WORKSPACE "$([[ -f "$TARGET/pnpm-workspace.yaml" ]] && echo true || echo false)"

# --- Linter / formatter ------------------------------------------------------
eslint="false"
[[ -n "$(first_glob "$TARGET"/eslint.config.* "$TARGET"/.eslintrc*)" ]] && eslint="true"
{ has_dep eslint || [[ -n "$(field eslintConfig)" ]]; } && eslint="true"
emit HAS_ESLINT "$eslint"

prettier="false"
[[ -n "$(first_glob "$TARGET"/.prettierrc* "$TARGET"/prettier.config.* "$TARGET"/.prettierignore)" ]] && prettier="true"
{ has_dep prettier || [[ -n "$(field prettier)" ]]; } && prettier="true"
emit HAS_PRETTIER "$prettier"

emit HAS_LINT_STAGED "$({ [[ -n "$(field lint-staged)" ]] || has_dep lint-staged; } && echo true || echo false)"
emit HAS_BIOME "$([[ -n "$(first_glob "$TARGET"/biome.json "$TARGET"/biome.jsonc)" ]] && echo true || echo false)"

# --- Bundler -----------------------------------------------------------------
bundler="none"
if [[ -n "$(first_glob "$TARGET"/tsdown.config.*)" ]] || has_dep tsdown; then bundler="tsdown"
elif [[ -n "$(first_glob "$TARGET"/tsup.config.*)" ]] || has_dep tsup; then bundler="tsup"; fi
emit BUNDLER "$bundler"

# --- Private @alienfast registry consumption ---------------------------------
# Does the target depend on @alienfast/* and, if so, where do those tarballs resolve from?
# npm.pkg.github.com anywhere the *current* package manager records the scope => private GitHub
# Packages (needs `registries:` + token injection). Check registry-config files AND every lockfile,
# not just pnpm-lock.yaml — a pre-migration project on yarn/npm has no pnpm-lock.yaml yet, so keying
# off it alone is a false negative (the mapping lives in .npmrc / .yarnrc.yml / the yarn|npm lockfile).
alienfast="none"
if grep -rqE '"@alienfast/' "$TARGET"/package.json "$TARGET"/{apps,packages,ops}/*/package.json 2>/dev/null; then
  alienfast="npm"
  for f in .npmrc .yarnrc.yml .yarnrc pnpm-workspace.yaml pnpm-lock.yaml yarn.lock package-lock.json; do
    if [[ -f "$TARGET/$f" ]] && grep -qE 'npm\.pkg\.github\.com' "$TARGET/$f"; then alienfast="github"; break; fi
  done
fi
emit ALIENFAST_REGISTRY "$alienfast"

# --- Publishing --------------------------------------------------------------
published="true"; [[ "$(field private)" == "true" ]] && published="false"
emit IS_PUBLISHED "$published"
emit HAS_AUTO "$({ [[ -n "$(field auto)" ]] || has_dep auto || [[ -f "$TARGET/.autorc" ]]; } && echo true || echo false)"
oidc="false"
if [[ -d "$TARGET/.github/workflows" ]] && grep -rqE 'id-token:\s*write' "$TARGET/.github/workflows" 2>/dev/null; then oidc="true"; fi
emit HAS_OIDC_WORKFLOW "$oidc"

# --- check suite & tooling ---------------------------------------------------
check="$(field scripts.check)"
emit HAS_CHECK_SUITE "$([[ "$check" == *run-p* && "$check" == *check-biome* ]] && echo true || echo false)"
emit HAS_BUILD_IDE_SCRIPT "$([[ -n "$(field scripts.build:ide)" ]] && echo true || echo false)"
emit HAS_NPM_RUN_ALL "$(has_dep npm-run-all && echo true || echo false)"
emit HAS_MADGE "$({ has_dep madge || [[ -f "$TARGET/.madgerc" ]] || [[ -n "$(field scripts.check-circular)" ]]; } && echo true || echo false)"
emit HAS_MADGERC "$([[ -f "$TARGET/.madgerc" ]] && echo true || echo false)"
emit HAS_MARKDOWNLINT "$({ has_dep markdownlint-cli2 || [[ -f "$TARGET/.markdownlint-cli2.jsonc" ]]; } && echo true || echo false)"
emit HAS_COOLDOWN "$({ [[ -f "$TARGET/pnpm-workspace.yaml" ]] && grep -qE '^\s*minimumReleaseAge:' "$TARGET/pnpm-workspace.yaml"; } && echo true || echo false)"
emit HAS_NCURC "$([[ -n "$(first_glob "$TARGET"/.ncurc.cjs "$TARGET"/.ncurc.js)" ]] && echo true || echo false)"

# --- .vscode -----------------------------------------------------------------
vscode_ct="false"
if [[ -f "$TARGET/.vscode/tasks.json" ]] && grep -q 'check-types' "$TARGET/.vscode/tasks.json"; then vscode_ct="true"; fi
emit VSCODE_TASKS_CHECK_TYPES "$vscode_ct"
emit HAS_VSCODE "$([[ -d "$TARGET/.vscode" ]] && echo true || echo false)"
