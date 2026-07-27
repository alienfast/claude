#!/bin/bash
# wt-disown.sh — release a /start wt worktree's ownership stamp so any session may resume it.
#
# Ownership is otherwise overwrite-only: nothing on stall or abandon clears the stamp, and the only
# way past start-wt-create.sh's live-owner gate is another stamp — which that gate blocks. In a
# `claude agents` fleet the stamped pid is the shared root/daemon, so a worktree whose session hit
# BLOCKED-ON-REVIEW and moved on still reads alive for that process's whole lifetime (the BF-525
# trap: /auto's own abandonment comment named a resume path its own stamp made unreachable). This is
# the sanctioned release: /auto calls it when it labels an issue `stalled`, /start's ABANDONED path
# calls it on walk-away, and /start's refusal mapping offers `--force` for stale pre-release stamps.
# Being a single gated tool also keeps the intent legible to permission classifiers, which
# (correctly) read raw `git config --unset` / sed surgery on the identity tiers as guard tampering.
#
# After a release the worktree reads OWNER_ALIVE=released: start-wt-create.sh falls through to
# reuse and re-stamps (which revokes the release), and /auto's orphan sweep treats it like `dead`.
# start.owner-session is KEPT as last-owner attribution.
#
# Usage: wt-disown.sh [--force] <wt_dir>
#
# The gate (checked under the repo lock, so disown-vs-takeover is race-free in both orders):
#   allowed iff the calling session IS the stamped owner (session-id equality only — pid equality
#   collapses onto the shared fleet root and would let any sibling release live work), OR the owner
#   is provably dead, OR --force. An `unknown` owner is not provably dead and needs owner-match or
#   --force — the same fail-safe direction as /auto's sweep.
#
# Stdout on success: DISOWN=<ok|noop>, RELEASED_AT=<epoch>, OWNER_SESSION=<kept id, may be empty>.
# Exit codes:
#   0 released, or noop (already released / no owner evidence at all)
#   2 usage error, not a git worktree, unresolvable lock key, or a tier write failed verification
#   3 refused: caller is not the owner, owner not provably dead, and no --force

set -eo pipefail

force=0
wt_dir=""
orig_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    -*)
      echo "ERROR: unknown option '$1' (usage: $(basename "$0") [--force] <wt_dir>)" >&2
      exit 2
      ;;
    *)
      if [ -n "$wt_dir" ]; then
        echo "ERROR: usage: $(basename "$0") [--force] <wt_dir>" >&2
        exit 2
      fi
      wt_dir="$1"; shift
      ;;
  esac
done

if [ -z "$wt_dir" ]; then
  echo "ERROR: usage: $(basename "$0") [--force] <wt_dir>" >&2
  exit 2
fi

toplevel=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$toplevel" ]; then
  echo "ERROR: '$wt_dir' is not inside a git worktree" >&2
  exit 2
fi
# Canonicalize immediately: the sidecar filename is derived from basename "$wt_dir", so a relative
# invocation ('.') would miss the sidecars and release only the seizable git-config tier.
wt_dir="$toplevel"

script_dir=$(cd "$(dirname "$0")" && pwd)

# Identity writes must serialize with every other identity writer (/start's setup, restamp, /finish's
# recovery) — they share the repo lock keyed by the common git dir. Re-exec under it before touching
# config or sidecars. The sentinel is PID-tied (Unix exec keeps the PID, so the post-exec check
# matches; a stray exported value from an unrelated process cannot disable serialization), with
# _WITH_REPO_LOCK_HELD covering Windows, where the helper spawns a child instead of exec'ing.
if [ "${WT_DISOWN_LOCK_PID:-}" != "$$" ] && [ -z "${_WITH_REPO_LOCK_HELD:-}" ]; then
  repo_key=$(git -C "$wt_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$repo_key" ] || [ "$repo_key" = "/" ]; then
    echo "ERROR: cannot resolve the common git dir for '$wt_dir' — refusing to disown unserialized." >&2
    exit 2
  fi
  export WT_DISOWN_LOCK_PID=$$
  exec "$script_dir/with-repo-lock.py" "$repo_key" "$0" "${orig_args[@]}"
fi

# shellcheck source=/dev/null
. "$script_dir/wt-identity.sh"

issue_lower=$(basename "$wt_dir" | tr '[:upper:]' '[:lower:]')

wt_owner_alive "$wt_dir" || true

if [ "$WTID_OWNER_ALIVE" = "released" ]; then
  printf 'DISOWN=noop\n'
  printf 'RELEASED_AT=%s\n' "$WTID_OWNER_RELEASED_AT"
  printf 'OWNER_SESSION=%s\n' "$WTID_OWNER_SESSION"
  exit 0
fi

if [ -z "$WTID_OWNER_PID" ] && [ -z "$WTID_OWNER_SESSION" ]; then
  # Never stamped (or identity long gone): there is no claim to release, and the create gate
  # already falls through on unknown for exactly this legacy shape.
  printf 'DISOWN=noop\n'
  printf 'RELEASED_AT=\n'
  printf 'OWNER_SESSION=\n'
  exit 0
fi

if [ "$force" != 1 ] && [ "$WTID_OWNER_ALIVE" != "dead" ] && ! wtid_owner_session_matches; then
  echo "ERROR: refusing to disown '$wt_dir': stamped owner is session '${WTID_OWNER_SESSION:-unknown}' (pid ${WTID_OWNER_PID:-unset}, liveness: $WTID_OWNER_ALIVE) and this session is not it. Only the owner, a provably dead owner, or --force may release the stamp." >&2
  exit 3
fi

if ! wt_identity_disown "$wt_dir" "$issue_lower"; then
  echo "ERROR: disown incomplete for '$wt_dir' — one or more identity tiers failed verification (see WARNs above). The create gate may still refuse; re-run once the failing tier is writable." >&2
  exit 2
fi

printf 'DISOWN=ok\n'
printf 'RELEASED_AT=%s\n' "$WTID_DISOWN_RELEASED_AT"
printf 'OWNER_SESSION=%s\n' "$WTID_OWNER_SESSION"
