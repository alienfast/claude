#!/bin/bash
# start-wt-create.sh — The git-mutating critical section of /start worktree setup.
#
# Usage: start-wt-create.sh <issue-id> <issue-lower> <branch> <source-branch> <wt-dir>
#
# This is the locked inner half of start-wt-setup.sh. It is invoked by the parent
# UNDER an exclusive repo lock (scripts/with-repo-lock.py, keyed on the git common
# dir — the SAME key /finish merge uses, so worktree creation and source-branch
# advances mutually exclude). Splitting it into its own script is required because
# with-repo-lock.py execvp's its command and cannot run an inline shell function.
#
# Why locked: the worktree-existence check → `git worktree add` sequence is a
# classic TOCTOU on shared .git state. Two concurrent /start runs (or a confused
# duplicate launch) racing it could `checkout -b` a new branch inside an existing
# worktree, swapping a live session's branch and HEAD and wiping its config — the
# exact corruption observed when ~8 /full wt ran in parallel. Holding the lock
# across the check + add + identity stamp closes that window.
#
# What stays OUTSIDE this script (in the parent, lock-free): the network digest
# fetch and the ~16s warm `pnpm install`. Holding the repo lock through those
# would serialize all parallel starts and destroy the parallelism the user wants.
# Only this ~git-mutating span serializes.
#
# Tamper-evident identity: after create, this script stamps the worktree's
# identity (branch, baseline SHA, source branch, owner session, plus head-sha —
# wt-restamp.sh's rewrite anchor — and stamped-at, the era that anchor opens) to
# TWO places:
#   1. per-worktree git config (start.*) — convenience copy the happy path reads;
#      EXPECTED to be wiped by a hostile reset (its absence is the detection trigger);
#   2. an immune sidecar outside .git — the source of truth /finish compares against
#      to detect a hijacked worktree. Written to $CLAUDE_JOB_DIR (most durable, not
#      automatically the freshest: fully external, survives even a repo-level
#      `git clean`, but a later stamp under another job dir leaves it behind — the
#      loader ranks the two sidecars by recency) when set, AND to a
#      repo-level fallback (.claude/worktree-identity/, gitignored + .git-external)
#      so a DIFFERENT session (manual /finish after a dead /full) can still find it.
#
# Output (stdout — KEY=value lines the parent reads; diagnostics go to stderr):
#   WT_ABS=<absolute worktree path>
#   CREATED_WT=<0|1>           (1 iff we just created/attached, vs reused)
#   BRANCH=<branch>
#   SOURCE_BRANCH=<source branch>
#   BASELINE_SHA=<fork-point commit the worktree's work descends from>
#   OWNER_SESSION=<owning session id, or empty>
#   IDENTITY_SIDECAR=<path of the strongest sidecar written, or empty>
#
# Exit non-zero on any failure; a failed create (CREATED_WT path) self-cleans the
# half-prepared worktree via an EXIT trap so the user can re-run cleanly. Exit 4 is
# the parallel-session refusal (existing worktree owned by a LIVE other session —
# see the reuse guard); nothing is created, modified, or cleaned up in that case.

set -eo pipefail

