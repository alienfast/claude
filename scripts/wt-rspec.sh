#!/usr/bin/env bash
# Run rspec in a given directory without a `cd` or `VAR=` prefix on the command line.
#
# WHY THIS EXISTS: Bash permission rules are prefix-matched against the WHOLE command string, so
# `Bash(bundle exec rspec:*)` matches only a command that literally starts with `bundle exec rspec`.
# The invocation every worktree actually needs —
#     cd /path/to/worktree/apps/api && DB_PORT=3606 bundle exec rspec spec/foo_spec.rb
# — starts with `cd`, so no allow rule matches it and every such call falls through to the auto-mode
# classifier instead. That classifier is an LLM and therefore non-deterministic: on the 2026-08-01 BF
# fleet run it allowed 517 of 523 identical-shaped rspec calls and blocked 6. Two of the blocks were
# absorbed (a reviewer silently dropped a mutation test), and the third retry of one escalated to an
# interactive permission prompt that blocked an unattended session for 5h27m.
#
# Routing the call through a FIXED script path makes the command start with something a single
# allow rule can match exactly, so the classifier is never consulted and the outcome is the same
# every time. The wrapper is deliberately generic — it holds no project knowledge; the caller passes
# the directory and any env the project needs.
#
# USAGE
#   wt-rspec.sh [--env KEY=VALUE]... <dir> [rspec args...]
#
#   wt-rspec.sh --env DB_PORT=3606 /path/to/.claude/worktrees/bf-751/apps/api spec/policies/a_spec.rb
#   wt-rspec.sh --env DB_PORT=3606 "$WT/apps/api" spec/foo_spec.rb -e "some example"
#
# Exits with rspec's own status. --env is repeatable and applied only to the rspec process.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: wt-rspec.sh [--env KEY=VALUE]... <dir> [rspec args...]

  --env KEY=VALUE   Set an environment variable for the rspec process (repeatable).
  <dir>             Directory to run from (e.g. <worktree>/apps/api). Must exist.

Everything after <dir> is passed through to `bundle exec rspec` unchanged.
EOF
}

ENVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "wt-rspec: --env needs KEY=VALUE" >&2; exit 2; }
      [[ "$2" == *=* ]] || { echo "wt-rspec: --env expects KEY=VALUE, got: $2" >&2; exit 2; }
      ENVS+=("$2"); shift 2 ;;
    --env=*)
      ENVS+=("${1#--env=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { echo "wt-rspec: missing <dir>" >&2; usage; exit 2; }
DIR="$1"; shift
[[ -d "$DIR" ]] || { echo "wt-rspec: not a directory: $DIR" >&2; exit 2; }

cd "$DIR" || { echo "wt-rspec: cannot cd to $DIR" >&2; exit 2; }

# `env` applies the assignments to the child only, so a caller-supplied DB_PORT cannot leak into
# this shell or a later command. An empty ENVS array must not expand to a bare `env` argument, hence
# the explicit branch — under `set -u` an empty array expansion is an error on older bash.
if [[ ${#ENVS[@]} -gt 0 ]]; then
  exec env "${ENVS[@]}" bundle exec rspec "$@"
else
  exec bundle exec rspec "$@"
fi
