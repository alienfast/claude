#!/usr/bin/env bash
# Pre-flight for the /sentry skill: the agentic `sentry` CLI and jq exist, and the stored credential can READ
# issues for the project — probed with a real list, never `auth status`, because an organization release token
# (sntrys_*) passes a status check and 403s on the first query. The target is the optional <org/project>
# argument; without one the CLI resolves it itself (SENTRY_ORG/SENTRY_PROJECT, then the DSN or config under
# the cwd). On success prints the short-id prefix the probe returned, which is the check that the intended
# project was resolved. Exit 1 with one block of fixes on any failure; the calling skill stops there.

set -uo pipefail

target="${1:-}"
case "$target" in
  -h|--help)
    cat <<'SENTRY_PREFLIGHT_HELP'
Usage: preflight.sh [<org/project>]

Checks: jq installed; `sentry` installed; `sentry issue list [<org/project>] --limit 1` succeeds.
Run from the repo root when no target is given so the CLI can auto-detect from the project's DSN.
SENTRY_PREFLIGHT_HELP
    exit 0 ;;
esac

failures=()

command -v jq >/dev/null 2>&1 || failures+=("jq: not installed. Install: brew install jq")

if ! command -v sentry >/dev/null 2>&1; then
  failures+=("sentry: not installed. Run the project's .claude/update.sh, or: curl -fsS https://cli.sentry.dev/install | bash -s -- --no-agent-skills")
else
  args=(issue list)
  [ -n "$target" ] && args+=("$target")
  args+=(--limit 1 --json --fresh --fields shortId)
  err="$(mktemp)"
  out="$(sentry "${args[@]}" 2>"$err")"
  rc=$?
  if [ $rc -ne 0 ]; then
    detail="$(tr '\n' ' ' <"$err" | sed 's/  */ /g')"
    if [ -z "$target" ] && grep -qi 'organization and project are required' "$err"; then
      failures+=("sentry: no org/project resolved from this cwd. Run from the repo root (DSN auto-detect), export SENTRY_ORG and SENTRY_PROJECT, or pass <org/project> — the project's .claude/rules/sentry.md declares it")
    else
      case "${SENTRY_AUTH_TOKEN:-}" in
        sntrys_*) failures+=("sentry: cannot read ${target:-the detected project}'s issues — SENTRY_AUTH_TOKEN is an organization (CI release) token with no issue scopes. Run: sentry auth login (the stored login then outranks the env token). CLI said: ${detail}") ;;
        *)        failures+=("sentry: cannot read ${target:-the detected project}'s issues (unauthenticated, expired, scope-limited, or wrong target). Run: sentry auth login. CLI said: ${detail}") ;;
      esac
    fi
  else
    prefix="$(printf '%s' "$out" | jq -r '.data[0].shortId // empty' 2>/dev/null | sed -E 's/-[^-]+$//')"
  fi
  rm -f "$err"
fi

if [ ${#failures[@]} -gt 0 ]; then
  {
    echo "preflight: ${#failures[@]} problem(s) — fix and re-run the skill:"
    for f in "${failures[@]}"; do echo "  - $f"; done
  } >&2
  exit 1
fi

if [ -n "${prefix:-}" ]; then
  echo "preflight: ok — target ${target:-auto-detected}, short ids ${prefix}-*"
else
  echo "preflight: ok — target ${target:-auto-detected} (no issues in the last 90 days, so no short-id prefix to show)"
fi
