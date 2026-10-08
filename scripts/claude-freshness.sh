#!/usr/bin/env bash
# claude-freshness.sh — is the ~/.claude checkout a fleet is about to dispatch on behind origin/main in a file the
# dispatched sessions load?
#
# WHY: every fleet session runs the hooks, skills, rules, standards and scripts in this checkout, and nothing updates it
# while a fleet runs, so a fleet launched from a stale checkout runs without everything that landed upstream since — a
# missing recovery hook, a retired launch posture. A checkout that has not fetched in weeks still reads 0 behind its own
# origin/main ref, so the check fetches first. The launchers (fleet-launch.sh, fleet-sequence.sh) call it before they
# dispatch or write anything and refuse on exit 4 unless the operator passes `stale-ok`.
#
# Usage: claude-freshness.sh
# Env:   CLAUDE_FRESHNESS_DIR      the checkout to check (default ~/.claude — tests point it at a fixture clone)
#        CLAUDE_FRESHNESS_TIMEOUT  seconds the fetch may take before it is killed (default 10)
#
# Exit 0, silent             current with origin/main.
# Exit 0, one NOTE line      behind only in files no session loads (NOT_LOADED below), or the fetch failed or timed
#                            out — an offline launch is never blocked.
# Exit 4, TOOLING-STALE      behind in a session-loaded file; up to 8 of those commits follow, on stderr.
# When behind and `/update`'s `git pull --ff-only` would refuse — a locally modified or untracked file that upstream
# also changed, or local commits ahead — the output also says so and points at /keeper, which owns local drift.
#
# Run ./claude-freshness.test.sh after ANY change.

set -uo pipefail

dir="${CLAUDE_FRESHNESS_DIR:-$HOME/.claude}"
limit="${CLAUDE_FRESHNESS_TIMEOUT:-10}"
[[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] || limit=10

unchecked() { # <reason>
  echo "NOTE: could not check ~/.claude freshness ($1) — launching"
  exit 0
}

# Everything outside this list counts as session-loaded, so a new top-level path is loaded until someone lists it here.
# What is listed is read by people or by repo tooling (markdownlint, the test chain), never by a running session.
NOT_LOADED=(
  ':(exclude)README.md'
  ':(exclude)skills/README.md'
  ':(exclude)linear-for-stakeholders.md'
  ':(exclude)mcpServers.md'
  ':(exclude)project-setup.md'
  ':(exclude)LICENSE'
  ':(exclude,glob)doc/**'
  ':(exclude,glob)pics/**'
  ':(exclude,glob).github/**'
  ':(exclude,glob).vscode/**'
  ':(exclude).editorconfig'
  ':(exclude).gitattributes'
  ':(exclude).gitignore'
  ':(exclude).markdownlint-cli2.jsonc'
  ':(exclude)package.json'
  ':(exclude)pnpm-lock.yaml'
  ':(exclude)pnpm-workspace.yaml'
  ':(exclude,glob)**/*.test.sh'
)

git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || unchecked "$dir is not a git checkout"

# macOS ships no `timeout`, so the fetch runs in the background under a polled deadline.
GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet origin main >/dev/null 2>&1 &
fetch_pid=$!
ticks=$(( limit * 5 ))
while kill -0 "$fetch_pid" 2>/dev/null && [ "$ticks" -gt 0 ]; do
  sleep 0.2
  ticks=$(( ticks - 1 ))
done
if kill -0 "$fetch_pid" 2>/dev/null; then
  pkill -TERM -P "$fetch_pid" 2>/dev/null
  kill -TERM "$fetch_pid" 2>/dev/null
  wait "$fetch_pid" 2>/dev/null
  unchecked "fetch failed"
fi
wait "$fetch_pid" || unchecked "fetch failed"

behind=$(git -C "$dir" rev-list --count HEAD..origin/main 2>/dev/null) || unchecked "no origin/main after the fetch"
[ "$behind" -gt 0 ] || exit 0
commits="$behind commits"; [ "$behind" -eq 1 ] && commits="1 commit"

refusal=""
upstream=$(git -C "$dir" diff --name-only HEAD...origin/main 2>/dev/null | sort -u)
local_files=$( { git -C "$dir" diff --name-only HEAD; git -C "$dir" ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
clash=$(comm -12 <(printf '%s\n' "$upstream") <(printf '%s\n' "$local_files") | grep -v '^$' | paste -sd, - | sed 's/,/, /g')
ahead=$(git -C "$dir" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
[ -n "$clash" ] && refusal="$clash modified locally"
if [ "$ahead" -gt 0 ]; then
  [ -n "$refusal" ] && refusal="$refusal; "
  refusal="$refusal$ahead local commit(s) not on origin/main"
fi
[ -n "$refusal" ] && refusal="the ~/.claude pull will refuse ($refusal) — run /keeper first"

loaded=$(git -C "$dir" log --oneline HEAD..origin/main -- . "${NOT_LOADED[@]}" 2>/dev/null)
if [ -z "$loaded" ]; then
  echo "NOTE: ~/.claude is $commits behind origin/main, none in a file sessions load — launching${refusal:+; $refusal}"
  exit 0
fi

n_loaded=$(printf '%s\n' "$loaded" | wc -l | tr -d ' ')
{
  echo "TOOLING-STALE: ~/.claude is $commits behind origin/main, including:"
  printf '%s\n' "$loaded" | head -8 | sed 's/^/  /'
  [ "$n_loaded" -gt 8 ] && echo "  … and $(( n_loaded - 8 )) more that touch session-loaded files"
  [ -n "$refusal" ] && echo "$refusal"
} >&2
exit 4
