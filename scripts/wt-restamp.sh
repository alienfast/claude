#!/bin/bash
# wt-restamp.sh — owner-gated re-baseline of a /start wt worktree's identity stamp.
#
# The /finish identity check (wt_identity_verify) is `merge-base --is-ancestor
# <stamped-baseline> HEAD`: a deliberate history rewrite (rebase onto source) detaches
# it, and /finish refuses as a suspected hijack (exit 4; auto mode aborts). This script
# is the sanctioned way to make a deliberate rewrite first-class: run it IMMEDIATELY
# AFTER the rewrite, from the session that owns the worktree. The finish-time check
# stays strict by design — softening it to "owner is me" at check time would also pass
# a foreign reset made while the owner is live (BF-534); re-stamping at rewrite time
# keeps that threat model intact.
#
# Two gates make the restamp mean something beyond "someone asked for it":
#   - ownership is proven by SESSION ID equality only (pid equality collapses onto the
#     shared fleet root, so it can never prove same-session);
#   - the rewrite must have PRESERVED every commit the branch had at its last sanctioned
#     stamp (and every tip it has held since). A rewrite that dropped content is either a
#     foreign reset (the case a restamp would launder) or a deliberate drop — neither may
#     be self-authorized, so both refuse with exit 5.
# --acknowledge-lost bypasses ONLY that last refusal. /finish's interactive fast path
# may pass it after the user explicitly confirms the drops; auto mode never does.
#
# Usage: wt-restamp.sh [--acknowledge-lost] <wt_dir>
#
# Stdout on success: RESTAMP=<ok|noop>, OLD_BASELINE=<sha>, NEW_BASELINE=<sha>,
# plus one ACKNOWLEDGED_LOST=<sha> <subject> line per dropped commit under --acknowledge-lost.
# Exit codes:
#   0 restamped, or a noop: HEAD still equals the recorded anchor (for a legacy stamp: the branch
#     never moved at all), the worktree verifies clean, and no --acknowledge-lost was requested
#   2 usage error, not a git worktree, no verifiable identity (legacy/pre-stamp
#     worktree — nothing to restamp), mid-rebase / detached HEAD, unresolvable or
#     unrecorded source branch, or restamp verification failed
#   3 refused: this session is not the recorded owning session
#   4 refused: current branch != stamped branch (branch-swapped is not a self-rebase)
#   5 refused: the rewrite lost commits or merges (or the stamp / reflog cannot prove it didn't)

set -eo pipefail

ack_lost=0
wt_dir=""
orig_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --acknowledge-lost) ack_lost=1; shift ;;
    -*)
      echo "ERROR: unknown option '$1' (usage: $(basename "$0") [--acknowledge-lost] <wt_dir>)" >&2
      exit 2
      ;;
    *)
      if [ -n "$wt_dir" ]; then
        echo "ERROR: usage: $(basename "$0") [--acknowledge-lost] <wt_dir>" >&2
        exit 2
      fi
      wt_dir="$1"; shift
      ;;
  esac
done

if [ -z "$wt_dir" ]; then
  echo "ERROR: usage: $(basename "$0") [--acknowledge-lost] <wt_dir>" >&2
  exit 2
fi

