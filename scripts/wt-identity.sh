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
# Provides two functions, both populating WTID_* globals (read them after calling):
#
#   wt_identity_load <wt_dir> [<issue_lower>]
#     Finds the strongest available identity (job-dir sidecar → repo-fallback
#     sidecar → per-worktree git config) and sets:
#       WTID_SOURCE         job-dir | repo-fallback | git-config | none
#       WTID_ISSUE WTID_BRANCH WTID_SOURCE_BRANCH WTID_BASELINE WTID_SIDECAR_PATH
#     Returns 0 if a VERIFIABLE identity was found (sidecar, or git config carrying
#     the NEW start.worktree-branch + start.baseline-sha fields), 1 otherwise. A
#     pre-stamp "legacy" worktree (only start.source-branch, no new fields) and a
#     non-worktree both return 1 → callers fall back to today's behavior.
#
#   wt_identity_verify <wt_dir>
#     Run only after a successful wt_identity_load. Compares the worktree's CURRENT
#     branch/HEAD/config against the loaded identity and sets:
#       WTID_CORRUPTION         0 | 1
#       WTID_CORRUPTION_REASON  branch-swapped | baseline-detached |
#                               source-branch-config-wiped | ""
#     Always returns 0.

# Read the known keys out of a sidecar .env without eval/source (values may contain
# slashes; they never contain newlines).
_wtid_read_sidecar() {
  local f="$1"
  WTID_ISSUE=$(sed -n 's/^WT_IDENTITY_ISSUE=//p' "$f" | head -1)
  WTID_BRANCH=$(sed -n 's/^WT_IDENTITY_BRANCH=//p' "$f" | head -1)
  WTID_SOURCE_BRANCH=$(sed -n 's/^WT_IDENTITY_SOURCE_BRANCH=//p' "$f" | head -1)
  WTID_BASELINE=$(sed -n 's/^WT_IDENTITY_BASELINE_SHA=//p' "$f" | head -1)
  WTID_WT_DIR=$(sed -n 's/^WT_IDENTITY_WT_DIR=//p' "$f" | head -1)
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

wt_identity_load() {
  local wt_dir="$1" issue_lower="$2"
  WTID_SOURCE="none"; WTID_ISSUE=""; WTID_BRANCH=""; WTID_SOURCE_BRANCH=""
  WTID_BASELINE=""; WTID_SIDECAR_PATH=""
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  local name="wt-identity-${issue_lower}.env"

  # 1. Current session's job dir — strongest, and the same-session /full wt case.
  # Skip a stale sidecar whose recorded worktree path isn't this one (fall through).
  if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -f "$CLAUDE_JOB_DIR/$name" ]; then
    _wtid_read_sidecar "$CLAUDE_JOB_DIR/$name"
    if _wtid_sidecar_matches "$wt_dir"; then
      WTID_SOURCE="job-dir"; WTID_SIDECAR_PATH="$CLAUDE_JOB_DIR/$name"
      return 0
    fi
  fi

  # 2. Repo-level fallback under the MAIN checkout — found by any session.
  local main_root
  main_root=$(_wtid_main_root "$wt_dir" || true)
  if [ -n "$main_root" ] && [ -f "$main_root/.claude/worktree-identity/$name" ]; then
    _wtid_read_sidecar "$main_root/.claude/worktree-identity/$name"
    if _wtid_sidecar_matches "$wt_dir"; then
      WTID_SOURCE="repo-fallback"; WTID_SIDECAR_PATH="$main_root/.claude/worktree-identity/$name"
      return 0
    fi
  fi

  # 3. Per-worktree git config — only "verifiable" if it carries the NEW fields.
  # A legacy worktree (start.source-branch only) lacks these → treated as no
  # verifiable identity so the caller keeps today's behavior.
  local cb cbase csrc
  cb=$(git -C "$wt_dir" config --worktree --get start.worktree-branch 2>/dev/null || true)
  cbase=$(git -C "$wt_dir" config --worktree --get start.baseline-sha 2>/dev/null || true)
  csrc=$(git -C "$wt_dir" config --worktree --get start.source-branch 2>/dev/null || true)
  if [ -n "$cb" ] && [ -n "$cbase" ]; then
    WTID_BRANCH="$cb"; WTID_BASELINE="$cbase"; WTID_SOURCE_BRANCH="$csrc"
    WTID_SOURCE="git-config"
    return 0
  fi

  return 1
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

  # (c) Sidecar identity exists but the worktree's own start.source-branch config
  # was wiped — proven tampering. (For a git-config-only identity this can't fire:
  # the config IS the identity, so its source-branch is present by construction.)
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
# Args: dir issue_id branch source_branch baseline wt_abs owner created_at
_wtid_write_sidecar() {
  local dir="$1" issue_id="$2" branch="$3" source_branch="$4" baseline="$5" wt_abs="$6" owner="$7" created_at="$8"
  local issue_lower path
  issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')
  path="$dir/wt-identity-${issue_lower}.env"
  mkdir -p "$dir" 2>/dev/null || return 1
  {
    printf 'WT_IDENTITY_VERSION=1\n'
    printf 'WT_IDENTITY_ISSUE=%s\n' "$issue_id"
    printf 'WT_IDENTITY_BRANCH=%s\n' "$branch"
    printf 'WT_IDENTITY_SOURCE_BRANCH=%s\n' "$source_branch"
    printf 'WT_IDENTITY_BASELINE_SHA=%s\n' "$baseline"
    printf 'WT_IDENTITY_WT_DIR=%s\n' "$wt_abs"
    printf 'WT_IDENTITY_OWNER=%s\n' "$owner"
    printf 'WT_IDENTITY_CREATED_AT=%s\n' "$created_at"
  } > "$path" 2>/dev/null || return 1
  printf '%s' "$path"
}

# Stamp a tamper-evident identity on a worktree: MANDATORY per-worktree git config
# (the caller's `set -e` + create-failure trap handle a failure here) + BEST-EFFORT
# immune sidecars (job-dir, strongest; plus a repo-level .claude/worktree-identity/
# fallback any session can find). Sets globals for the caller to emit:
#   WTID_STAMP_OWNER WTID_STAMP_CREATED_AT WTID_STAMP_SIDECAR
# Args: wt_dir wt_abs issue_id branch source_branch baseline_sha
wt_identity_stamp() {
  local wt_dir="$1" wt_abs="$2" issue_id="$3" branch="$4" source_branch="$5" baseline="$6"
  WTID_STAMP_OWNER=$(wt_identity_owner)
  WTID_STAMP_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  WTID_STAMP_SIDECAR=""

  # Mandatory git config (convenience copy; its absence later is a corruption tell).
  git -C "$wt_dir" config --worktree start.source-branch "$source_branch"
  git -C "$wt_dir" config --worktree start.worktree-branch "$branch"
  git -C "$wt_dir" config --worktree start.baseline-sha "$baseline"
  git -C "$wt_dir" config --worktree start.created-at "$WTID_STAMP_CREATED_AT"
  [ -n "$WTID_STAMP_OWNER" ] && git -C "$wt_dir" config --worktree start.owner-session "$WTID_STAMP_OWNER"

  # Immune sidecars (best-effort; a worktree with no sidecar degrades to legacy
  # behavior at /finish rather than failing setup).
  local p main_root
  if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -d "${CLAUDE_JOB_DIR}" ]; then
    if p=$(_wtid_write_sidecar "$CLAUDE_JOB_DIR" "$issue_id" "$branch" "$source_branch" "$baseline" "$wt_abs" "$WTID_STAMP_OWNER" "$WTID_STAMP_CREATED_AT"); then
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
    if p=$(_wtid_write_sidecar "$id_dir" "$issue_id" "$branch" "$source_branch" "$baseline" "$wt_abs" "$WTID_STAMP_OWNER" "$WTID_STAMP_CREATED_AT"); then
      [ -z "$WTID_STAMP_SIDECAR" ] && WTID_STAMP_SIDECAR="$p"
    else
      echo "WARN: could not write repo-level identity sidecar under $id_dir" >&2
    fi
  fi
  if [ -z "$WTID_STAMP_SIDECAR" ]; then
    echo "WARN: no identity sidecar could be written; worktree falls back to git-config-only identity (less tamper-resistant)." >&2
  fi
  return 0
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
  local wt_dir="$1" issue_lower="$2" name main_root
  [ -z "$issue_lower" ] && issue_lower=$(basename "$wt_dir")
  name="wt-identity-${issue_lower}.env"
  [ -n "${CLAUDE_JOB_DIR:-}" ] && rm -f "$CLAUDE_JOB_DIR/$name" 2>/dev/null || true
  main_root=$(_wtid_main_root "$wt_dir" || true)
  [ -n "$main_root" ] && rm -f "$main_root/.claude/worktree-identity/$name" 2>/dev/null || true
  return 0
}
