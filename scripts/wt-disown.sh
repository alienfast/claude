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
# --reclaim is the release's sanctioned in-worktree withdrawal, for ONE narrow shape: the recorded
# owner session, still live, taking its own release back (e.g. /auto disowned on a BLOCKED-ON-REVIEW
# halt, then a human attributed the halt and the same session resumed). Without it the worktree
# stays advertised as up for grabs — /auto's sweep adjudicates `released` ahead of OWNER_IS_ME and
# will dispatch a sibling /full into it, and reap-worktrees.sh treats released + zero-commit +
# clean + idle as reap-eligible (BF-994). The gate is session-id equality with the KEPT owner
# attribution — never pid equality (which collapses onto the shared fleet root), and never --force
# (a force-reclaim is a seizure, which belongs to the fresh-invocation path and its checks). Any
# other claimant resumes through a fresh invocation (/start or /full <ID>), whose
# start-wt-create.sh reuse path re-stamps behind the full identity arbitration. Identity is
# inherited VERBATIM — branch, source, baseline, and the head-sha/stamped-at anchor era, the same
# rule as the reuse path — so a reclaim changes ownership only, never what the stamp vouches for;
# only the claim epoch advances, as it does on every stamp.
#
# Usage: wt-disown.sh [--force] <wt_dir>
#        wt-disown.sh --reclaim <wt_dir>
#
# The gate (checked under the repo lock, so disown-vs-takeover is race-free in both orders):
#   allowed iff the calling session IS the stamped owner (session-id equality only — pid equality
#   collapses onto the shared fleet root and would let any sibling release live work), OR the owner
#   is provably dead, OR --force. An `unknown` owner is not provably dead and needs owner-match or
#   --force — the same fail-safe direction as /auto's sweep.
#
# Stdout on success: DISOWN=<ok|noop>, RELEASED_AT=<epoch>, OWNER_SESSION=<kept id, may be empty>.
#   --reclaim: RECLAIM=<ok|noop>, OWNER_SESSION=<id>, CLAIMED_AT=<epoch>.
# Exit codes:
#   0 released/reclaimed, or noop (already released / already live-owned by this session / no owner
#     evidence at all)
#   2 usage error, not a git worktree, unresolvable lock key, a tier write failed verification, or
#     (--reclaim) recorded identity too incomplete to inherit
#   3 refused: (disown) caller is not the owner, owner not provably dead, and no --force;
#     (--reclaim) worktree is not in this session's own released state

set -eo pipefail

force=0
reclaim=0
wt_dir=""
orig_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --reclaim) reclaim=1; shift ;;
    -*)
      echo "ERROR: unknown option '$1' (usage: $(basename "$0") [--force|--reclaim] <wt_dir>)" >&2
      exit 2
      ;;
    *)
      if [ -n "$wt_dir" ]; then
        echo "ERROR: usage: $(basename "$0") [--force|--reclaim] <wt_dir>" >&2
        exit 2
      fi
      wt_dir="$1"; shift
      ;;
  esac
done

if [ -z "$wt_dir" ]; then
  echo "ERROR: usage: $(basename "$0") [--force|--reclaim] <wt_dir>" >&2
  exit 2
fi

if [ "$reclaim" = 1 ] && [ "$force" = 1 ]; then
  echo "ERROR: --reclaim does not combine with --force — a forced reclaim is a seizure, which belongs to the fresh-invocation path (/start or /full <ID>) and its identity checks." >&2
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

if [ "$reclaim" = 1 ]; then
  # Already live-owned by this session: nothing to withdraw — idempotent, like DISOWN=noop.
  if [ "$WTID_OWNER_ALIVE" = "alive" ] && wtid_owner_session_matches; then
    printf 'RECLAIM=noop\n'
    printf 'OWNER_SESSION=%s\n' "$WTID_OWNER_SESSION"
    printf 'CLAIMED_AT=%s\n' "$WTID_OWNER_CLAIMED_AT"
    exit 0
  fi
  if [ "$WTID_OWNER_ALIVE" != "released" ]; then
    echo "ERROR: refusing to reclaim '$wt_dir': owner state is '${WTID_OWNER_ALIVE:-unknown}' (session '${WTID_OWNER_SESSION:-unknown}'), not 'released'. Reclaim only withdraws this session's own release; every other shape resumes through a fresh invocation (/start or /full <ID>), whose reuse path re-stamps behind the full identity checks." >&2
    exit 3
  fi
  if ! wtid_owner_session_matches; then
    echo "ERROR: refusing to reclaim '$wt_dir': released by session '${WTID_OWNER_SESSION:-unknown}' and this session is not it (session-id equality only — pid equality would let any fleet sibling reclaim live work). A non-owner resumes through a fresh invocation instead." >&2
    exit 3
  fi
  # Inherit identity VERBATIM, exactly as start-wt-create.sh's reuse path does — the reclaim changes
  # ownership only. A load too torn to yield branch/source/baseline is not reclaim material; the
  # fresh-invocation path carries the arbitration and warnings for that shape.
  if ! wt_identity_load "$wt_dir" "$issue_lower" || [ -z "$WTID_BRANCH" ] || [ -z "$WTID_SOURCE_BRANCH" ] || [ -z "$WTID_BASELINE" ]; then
    echo "ERROR: cannot reclaim '$wt_dir': recorded identity is incomplete (branch/source/baseline unresolvable). Recover through a fresh invocation instead." >&2
    exit 2
  fi
  if [ -n "$WTID_HEAD_SHA" ] && [ -n "$WTID_STAMPED_AT" ]; then
    # Preserve the anchor era: re-arming it on the current tip would retroactively bless everything
    # since the original stamp. The same override pair the reuse path exports.
    export WTID_STAMP_HEAD_SHA_OVERRIDE="$WTID_HEAD_SHA"
    export WTID_STAMP_STAMPED_AT_OVERRIDE="$WTID_STAMPED_AT"
  fi
  if ! wt_identity_stamp "$wt_dir" "$wt_dir" "$issue_lower" "$WTID_BRANCH" "$WTID_SOURCE_BRANCH" "$WTID_BASELINE"; then
    echo "ERROR: reclaim incomplete for '$wt_dir' — one or more identity tiers failed verification (see WARNs above). The worktree may still read released; re-run once the failing tier is writable." >&2
    exit 2
  fi
  printf 'RECLAIM=ok\n'
  printf 'OWNER_SESSION=%s\n' "$WTID_STAMP_OWNER"
  printf 'CLAIMED_AT=%s\n' "$WTID_STAMP_OWNER_CLAIMED_AT"
  exit 0
fi

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
