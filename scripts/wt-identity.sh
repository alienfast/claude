#!/bin/bash
# wt-identity.sh — Shared library to locate and verify a /start wt worktree's
# tamper-evident identity. SOURCE this file; do not execute it.
#
# A worktree's identity is stamped at /start (start-wt-create.sh) to two immune
# sidecars (the session's $CLAUDE_JOB_DIR, and a repo-level .claude/worktree-identity/
# fallback) plus per-worktree git config. The sidecars survive a hostile git reset /
# branch swap / config wipe — the corruption seen when parallel /full wt runs
# clobber each other — so /finish can detect a hijacked worktree instead of
# stumbling over the resulting missing config.
#
# Provides the two functions documented here plus the ownership, stamping and release helpers
# documented at their own definitions. Both of these populate WTID_* globals (read them after calling):
#
#   wt_identity_load <wt_dir> [<issue_lower>]
#     Arbitrates the three tiers into ONE identity and sets:
#       WTID_SOURCE         job-dir | repo-fallback | git-config | none
#       WTID_ISSUE WTID_BRANCH WTID_SOURCE_BRANCH WTID_BASELINE WTID_HEAD_SHA
#       WTID_STAMPED_AT WTID_SIDECAR_PATH
#       WTID_CORROBORATION  <agreeing>/<readable>   WTID_TIER_DISSENT  losing tier names
#     STRUCTURAL and audit fields (branch, source-branch, baseline, head-sha, stamped-at) are arbitrated
#     CORROBORATION-first. wt_identity_stamp is the only writer of identity and it writes every reachable
#     tier in one call, so under honest operation all readable tiers agree; agreement between two
#     INDEPENDENT tiers is therefore positive evidence of a completed stamp, and a lone dissenter is stale
#     or forged. With no majority the ranking is COMPLETENESS first (a tier no stamp could have written as
#     it stands is damaged, and its surviving era proves nothing) and only then recency — the self-reported
#     era is never authority. That path also WARNs on stderr, since two or more tiers agreeing on nothing
#     is always a partial write or tampering.
#     OWNERSHIP is arbitrated by a DIFFERENT rule and is not settled here, so this function leaves every
#     WTID_OWNER* global EMPTY: the structural winner's owner claim may be outdated, and publishing it lets a
#     caller act on a tuple nothing adjudicated. wt_owner_alive is the only sanctioned reader of ownership —
#     see _wtid_resolve_owner for why git config is authoritative there.
#     WTID_HEAD_SHA (branch tip at stamp time) and WTID_STAMPED_AT (epoch seconds of the
#     stamp) are wt-restamp.sh's rewrite anchors. Neither is a corruption signal (verify
#     never reads them): the branch is expected to move as the session works.
#     Returns 0 if a VERIFIABLE identity was found, 1 otherwise. A tier counts as READABLE only when it
#     carries at least a branch and a baseline: an unreadable, empty or truncated sidecar yields all-empty
#     fields, and without that floor it would count as a readable tier, corroborate every other empty tier,
#     and verify CLEAN as a wholly empty identity. A pre-stamp "legacy" worktree (only start.source-branch,
#     no new fields) and a non-worktree both return 1 → callers fall back to today's behavior.
#
#   wt_identity_verify <wt_dir>
#     Run only after a successful wt_identity_load. Compares the worktree's CURRENT
#     branch/HEAD/config against the loaded identity and sets:
#       WTID_CORRUPTION         0 | 1
#       WTID_CORRUPTION_REASON  branch-swapped | baseline-detached |
#                               source-branch-config-wiped | ""
#     Always returns 0. Verify cannot see a tip moved BACKWARDS along its own lineage —
#     wt_identity_preservation_audit (documented at its definition) is the companion check
#     that can, and the /finish gates run both.
#
# Also provides owner-liveness helpers (wt_owner_alive, wtid_harness_pid) so parallel
# sessions can distinguish a worktree whose owning session DIED (safe to resume) from
# one another live session is working RIGHT NOW (hands off) — see that section below.

# Read the known keys out of a sidecar .env without eval/source (values may contain slashes; they never
# contain newlines). Errors are swallowed: an unreadable sidecar is judged by _wtid_tier_readable on the
# all-empty result it leaves, and without the redirect it would also print eleven permission-denied lines
# into the stderr of every command that loads an identity.
_wtid_read_sidecar() {
  local f="$1"
  WTID_ISSUE=$(sed -n 's/^WT_IDENTITY_ISSUE=//p' "$f" 2>/dev/null | head -1)
  WTID_BRANCH=$(sed -n 's/^WT_IDENTITY_BRANCH=//p' "$f" 2>/dev/null | head -1)
  WTID_SOURCE_BRANCH=$(sed -n 's/^WT_IDENTITY_SOURCE_BRANCH=//p' "$f" 2>/dev/null | head -1)
  WTID_BASELINE=$(sed -n 's/^WT_IDENTITY_BASELINE_SHA=//p' "$f" 2>/dev/null | head -1)
  WTID_HEAD_SHA=$(sed -n 's/^WT_IDENTITY_HEAD_SHA=//p' "$f" 2>/dev/null | head -1)
  WTID_STAMPED_AT=$(sed -n 's/^WT_IDENTITY_STAMPED_AT=//p' "$f" 2>/dev/null | head -1)
  WTID_WT_DIR=$(sed -n 's/^WT_IDENTITY_WT_DIR=//p' "$f" 2>/dev/null | head -1)
  WTID_OWNER=$(sed -n 's/^WT_IDENTITY_OWNER=//p' "$f" 2>/dev/null | head -1)
  WTID_OWNER_PID=$(sed -n 's/^WT_IDENTITY_OWNER_PID=//p' "$f" 2>/dev/null | head -1)
  WTID_OWNER_PID_START=$(sed -n 's/^WT_IDENTITY_OWNER_PID_START=//p' "$f" 2>/dev/null | head -1)
  WTID_OWNER_RELEASED_AT=$(sed -n 's/^WT_IDENTITY_OWNER_RELEASED_AT=//p' "$f" 2>/dev/null | head -1)
  WTID_OWNER_CLAIMED_AT=$(sed -n 's/^WT_IDENTITY_OWNER_CLAIMED_AT=//p' "$f" 2>/dev/null | head -1)
}

# Read one per-worktree config value into <var>. Assigns rather than echoes because a command
# substitution could not report the corruption below back to its caller.
# `git config --get` silently returns the LAST value of a multi-valued key, so a lone
# `git config --worktree --add start.baseline-sha <evil>` would read back as truth — and stay that way,
# since every single-value write onto it then fails rc 5. wt_identity_stamp only ever writes
# --replace-all, so a key holding more than one value was not written by a stamp: it reads EMPTY, which
# drops the config tier below the readable floor instead of surfacing the planted value.
_wtid_config_get() {
  local wt_dir="$1" key="$2" var="$3" vals
  vals=$(git -C "$wt_dir" config --worktree --get-all "$key" 2>/dev/null || true)
  if [ -n "$vals" ] && [ "$(printf '%s\n' "$vals" | wc -l | tr -d '[:space:]')" != "1" ]; then
    WTID_CONFIG_MULTIVALUED="$WTID_CONFIG_MULTIVALUED $key"
    vals=""
  fi
  printf -v "$var" '%s' "$vals"
}

# Read the SAME field set out of per-worktree git config, so all three tiers are comparable objects
# instead of two shapes arbitrated by different rules — the divergence that let ownership and identity
# disagree about which tier wins. Config carries no issue id and no recorded worktree path; both stay
# empty, and _wtid_fingerprint excludes them for exactly that reason.
_wtid_read_config() {
  local wt_dir="$1"
  WTID_CONFIG_MULTIVALUED=""
  WTID_ISSUE=""
  WTID_WT_DIR=""
  _wtid_config_get "$wt_dir" start.worktree-branch   WTID_BRANCH
  _wtid_config_get "$wt_dir" start.source-branch     WTID_SOURCE_BRANCH
  _wtid_config_get "$wt_dir" start.baseline-sha      WTID_BASELINE
  _wtid_config_get "$wt_dir" start.head-sha          WTID_HEAD_SHA
  _wtid_config_get "$wt_dir" start.stamped-at        WTID_STAMPED_AT
  _wtid_config_get "$wt_dir" start.owner-session     WTID_OWNER
  _wtid_config_get "$wt_dir" start.owner-pid         WTID_OWNER_PID
  _wtid_config_get "$wt_dir" start.owner-pid-start   WTID_OWNER_PID_START
  _wtid_config_get "$wt_dir" start.owner-released-at WTID_OWNER_RELEASED_AT
  _wtid_config_get "$wt_dir" start.owner-claimed-at  WTID_OWNER_CLAIMED_AT
  WTID_CONFIG_MULTIVALUED="${WTID_CONFIG_MULTIVALUED# }"
  if [ -n "$WTID_CONFIG_MULTIVALUED" ] && [ "${WTID_MULTIVALUED_WARNED:-}" != "$wt_dir|$WTID_CONFIG_MULTIVALUED" ]; then
    WTID_MULTIVALUED_WARNED="$wt_dir|$WTID_CONFIG_MULTIVALUED"
    echo "WARN: per-worktree git config for '$wt_dir' holds multiple values for: $WTID_CONFIG_MULTIVALUED. A stamp writes each key once, so these were added by something else; they are being IGNORED. Repair with: git -C '$wt_dir' config --worktree --unset-all <key>" >&2
  fi
}

