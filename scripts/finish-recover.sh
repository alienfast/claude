#!/bin/bash
# finish-recover.sh — Recover a /start wt worktree that a parallel session hijacked.
#
# Usage (run from the MAIN checkout, cwd = repo root):
#   finish-recover.sh <wt-dir> <baseline-sha> <source-branch> <worktree-branch> <commit-message-file>
#
# Codifies the rescue that PL-454 and PL-460 each hand-rolled when parallel /full wt
# runs reset their worktrees: salvage the session's intended work, re-apply it onto
# a FRESH branch forked from the CURRENT source tip, gate on `pnpm check`, commit,
# and hand to finish-merge.sh. The arguments come from finish-detect-mode.sh's
# exit-4 output (EXPECTED_BASELINE / EXPECTED_SOURCE_BRANCH / EXPECTED_BRANCH) —
# i.e. from the IMMUNE sidecar, not the clobbered git config.
#
# Invoked only after the /finish skill surfaces the corruption and the user confirms
# (detect-and-stop posture). Deterministic + re-runnable: the recovered worktree
# lives at a fixed path (`.claude/worktrees/<id>-recovered`) so a re-run RESUMES
# (skips re-salvage when work is already committed/resolved there) rather than
# duplicating or clobbering a hand-resolved conflict.
#
# <commit-message-file> is the WORK commit's message (must contain the issue ID,
# e.g. `PL-454: <summary>`). The merge-commit message handed to finish-merge.sh is
# synthesized here (`Merge <ISSUE-ID>`) since it is only used in the rare divergent
# case — a fresh fork + one commit fast-forwards.
#
# Exit codes:
#   0 — recovered and merged.
#   1 — precondition/setup failure (bad args, source branch gone, nothing to
#       salvage, worktree-add failed). Nothing was merged.
#   2 — conflict: `git apply` (or the downstream merge) hit conflicts in the
#       recovered worktree. Resolve there, then re-run finish-recover.sh.
#   3 — transient: finish-merge.sh deferred the merge to the local queue. The
#       recovered work is committed on <branch>-recovered and queued; a drainer
#       lands it. The corrupted original worktree has been retired.
#   4 — `pnpm check` failed in the recovered worktree. State preserved; fix and re-run.

set -eo pipefail

if [ $# -ne 5 ]; then
  echo "Usage: $0 <wt-dir> <baseline-sha> <source-branch> <worktree-branch> <commit-message-file>" >&2
  exit 1
fi

wt_dir="$1"
baseline_sha="$2"
source_branch="$3"
worktree_branch="$4"
message_file="$5"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Shared worktree library — sourced up here (not just before wt_identity_stamp at step 4) so
# wt_force_remove is available to the earlier worktree removals in steps 2 and 6.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/wt-identity.sh"

if [ ! -s "$message_file" ]; then
  echo "ERROR: commit-message file '$message_file' is missing or empty (needs the issue ID)." >&2
  exit 1
fi

issue_lower=$(basename "$wt_dir")
issue_upper=$(printf '%s' "$issue_lower" | tr '[:lower:]' '[:upper:]')
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
# Anchor cwd to the main checkout so relative .claude/worktrees paths and the
# absolute repo_root used in cleanup never desync (the header requires cwd = repo
# root, but harden against being invoked from a subdirectory).
cd "$repo_root" || { echo "ERROR: cannot cd to repo root '$repo_root'." >&2; exit 1; }
rec_wt=".claude/worktrees/${issue_lower}-recovered"
rec_branch="${worktree_branch}-recovered"

# "Already recovered" guard: a prior run retires the corrupted original ($wt_dir) ONLY
# after a successful (exit 0) OR queued (exit 3) merge. So if $wt_dir is gone but the
# recovered branch still carries the work, recovery already happened — re-running must
# NOT error with an alarming "nothing to recover from". Distinguish the two so a re-run
# never PREMATURELY marks Ready For Release: if the recovered work is already an ancestor
# of source it LANDED (exit 0 — RFR is correct); if not, it is still QUEUED (exit 3 — the
# merge drainer owns the RFR transition when it lands).
if [ ! -d "$wt_dir" ] && git rev-parse --verify --quiet "refs/heads/$rec_branch" >/dev/null 2>&1; then
  if git merge-base --is-ancestor "$rec_branch" "$source_branch" 2>/dev/null; then
    echo "Already recovered: '$rec_branch' is merged into $source_branch; the corrupted original was retired. Nothing to do." >&2
    echo "RECOVERED: $issue_upper — prior recovery already merged into $source_branch." >&2
    exit 0
  fi
  echo "Already recovered: work is committed on '$rec_branch' and queued for merge (not yet in $source_branch); corrupted original retired." >&2
  echo "DEFERRED: $issue_upper — recovered work queued for merge; will land via the drainer. Check /merge-queue." >&2
  exit 3
fi
if [ ! -d "$wt_dir" ]; then
  echo "ERROR: corrupted worktree '$wt_dir' does not exist and no recovered branch '$rec_branch' exists; nothing to recover from." >&2
  exit 1
fi

# Repo lock key — same as finish-merge.sh / start-wt-create.sh, so the worktree
# add here serializes against concurrent setups and merges on this parent repo.
# --path-format=absolute yields the SAME key from any worktree or the main checkout (avoids the MSYS
# `pwd -P` divergence — see standards/git.md "Windows Git Bash: comparing paths").
repo_key=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "ERROR: not inside a git repository (cwd: $PWD)" >&2
  exit 1
}
{ [ -n "$repo_key" ] && [ "$repo_key" != "/" ]; } || { echo "ERROR: could not resolve repo lock key (repo_key='$repo_key')." >&2; exit 1; }