toplevel=$(git -C "$wt_dir" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$toplevel" ]; then
  echo "ERROR: '$wt_dir' is not inside a git worktree" >&2
  exit 2
fi
# Canonicalize immediately: the sidecar filename is derived from basename "$wt_dir", so a relative
# invocation ('.') would miss the sidecars, silently downgrade to the git-config tier — the one a
# hijacker can seize — and then overwrite the immune tiers from it.
wt_dir="$toplevel"

script_dir=$(cd "$(dirname "$0")" && pwd)

# Identity writes must serialize with every other identity writer (/start's setup, /finish's merge
# finalize, recovery) — they share the repo lock keyed by the common git dir. Re-exec under it before
# touching config or sidecars. The sentinel is PID-tied (Unix exec keeps the PID, so the post-exec
# check matches; a stray exported value from an unrelated process cannot disable serialization), with
# _WITH_REPO_LOCK_HELD covering Windows, where the helper spawns a child instead of exec'ing.
if [ "${WT_RESTAMP_LOCK_PID:-}" != "$$" ] && [ -z "${_WITH_REPO_LOCK_HELD:-}" ]; then
  repo_key=$(git -C "$wt_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$repo_key" ] || [ "$repo_key" = "/" ]; then
    echo "ERROR: cannot resolve the common git dir for '$wt_dir' — refusing to restamp unserialized." >&2
    exit 2
  fi
  export WT_RESTAMP_LOCK_PID=$$
  exec "$script_dir/with-repo-lock.py" "$repo_key" "$0" "${orig_args[@]}"
fi

# shellcheck source=/dev/null
. "$script_dir/wt-identity.sh"

if ! wt_identity_load "$wt_dir"; then
  echo "ERROR: no verifiable /start identity on '$wt_dir' (legacy/pre-stamp worktree) — nothing to restamp." >&2
  exit 2
fi

# Snapshot the loaded identity: wt_owner_alive re-loads and would clobber these globals.
old_baseline="$WTID_BASELINE"
stamped_branch="$WTID_BRANCH"
issue_id="$WTID_ISSUE"
source_branch="$WTID_SOURCE_BRANCH"
anchor="$WTID_HEAD_SHA"
stamped_at="$WTID_STAMPED_AT"
[ -z "$issue_id" ] && issue_id=$(basename "$toplevel")
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')
sidecar_name="wt-identity-${issue_lower}.env"

# Every identity tier must carry the same (baseline, head) pair. A tier whose write silently failed
# still reads as a valid identity to whichever session finds it first, so "the load looks fine" proves
# nothing — the job-dir tier can be fresh while the repo-fallback tier every OTHER session reads is
# stale. Args: expected_baseline expected_head. Sets TIER_STALE; non-zero when any tier disagrees.
tiers_consistent() {
  local want_base="$1" want_head="$2" f base head main_root repo_sidecar
  TIER_STALE=""
  base=$(git -C "$wt_dir" config --worktree --get start.baseline-sha 2>/dev/null || true)
  head=$(git -C "$wt_dir" config --worktree --get start.head-sha 2>/dev/null || true)
  if [ "$base" != "$want_base" ] || [ "$head" != "$want_head" ]; then
    TIER_STALE="per-worktree git config is stale (baseline '${base:-empty}', head '${head:-empty}')"
    return 1
  fi
  main_root=$(_wtid_main_root "$wt_dir" || true)
  if [ -z "$main_root" ]; then
    TIER_STALE="the main checkout could not be resolved, so the repo-fallback sidecar cannot be checked"
    return 1
  fi
  repo_sidecar="$main_root/.claude/worktree-identity/$sidecar_name"
  if [ ! -f "$repo_sidecar" ]; then
    TIER_STALE="repo-fallback sidecar '$repo_sidecar' was not written"
    return 1
  fi
  for f in "$repo_sidecar" "${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/$sidecar_name}"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then continue; fi
    base=$(sed -n 's/^WT_IDENTITY_BASELINE_SHA=//p' "$f" | head -1)
    head=$(sed -n 's/^WT_IDENTITY_HEAD_SHA=//p' "$f" | head -1)
    if [ "$base" != "$want_base" ] || [ "$head" != "$want_head" ]; then
      TIER_STALE="sidecar '$f' is stale (baseline '${base:-empty}', head '${head:-empty}')"
      return 1
    fi
  done
  return 0
}

# A halted rebase/cherry-pick leaves HEAD detached, which the branch gate below would
# misreport as a branch swap (exit 4, pointing at recovery). Name the real state instead.
git_path() {
  local p
  p=$(git -C "$wt_dir" rev-parse --git-path "$1" 2>/dev/null || true)
  case "$p" in /*) printf '%s' "$p" ;; ?*) printf '%s/%s' "$wt_dir" "$p" ;; esac
}
cur_branch=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -d "$(git_path rebase-merge)" ] || [ -d "$(git_path rebase-apply)" ] \
   || [ -f "$(git_path CHERRY_PICK_HEAD)" ] || [ -z "$cur_branch" ]; then
  echo "ERROR: '$wt_dir' is mid-rebase / detached HEAD — finish or abort the rebase first, then restamp." >&2
  exit 2
fi

if [ -n "$stamped_branch" ] && [ "$cur_branch" != "$stamped_branch" ]; then
  echo "ERROR: current branch '$cur_branch' != stamped branch '$stamped_branch' — branch-swapped is not a self-rebase; refusing. Use /finish's exit-4 recovery." >&2
  exit 4
fi

[ -z "$source_branch" ] && source_branch=$(git -C "$wt_dir" config --worktree --get start.source-branch 2>/dev/null || true)
if [ -z "$source_branch" ]; then
  echo "ERROR: no source branch recorded for '$wt_dir' — cannot compute a new baseline." >&2
  exit 2
fi
if ! git -C "$wt_dir" rev-parse --verify --quiet "$source_branch^{commit}" >/dev/null 2>&1; then
  echo "ERROR: recorded source branch '$source_branch' does not resolve — cannot compute a baseline." >&2
  exit 2
fi

# Ownership: session id equality ONLY (wtid_owner_session_matches — no pid fallback). wt_owner_is_me
# would fall back to pid equality, which in a `claude agents` fleet matches every sibling session
# (they share the fleet-root pid): fine for its other callers, but here it would let a foreign
# session seize the stamp.
wt_owner_alive "$wt_dir" || true
if ! wtid_owner_session_matches; then
  echo "ERROR: refusing to restamp — cannot prove this is the owning session (stamped owner '${WTID_OWNER_SESSION:-none}', this session '$(wtid_session_ids | tr '\n' '/' | sed 's#/*$##')')." >&2
  echo "  Session ids must match exactly: pid equality cannot prove same-session in a fleet, and an id-less stamp cannot be restamped at all. Use /finish's exit-4 recovery." >&2
  exit 3
fi

# Same formula the creation stamp uses: the fork-point the work now descends from.
new_baseline=$(git -C "$wt_dir" merge-base "$cur_branch" "$source_branch" 2>/dev/null || true)
if [ -z "$new_baseline" ]; then
  echo "ERROR: no merge-base between '$cur_branch' and '$source_branch' — cannot compute a baseline." >&2
  exit 2
fi

# Nothing to sanction only when the branch still sits exactly where the stamp left it. Keyed on the
# ANCHOR, not the baseline: a squash rewrites history without moving the merge-base, and keying on
# the baseline there skips the preservation audit entirely — silently, and discarding an
# --acknowledge-lost the caller explicitly asked for.
# Even then the identity must verify and every tier must agree: a wiped start.source-branch config is
# corruption the anchor can't see, and a half-written stamp leaves tiers disagreeing while the
# strongest one still reads clean. Falling through re-stamps every tier, which is how a partial write
# repairs itself on retry.
# --acknowledge-lost is never a noop: the caller is asking for drops to be recorded and the era to
# advance, and short-circuiting would silently discard both.
# A legacy stamp has no anchor to compare against, so it can only claim "unchanged" when the reflog
# positively shows the branch never moved — exactly one entry, the one that created it. More entries
# are movement it cannot audit, and NO entries are no record at all; both are refused below.
cur_head=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)
reflog_entries=$(git -C "$wt_dir" reflog show "$cur_branch" 2>/dev/null | wc -l | tr -d ' ')
branch_unmoved=0
if [ "$reflog_entries" = "1" ]; then
  # One entry only proves stillness if it is the one that CREATED the branch. Partial expiry can
  # leave a lone MOVEMENT entry behind, which would otherwise read as never-moved. Discriminated on
  # the entry's subject; the equivalent test is whether its old value is the all-zeros sha.
  case "$(git -C "$wt_dir" reflog show --format='%gs' "$cur_branch" 2>/dev/null | head -1)" in
    'branch: Created'*) branch_unmoved=1 ;;
  esac
fi
if [ "$ack_lost" = "0" ] && { { [ -n "$anchor" ] && [ "$cur_head" = "$anchor" ]; } \
   || { [ -z "$anchor" ] && [ "$new_baseline" = "$old_baseline" ] && [ "$branch_unmoved" = "1" ]; }; }; then
  # stdout only: the load's tier-dissent WARN goes to stderr and must reach the operator, so the noop path and
  # tiers_consistent below report the same contested state instead of one of them silently passing.
  wt_identity_load "$wt_dir" >/dev/null || true
  wt_identity_verify "$wt_dir"
  if [ "$WTID_CORRUPTION" = "0" ]; then
    if tiers_consistent "$old_baseline" "$anchor"; then
      printf 'RESTAMP=noop\nOLD_BASELINE=%s\nNEW_BASELINE=%s\n' "$old_baseline" "$new_baseline"
      exit 0
    fi
    echo "NOTE: identity tiers disagree — $TIER_STALE; re-stamping to repair." >&2
  fi
fi

# Work preservation: prove the rewrite KEPT every commit this branch is known to have carried since
# its last sanctioned stamp. The audit mechanics — the stamped-head + time-bounded-reflog anchor
# walk, merge-base --independent reduction, and cherry + rev-list --merges checks — live in
# wt_identity_preservation_audit (wt-identity.sh), factored there so the /finish gates run the same
# machinery (BF-547). This caller maps its verdicts onto the exit-5 refusal contract: dropped and
# every unauditable form refuse, because a rewrite that dropped content is either a foreign reset
# (which a restamp would launder) or a deliberate drop, and neither may be self-authorized.
# legacy-unmoved refuses too: an --acknowledge-lost on a legacy stamp has nothing auditable to
# acknowledge (the ack_lost=0 unmoved-legacy case already exited 0 at the noop above).
# --acknowledge-lost bypasses ONLY the dropped refusal further below.
wt_identity_preservation_audit "$wt_dir" "$cur_branch" "$anchor" "$stamped_at"
case "$WTID_AUDIT:$WTID_AUDIT_REASON" in
  clean:*|dropped:*) : ;;
  unauditable:no-reflog)
    echo "ERROR: refusing to restamp — this legacy stamp records no rewrite anchor and the branch has no reflog (expired, disabled, or deleted), so the drop window is unobservable. Use /finish's exit-4 interactive recovery." >&2
    exit 5 ;;
  unauditable:legacy-unmoved|unauditable:legacy-no-anchor)
    echo "ERROR: refusing to restamp — this legacy stamp records no rewrite anchor, so it cannot audit whatever movement its reflog may hold. Use /finish's exit-4 interactive recovery." >&2
    exit 5 ;;
  unauditable:bad-stamp-time)
    echo "ERROR: refusing to restamp — this stamp has no usable stamp time ('$WTID_AUDIT_DETAIL'); the window to audit is unknown. Use /finish's exit-4 interactive recovery." >&2
    exit 5 ;;
  unauditable:anchor-missing)
    echo "ERROR: refusing to restamp — the stamped head '$anchor' is missing from this repo; cannot prove preservation. Use /finish's exit-4 recovery." >&2
    exit 5 ;;
  unauditable:window-unobservable)
    echo "ERROR: refusing to restamp — HEAD moved since the stamp but no post-stamp reflog entry exists (expired, disabled, or its timestamps are not trustworthy); the drop window is unobservable. Use /finish's exit-4 recovery." >&2
    exit 5 ;;
  unauditable:git-merge-base-failed)
    echo "ERROR: git merge-base --independent failed ($WTID_AUDIT_DETAIL) — cannot prove preservation; refusing." >&2
    exit 5 ;;
  unauditable:no-anchor-survived)
    echo "ERROR: refusing to restamp — no auditable anchor survived (internal inconsistency); nothing would be verified. Use /finish's exit-4 recovery." >&2
    exit 5 ;;
  unauditable:git-cherry-failed)
    echo "ERROR: git cherry failed ($WTID_AUDIT_DETAIL) — cannot prove preservation; refusing." >&2
    exit 5 ;;
  unauditable:git-rev-list-failed)
    echo "ERROR: git rev-list failed ($WTID_AUDIT_DETAIL) — cannot prove preservation; refusing." >&2
    exit 5 ;;
  *)
    echo "ERROR: refusing to restamp — preservation audit returned an unknown verdict ('$WTID_AUDIT:$WTID_AUDIT_REASON'); nothing is proven. Use /finish's exit-4 recovery." >&2
    exit 5 ;;
esac
lost="$WTID_AUDIT_LOST"
lost_merges="$WTID_AUDIT_LOST_MERGES"

describe_shas() { # newline-separated shas -> "<short> <subject>" lines
  local sha out=""
  while read -r sha; do
    [ -z "$sha" ] && continue
    out="${out}$(git -C "$wt_dir" log -1 --format='%h %s' "$sha" 2>/dev/null || printf '%s (unreadable)' "$sha")
"
  done <<< "$1"
  printf '%s' "$out"
}

lost_lines=""
[ -n "$lost" ] && lost_lines=$(describe_shas "$lost")
merge_lines=""
[ -n "$lost_merges" ] && merge_lines=$(describe_shas "$lost_merges")

if { [ -n "$lost_lines" ] || [ -n "$merge_lines" ]; } && [ "$ack_lost" = "0" ]; then
  echo "ERROR: refusing to restamp — the rewrite dropped history this branch carried since its last stamp ($anchor):" >&2
  if [ -n "$lost_lines" ]; then
    echo "  commits whose content is no longer present:" >&2
    printf '%s\n' "$lost_lines" | sed 's/^/    /' >&2
  fi
  if [ -n "$merge_lines" ]; then
    echo "  merge commits no longer reachable:" >&2
    printf '%s\n' "$merge_lines" | sed 's/^/    /' >&2
    echo "  A rebase that FLATTENS a merge lands here by design: flattening discards the resolution provenance the merge recorded, and worktree branches are meant to merge from source, not rebase onto it." >&2
  fi
  echo "  A rewrite that dropped history is either a foreign reset (which restamping would launder) or a deliberate drop; neither may be self-authorized." >&2
  echo "  If the drops were deliberate and confirmed, re-run: $(basename "$0") --acknowledge-lost '$wt_dir'" >&2
  exit 5
fi
if [ -n "$merge_lines" ]; then
  if [ -n "$lost_lines" ]; then lost_lines="$lost_lines
$merge_lines"; else lost_lines="$merge_lines"; fi
fi

# Preserve the worktree's original creation time — a restamp re-baselines, it does not re-create.
created_at=$(git -C "$wt_dir" config --worktree --get start.created-at 2>/dev/null || true)
[ -n "$created_at" ] && export WTID_STAMP_CREATED_AT_OVERRIDE="$created_at"

if ! wt_identity_stamp "$wt_dir" "$toplevel" "$issue_id" "$cur_branch" "$source_branch" "$new_baseline"; then
  echo "ERROR: identity stamp failed" >&2
  exit 2
fi

# /finish trusts a RESTAMP=ok, so prove every tier actually carries the new (baseline, head) pair —
# sidecar writes are best-effort inside wt_identity_stamp, and a silently stale one still reads as
# identity to the next session that finds it.
if ! tiers_consistent "$new_baseline" "$WTID_STAMP_HEAD_SHA"; then
  echo "ERROR: restamp incomplete — $TIER_STALE; expected baseline '$new_baseline', head '${WTID_STAMP_HEAD_SHA:-empty}'." >&2
  exit 2
fi

wt_identity_load "$wt_dir" || true
wt_identity_verify "$wt_dir"
if [ "$WTID_CORRUPTION" = "1" ]; then
  echo "ERROR: restamp did not take (still $WTID_CORRUPTION_REASON) — investigate before /finish." >&2
  exit 2
fi

printf 'RESTAMP=ok\nOLD_BASELINE=%s\nNEW_BASELINE=%s\n' "$old_baseline" "$new_baseline"
if [ -n "$lost_lines" ]; then
  printf '%s\n' "$lost_lines" | sed 's/^/ACKNOWLEDGED_LOST=/'
fi