# The tuple ONE stamp writes, over the fields BOTH tier formats carry — equal fingerprints can only come from
# the same wt_identity_stamp call, which is what makes agreement evidence rather than coincidence. Sidecar-only
# keys (issue, version, recorded wt dir) and the config-only created-at are excluded: they are not written
# symmetrically, so including them would manufacture dissent between honest tiers. The owner claim epoch is
# excluded for a different reason: it advances on every stamp and honors no override (BF-575), so it can never
# be pinned equal across the paired same-worktree stamps corroboration is compared over (the BF-578 straddle
# would return, unpinnable this time), and a failed best-effort sidecar rewrite would turn into new structural
# dissent where today there is none. wt_owner_contest reads it per tier directly; it needs no membership here.
_wtid_fingerprint() {
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s' \
    "$WTID_BRANCH" "$WTID_SOURCE_BRANCH" "$WTID_BASELINE" "$WTID_HEAD_SHA" "$WTID_STAMPED_AT" \
    "$WTID_OWNER" "$WTID_OWNER_PID" "$WTID_OWNER_PID_START" "$WTID_OWNER_RELEASED_AT"
}

# Is the tier just read a shape one wt_identity_stamp could have written? A legacy stamp predating anchor
# recording carries neither half of the head-sha/stamped-at pair and is complete for its shape. Damage falls on
# the era too, so an incomplete tier must never outrank an intact one on the strength of the era it still carries.
_wtid_tier_complete() {
  if [ -z "$WTID_BRANCH" ] || [ -z "$WTID_SOURCE_BRANCH" ] || [ -z "$WTID_BASELINE" ]; then return 1; fi
  if [ -n "$WTID_HEAD_SHA" ] && [ -z "$WTID_STAMPED_AT" ]; then return 1; fi
  if [ -z "$WTID_HEAD_SHA" ] && [ -n "$WTID_STAMPED_AT" ]; then return 1; fi
  return 0
}

# Minimum viable shape: does the tier just read say ANYTHING about which branch off which commit? Below this
# floor the tier does not exist at all — for arbitration, for the readable count, for the dissent WARN, and
# for supplying an owner.
_wtid_tier_readable() {
  [ -n "$WTID_BRANCH" ] && [ -n "$WTID_BASELINE" ]
}

