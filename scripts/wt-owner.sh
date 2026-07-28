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
#   OWNER_ALIVE=alive|dead|unknown|released
#   OWNER_RELEASED_AT=<epoch of the deliberate release, or empty>
#   OWNER_IS_ME=0|1          (1 iff the owner is THIS session — session ids compared first; pid equality alone can't decide in a `claude agents` fleet, where every session shares one root harness pid)
#   CORROBORATION=<agreeing>/<readable>   (identity tiers that corroborate the winning one, out of those readable)
#   TIER_DISSENT=<space-separated names of the tiers that disagree with it, or empty>
#
# Ownership is read from per-worktree git config ALONE (it is the only tier a completed stamp is guaranteed to have written, and ownership needs recency, not a
# majority), so one config write can seize a worktree. The last two fields are how that seizure stays VISIBLE — the owner keys are inside the compared
# fingerprint, so a seizure leaves the other tiers dissenting — and they are reported for a human to read, NOT for automation to gate on. TIER_DISSENT also
# fires on an interrupted disown and on an ordinary stale era, and a worktree whose owner is merely gone must still be resumable: refusing to adopt on a
# dissent strands the work instead of protecting it.
#
# A CORROBORATION denominator of 1 is its own warning: with a single readable tier there is nothing to dissent, so TIER_DISSENT is empty no matter what was
# written. That is the weakest identity state, not the safest — see wt_identity_stamp's "git-config-only identity" WARN.
#
# Exit 0 whenever a report was produced (regardless of liveness); 2 on usage error or when <wt_dir> is not a git worktree.
# "dead" requires positive evidence; "unknown" means a live owner cannot be ruled out — automation must not treat unknown as resumable.
# "released" means the prior owner deliberately relinquished the stamp (wt-disown.sh) — resumable like dead; OWNER_SESSION then names the LAST owner, not a live claim.

set -o pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: wt-owner.sh <wt_dir>" >&2
  exit 2
fi
wt_dir="$1"

toplevel=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$toplevel" ]; then
  echo "ERROR: wt-owner.sh: '$wt_dir' is not a git worktree" >&2
  exit 2
fi
# Canonicalize immediately: the sidecar filename is derived from basename "$wt_dir", so a relative
# invocation ('.') would miss both sidecars and report ownership off the git-config tier alone.
wt_dir="$toplevel"

# shellcheck source=/dev/null
. "$(dirname "$0")/wt-identity.sh"

wt_owner_alive "$wt_dir" || true

is_me=0
wt_owner_is_me && is_me=1

printf 'OWNER_PID=%s\n' "$WTID_OWNER_PID"
printf 'OWNER_PID_START=%s\n' "$WTID_OWNER_PID_START"
printf 'OWNER_SESSION=%s\n' "$WTID_OWNER_SESSION"
printf 'OWNER_ALIVE=%s\n' "$WTID_OWNER_ALIVE"
printf 'OWNER_RELEASED_AT=%s\n' "$WTID_OWNER_RELEASED_AT"
printf 'OWNER_IS_ME=%s\n' "$is_me"
printf 'CORROBORATION=%s\n' "$WTID_CORROBORATION"
printf 'TIER_DISSENT=%s\n' "$WTID_TIER_DISSENT"