# --- 1. Resolve the CURRENT source tip (re-fork from here, not the stale baseline). ---
git fetch --quiet 2>/dev/null || true
if ! git rev-parse --verify "$source_branch" >/dev/null 2>&1; then
  echo "ERROR: source branch '$source_branch' no longer exists locally; cannot re-fork." >&2
  exit 1
fi
src_tip=$(git rev-parse --verify "$source_branch")

# --- 2. Classify the recovered worktree: resume an in-flight recovery vs start fresh. ---
# Prune first so stale admin metadata from a manually-deleted dir can't wedge the add.
git worktree prune 2>/dev/null || true
rec_state="fresh"
if [ -d "$rec_wt" ]; then
  rec_cur=$(git -C "$rec_wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$rec_cur" = "$rec_branch" ]; then
    if [ "$(git -C "$rec_wt" rev-list --count "${src_tip}..HEAD" 2>/dev/null || echo 0)" != "0" ]; then
      rec_state="committed"   # a prior run already applied + committed the recovered work
    elif ! git -C "$rec_wt" diff --quiet 2>/dev/null \
         || ! git -C "$rec_wt" diff --cached --quiet 2>/dev/null \
         || [ -n "$(git -C "$rec_wt" ls-files --others --exclude-standard 2>/dev/null)" ]; then
      rec_state="pending"     # a hand-resolved exit-2 conflict, not yet committed
    else
      rec_state="empty"       # exists but nothing applied (prior add succeeded, apply didn't)
    fi
  else
    echo "Stale recovered worktree at $rec_wt (on '${rec_cur:-detached}'); recreating." >&2
    wt_force_remove "$PWD" "$rec_wt" || true
    git branch -D "$rec_branch" 2>/dev/null || true
    rec_state="fresh"
  fi
fi

PATCH=""
diff_strategy=""
if [ "$rec_state" = "committed" ]; then
  echo "Resuming: recovered work already committed on $rec_branch; skipping salvage/apply, going to merge." >&2
  diff_strategy="resumed-committed"
  echo "RECOVER_DIFF_STRATEGY=$diff_strategy" >&2
elif [ "$rec_state" = "pending" ]; then
  echo "Resuming: committing the hand-resolved conflict in $rec_wt; skipping salvage/apply." >&2
  diff_strategy="resumed-pending"
  echo "RECOVER_DIFF_STRATEGY=$diff_strategy" >&2