# The sidecar filename for an issue slug. Lowercased on READ as well as on write (_wtid_write_sidecar
# lowercases too): otherwise an uppercase worktree basename looks for a name no stamp ever wrote and BOTH
# sidecar tiers vanish in silence, leaving ownership resting on the seizable config tier.
_wtid_sidecar_name() {
  printf 'wt-identity-%s.env' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

# device:inode of a file, symlinks followed; empty when no stat dialect answers. GNU is tried FIRST for the
# reason reap-worktrees.sh records from measurement: GNU stat "accepts" -f as --file-system and writes output
# before failing, so a BSD-first order is caught only by the exit status, never by an empty result. Probing in
# this order keeps the fallback resting on a clean rc rather than on that near-miss.
_wtid_file_id() {
  local id
  id=$(stat -L -c '%d:%i' "$1" 2>/dev/null) || id=""
  if [ -z "$id" ]; then id=$(stat -L -f '%d:%i' "$1" 2>/dev/null) || id=""; fi
  printf '%s' "$id"
}

# Do two sidecar paths name the same physical file? The two sidecar tiers are independent evidence only while
# they are two files: with CLAUDE_JOB_DIR set to, symlinked into, or hardlinked onto the repo fallback, one
# file corroborates itself and a single forged write reads as a majority. Compared by device:inode rather than
# by resolved directory, because a symlinked or hardlinked sidecar FILE sits in a genuinely distinct directory.
# With no usable stat the answer is "same", withholding corroboration credit rather than granting it unchecked.
# stat() needs only directory search permission, so for a file that exists this is reached when no stat dialect
# answers at all, not when the file itself is unreadable.
_wtid_same_file() {
  local a b
  a=$(_wtid_file_id "$1"); b=$(_wtid_file_id "$2")
  if [ -z "$a" ] || [ -z "$b" ]; then return 0; fi
  [ "$a" = "$b" ]
}

# Every field a tier read populates, cleared. Used both to enter wt_identity_load with no residue from a
# previous call and to scrub after every candidate was rejected, so nothing leaks between tiers or calls.
_wtid_reset_identity() {
  WTID_ISSUE=""; WTID_BRANCH=""; WTID_SOURCE_BRANCH=""; WTID_BASELINE=""; WTID_HEAD_SHA=""; WTID_STAMPED_AT=""
  WTID_WT_DIR=""; WTID_OWNER=""; WTID_OWNER_SESSION=""; WTID_OWNER_PID=""; WTID_OWNER_PID_START=""; WTID_OWNER_RELEASED_AT=""
  WTID_OWNER_CLAIMED_AT=""
}

# A sidecar is only trustworthy for <wt_dir> if its recorded WT_IDENTITY_WT_DIR is
# that same worktree. Guards against a STALE same-issue sidecar (e.g. a prior aborted
# /start of the same issue) in $CLAUDE_JOB_DIR being read for a different/recreated
# worktree and falsely flagging it branch-swapped. Accepts when the sidecar predates
# this field (empty) or the path can't be resolved — never false-reject a healthy one.
_wtid_sidecar_matches() {
  local wt_dir="$1" abs stored
  [ -z "$WTID_WT_DIR" ] && return 0
  # Resolve BOTH sides to the PHYSICAL path (pwd -P, symlinks resolved). The stored
  # value may have been written as a logical path while callers feed wt_dir from
  # `git rev-parse --show-toplevel` (physical) — comparing raw strings would
  # false-reject a healthy sidecar on a symlinked repo path, which in the config-wiped
  # corruption case would silently MISS the hijack. Resolving both is symlink-robust.
  abs=$(cd "$wt_dir" 2>/dev/null && pwd -P) || return 0
  stored=$(cd "$WTID_WT_DIR" 2>/dev/null && pwd -P) || stored="$WTID_WT_DIR"
  [ "$abs" = "$stored" ]
}

# Absolute path of the MAIN checkout (parent of the git common dir). The
# repo-level identity sidecar lives under the main checkout's .claude/, not the
# worktree's own toplevel.
_wtid_main_root() {
  local wt_dir="$1" cdir
  cdir=$(git -C "$wt_dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -z "$cdir" ] && return 1
  case "$cdir" in
    /*) : ;;
    *)  cdir="$wt_dir/$cdir" ;;
  esac
  (cd "$cdir/.." 2>/dev/null && pwd) || return 1
}

_wtid_now() {
  printf '%s' "${EPOCHSECONDS:-$(date +%s)}"
}

# The era a tier CLAIMS, as a comparable number: anything non-numeric, empty, or too wide for shell
# arithmetic reads 0, so a damaged era can never win a comparison.
_wtid_era_claim() {
  case "$1" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  if [ "${#1}" -gt 10 ]; then printf '0'; return 0; fi
  printf '%s' "$1"
}

# The era a tier may be RANKED by. A claim more than a small skew tolerance in the FUTURE sorts oldest,
# exactly as a damaged one does: a stamp cannot honestly claim a time that has not happened, and without
# this such a claim stays permanently "newest", so every later resume reverts to that identity — a stale
# baseline then reads as baseline-detached and auto mode aborts BLOCKED-ON-RECOVERY. That is the
# non-hostile clock-skew failure as much as the forged one.
_wtid_era_num() {
  local era now
  era=$(_wtid_era_claim "$1")
  [ "$era" = "0" ] && { printf '0'; return 0; }
  now=$(_wtid_now)
  case "$now" in ''|*[!0-9]*) printf '%s' "$era"; return 0 ;; esac
  if [ "$era" -gt $((now + 300)) ]; then printf '0'; return 0; fi
  printf '%s' "$era"
}

wt_identity_load() {
  local wt_dir="$1" issue_lower="${2-}"
  _wtid_reset_identity
  WTID_SOURCE="none"; WTID_SIDECAR_PATH=""
  WTID_CORROBORATION="0/0"; WTID_TIER_DISSENT=""
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  local name
  name=$(_wtid_sidecar_name "$issue_lower")

  # Read every tier into its own slot BEFORE judging any of them, each behind its existing gate: the two
  # sidecars must record THIS worktree's path (_wtid_sidecar_matches, which keeps a stale same-issue
  # sidecar from another worktree out), every tier must clear _wtid_tier_readable, and git config must
  # carry the NEW worktree-branch + baseline-sha fields — a legacy worktree (start.source-branch only) is
  # not a verifiable identity and must keep degrading to the caller's pre-identity behavior.
  local job_file="" job_fp="" job_era="" job_ok=0
  local repo_file="" repo_fp="" repo_era="" repo_ok=0
  local cfg_fp="" cfg_era="" cfg_ok=0 cfg_readable=0 main_root
  if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -f "$CLAUDE_JOB_DIR/$name" ]; then
    _wtid_read_sidecar "$CLAUDE_JOB_DIR/$name"
    if _wtid_tier_readable && _wtid_sidecar_matches "$wt_dir"; then
      job_file="$CLAUDE_JOB_DIR/$name"; job_fp=$(_wtid_fingerprint); job_era="$WTID_STAMPED_AT"
      _wtid_tier_complete && job_ok=1
    fi
  fi
  main_root=$(_wtid_main_root "$wt_dir" || true)
  if [ -n "$main_root" ] && [ -f "$main_root/.claude/worktree-identity/$name" ]; then
    _wtid_read_sidecar "$main_root/.claude/worktree-identity/$name"
    if _wtid_tier_readable && _wtid_sidecar_matches "$wt_dir"; then
      repo_file="$main_root/.claude/worktree-identity/$name"; repo_fp=$(_wtid_fingerprint); repo_era="$WTID_STAMPED_AT"
      _wtid_tier_complete && repo_ok=1
    fi
  fi
  # One file is one tier however many names reach it, so the duplicate drops out entirely — counting it
  # twice would also report a self-corroborating forgery as 2 of 3 readable tiers agreeing.
  if [ -n "$job_file" ] && [ -n "$repo_file" ] && _wtid_same_file "$job_file" "$repo_file"; then
    repo_file=""; repo_fp=""; repo_era=""; repo_ok=0
  fi
  _wtid_read_config "$wt_dir"
  if _wtid_tier_readable; then
    cfg_readable=1; cfg_fp=$(_wtid_fingerprint); cfg_era="$WTID_STAMPED_AT"
    _wtid_tier_complete && cfg_ok=1
  fi

  local readable=0
  [ -n "$job_file" ] && readable=$((readable + 1))
  [ -n "$repo_file" ] && readable=$((readable + 1))
  [ "$cfg_readable" = 1 ] && readable=$((readable + 1))

  # Corroboration first, for the STRUCTURAL and audit fields only: two tiers carrying one fingerprint witness a
  # completed stamp no single write could have produced, while any ONE tier (git config most of all, since any
  # in-repo command can rewrite it) is seizable alone. What agreement CANNOT establish is recency — two stale
  # tiers agree as readily as two fresh ones — which is why ownership is arbitrated elsewhere. The winner is
  # the STRONGEST member of the agreeing group, so WTID_SOURCE names the most durable place it was found.
  local jr=0 jc=0 rc_cfg=0 winner="" agree=0
  if [ -n "$job_file" ] && [ -n "$repo_file" ] && [ "$job_fp" = "$repo_fp" ]; then jr=1; fi
  if [ -n "$job_file" ] && [ "$cfg_readable" = 1 ] && [ "$job_fp" = "$cfg_fp" ]; then jc=1; fi
  if [ -n "$repo_file" ] && [ "$cfg_readable" = 1 ] && [ "$repo_fp" = "$cfg_fp" ]; then rc_cfg=1; fi
  if [ "$jr" = 1 ] || [ "$jc" = 1 ]; then
    winner="job"; agree=$((1 + jr + jc))
  elif [ "$rc_cfg" = 1 ]; then
    winner="repo"; agree=2
  fi

  # No majority: exactly one readable tier, or every readable tier telling a different story. Ranked
  # COMPLETENESS first, era second — a tier a stamp could not have written as it stands is damaged, and its
  # surviving era proves nothing, so it loses to any intact tier however old that one claims to be.
  # Completeness never REJECTS a tier; a lone damaged tier is still the identity. Strictly-greater keeps
  # job-dir > repo-fallback > git-config order on a tie, so the more durable tier wins when nothing separates
  # them.
  if [ -z "$winner" ] && [ "$readable" -ge 1 ]; then
    local best_ok=0 best=0 ok era
    if [ -n "$job_file" ]; then winner="job"; best_ok="$job_ok"; best=$(_wtid_era_num "$job_era"); fi
    if [ -n "$repo_file" ]; then
      ok="$repo_ok"; era=$(_wtid_era_num "$repo_era")
      if [ -z "$winner" ] || [ "$ok" -gt "$best_ok" ] || { [ "$ok" = "$best_ok" ] && [ "$era" -gt "$best" ]; }; then
        winner="repo"; best_ok="$ok"; best="$era"
      fi
    fi
    if [ "$cfg_readable" = 1 ]; then
      ok="$cfg_ok"; era=$(_wtid_era_num "$cfg_era")
      if [ -z "$winner" ] || [ "$ok" -gt "$best_ok" ] || { [ "$ok" = "$best_ok" ] && [ "$era" -gt "$best" ]; }; then
        winner="cfg"; best_ok="$ok"; best="$era"
      fi
    fi
    agree=1
  fi

  if [ -z "$winner" ]; then
    _wtid_reset_identity
    return 1
  fi

  local win_fp=""
  case "$winner" in
    job)  win_fp="$job_fp" ;;
    repo) win_fp="$repo_fp" ;;
    cfg)  win_fp="$cfg_fp" ;;
  esac

  # Name the losers for the WARN below and for callers that report which tier dissented.
  if [ -n "$job_file" ] && [ "$job_fp" != "$win_fp" ]; then WTID_TIER_DISSENT="$WTID_TIER_DISSENT job-dir"; fi
  if [ -n "$repo_file" ] && [ "$repo_fp" != "$win_fp" ]; then WTID_TIER_DISSENT="$WTID_TIER_DISSENT repo-fallback"; fi
  if [ "$cfg_readable" = 1 ] && [ "$cfg_fp" != "$win_fp" ]; then WTID_TIER_DISSENT="$WTID_TIER_DISSENT git-config"; fi
  WTID_TIER_DISSENT="${WTID_TIER_DISSENT# }"
  WTID_CORROBORATION="$agree/$readable"

  # Re-read the winner so the globals hold exactly one tier's values — never a splice of several. Its owner
  # claim is then SCRUBBED rather than published: a structural winner can be an outdated owner, and
  # _wtid_resolve_owner re-reads every owner field from scratch, so clearing them makes acting on an
  # unadjudicated tuple impossible instead of merely discouraged.
  case "$winner" in
    job)  _wtid_read_sidecar "$job_file";  WTID_SOURCE="job-dir";       WTID_SIDECAR_PATH="$job_file" ;;
    repo) _wtid_read_sidecar "$repo_file"; WTID_SOURCE="repo-fallback"; WTID_SIDECAR_PATH="$repo_file" ;;
    cfg)  _wtid_read_config "$wt_dir";     WTID_SOURCE="git-config" ;;
  esac
  WTID_OWNER=""; WTID_OWNER_SESSION=""; WTID_OWNER_PID=""; WTID_OWNER_PID_START=""; WTID_OWNER_RELEASED_AT=""
  WTID_OWNER_CLAIMED_AT=""

  # Two or more readable tiers and not one pair agrees: one stamp writes every reachable tier together,
  # so this state is a partial write or a tampered tier — never healthy, and it must not resolve in
  # silence, which is how a seizure looks exactly like an ordinary resume. Deduplicated on the situation,
  # not suppressed: several functions load the same identity in one run, and four copies of this train
  # readers to skip it. The winning fingerprint is part of the key so a CHANGED verdict still speaks —
  # without it a second, different forgery of the same shape would be silenced by the first one's warning.
  if [ "$agree" = 1 ] && [ "$readable" -ge 2 ]; then
    local key="$wt_dir|$WTID_CORROBORATION|$WTID_TIER_DISSENT|$WTID_SOURCE|$win_fp"
    if [ "${WTID_DISSENT_WARNED:-}" != "$key" ]; then
      WTID_DISSENT_WARNED="$key"
      echo "WARN: identity tiers disagree for '$wt_dir' — no two of the $readable readable tiers corroborate each other (corroboration $WTID_CORROBORATION; dissenting: $WTID_TIER_DISSENT)." >&2
      echo "  A stamp writes every reachable tier at once, so this is a partial write or a tampered tier. Proceeding on the '$WTID_SOURCE' tier, ranked by completeness then recency — the weakest evidence this library has." >&2
    fi
  fi
  return 0
}

wt_identity_verify() {
  local wt_dir="$1"
  WTID_CORRUPTION=0; WTID_CORRUPTION_REASON=""

  local cur
  cur=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  # (a) Branch swapped out from under the session — the primary observed signature.
  if [ -n "$WTID_BRANCH" ] && [ "$cur" != "$WTID_BRANCH" ]; then
    WTID_CORRUPTION=1; WTID_CORRUPTION_REASON="branch-swapped"
    return 0
  fi

  # (b) HEAD no longer descends from the stamped baseline — the branch was reset.
  # Only assert this when the baseline object actually exists locally; a GC'd or
  # unfetched baseline can't prove detachment and must not false-flag.
  if [ -n "$WTID_BASELINE" ] && git -C "$wt_dir" cat-file -e "${WTID_BASELINE}^{commit}" 2>/dev/null; then
    if ! git -C "$wt_dir" merge-base --is-ancestor "$WTID_BASELINE" HEAD 2>/dev/null; then
      WTID_CORRUPTION=1; WTID_CORRUPTION_REASON="baseline-detached"
      return 0
    fi
  fi

  # (c) The identity came from a sidecar but the worktree's own start.source-branch config was wiped —
  # proven tampering, since one stamp writes both. Only sidecar-sourced identities are checked, because a
  # tier cannot corroborate itself: WTID_SOURCE=git-config means the config IS the identity just read
  # (which also happens when sidecars existed and lost arbitration).
  if [ "$WTID_SOURCE" = "job-dir" ] || [ "$WTID_SOURCE" = "repo-fallback" ]; then
    local cfg_src
    cfg_src=$(git -C "$wt_dir" config --worktree --get start.source-branch 2>/dev/null || true)
    if [ -z "$cfg_src" ]; then
      WTID_CORRUPTION=1; WTID_CORRUPTION_REASON="source-branch-config-wiped"
      return 0
    fi
  fi

  return 0
}

# wt_identity_preservation_audit <wt_dir> [<branch>] [<anchor>] [<stamped_at>]
#   Run only after a successful wt_identity_load; <branch> defaults to WTID_BRANCH (callers that
#   already proved current-branch == stamped-branch may pass the current branch explicitly), and
#   <anchor>/<stamped_at> default to WTID_HEAD_SHA/WTID_STAMPED_AT — a caller that snapshotted the
#   loaded identity before something re-loaded it (wt_owner_alive clobbers the globals) passes its
#   snapshots explicitly.
#   The work-preservation audit behind wt-restamp.sh's exit-5 gate, factored here so the /finish
#   path runs the same machinery (BF-547): verify's baseline ancestry check cannot see a tip moved
#   backwards along its own lineage — a foreign reset onto the source tip, or back to the fork plus
#   a foreign commit, leaves the baseline an ancestor of HEAD and verifies clean while committed
#   work is gone. This audit proves the branch still CARRIES every commit it is known to have held
#   since its last sanctioned stamp. Two anchors, because neither alone is sound: the stamped head
#   (everything the branch held when last blessed) and every reflog tip recorded since the stamp —
#   bounded by TIME, never by value, since a foreign reset can land the branch back on the stamped
#   head's value and a value-bounded walk would stop there and never see the drop. Entries at or
#   before stamped-at end nothing individually (each is examined — back-dating one entry must not
#   hide the honest entries below it), same-second entries are collected (reading same-second work
#   as pre-stamp is the fail-open direction), and an unreadable timestamp adds scrutiny rather than
#   judgment. Anchors reduce via merge-base --independent; each survivor is checked with `git
#   cherry` (content) plus `git rev-list --merges` (a dropped merge is invisible to cherry, which
#   compares patches and a merge has none of its own). Sets:
#     WTID_AUDIT              clean | dropped | unauditable
#     WTID_AUDIT_REASON       "" (clean/dropped) | no-reflog | legacy-unmoved | legacy-no-anchor |
#                             bad-stamp-time | anchor-missing | window-unobservable |
#                             no-anchor-survived | git-merge-base-failed | git-cherry-failed |
#                             git-rev-list-failed
#     WTID_AUDIT_DETAIL       first line of the failing git command's output (git-* reasons only)
#     WTID_AUDIT_LOST         newline-separated SHAs whose content HEAD no longer carries
#     WTID_AUDIT_LOST_MERGES  newline-separated merge SHAs no longer reachable from HEAD
#   Always returns 0 — verdict semantics belong to the caller. wt-restamp.sh refuses dropped and
#   every unauditable form (exit 5; legacy-unmoved included, because an --acknowledge-lost on a
#   legacy stamp has nothing auditable to acknowledge). The /finish gates fail closed on dropped
#   and unauditable alike (exit 4) — an unobservable drop window at merge time is exactly the
#   laundering surface a hijacker who can expire a reflog would use — EXCEPT legacy-unmoved, which
#   they pass: a branch whose reflog holds only its creation entry never moved, so nothing could
#   have been dropped, and blocking a still worktree over a pre-anchor stamp is pure availability
#   loss.
wt_identity_preservation_audit() {
  local wt_dir="$1" branch="${2:-$WTID_BRANCH}"
  WTID_AUDIT="clean"; WTID_AUDIT_REASON=""; WTID_AUDIT_DETAIL=""; WTID_AUDIT_LOST=""; WTID_AUDIT_LOST_MERGES=""
  local anchor="${3:-$WTID_HEAD_SHA}" stamped_at="${4:-$WTID_STAMPED_AT}"
  local cur_head reflog_entries
  [ -z "$branch" ] && branch=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  cur_head=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)
  reflog_entries=$(git -C "$wt_dir" reflog show "$branch" 2>/dev/null | wc -l | tr -d ' ')

  # A legacy stamp has no anchor to audit from. Stillness is provable only by a reflog holding
  # exactly the entry that CREATED the branch (partial expiry can leave a lone MOVEMENT entry
  # behind, which would otherwise read as never-moved); anything else is movement it cannot audit,
  # and no entries are no record at all.
  if [ -z "$anchor" ]; then
    WTID_AUDIT="unauditable"
    if [ "$reflog_entries" = "0" ]; then
      WTID_AUDIT_REASON="no-reflog"
    elif [ "$reflog_entries" = "1" ]; then
      case "$(git -C "$wt_dir" reflog show --format='%gs' "$branch" 2>/dev/null | head -1)" in
        'branch: Created'*) WTID_AUDIT_REASON="legacy-unmoved" ;;
        *) WTID_AUDIT_REASON="legacy-no-anchor" ;;
      esac
    else
      WTID_AUDIT_REASON="legacy-no-anchor"
    fi
    return 0
  fi

  # Epoch seconds are 10 digits through the year 2286; anything longer is not a second-resolution
  # stamp and would silently break every arithmetic comparison below.
  local stamped_at_ok=1
  case "$stamped_at" in ''|*[!0-9]*) stamped_at_ok=0 ;; esac
  [ "${#stamped_at}" -gt 10 ] && stamped_at_ok=0
  if [ "$stamped_at_ok" = "0" ]; then
    WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="bad-stamp-time"; WTID_AUDIT_DETAIL="${stamped_at:-empty}"
    return 0
  fi
  if ! git -C "$wt_dir" cat-file -e "${anchor}^{commit}" 2>/dev/null; then
    WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="anchor-missing"; WTID_AUDIT_DETAIL="$anchor"
    return 0
  fi

  local anchors="$anchor" post_stamp=0 line tip entry_at entry_ok
  while read -r line; do
    [ -z "$line" ] && continue
    tip=${line%% *}
    entry_at=${line##*@\{}; entry_at=${entry_at%\}}
    # A timestamp we cannot read (or one too wide to compare) must not be compared at all — and the
    # fail-safe answer is to AUDIT that tip rather than judge its age, so a corrupted entry can only
    # ever add scrutiny.
    entry_ok=1
    case "$entry_at" in ''|*[!0-9]*) entry_ok=0 ;; esac
    [ "${#entry_at}" -gt 10 ] && entry_ok=0
    if [ "$entry_ok" = "0" ]; then
      anchors="$anchors
$tip"
      post_stamp=$((post_stamp + 1))
      continue
    fi
    if [ "$entry_at" -lt "$stamped_at" ]; then continue; fi
    anchors="$anchors
$tip"
    post_stamp=$((post_stamp + 1))
  done <<< "$(git -C "$wt_dir" reflog show --format='%H %gd' --date=unix "$branch" 2>/dev/null || true)"

  # Under an honest reflog, a branch that moved since the stamp ALWAYS has at least one entry at or
  # after stamped-at. Zero collected therefore means the record itself is unusable — expired,
  # disabled, deleted, back-dated, or a stamp time pushed into the future — and the window in which
  # commits could have been dropped is unobservable. Sound only because head-sha and stamped-at are
  # always written together (a resume inherits the pair), so "no entry since the stamp" cannot mean
  # the era was re-armed under a stale anchor.
  if [ "$post_stamp" = "0" ] && [ "$cur_head" != "$anchor" ]; then
    WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="window-unobservable"
    return 0
  fi

  # Collapse to maximal anchors: a tip reachable from another adds nothing, and each survivor costs
  # a cherry + rev-list. A pruned old tip proves nothing and is skipped.
  local anchors_present="" a
  while read -r a; do
    [ -z "$a" ] && continue
    git -C "$wt_dir" cat-file -e "${a}^{commit}" 2>/dev/null || continue
    anchors_present="$anchors_present$a
"
  done <<< "$(printf '%s\n' "$anchors" | sort -u)"
  if [ -n "$anchors_present" ]; then
    # Unquoted on purpose: the newline-separated shas must split into arguments.
    # shellcheck disable=SC2086
    if ! anchors=$(git -C "$wt_dir" merge-base --independent $anchors_present 2>&1); then
      WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="git-merge-base-failed"
      WTID_AUDIT_DETAIL=$(printf '%s' "$anchors" | head -1)
      return 0
    fi
  else
    # The stamped head was proven present above, so this list can never be empty — if it somehow
    # is, the audit would run against nothing at all.
    WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="no-anchor-survived"
    return 0
  fi

  local lost="" lost_merges="" cherry_out merges_out
  while read -r a; do
    [ -z "$a" ] && continue
    git -C "$wt_dir" merge-base --is-ancestor "$a" HEAD 2>/dev/null && continue   # nothing unreachable below HEAD
    # No pipeline here: `git cherry ... | sed` swallows both the status and the reason, so a broken
    # repo would read as "nothing lost" and the gate would fail OPEN.
    if ! cherry_out=$(git -C "$wt_dir" cherry HEAD "$a" 2>&1); then
      WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="git-cherry-failed"
      WTID_AUDIT_DETAIL=$(printf '%s' "$cherry_out" | head -1)
      return 0
    fi
    lost="$lost$(printf '%s\n' "$cherry_out" | sed -n 's/^+ //p')
"
    # cherry compares PATCHES, and a merge commit has no patch of its own — a dropped merge is
    # therefore invisible to it even when the merge is the only record of a conflict resolution.
    if ! merges_out=$(git -C "$wt_dir" rev-list --merges "HEAD..$a" 2>&1); then
      WTID_AUDIT="unauditable"; WTID_AUDIT_REASON="git-rev-list-failed"
      WTID_AUDIT_DETAIL=$(printf '%s' "$merges_out" | head -1)
      return 0
    fi
    lost_merges="$lost_merges$merges_out
"
  done <<< "$(printf '%s\n' "$anchors" | sort -u)"
  WTID_AUDIT_LOST=$(printf '%s' "$lost" | sed '/^$/d' | sort -u)
  WTID_AUDIT_LOST_MERGES=$(printf '%s' "$lost_merges" | sed '/^$/d' | sort -u)
  if [ -n "$WTID_AUDIT_LOST" ] || [ -n "$WTID_AUDIT_LOST_MERGES" ]; then
    WTID_AUDIT="dropped"
  fi
  return 0
}

# --- Owner liveness (parallel-session coordination) ---
# A worktree's "owner" is the harness (claude) process of the session that last stamped it. A session id alone (start.owner-session) cannot be tested for
# liveness, so the stamp also records the harness PID + its start time — PID recycling makes a bare PID ambiguous; PID + start time is unique in practice.
# A session that deliberately walks away (stall, abandon) releases the stamp via wt_identity_disown: owner-pid is cleared and owner-released-at set, while
# owner-session persists as LAST-OWNER attribution, not a live claim. Pid liveness alone can't express "gave up" — the shared fleet-root/daemon pid stays
# alive for days after a session stops working a worktree, which is exactly the state a release marks.

# Nearest ancestor process that is the claude harness binary. Honors $CLAUDE_HARNESS_PID when a caller pre-resolved it. Empty/rc-1 when undeterminable
# (npm-installed CLI runs under `node`; MSYS ps can't see native processes) — callers MUST treat empty as "unknown", never as "dead".
# In a `claude agents` fleet the shell's nearer claude-lineage ancestors are retitled pool processes (`claude bg-pty-host`, `claude bg-spare`) whose pids are
# transient pool artifacts; the comm match below skips those (suffixed titles don't match) and lands on the fleet ROOT — shared by every fleet session. That is
# correct for LIVENESS (root dies = all its sessions die) but means pid equality can NEVER prove same-session: use wt_owner_is_me, which compares session ids first.
wtid_harness_pid() {
  if [ -n "${CLAUDE_HARNESS_PID:-}" ]; then printf '%s' "$CLAUDE_HARNESS_PID"; return 0; fi
  local pid=$$ comm base
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tail -1)
    base=$(basename "$comm" 2>/dev/null)
    case "$base" in
      claude|claude.exe|claude-code) printf '%s' "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  done
  return 1
}

# Whitespace-normalized start time of a PID (lstart pads with spaces). Empty if unknown —
# an unresolvable pid must not fail the pipeline, which under a caller's `set -eo pipefail`
# would abort the whole stamp with no output.
wtid_pid_start() {
  ps -o lstart= -p "$1" 2>/dev/null | tail -1 | awk '{$1=$1; print}' || true
}

# Settle WHO owns <wt_dir>, filling the owner globals wt_identity_load deliberately left empty (structural
# fields are preserved untouched). Ownership is arbitrated by a different rule than structural identity, and
# this is the only place that rule lives.
#
# GIT CONFIG IS AUTHORITATIVE for ownership. Ownership is inherently latest-wins — dead-session takeover is
# precisely the newest claim replacing an older one — and corroboration cannot supply recency: two STALE
# tiers corroborate each other exactly as readily as two fresh ones, so a majority proves only that SOME
# completed stamp wrote them, never that it was the latest. wt_identity_stamp writes git config MANDATORILY
# while both sidecars are best-effort, so config is the only tier a completed stamp is guaranteed to have
# written — which makes it the recency oracle ownership needs. BF-546 records the tradeoff this accepts.
#
# Authority needs a COMPLETE tuple, not merely a non-empty one: the owner keys are written in sequence, so an
# interrupted /start leaves {session, no pid} — which taken whole erases a LIVE owner into `unknown`, and the
# reuse guard admits on unknown. A completed stamp leaves only CLAIMED (owner-pid; the session id is empty
# whenever none was resolvable) or RELEASED (owner-released-at); anything else is torn and falls through to a
# path-verified sidecar, or stands as-is when no sidecar answers.
#
# The tuple moves WHOLE, never gap-filled field by field: a pid from one stamp spliced onto a session id from
# another asserts an owner no stamp ever wrote, and wt_owner_is_me and wt-disown's session gate would then
# adjudicate a fiction.
#
# RESIDUAL, stated because this comment is the threat model of record: the fall-through is disabled whenever the
# only reachable sidecar names a SUPERSEDED session, which is the "newest session id" rule above doing its job.
# A torn config naming B while B is alive and only A's sidecar survives therefore still resolves `unknown`, and
# the reuse guard admits on unknown. The tier disagreement it leaves behind is what the reuse guard WARNs on.
_wtid_resolve_owner() {
  local wt_dir="$1" issue_lower="${2-}" name f main_root
  local keep_issue="$WTID_ISSUE" keep_branch="$WTID_BRANCH" keep_src="$WTID_SOURCE_BRANCH" keep_base="$WTID_BASELINE"
  local keep_head="$WTID_HEAD_SHA" keep_era="$WTID_STAMPED_AT" keep_wt="$WTID_WT_DIR"
  local owner pid pid_start released claimed
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  _wtid_read_config "$wt_dir"
  owner="$WTID_OWNER"; pid="$WTID_OWNER_PID"; pid_start="$WTID_OWNER_PID_START"; released="$WTID_OWNER_RELEASED_AT"
  claimed="$WTID_OWNER_CLAIMED_AT"
  if [ -z "$pid" ] && [ -z "$released" ]; then
    name=$(_wtid_sidecar_name "$issue_lower")
    main_root=$(_wtid_main_root "$wt_dir" || true)
    for f in ${CLAUDE_JOB_DIR:+"$CLAUDE_JOB_DIR/$name"} ${main_root:+"$main_root/.claude/worktree-identity/$name"}; do
      [ -f "$f" ] || continue
      _wtid_read_sidecar "$f"
      # The structural path's gates apply here too: a file below the readable floor is not a tier, so a planted
      # two-line .env cannot hand an owner to a worktree that carries no identity at all.
      _wtid_tier_readable || continue
      _wtid_sidecar_matches "$wt_dir" || continue
      # A torn config still carries the LATEST session id, so only THAT session's sidecar may complete the
      # tuple — completing it from another session's would splice a foreign pid onto the newest claim and
      # resurrect an owner that was already replaced.
      if [ -n "$owner" ] && [ "$WTID_OWNER" != "$owner" ]; then continue; fi
      if [ -n "$WTID_OWNER" ] || [ -n "$WTID_OWNER_PID" ]; then
        owner="$WTID_OWNER"; pid="$WTID_OWNER_PID"; pid_start="$WTID_OWNER_PID_START"; released="$WTID_OWNER_RELEASED_AT"
        claimed="$WTID_OWNER_CLAIMED_AT"
        break
      fi
    done
  fi
  WTID_ISSUE="$keep_issue"; WTID_BRANCH="$keep_branch"; WTID_SOURCE_BRANCH="$keep_src"; WTID_BASELINE="$keep_base"
  WTID_HEAD_SHA="$keep_head"; WTID_STAMPED_AT="$keep_era"; WTID_WT_DIR="$keep_wt"
  WTID_OWNER="$owner"; WTID_OWNER_SESSION="$owner"
  WTID_OWNER_PID="$pid"; WTID_OWNER_PID_START="$pid_start"; WTID_OWNER_RELEASED_AT="$released"
  WTID_OWNER_CLAIMED_AT="$claimed"
}

# Adjudicate the liveness of <wt_dir>'s owning session. Runs wt_identity_load for the structural identity and then _wtid_resolve_owner for the owner tuple,
# so it populates the whole WTID_* set and is the only caller that may act on ownership — of interest here:
# WTID_OWNER_SESSION, WTID_OWNER_PID, WTID_OWNER_PID_START, WTID_OWNER_RELEASED_AT,
# WTID_OWNER_ALIVE = alive | dead | unknown | released. Returns 0 alive, 1 dead, 2 unknown, 3 released.
# "dead" requires POSITIVE evidence (PID gone, or recycled into a non-harness / different-start-time process);
# "released" requires POSITIVE evidence too (owner-released-at present with no resolvable pid — a deliberate wt_identity_disown);
# anything less is "unknown" — automation must fail safe on unknown (a live owner can't be ruled out).
wt_owner_alive() {
  local wt_dir="$1"
  WTID_OWNER_ALIVE="unknown"
  # The structural identity is arbitrated by corroboration, the owner tuple by _wtid_resolve_owner. A legacy /
  # never-stamped worktree loses the structural half and still resolves ownership, which start-wt-create.sh's
  # reuse guard depends on.
  wt_identity_load "$wt_dir" || true
  _wtid_resolve_owner "$wt_dir"
  # Within the resolved tuple a pid ALWAYS wins over a released marker, so a re-claimed worktree can never read
  # as up for grabs: every stamp unsets released-at before writing the pid, and a crash between the two leaves
  # neither — unknown, which automation treats as hands-off.
  if [ -z "$WTID_OWNER_PID" ]; then
    if [ -n "$WTID_OWNER_RELEASED_AT" ]; then
      WTID_OWNER_ALIVE="released"
      return 3
    fi
    return 2
  fi

  local msys=0 cur_comm base cur_start
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) msys=1 ;; esac
  cur_comm=$(ps -o comm= -p "$WTID_OWNER_PID" 2>/dev/null | tail -1)
  if [ -z "$cur_comm" ]; then
    # MSYS ps can't see native processes, so an empty result there proves nothing.
    if [ "$msys" = 1 ]; then return 2; fi
    WTID_OWNER_ALIVE="dead"; return 1
  fi
  base=$(basename "$cur_comm" 2>/dev/null)
  case "$base" in
    claude|claude.exe|claude-code|node) : ;;
    *) WTID_OWNER_ALIVE="dead"; return 1 ;;   # PID recycled into an unrelated process
  esac
  if [ -n "$WTID_OWNER_PID_START" ]; then
    cur_start=$(wtid_pid_start "$WTID_OWNER_PID")
    if [ -n "$cur_start" ] && [ "$cur_start" != "$WTID_OWNER_PID_START" ]; then
      WTID_OWNER_ALIVE="dead"; return 1     # PID recycled into a different harness instance
    fi
  fi
  WTID_OWNER_ALIVE="alive"
  return 0
}

# Cross-tier ownership-contest signal (BF-575). Run after wt_owner_alive; leaves its resolved tuple intact.
# Sets WTID_OWNER_CONTEST=0|1 and WTID_OWNER_CONTEST_DETAIL (one line naming the rival tier and both claims).
#
# A contest is config's owner claim standing UNWITNESSED against a rival: some readable, path-matched sidecar
# records a DIFFERENT owner whose claim epoch is equal-or-newer than config's (-ge, never -gt — stamped-at is
# frozen across reuse, so a seizure that leaves the epochs alone is only visible on equality), AND no readable
# sidecar corroborates config's exact owner+epoch pair. The corroborator is a same-stamp witness: a real
# takeover's own stamp writes the new claim to the sidecars in the same call, so its claim never stands alone —
# which is also what keeps a same-second takeover (rival epoch EQUAL by clock, not by seizure) out of the
# signal. The three states TIER_DISSENT conflates separate here: a seizure contests; an interrupted disown
# never does (same owner on every tier — only pid/release fields differ); an ordinary stale tier never does
# (its claim epoch is older than the corroborated current one).
#
# SUBORDINATE TO LIVENESS by contract: this signal refines messaging and reporting; admission decisions stay
# on wt_owner_alive's verdict, and no consumer may park or relabel a worktree on contest alone — a worktree
# whose owner is merely gone must stay takeoverable (the stranding that killed BF-546's OWNER_DISSENT gate).
# Residuals, stated: a seizure that also forges a NEWER claim epoch mimics supersession here (it still trips
# TIER_DISSENT structurally), and a stamp whose sidecar writes all failed leaves its honest claim unwitnessed —
# both are the two-coordinated-writes / degraded-tier states BF-546 accepts, each loudly warned at stamp time.
wt_owner_contest() {
  local wt_dir="$1" issue_lower="${2-}" name main_root f
  WTID_OWNER_CONTEST=0; WTID_OWNER_CONTEST_DETAIL=""
  local keep_issue="$WTID_ISSUE" keep_branch="$WTID_BRANCH" keep_src="$WTID_SOURCE_BRANCH" keep_base="$WTID_BASELINE"
  local keep_head="$WTID_HEAD_SHA" keep_era="$WTID_STAMPED_AT" keep_wt="$WTID_WT_DIR"
  local keep_owner="$WTID_OWNER" keep_sess="$WTID_OWNER_SESSION" keep_pid="$WTID_OWNER_PID"
  local keep_pid_start="$WTID_OWNER_PID_START" keep_rel="$WTID_OWNER_RELEASED_AT" keep_claim="$WTID_OWNER_CLAIMED_AT"
  local cfg_owner cfg_claim rival_tier="" rival_owner="" rival_claim="" witnessed=0 tier
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  # The comparison base is config ITSELF — the seizable tier the contest is about — never the resolved
  # tuple, which may have been completed from a sidecar precisely when config is torn.
  _wtid_read_config "$wt_dir"
  cfg_owner="$WTID_OWNER"; cfg_claim="$WTID_OWNER_CLAIMED_AT"
  if [ -n "$cfg_owner" ]; then
    name=$(_wtid_sidecar_name "$issue_lower")
    main_root=$(_wtid_main_root "$wt_dir" || true)
    for f in ${CLAUDE_JOB_DIR:+"$CLAUDE_JOB_DIR/$name"} ${main_root:+"$main_root/.claude/worktree-identity/$name"}; do
      [ -f "$f" ] || continue
      _wtid_read_sidecar "$f"
      _wtid_tier_readable || continue
      _wtid_sidecar_matches "$wt_dir" || continue
      [ -n "$WTID_OWNER" ] || continue
      # The guard default can never prefix a real path: with CLAUDE_JOB_DIR unset the pattern would
      # otherwise degenerate to /* and label the repo-fallback tier job-dir in the detail line.
      case "$f" in "${CLAUDE_JOB_DIR:-/dev/null/none}"/*) tier="job-dir" ;; *) tier="repo-fallback" ;; esac
      if [ "$WTID_OWNER" = "$cfg_owner" ]; then
        [ "$WTID_OWNER_CLAIMED_AT" = "$cfg_claim" ] && witnessed=1
      elif [ "$(_wtid_era_num "$WTID_OWNER_CLAIMED_AT")" -ge "$(_wtid_era_num "$cfg_claim")" ]; then
        rival_tier="$tier"; rival_owner="$WTID_OWNER"; rival_claim="$WTID_OWNER_CLAIMED_AT"
      fi
    done
    if [ -n "$rival_owner" ] && [ "$witnessed" = 0 ]; then
      WTID_OWNER_CONTEST=1
      WTID_OWNER_CONTEST_DETAIL="$rival_tier records owner '$rival_owner' (claimed ${rival_claim:-unrecorded}) against config's unwitnessed '$cfg_owner' (claimed ${cfg_claim:-unrecorded})"
    fi
  fi
  WTID_ISSUE="$keep_issue"; WTID_BRANCH="$keep_branch"; WTID_SOURCE_BRANCH="$keep_src"; WTID_BASELINE="$keep_base"
  WTID_HEAD_SHA="$keep_head"; WTID_STAMPED_AT="$keep_era"; WTID_WT_DIR="$keep_wt"
  WTID_OWNER="$keep_owner"; WTID_OWNER_SESSION="$keep_sess"; WTID_OWNER_PID="$keep_pid"
  WTID_OWNER_PID_START="$keep_pid_start"; WTID_OWNER_RELEASED_AT="$keep_rel"; WTID_OWNER_CLAIMED_AT="$keep_claim"
  return 0
}

# Is the loaded owner THIS session? Run only after wt_owner_alive. Session ids are the primary comparison: in a `claude agents` fleet every session's
# harness-pid walk collapses to the shared fleet root, so pid equality would call every sibling's worktree "mine". Pid + start time is only the fallback
# for environments where no session id was stamped or none is resolvable here. Returns 0 = me, 1 = not me (or undeterminable — callers treat that as foreign).
wt_owner_is_me() {
  local my_pid
  if [ -n "${WTID_OWNER_SESSION:-}" ]; then
    wtid_owner_session_matches && return 0
    # A stamped id matching none of ours is foreign — unless we can present no id at all, which is
    # the "no session id resolvable here" case the pid path exists for.
    [ -n "$(wtid_session_ids)" ] && return 1
  fi
  my_pid=$(wtid_harness_pid || true)
  [ -n "$my_pid" ] && [ -n "${WTID_OWNER_PID:-}" ] && [ "$my_pid" = "${WTID_OWNER_PID:-}" ]
}

# Every identifier this session can legitimately be known by, newline-separated (may be empty). A
# fleet run stamps its job-dir basename; the same session continuing outside the fleet presents only
# CLAUDE_CODE_SESSION_ID — same session, different label, so comparing one resolved id strands it.
wtid_session_ids() {
  [ -n "${CLAUDE_JOB_DIR:-}" ] && basename "$CLAUDE_JOB_DIR"
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && printf '%s\n' "$CLAUDE_CODE_SESSION_ID"
  [ -n "${CLAUDE_SESSION_ID:-}" ] && printf '%s\n' "$CLAUDE_SESSION_ID"
  return 0
}

# Does the loaded WTID_OWNER_SESSION match any id this session presents? Session ids ONLY — no pid
# fallback, so callers that must not accept fleet-root pid equality can gate on this directly.
wtid_owner_session_matches() {
  local id
  [ -z "${WTID_OWNER_SESSION:-}" ] && return 1
  while read -r id; do
    if [ -n "$id" ] && [ "$id" = "$WTID_OWNER_SESSION" ]; then return 0; fi
  done <<< "$(wtid_session_ids)"
  return 1
}

# --- Stamping (the write side; used by start-wt-create.sh and finish-recover.sh) ---

# Resolve the owning session id (best-effort; empty is acceptable — identity still
# works, ownership just isn't attributable).
wt_identity_owner() {
  if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    basename "$CLAUDE_JOB_DIR"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
  elif [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_SESSION_ID"
  fi
}

# Write one sidecar .env into <dir>. Echoes the path on success; non-zero on failure.
# Args: dir issue_id branch source_branch baseline wt_abs owner created_at [owner_pid] [owner_pid_start] [head_sha] [stamped_at] [owner_claimed_at]
_wtid_write_sidecar() {
  local dir="$1" issue_id="$2" branch="$3" source_branch="$4" baseline="$5" wt_abs="$6" owner="$7" created_at="$8" owner_pid="$9" owner_pid_start="${10}" head_sha="${11}" stamped_at="${12}" owner_claimed_at="${13-}"
  local issue_lower path tmp
  issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')
  path="$dir/wt-identity-${issue_lower}.env"
  mkdir -p "$dir" 2>/dev/null || return 1
  # Write-then-rename (same dir, so the rename is atomic): a concurrent reader must never see a
  # half-written block — the missing keys would parse as an all-empty identity that verifies CLEAN.
  tmp="$path.tmp.$$"
  {
    printf 'WT_IDENTITY_VERSION=1\n'
    printf 'WT_IDENTITY_ISSUE=%s\n' "$issue_id"
    printf 'WT_IDENTITY_BRANCH=%s\n' "$branch"
    printf 'WT_IDENTITY_SOURCE_BRANCH=%s\n' "$source_branch"
    printf 'WT_IDENTITY_BASELINE_SHA=%s\n' "$baseline"
    printf 'WT_IDENTITY_HEAD_SHA=%s\n' "$head_sha"
    printf 'WT_IDENTITY_STAMPED_AT=%s\n' "$stamped_at"
    printf 'WT_IDENTITY_WT_DIR=%s\n' "$wt_abs"
    printf 'WT_IDENTITY_OWNER=%s\n' "$owner"
    printf 'WT_IDENTITY_CREATED_AT=%s\n' "$created_at"
    printf 'WT_IDENTITY_OWNER_PID=%s\n' "$owner_pid"
    printf 'WT_IDENTITY_OWNER_PID_START=%s\n' "$owner_pid_start"
    printf 'WT_IDENTITY_OWNER_CLAIMED_AT=%s\n' "$owner_claimed_at"
  # stderr is silenced BEFORE the file redirection, not after: redirections apply left to right, so the other
  # order lets the shell's own "Permission denied" for $tmp escape to the caller's stderr.
  } 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s' "$path"
}

# Set one MANDATORY per-worktree config key, or WARN and mark the stamp failed. Assigning to the caller's
# rc rather than relying on `set -e`: every real call site (`if ! wt_identity_stamp`, `wt_identity_stamp ||
# true`) disables set -e inside the function, so an unchecked write would report success on a stamp that
# wrote nothing. --replace-all because a single-value write onto a multi-valued key fails rc 5 — that is
# how a planted `--add` becomes unrepairable.
_wtid_stamp_cfg() {
  local wt_dir="$1" key="$2" value="$3"
  if ! git -C "$wt_dir" config --worktree --replace-all "$key" "$value"; then
    echo "WARN: identity stamp could not write mandatory per-worktree config '$key' for '$wt_dir'" >&2
    return 1
  fi
}

# Clear one per-worktree config key the stamp GUARANTEES ends up absent, or WARN and mark the stamp failed —
# an unresolvable value must leave the key GONE, never the previous owner's value in place, which config being
# the ownership tier would read as a current claim. git's rc 5 ("no such option") is the wanted end state.
_wtid_unstamp_cfg() {
  local wt_dir="$1" key="$2" rc=0
  git -C "$wt_dir" config --worktree --unset-all "$key" 2>/dev/null || rc=$?
  if [ "$rc" != "0" ] && [ "$rc" != "5" ]; then
    echo "WARN: identity stamp could not clear per-worktree config '$key' for '$wt_dir' (git config exit $rc)" >&2
    return 1
  fi
}

# Stamp a tamper-evident identity on a worktree: MANDATORY per-worktree git config + BEST-EFFORT immune
# sidecars (job-dir, strongest; plus a repo-level .claude/worktree-identity/ fallback any session can
# find). Returns non-zero if any mandatory config write failed — the identity is then partial, and callers
# must treat the worktree as unstamped rather than proceeding on whatever landed. Sets globals for the
# caller to emit:
#   WTID_STAMP_OWNER WTID_STAMP_CREATED_AT WTID_STAMP_SIDECAR WTID_STAMP_HEAD_SHA WTID_STAMP_STAMPED_AT
# Args: wt_dir wt_abs issue_id branch source_branch baseline_sha
wt_identity_stamp() {
  local wt_dir="$1" wt_abs="$2" issue_id="$3" branch="$4" source_branch="$5" baseline="$6" cfg_rc=0
  WTID_STAMP_OWNER=$(wt_identity_owner)
  # The tip this stamp sanctions. wt-restamp.sh proves a later rewrite preserved it; recorded here
  # (not passed in) so every caller gets the anchor without a signature change. The override exists
  # for /start's RESUME path: re-stamping a worktree that already has work must not re-arm the anchor
  # on the current tip, which would retroactively bless whatever happened since the original stamp.
  WTID_STAMP_HEAD_SHA=${WTID_STAMP_HEAD_SHA_OVERRIDE:-$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)}
  # When this stamp happened. wt-restamp.sh walks the branch reflog back to this instant to find
  # tips created since — bounding by TIME, not by value: a foreign reset can land the branch back ON
  # the anchor's value, and a value-bounded walk would stop there and never see the drop.
  # The override travels WITH WTID_STAMP_HEAD_SHA_OVERRIDE and only with it: an anchor whose era has
  # been re-armed hides everything that happened between them from the walk.
  WTID_STAMP_STAMPED_AT=${WTID_STAMP_STAMPED_AT_OVERRIDE:-$(date +%s)}
  # Override lets a RE-stamp (wt-restamp.sh) keep the worktree's original creation time.
  WTID_STAMP_CREATED_AT=${WTID_STAMP_CREATED_AT_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  # The ownership claim epoch (BF-575): when THIS stamp asserted the owner tuple. Deliberately decoupled
  # from stamped-at, which is FROZEN across reuse as wt-restamp's audit anchor — the freeze is what made a
  # legitimate takeover and a config seizure byte-identical on every persisted field. No override is
  # honored, ever: an overridable claim epoch would be freezable, restoring exactly that blindness, and a
  # forged-future value already sorts to 0 through _wtid_era_num on the read side.
  WTID_STAMP_OWNER_CLAIMED_AT=$(date +%s)
  WTID_STAMP_SIDECAR=""
  WTID_STAMP_OWNER_PID=$(wtid_harness_pid || true)
  WTID_STAMP_OWNER_PID_START=""
  [ -n "$WTID_STAMP_OWNER_PID" ] && WTID_STAMP_OWNER_PID_START=$(wtid_pid_start "$WTID_STAMP_OWNER_PID")
  # A stamp that cannot present a session id CARRIES THE PRIOR OWNER FORWARD, into every tier, and publishes no
  # pid alongside it. Two invariants meet here and only this shape satisfies both. Erasing the id would leave
  # wt-restamp.sh's session gate — the one check between a foreign session and a merge — matching NOBODY, the
  # true owner included, permanently. Keeping the id while writing THIS process's pid would assert a tuple no
  # stamp ever wrote, pairing one session's identity with another's pid, which is the splice _wtid_resolve_owner
  # refuses to construct. So attribution survives and the claim does not: the tuple reads incomplete, ownership
  # falls through to a path-verified sidecar or resolves `unknown`, and `unknown` is hands-off.
  if [ -z "$WTID_STAMP_OWNER" ]; then
    WTID_STAMP_OWNER=$(git -C "$wt_dir" config --worktree --get start.owner-session 2>/dev/null || true)
    [ -n "$WTID_STAMP_OWNER" ] && { WTID_STAMP_OWNER_PID=""; WTID_STAMP_OWNER_PID_START=""; }
  fi

  # Mandatory git config. This is the tier ownership is read from, so a failure here is a failed stamp, not a
  # degraded one — hence every write AND every unset is checked; each unset carries a guarantee of its own.
  _wtid_stamp_cfg "$wt_dir" start.source-branch   "$source_branch"           || cfg_rc=1
  _wtid_stamp_cfg "$wt_dir" start.worktree-branch "$branch"                  || cfg_rc=1
  _wtid_stamp_cfg "$wt_dir" start.baseline-sha    "$baseline"                || cfg_rc=1
  _wtid_stamp_cfg "$wt_dir" start.created-at      "$WTID_STAMP_CREATED_AT"   || cfg_rc=1
  if [ -n "$WTID_STAMP_HEAD_SHA" ]; then
    _wtid_stamp_cfg "$wt_dir" start.head-sha "$WTID_STAMP_HEAD_SHA" || cfg_rc=1
  else
    _wtid_unstamp_cfg "$wt_dir" start.head-sha || cfg_rc=1
  fi
  _wtid_stamp_cfg "$wt_dir" start.stamped-at "$WTID_STAMP_STAMPED_AT" || cfg_rc=1
  # Owner session: written whenever one is known — this session's, or the prior owner carried forward above.
  # Only a worktree that has never had an owner reaches the unset, so no attribution is ever destroyed, and
  # because the same value goes to the sidecars the tiers still agree.
  if [ -n "$WTID_STAMP_OWNER" ]; then
    _wtid_stamp_cfg "$wt_dir" start.owner-session "$WTID_STAMP_OWNER" || cfg_rc=1
  else
    _wtid_unstamp_cfg "$wt_dir" start.owner-session || cfg_rc=1
  fi
  # The claim epoch is written unconditionally — even a carried-forward or ownerless stamp re-asserts
  # whatever tuple it writes, and the contest comparison requires both owners non-empty anyway.
  _wtid_stamp_cfg "$wt_dir" start.owner-claimed-at "$WTID_STAMP_OWNER_CLAIMED_AT" || cfg_rc=1
  # Every stamp revokes a prior release: a claimed worktree must never read released. Unset BEFORE the pid write —
  # a crash between the two leaves no-released + no-pid = unknown, which automation treats as hands-off.
  _wtid_unstamp_cfg "$wt_dir" start.owner-released-at || cfg_rc=1
  # Owner PID: set on success, UNSET on failure — a takeover stamp that can't resolve its own PID must not leave the dead prior owner's PID looking current.
  if [ -n "$WTID_STAMP_OWNER_PID" ]; then
    _wtid_stamp_cfg "$wt_dir" start.owner-pid       "$WTID_STAMP_OWNER_PID"       || cfg_rc=1
    _wtid_stamp_cfg "$wt_dir" start.owner-pid-start "$WTID_STAMP_OWNER_PID_START" || cfg_rc=1
  else
    _wtid_unstamp_cfg "$wt_dir" start.owner-pid       || cfg_rc=1
    _wtid_unstamp_cfg "$wt_dir" start.owner-pid-start || cfg_rc=1
  fi

  # Immune sidecars (best-effort; a worktree with no sidecar degrades to legacy
  # behavior at /finish rather than failing setup).
  local p main_root
  if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -d "${CLAUDE_JOB_DIR}" ]; then
    if p=$(_wtid_write_sidecar "$CLAUDE_JOB_DIR" "$issue_id" "$branch" "$source_branch" "$baseline" "$wt_abs" "$WTID_STAMP_OWNER" "$WTID_STAMP_CREATED_AT" "$WTID_STAMP_OWNER_PID" "$WTID_STAMP_OWNER_PID_START" "$WTID_STAMP_HEAD_SHA" "$WTID_STAMP_STAMPED_AT" "$WTID_STAMP_OWNER_CLAIMED_AT"); then
      WTID_STAMP_SIDECAR="$p"
    else
      echo "WARN: could not write identity sidecar under \$CLAUDE_JOB_DIR ($CLAUDE_JOB_DIR)" >&2
    fi
  fi
  main_root=$(_wtid_main_root "$wt_dir" || true)
  if [ -n "$main_root" ]; then
    local id_dir="$main_root/.claude/worktree-identity"
    # Make the dir self-ignoring (a `.gitignore` of `*`) so sidecars can never be
    # accidentally committed in repos that don't already ignore .claude/* — these
    # are machine-local, not team artifacts.
    if mkdir -p "$id_dir" 2>/dev/null && [ ! -f "$id_dir/.gitignore" ]; then
      printf '*\n' > "$id_dir/.gitignore" 2>/dev/null || true
    fi
    if p=$(_wtid_write_sidecar "$id_dir" "$issue_id" "$branch" "$source_branch" "$baseline" "$wt_abs" "$WTID_STAMP_OWNER" "$WTID_STAMP_CREATED_AT" "$WTID_STAMP_OWNER_PID" "$WTID_STAMP_OWNER_PID_START" "$WTID_STAMP_HEAD_SHA" "$WTID_STAMP_STAMPED_AT" "$WTID_STAMP_OWNER_CLAIMED_AT"); then
      [ -z "$WTID_STAMP_SIDECAR" ] && WTID_STAMP_SIDECAR="$p"
    else
      echo "WARN: could not write repo-level identity sidecar under $id_dir" >&2
    fi
  fi
  if [ -z "$WTID_STAMP_SIDECAR" ]; then
    echo "WARN: no identity sidecar could be written; worktree falls back to git-config-only identity (less tamper-resistant)." >&2
  fi
  return $cfg_rc
}

# Release one sidecar's ownership claim IN PLACE: owner-pid fields emptied, released-at added, every other line
# byte-preserved. Never a full rewrite from loaded values — that could splice a stale tier's baseline/head/era
# over a fresher one's (the tier-consistency invariant wt-restamp.sh audits). Write-then-rename like _wtid_write_sidecar.
_wtid_disown_sidecar() {
  local f="$1" released_at="$2" tmp
  tmp="$f.tmp.$$"
  awk -v rel="$released_at" '
    /^WT_IDENTITY_OWNER_PID=/       { print "WT_IDENTITY_OWNER_PID="; next }
    /^WT_IDENTITY_OWNER_PID_START=/ { print "WT_IDENTITY_OWNER_PID_START="; next }
    /^WT_IDENTITY_OWNER_RELEASED_AT=/ { next }
    { print }
    END { print "WT_IDENTITY_OWNER_RELEASED_AT=" rel }
  ' "$f" 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Release a worktree's ownership so any session may resume it: unset start.owner-pid/-pid-start, set
# start.owner-released-at, KEEP start.owner-session (last-owner attribution; wt-restamp's session gate
# still recognizes the original owner). Ownership is otherwise overwrite-only, and in a fleet the stamped
# pid is the shared root that reads alive for days after the owning session moved on — without a release,
# a stalled/abandoned worktree is unreachable by every other session for that process's whole lifetime.
# Ungated mechanics (like wt_identity_stamp): callers gate — wt-disown.sh is the sanctioned entry point.
# Sidecars are transformed in place; only reachable ones (this session's job dir + the repo fallback) —
# a foreign owner's job-dir sidecar is invisible to other sessions' loads and goes inert on the next stamp.
# Post-verifies every tier it touched; returns non-zero (after a WARN naming the tier) if any write did not
# take. A non-zero return does NOT mean the release was withheld: git config is the tier ownership is read
# from, so once its unset+released-at land the worktree IS released even if a sidecar rewrite failed. The
# return code reports that the tiers were left inconsistent, which the operator must repair.
# Sets WTID_DISOWN_RELEASED_AT for the caller to emit.
# Args: wt_identity_disown <wt_dir> [issue_lower]
wt_identity_disown() {
  local wt_dir="$1" issue_lower="${2-}" rc=0 name main_root f
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  name=$(_wtid_sidecar_name "$issue_lower")
  WTID_DISOWN_RELEASED_AT=$(date +%s)

  git -C "$wt_dir" config --worktree --unset-all start.owner-pid 2>/dev/null || true
  git -C "$wt_dir" config --worktree --unset-all start.owner-pid-start 2>/dev/null || true
  git -C "$wt_dir" config --worktree --replace-all start.owner-released-at "$WTID_DISOWN_RELEASED_AT" 2>/dev/null || true
  # owner-pid-start is checked too, not just owner-pid: it is part of the fingerprint tiers are compared on, so
  # a survivor leaves this worktree permanently dissenting from the sidecars the release DID rewrite.
  if git -C "$wt_dir" config --worktree --get start.owner-pid >/dev/null 2>&1 || \
     git -C "$wt_dir" config --worktree --get start.owner-pid-start >/dev/null 2>&1 || \
     ! git -C "$wt_dir" config --worktree --get start.owner-released-at >/dev/null 2>&1; then
    echo "WARN: disown did not take effect in per-worktree git config for '$wt_dir'" >&2
    rc=1
  fi

  main_root=$(_wtid_main_root "$wt_dir" || true)
  for f in ${CLAUDE_JOB_DIR:+"$CLAUDE_JOB_DIR/$name"} ${main_root:+"$main_root/.claude/worktree-identity/$name"}; do
    [ -f "$f" ] || continue
    _wtid_read_sidecar "$f"
    # A stale same-issue sidecar recorded for a DIFFERENT worktree path is not this worktree's claim — leave it alone.
    _wtid_sidecar_matches "$wt_dir" || continue
    if ! _wtid_disown_sidecar "$f" "$WTID_DISOWN_RELEASED_AT"; then
      echo "WARN: disown could not rewrite identity sidecar '$f'" >&2
      rc=1
      continue
    fi
    _wtid_read_sidecar "$f"
    if [ -n "$WTID_OWNER_PID" ] || [ -z "$WTID_OWNER_RELEASED_AT" ]; then
      echo "WARN: disown verification failed for identity sidecar '$f'" >&2
      rc=1
    fi
  done
  return $rc
}

# Robustly remove a linked worktree dir on all platforms — notably Windows Git Bash, where a sibling
# node/pnpm process (parallel /auto) can hold node_modules files open and long paths defeat a single
# unlink. A bare `git worktree remove --force || rm -rf` deregisters first, then leaves the locked
# content as an orphaned .claude/worktrees/<slug> (content but no .git pointer) that the reaper can't
# reason about. This retries, always prunes, and RETURNS NON-ZERO with a loud WARN naming the residual
# if the dir survives — surfacing it at removal time instead of letting a later prune finalize an
# invisible orphan. Only removes the dir; callers keep their own branch-delete logic.
# Args: wt_force_remove <git_ctx> <wt_dir>   (git_ctx = a path inside the repo for `git -C`)
wt_force_remove() {
  local ctx="$1" wt="$2" attempt
  for attempt in 1 2; do
    git -C "$ctx" worktree remove --force "$wt" 2>/dev/null || true
    [ -d "$wt" ] && rm -rf "$wt" 2>/dev/null || true
    git -C "$ctx" worktree prune 2>/dev/null || true
    [ -d "$wt" ] || return 0
    [ "$attempt" = 1 ] && sleep 1   # brief backoff: a transient lock is often a sibling process still exiting
  done
  echo "WARN: could not fully remove worktree '$wt' after retries (Windows locked files / long paths?). Residual content left as an unregistered STRAY dir — /reap-worktrees will surface it. Remove manually once no process holds it: rm -rf '$wt'" >&2
  return 1
}

# Remove all identity sidecars for an issue (both locations). Best-effort cleanup
# called after a successful merge/recovery. Args: wt_dir issue_lower
wt_identity_cleanup() {
  local wt_dir="$1" issue_lower="${2-}" name main_root
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  name=$(_wtid_sidecar_name "$issue_lower")
  [ -n "${CLAUDE_JOB_DIR:-}" ] && rm -f "$CLAUDE_JOB_DIR/$name" 2>/dev/null || true
  main_root=$(_wtid_main_root "$wt_dir" || true)
  [ -n "$main_root" ] && rm -f "$main_root/.claude/worktree-identity/$name" 2>/dev/null || true
  return 0
}
