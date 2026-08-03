#!/usr/bin/env bash
# Run a project's ./ci subcommand in a given directory without a `cd` or `VAR=` prefix on the
# command line.
#
# WHY THIS EXISTS: same mechanism as wt-rspec.sh — Bash permission rules are prefix-matched against
# the WHOLE command string, so the invocation a worktree actually needs,
#     cd /path/to/worktree/apps/api && STACK_SLOT=3 ./ci db_setup
# starts with `cd`, matches no allow rule, and falls through to the non-deterministic auto-mode
# classifier. On the 2026-08-02 BF fleet run the classifier blocked exactly this shape (a sanctioned
# `./ci db_setup` rebuild) mid-issue; the agent recovered by rerouting, but the same roulette stalled
# a session 5h27m on the 2026-08-01 run in its rspec form. wt-rspec.sh closed the bare-rspec shape;
# this closes the ./ci one.
#
# The executable is HARDCODED to `./ci` inside <dir> — the caller chooses the directory, env, and
# subcommand, never the program — so allowlisting this script's fixed path does not create a
# run-anything escape hatch.
#
# USAGE
#   wt-ci.sh [--env KEY=VALUE]... <dir> <ci-subcommand> [args...]
#
#   wt-ci.sh --env STACK_SLOT=3 "$WT/apps/api" db_setup
#   wt-ci.sh --env STACK_SLOT=3 "$WT/apps/api" run_rspec
#
# Exits with ./ci's own status. --env is repeatable and applied only to the ./ci process.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: wt-ci.sh [--env KEY=VALUE]... <dir> <ci-subcommand> [args...]

  --env KEY=VALUE   Set an environment variable for the ./ci process (repeatable).
  <dir>             Directory containing the ./ci script (e.g. <worktree>/apps/api). Must exist.

Everything after <dir> is passed through to `./ci` unchanged.
EOF
}

ENVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "wt-ci: --env needs KEY=VALUE" >&2; exit 2; }
      [[ "$2" == *=* ]] || { echo "wt-ci: --env expects KEY=VALUE, got: $2" >&2; exit 2; }
      ENVS+=("$2"); shift 2 ;;
    --env=*)
      ENVS+=("${1#--env=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { echo "wt-ci: missing <dir>" >&2; usage; exit 2; }
DIR="$1"; shift
[[ -d "$DIR" ]] || { echo "wt-ci: not a directory: $DIR" >&2; exit 2; }

cd "$DIR" || { echo "wt-ci: cannot cd to $DIR" >&2; exit 2; }
[[ -x ./ci ]] || { echo "wt-ci: no executable ./ci in $DIR" >&2; exit 2; }

[[ $# -ge 1 ]] || { echo "wt-ci: missing <ci-subcommand>" >&2; usage; exit 2; }

# `env` applies the assignments to the child only, so a caller-supplied STACK_SLOT cannot leak into
# this shell or a later command. An empty ENVS array must not expand to a bare `env` argument, hence
# the explicit branch — under `set -u` an empty array expansion is an error on older bash.
if [[ ${#ENVS[@]} -gt 0 ]]; then
  exec env "${ENVS[@]}" ./ci "$@"
else
  exec ./ci "$@"
fi