if [ $# -ne 5 ]; then
  echo "ERROR: start-wt-create.sh: expected 5 args (issue-id issue-lower branch source-branch wt-dir), got $#" >&2
  exit 1
fi

issue_id="$1"
issue_lower="$2"
branch="$3"
source_branch="$4"
wt_dir="$5"

# Shared worktree library — sourced up here (not just before wt_identity_stamp) so wt_force_remove is
# available to the create-failure trap below, which fires before the stamp.
# shellcheck source=/dev/null
. "$(dirname "$0")/wt-identity.sh"

# Defensive re-check: we must be inside a work tree (the parent verified this, but
# this script can be invoked directly under the lock, so don't assume).
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: start-wt-create.sh: not inside a git working tree (cwd: $PWD)" >&2
  exit 1
fi

# --- Three-way create/reuse/attach (the TOCTOU-prone span, now lock-held) ---
# mode is one of:
#   reuse  — worktree dir and branch both exist; the session resumes in place.
#   attach — the branch (and its history) survived but the worktree dir is gone; re-checked out here.
#   fresh  — neither existed; branch created off HEAD. The ONLY mode that establishes a new identity;
#            the other two inherit the prior stamp below.
# CREATED_WT is 1 for attach/fresh.
mode=""
CREATED_WT=0
if [ -d "$wt_dir" ]; then
  # Reuse. Verify it's a worktree on the expected branch.
  current_wt_branch=$(git -C "$wt_dir" branch --show-current 2>/dev/null || true)
  if [ "$current_wt_branch" != "$branch" ]; then
    echo "ERROR: $wt_dir exists but is on '$current_wt_branch' (expected '$branch'). Investigate manually." >&2
    exit 1
  fi
  # Parallel-session guard: reusing a worktree that a LIVE other session owns would put two sessions in one worktree — the clobbering this lock exists to
  # prevent, reachable via a /next pick race or a preflight "orphan" resume of live work. Refuse only on positive proof of a live foreign owner; a dead,
  # released (deliberate wt-disown.sh relinquish — the stall/abandon path), or undeterminable owner falls through to reuse (manual resumption of
  # legacy/unstamped worktrees keeps working) and the stamp below re-records ownership and revokes any release marker.
  # Same-session is decided by wt_owner_is_me (session ids first — in a `claude agents` fleet every session shares one root harness pid).
  wt_owner_alive "$wt_dir" || true
  if [ "$WTID_OWNER_ALIVE" = "alive" ] && ! wt_owner_is_me; then
    echo "ERROR: worktree '$wt_dir' is owned by another live session (session '${WTID_OWNER_SESSION:-unknown}', harness pid $WTID_OWNER_PID, started ${WTID_OWNER_PID_START:-unknown}); refusing to reuse it. If that session should not own this issue, stop it first — otherwise let it finish." >&2
    exit 4
  fi
  # Warn about drift from source branch.
  behind=$(git -C "$wt_dir" rev-list --count "$branch..$source_branch" 2>/dev/null || echo "?")
  ahead=$(git -C "$wt_dir" rev-list --count "$source_branch..$branch" 2>/dev/null || echo "?")
  if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
    if [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
      echo "NOTE: worktree branch has DIVERGED from $source_branch: $ahead ahead, $behind behind." >&2
    else
      echo "NOTE: worktree branch is $behind commit(s) behind $source_branch." >&2
    fi
    # merge, never rebase: /finish verifies `merge-base --is-ancestor <stamped-baseline> HEAD`
    # (wt-identity.sh) — a merge preserves that unconditionally; a rebase detaches it (BF-534).
    echo "  Consider: git -C \"$wt_dir\" merge $source_branch   (resolve drift here, ahead of /finish merge)" >&2
    echo "  Do NOT rebase this branch: rewriting history detaches the stamped baseline and /finish refuses (exit 4; auto mode aborts as BLOCKED-ON-RECOVERY)." >&2
    echo "  If you deliberately rewrite history anyway, run ~/.claude/scripts/wt-restamp.sh \"$wt_dir\" immediately after, so the stamp follows the rewrite." >&2
  fi
  echo "Resuming worktree: $wt_dir" >&2
  mode="reuse"
elif git rev-parse --verify "$branch" >/dev/null 2>&1; then
  # Branch exists but no worktree directory. Check if it's checked out elsewhere.
  existing_wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
    /^worktree / { sub(/^worktree /, ""); wt = $0 }
    /^branch / && $2 == b { print wt; exit }
  ')
  if [ -n "$existing_wt" ]; then
    echo "ERROR: branch '$branch' is already checked out at '$existing_wt'." >&2
    echo "Either work from that location, or rename / remove that checkout first:" >&2
    echo "  git worktree remove '$existing_wt'      # if it's a worktree we no longer need" >&2
    echo "  git -C '$existing_wt' switch <other>    # if main checkout, switch off the branch" >&2
    exit 1
  fi
  # Dangling branch — safe to attach.
  git worktree add "$wt_dir" "$branch" >&2
  CREATED_WT=1
  mode="attach"
else
  # Fresh: create both worktree dir and branch off current HEAD.
  git worktree add "$wt_dir" -b "$branch" HEAD >&2
  CREATED_WT=1
  mode="fresh"
fi

# If we just created the worktree (vs reused), arm a cleanup trap. Any failure
# between here and the final identity stamp removes the half-prepared worktree so
# the user can re-run cleanly. Cleared at the end on success. (Reuse never arms
# it — we must never tear down an existing worktree that holds real work.)
if [ "$CREATED_WT" = "1" ]; then
  trap '
    echo "ERROR: worktree create failed mid-flow; removing partially-prepared worktree $wt_dir" >&2
    wt_force_remove "$PWD" "$wt_dir"
  ' EXIT
fi

# --- Identity inherited by every non-fresh setup ---
# All three inherited fields (baseline, and the head-sha/stamped-at pair) are read CONFIG-FIRST with
# the identity tier chain as fallback. Every stamp rewrites config latest-wins, so config is the
# recency-correct copy; the tier chain exists to survive the config wipe a hostile reset performs.
# Preferring a tier would let a STALE sidecar revert a legitimately advanced identity — a reverted
# baseline makes /finish report corruption on an untouched worktree, and a reverted anchor makes
# wt-restamp.sh re-litigate drops the user already accepted with --acknowledge-lost.
# head-sha and stamped-at additionally travel as a PAIR from whichever source supplies them: an
# anchor without its era (or the reverse) describes no audit window at all.
# Config is also the tier a hostile write can seize; corroborating tiers against each other is
# deliberately out of scope here — BF-546 owns the tier-authority design (recency, corroboration, seizable config).
prior_baseline=""
prior_head_sha=""
prior_stamped_at=""
if [ "$mode" != "fresh" ]; then
  cfg_head_sha=$(git -C "$wt_dir" config --worktree --get start.head-sha 2>/dev/null || true)
  cfg_stamped_at=$(git -C "$wt_dir" config --worktree --get start.stamped-at 2>/dev/null || true)
  if [ -n "$cfg_head_sha" ] && [ -n "$cfg_stamped_at" ]; then
    prior_head_sha="$cfg_head_sha"
    prior_stamped_at="$cfg_stamped_at"
  fi
  # The recorded baseline is inherited VERBATIM — no ancestry or existence check. A baseline that no
  # longer descends to HEAD is exactly what /finish's identity check exists to catch (wt_identity_verify
  # → baseline-detached → exit 4 → recovery), so filtering one out here would convert a detected hijack
  # into a resumed one. Staleness is handled where it belongs, by the sidecar recency ranking.
  prior_baseline=$(git -C "$wt_dir" config --worktree --get start.baseline-sha 2>/dev/null || true)
  if wt_identity_load "$wt_dir"; then
    [ -z "$prior_baseline" ] && prior_baseline="$WTID_BASELINE"
    if [ -z "$prior_head_sha" ] && [ -n "$WTID_HEAD_SHA" ] && [ -n "$WTID_STAMPED_AT" ]; then
      prior_head_sha="$WTID_HEAD_SHA"
      prior_stamped_at="$WTID_STAMPED_AT"
    fi
  fi
  if [ -n "$prior_head_sha" ] && [ -n "$prior_stamped_at" ]; then
    export WTID_STAMP_HEAD_SHA_OVERRIDE="$prior_head_sha"
    export WTID_STAMP_STAMPED_AT_OVERRIDE="$prior_stamped_at"
  else
    # No pair anywhere — destroyed, never stamped, or a legacy stamp predating anchor recording. The
    # stamp below opens a NEW era, so warn unconditionally: a branch sitting at its fork point with no
    # verifiable identity is MORE anomalous than one carrying commits, not less (work that was reset
    # away survives only in the reflog), so this must not be gated on the commit count.
    mb=$(git -C "$wt_dir" merge-base "$branch" "$source_branch" 2>/dev/null || true)
    ahead_of_base=0
    [ -n "$mb" ] && ahead_of_base=$(git -C "$wt_dir" rev-list --count "$mb..$branch" 2>/dev/null || echo 0)
    carries=""
    [ "$ahead_of_base" -gt 0 ] && carries=" — the branch already carries $ahead_of_base commit(s)"
    echo "WARN: no rewrite anchor to inherit for '$wt_dir' (identity destroyed, never stamped, or predating anchor recording)$carries." >&2
    echo "  This run opens a NEW stamp era: wt-restamp.sh can audit nothing that happened before it, so an earlier rewrite that dropped work can no longer be detected." >&2
    echo "  If this worktree may have been reset by another session, prefer /finish's exit-4 recovery over continuing here." >&2
  fi
fi

# --- Baseline SHA: the fork point the worktree's work descends from. ---
# With nothing inherited above, derive it: a fresh fork's HEAD IS the source tip we forked from,
# while an attach onto existing history has to fall back to the merge-base.
baseline_sha="$prior_baseline"
if [ -z "$baseline_sha" ]; then
  if [ "$mode" = "fresh" ]; then
    baseline_sha=$(git -C "$wt_dir" rev-parse HEAD)
  else
    baseline_sha=$(git -C "$wt_dir" merge-base "$branch" "$source_branch" 2>/dev/null \
                   || git -C "$wt_dir" rev-parse HEAD)
  fi
fi

wt_abs=$(cd "$wt_dir" && pwd)

# Stamp the tamper-evident identity via the shared library — the SAME code path
# /finish reads back (wt_identity_load/verify) and finish-recover.sh re-stamps a
# recovered worktree with. wt_identity_stamp writes the mandatory per-worktree git
# config (a failure there aborts under `set -e` and fires the create trap above)
# plus the best-effort immune sidecars (job-dir + repo-level fallback), and sets
# WTID_STAMP_OWNER / WTID_STAMP_SIDECAR for the emit below. (wt-identity.sh already sourced at top.)
wt_identity_stamp "$wt_dir" "$wt_abs" "$issue_id" "$branch" "$source_branch" "$baseline_sha"
owner="$WTID_STAMP_OWNER"
strongest_sidecar="$WTID_STAMP_SIDECAR"

# Stamp complete — clear the cleanup trap so the worktree persists.
trap - EXIT

# Emit the KEY=value contract for the parent.
printf 'WT_ABS=%s\n' "$wt_abs"
printf 'CREATED_WT=%s\n' "$CREATED_WT"
printf 'BRANCH=%s\n' "$branch"
printf 'SOURCE_BRANCH=%s\n' "$source_branch"
printf 'BASELINE_SHA=%s\n' "$baseline_sha"
printf 'OWNER_SESSION=%s\n' "$owner"
printf 'IDENTITY_SIDECAR=%s\n' "$strongest_sidecar"
