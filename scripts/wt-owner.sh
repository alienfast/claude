#!/bin/bash
# wt-owner.sh — report a /start wt worktree's owning session and whether it is still alive.
#
# Exists so orchestration (/auto's orphan-resumption preflight) can distinguish a worktree whose owning session DIED (resumable) from one a parallel live
# session is working right now (hands off) without re-implementing the adjudication that wt-identity.sh's stamp/liveness helpers own.
#
# Usage: wt-owner.sh <wt_dir>
#
# Stdout KEY=value contract:
#   OWNER_PID=<harness pid, or empty>
#   OWNER_PID_START=<process start time recorded at stamp, or empty>
#   OWNER_SESSION=<owning session id, or empty>
#   OWNER_ALIVE=alive|dead|unknown
#   OWNER_IS_ME=0|1          (1 iff the owner is THIS session's harness process)
#
# Exit 0 whenever a report was produced (regardless of liveness); 2 on usage error or when <wt_dir> is not a git worktree.
# "dead" requires positive evidence; "unknown" means a live owner cannot be ruled out — automation must not treat unknown as resumable.

set -o pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: wt-owner.sh <wt_dir>" >&2
  exit 2
fi
wt_dir="$1"

if ! git -C "$wt_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: wt-owner.sh: '$wt_dir' is not a git worktree" >&2
  exit 2
fi

# shellcheck source=/dev/null
. "$(dirname "$0")/wt-identity.sh"

wt_owner_alive "$wt_dir" || true

owner_session=$(git -C "$wt_dir" config --worktree --get start.owner-session 2>/dev/null || true)
[ -z "$owner_session" ] && owner_session="${WTID_OWNER:-}"

my_pid=$(wtid_harness_pid || true)
is_me=0
if [ -n "$my_pid" ] && [ -n "$WTID_OWNER_PID" ] && [ "$my_pid" = "$WTID_OWNER_PID" ]; then
  is_me=1
fi

printf 'OWNER_PID=%s\n' "$WTID_OWNER_PID"
printf 'OWNER_PID_START=%s\n' "$WTID_OWNER_PID_START"
printf 'OWNER_SESSION=%s\n' "$owner_session"
printf 'OWNER_ALIVE=%s\n' "$WTID_OWNER_ALIVE"
printf 'OWNER_IS_ME=%s\n' "$is_me"
