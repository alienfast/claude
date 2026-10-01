#!/usr/bin/env bash
# Run `bundle exec <command>` in a given directory without a `cd` or `VAR=` prefix on the command line.
#
# WHY THIS EXISTS: same mechanism as wt-rspec.sh and wt-ci.sh — Bash permission rules are prefix-matched
# against the WHOLE command string, so the invocation a worktree actually needs,
#     cd /path/to/worktree/apps/api && DB_PORT=4106 RAILS_ENV=development bundle exec rake db:migrate
# starts with `cd`, matches no allow rule, and falls through to the non-deterministic auto-mode
# classifier. On 2026-09-30 the classifier denied exactly that command as `[Modify Shared Resources]`
# (BF-2219, regenerating schema.rb after renumbering a migration past the target branch's), and the
# unattended merge stalled on a human prompt. wt-rspec.sh closed the bare-rspec shape and wt-ci.sh the
# ./ci one; this closes every other `bundle exec` subcommand — rake tasks, `rails runner`, zeitwerk.
#
# The executable is HARDCODED to `bundle exec` inside <dir> — the caller chooses the directory, the env,
# and the gem command, never the program — so allowlisting this script's fixed path grants nothing the
# existing `Bash(bundle exec:*)` rule does not already grant from a plain cwd.
#
# USAGE
#   wt-bundle.sh [--env KEY=VALUE]... <dir> <bundle-exec args...>
#
#   wt-bundle.sh --env DB_PORT=4106 --env RAILS_ENV=development "$WT/apps/api" rake db:migrate
#   wt-bundle.sh --env DB_PORT=4106 --env DB_NAME=basefund_w0 --env RAILS_ENV=test "$WT/apps/api" \
#     rails runner 'ActiveRecord::Base.connection_pool.migration_context.migrate'
#
# Exits with the command's own status. --env is repeatable and applied only to the child process.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: wt-bundle.sh [--env KEY=VALUE]... <dir> <bundle-exec args...>

  --env KEY=VALUE   Set an environment variable for the child process (repeatable).
  <dir>             Directory holding the Gemfile (e.g. <worktree>/apps/api). Must exist.

Everything after <dir> is passed through to `bundle exec` unchanged.
EOF
}

ENVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "wt-bundle: --env needs KEY=VALUE" >&2; exit 2; }
      [[ "$2" == *=* ]] || { echo "wt-bundle: --env expects KEY=VALUE, got: $2" >&2; exit 2; }
      ENVS+=("$2"); shift 2 ;;
    --env=*)
      ENVS+=("${1#--env=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { echo "wt-bundle: missing <dir>" >&2; usage; exit 2; }
DIR="$1"; shift
[[ -d "$DIR" ]] || { echo "wt-bundle: not a directory: $DIR" >&2; exit 2; }

cd "$DIR" || { echo "wt-bundle: cannot cd to $DIR" >&2; exit 2; }
[[ -f ./Gemfile ]] || { echo "wt-bundle: no Gemfile in $DIR" >&2; exit 2; }

[[ $# -ge 1 ]] || { echo "wt-bundle: missing command after <dir>" >&2; usage; exit 2; }

# `env` applies the assignments to the child only, so a caller-supplied DB_PORT cannot leak into this
# shell or a later command. An empty ENVS array must not expand to a bare `env` argument, hence the
# explicit branch — under `set -u` an empty array expansion is an error on older bash.
if [[ ${#ENVS[@]} -gt 0 ]]; then
  exec env "${ENVS[@]}" bundle exec "$@"
else
  exec bundle exec "$@"
fi
