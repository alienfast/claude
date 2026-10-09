#!/usr/bin/env bash
# typecheck.sh — run tsc over one mod against this build's claude-code.d.ts.
#
# The engine writes the declarations beside a mod (.claude-plugin/types/) only when an interactive session loads
# it; a `claude -p --plugin-dir` run does not. So this prefers that copy and falls back to the newest one the
# plugin-authoring skill extracted this session under /private/tmp/claude-<uid>/bundled-skills/.
#
# Usage: mods/typecheck.sh <mod-dir>
set -euo pipefail
mod=$(cd "${1:?usage: typecheck.sh <mod-dir>}" && pwd)
types="$mod/.claude-plugin/types/claude-code/index.d.ts"
if [ ! -f "$types" ]; then
  types=$(ls -t "/private/tmp/claude-$(id -u)"/bundled-skills/*/*/plugin-authoring/types/claude-code.d.ts 2>/dev/null | head -1 || true)
fi
if [ -z "$types" ] || [ ! -f "$types" ]; then
  echo "typecheck: no claude-code.d.ts found — load the plugin-authoring skill in a session first, or open the mod in an interactive session" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
work="$root/tmp/typecheck-$(basename "$mod")"
mkdir -p "$work"
cat >| "$work/tsconfig.json" <<TSCONFIG
{
  "compilerOptions": {
    "target": "es2023", "lib": ["es2023"], "types": [],
    "module": "esnext", "moduleResolution": "bundler",
    "strict": true, "noUncheckedIndexedAccess": true,
    "noEmit": true, "skipLibCheck": true,
    "jsx": "react", "jsxFactory": "h", "jsxFragmentFactory": "Fragment"
  },
  "include": ["$types", "$mod/hooks", "$mod/types", "$mod/tests"]
}
TSCONFIG
echo "typecheck: $(basename "$mod") against $types"
pnpm --package=typescript dlx tsc -p "$work/tsconfig.json"