else
  # fresh or empty → salvage the intended work from the corrupted original.
  patch_dir="${CLAUDE_JOB_DIR:-$repo_root/.claude/worktree-identity}"
  mkdir -p "$patch_dir" 2>/dev/null || patch_dir="$repo_root"
  PATCH="$patch_dir/recover-${issue_lower}.patch"
  : > "$PATCH"

  cur_branch=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  _obj_exists() { git -C "$wt_dir" cat-file -e "${1}^{commit}" 2>/dev/null; }
  branch_ref_exists=0
  git -C "$wt_dir" rev-parse --verify --quiet "$worktree_branch" >/dev/null 2>&1 && branch_ref_exists=1

  # Does the corrupted worktree have untracked NEW files? `git diff` patches never include
  # untracked files, but a session's just-created source files are real intended work — so
  # they're salvaged SEPARATELY (carried in step 3, NUL-safe). The recovery must proceed
  # even when the ONLY salvageable work is untracked (empty tracked patch). This boolean is
  # quoting-agnostic (only emptiness matters).
  has_untracked=0
  [ -n "$(git -C "$wt_dir" ls-files --others --exclude-standard 2>/dev/null)" ] && has_untracked=1

  # Tier A — branch NOT swapped (intact / config-wipe-only): salvage MY net change,
  # anchored on the merge-base with source (NOT the static baseline) so any source
  # content a sibling merged INTO the branch is excluded. `git diff <fork>` compares
  # the working tree to the fork → committed + staged + unstaged work, minus source.
  if [ "$cur_branch" = "$worktree_branch" ]; then
    fork=$(git -C "$wt_dir" merge-base HEAD "$source_branch" 2>/dev/null || true)
    [ -z "$fork" ] && fork="$baseline_sha"
    if [ -n "$fork" ] && _obj_exists "$fork"; then
      diff_strategy="mine-vs-fork(HEAD)"
      git -C "$wt_dir" diff "$fork" > "$PATCH"
    fi
  fi

  # Tier B — branch swapped/reset but the worktree_branch REF still carries the
  # session's COMMITTED work (the data-loss case: HEAD reset off the branch). Salvage
  # the branch's net change vs its own merge-base with source.
  if [ ! -s "$PATCH" ] && [ "$branch_ref_exists" = "1" ]; then
    fork=$(git -C "$wt_dir" merge-base "$worktree_branch" "$source_branch" 2>/dev/null || true)
    [ -z "$fork" ] && fork="$baseline_sha"
    if [ -n "$fork" ] && _obj_exists "$fork" \
       && [ "$(git -C "$wt_dir" rev-list --count "${fork}..${worktree_branch}" 2>/dev/null || echo 0)" != "0" ]; then
      diff_strategy="committed-on-branch(${worktree_branch})"
      git -C "$wt_dir" diff "$fork" "$worktree_branch" > "$PATCH"
    fi
  fi

  # Tier C — last resort: surviving uncommitted edits vs the CURRENT (possibly
  # foreign) HEAD. Diffing vs HEAD (not baseline) excludes the foreign commits.
  if [ ! -s "$PATCH" ]; then
    git -C "$wt_dir" diff HEAD > "$PATCH"
    [ -s "$PATCH" ] && diff_strategy="uncommitted-vs-head"
  fi

  have_patch=0
  [ -s "$PATCH" ] && have_patch=1

  # Nothing salvageable at all (no tracked diff AND no untracked new files) → give up,
  # leaving the corrupted worktree intact for manual inspection.
  if [ "$have_patch" = "0" ] && [ "$has_untracked" = "0" ]; then
    echo "RECOVER_DIFF_STRATEGY=none" >&2
    echo "ERROR: no intended changes could be salvaged from '$wt_dir' (no tracked diff, no untracked new files)." >&2
    echo "  Inspect manually: git -C '$wt_dir' status; git -C '$wt_dir' reflog; git -C '$wt_dir' log ${baseline_sha}..${worktree_branch}" >&2
    exit 1
  fi

  if [ "$have_patch" = "0" ]; then
    # Pure-untracked recovery: the only work is new files (carried in step 3).
    diff_strategy="untracked-only"
    echo "RECOVER_DIFF_STRATEGY=$diff_strategy" >&2
    echo "No tracked-file changes to salvage; recovering untracked new file(s) only." >&2
  else
    echo "RECOVER_DIFF_STRATEGY=$diff_strategy" >&2
    echo "Salvaged patch → $PATCH ($(grep -c '^' "$PATCH") lines, strategy: $diff_strategy)" >&2
    # Surface work the chosen strategy did NOT capture, so nothing is silently dropped.
    case "$diff_strategy" in
      committed-on-branch*)
        if ! git -C "$wt_dir" diff HEAD --quiet 2>/dev/null; then
          echo "WARN: '$wt_dir' also has uncommitted edits at its current HEAD that were NOT folded into the committed-work patch." >&2
          echo "      Inspect: git -C '$wt_dir' diff HEAD — fold any real edits into $rec_wt before merging." >&2
        fi ;;
      uncommitted-vs-head*)
        if [ "$branch_ref_exists" = "1" ] && [ -n "$baseline_sha" ] && _obj_exists "$baseline_sha"; then
          extra=$(git -C "$wt_dir" rev-list --count "${baseline_sha}..${worktree_branch}" 2>/dev/null || echo 0)
          if [ "$extra" != "0" ]; then
            echo "WARN: branch '$worktree_branch' has $extra commit(s) beyond baseline NOT in the uncommitted patch." >&2
            echo "      Inspect: git -C '$wt_dir' log ${baseline_sha}..${worktree_branch} and fold any missing commits into $rec_wt." >&2
          fi
        fi ;;
    esac
  fi

  # Create the recovered worktree off the current source tip (under the repo lock).
  if [ "$rec_state" = "fresh" ]; then
    git branch -D "$rec_branch" 2>/dev/null || true   # clear an orphaned branch from a prior partial run
    mkdir -p .claude/worktrees
    "$SCRIPT_DIR/with-repo-lock.py" "$repo_key" \
      git worktree add "$rec_wt" -b "$rec_branch" "$src_tip" >&2 || {
        echo "ERROR: could not create recovered worktree at $rec_wt off $source_branch ($src_tip)." >&2
        exit 1
      }
  fi
  rec_abs=$(cd "$rec_wt" && pwd)

  # Apply the salvaged tracked-diff patch (only when there is one; pure-untracked
  # recoveries skip straight to the carry in step 3). 3-way so it tolerates source drift.
  if [ "$have_patch" = "1" ]; then
    apply_err=$(mktemp)
    if ! git -C "$rec_wt" apply --3way "$PATCH" 2>"$apply_err"; then
      cat "$apply_err" >&2 2>/dev/null || true
      rm -f "$apply_err"
      conflicts=$(git -C "$rec_wt" diff --name-only --diff-filter=U 2>/dev/null || true)
      echo "CONFLICT: applying the salvaged patch onto $rec_branch (off $source_branch) hit conflicts." >&2
      if [ -n "$conflicts" ]; then
        echo "Conflicted files (worktree-relative):" >&2
        printf '%s\n' "$conflicts" >&2
      fi
      echo "Resolve in '$rec_wt', then re-run /finish recovery (it resumes from there)." >&2
      exit 2
    fi
    rm -f "$apply_err"
  fi
fi

# rec_abs is set in every non-committed branch above; set it for the committed branch too.
[ -n "${rec_abs:-}" ] || rec_abs=$(cd "$rec_wt" && pwd)

# --- 3. Commit the recovered work (skipped when already committed by a prior run). ---
if [ "$rec_state" != "committed" ]; then
  # Carry untracked NEW files from the corrupted original into the recovered worktree.
  # NUL-delimited (`-z` + `read -d ''`) so names with spaces, non-ASCII, tabs, or quotes
  # survive — `git ls-files -z` emits raw bytes (no core.quotepath C-quoting). Runs for
  # fresh/empty AND the `pending` resume (so an exit-2-then-resolve re-run doesn't drop
  # them), and AFTER any patch apply so a patched path can't be clobbered. `committed`
  # resumes skip this (their files were carried + committed by the original run).
  if [ -d "$wt_dir" ]; then
    carried=0
    while IFS= read -r -d '' uf; do
      [ -z "$uf" ] && continue
      [ -e "$wt_dir/$uf" ] || continue
      mkdir -p "$rec_abs/$(dirname "$uf")" 2>/dev/null || true
      if cp -p "$wt_dir/$uf" "$rec_abs/$uf" 2>/dev/null; then
        carried=$((carried + 1))
      else
        echo "WARN: could not carry untracked file '$uf'; salvage it manually from $wt_dir." >&2
      fi
    done < <(git -C "$wt_dir" ls-files --others --exclude-standard -z 2>/dev/null)
    [ "$carried" -gt 0 ] && echo "Carried $carried untracked new file(s) from the corrupted worktree into the recovery." >&2
  fi

  # pnpm check gate (Working Application Contract) — only for node projects.
  if [ -f "$rec_abs/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
    if [ ! -d "$rec_abs/node_modules" ]; then
      echo "Installing dependencies in recovered worktree (pnpm, warm path)..." >&2
      pnpm -C "$rec_abs" install --prefer-offline --frozen-lockfile >&2 \
        || echo "WARN: pnpm install reported issues; continuing to the check gate." >&2
    fi
    echo "Running pnpm check in recovered worktree..." >&2
    if ! ( cd "$rec_abs" && pnpm check ) >&2; then
      echo "ERROR: pnpm check FAILED in the recovered worktree. Not committing or merging." >&2
      echo "  Fix in '$rec_wt', then re-run /finish recovery." >&2
      exit 4
    fi
  else
    echo "NOTE: no pnpm project detected in recovered worktree; skipping the pnpm check gate." >&2
  fi

  # Stage exactly the applied/resolved/carried changes (never `git add -A`). `git apply
  # --3way` stages what it applies, a hand-resolved conflict may be staged or not, and the
  # carried untracked files are unstaged — so enumerate the union of staged + unstaged
  # tracked + new untracked (exclude-standard drops gitignored node_modules/tmp). NUL-
  # delimited so special filenames (which `git add -- "$f"` would otherwise choke on as
  # C-quoted strings) stage correctly. Duplicate paths across the three sets are harmless
  # (re-`add` is idempotent), so no dedup is needed.
  while IFS= read -r -d '' f; do
    [ -n "$f" ] && git -C "$rec_wt" add -- "$f"
  done < <({ git -C "$rec_wt" diff --cached --name-only -z
             git -C "$rec_wt" diff --name-only -z
             git -C "$rec_wt" ls-files --others --exclude-standard -z; })

  if git -C "$rec_wt" diff --cached --quiet; then
    echo "ERROR: nothing staged after applying the patch — recovery cannot produce a commit." >&2
    exit 1
  fi
  git -C "$rec_wt" commit -F "$message_file" >&2
fi

# --- 4. Re-stamp identity on the recovered worktree (baseline = the new fork). ---
# (wt-identity.sh already sourced near the top.)
rec_issue_id=$(printf '%s' "${issue_lower}-recovered" | tr '[:lower:]' '[:upper:]')
wt_identity_stamp "$rec_wt" "$rec_abs" "$rec_issue_id" "$rec_branch" "$source_branch" "$src_tip" || true

# --- 5. Hand to finish-merge.sh (skip its identity check — this worktree is fresh). ---
# Merge message lives in the recovered worktree's tmp/ (like /finish Step 9) so the
# merge-queue drainer can still find it if the merge is deferred, and it's removed
# with the worktree on success. (tmp/ is gitignored in real projects, so it does not
# block `git worktree remove`.)
mkdir -p "$rec_abs/tmp"
merge_msg_file="$rec_abs/tmp/git-merge-msg-${issue_lower}-recovered.md"
printf 'Merge %s\n' "$issue_upper" > "$merge_msg_file"

echo "Merging recovered work into $source_branch ..." >&2
set +e
_WT_SKIP_IDENTITY_CHECK=1 "$SCRIPT_DIR/finish-merge.sh" \
  "$rec_wt" "$source_branch" "$rec_branch" "$merge_msg_file" >&2
merge_rc=$?
set -e

# --- 6. Cleanup, keyed on the merge outcome. ---
# On BOTH success (0) and deferral (3) the recovered work is safely captured on
# $rec_branch (landed, or committed + queued), so the corrupted ORIGINAL worktree is
# no longer needed — retire it now to actually clear the corruption. On 1/2/4 the
# recovery is incomplete; leave everything intact for a re-run.
if [ "$merge_rc" = "0" ] || [ "$merge_rc" = "3" ]; then
  wt_identity_cleanup "$wt_dir" "$issue_lower" || true   # uses $wt_dir to resolve main root — do before removal
  wt_force_remove "$PWD" "$wt_dir" || true               # loud WARN + STRAY fallback handled inside
  [ -n "${PATCH:-}" ] && rm -f "$PATCH" 2>/dev/null || true   # work is committed on $rec_branch now
fi

if [ "$merge_rc" = "0" ]; then
  # Merge landed: finish-merge removed $rec_wt + $rec_branch (and its tmp/ merge msg).
  # Clear the recovered worktree's own identity sidecars.
  rec_lower="${issue_lower}-recovered"
  [ -n "${CLAUDE_JOB_DIR:-}" ] && rm -f "$CLAUDE_JOB_DIR/wt-identity-${rec_lower}.env" 2>/dev/null || true
  rm -f "$repo_root/.claude/worktree-identity/wt-identity-${rec_lower}.env" 2>/dev/null || true
  echo "RECOVERED: $issue_upper — salvaged via '$diff_strategy', re-forked off $source_branch, merged." >&2
  exit 0
fi

if [ "$merge_rc" = "3" ]; then
  # Deferred: the drainer re-invokes finish-merge.sh on $rec_wt and lands it later;
  # leave the recovered worktree + branch + tmp/ merge msg in place for it.
  echo "DEFERRED: $issue_upper — recovered work committed on $rec_branch and queued for merge; corrupted original retired. Check /merge-queue." >&2
  exit 3
fi

echo "finish-merge.sh exited $merge_rc; recovered worktree intact at $rec_wt and corrupted original at $wt_dir preserved for re-run." >&2
exit "$merge_rc"
