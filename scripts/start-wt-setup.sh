#!/bin/bash
# start-wt-setup.sh — Set up a /start worktree for a Linear issue.
#
# Usage: start-wt-setup.sh <issue-id>
#
# Performs the procedural setup that was previously embedded in /start
# Step 0's skill markdown:
#   1. Validates issue ID format (case-insensitive; normalized to upper).
#   2. Captures the current branch as the source branch.
#   3. Enables extensions.worktreeConfig (idempotent).
#   4. Fetches the issue title; composes a kebab-case branch name following
#      the convention <gh-username>/<id-lower>-<short-kebab-title>.
#   5. Creates, attaches, or reuses a worktree at .claude/worktrees/<id-lower>,
#      and stamps a tamper-evident identity on it (branch, baseline SHA, source
#      branch, owner session) to BOTH per-worktree git config and an immune
#      sidecar outside .git. Steps 5–6 run inside start-wt-create.sh UNDER a repo
#      lock (with-repo-lock.py, same key /finish merge uses) so concurrent /start
#      runs can't race the worktree-existence-check → `git worktree add` TOCTOU
#      that let parallel sessions clobber each other's worktree branch/HEAD/config.
#      Detects branch-already-checked-out-elsewhere and refuses with a clear error.
#   6. Records the source branch in per-worktree git config so /finish can locate
#      it (`git config --worktree start.source-branch`), plus the identity above.
#   7. Pre-fetches the issue digest via linear-context.sh and saves it into
#      the worktree's tmp/ — so the in-worktree subagent's Step 1 can read
#      it directly instead of round-tripping back to Linear.
#   8. Emits plain key=value lines on stdout for human/model consumption:
#        WT_ABS=<absolute worktree path>
#        BRANCH=<branch name>
#        SOURCE_BRANCH=<source branch>
#        ISSUE_ID=<uppercased issue id>
#        DIGEST_FILE=<absolute path to cached digest, or empty if pre-fetch failed>
#
#      The caller (skill markdown) reads these from the tool output and
#      substitutes them into the next step's Agent prompt. The values are
#      NOT shell-escaped — do not pipe to `eval`. They are safe to substitute
#      into double-quoted bash strings (no characters that require escaping
#      appear in branch names, paths, or issue IDs in practice).
#
# Read-write: creates worktree, writes git config, writes the digest file.
# Errors go to stderr; non-zero exit on any failure.

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <issue-id>" >&2
  exit 1
fi

for cmd in git gh linear-cli jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# Resolve script's own dir so we can locate sibling scripts.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Normalize issue ID: strip whitespace, uppercase, validate.
input=$(printf '%s' "$1" | tr -d '[:space:]')
issue_id=$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')
if ! [[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: issue ID '$issue_id' does not match ^[A-Z]+-[0-9]+\$" >&2
  exit 1
fi
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

# Verify we're inside a git working tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git working tree" >&2
  exit 1
fi

source_branch=$(git branch --show-current)
if [ -z "$source_branch" ]; then
  echo "ERROR: HEAD is detached; cannot determine source branch" >&2
  exit 1
fi

# Advisory (never blocks): if the main checkout is parked on the branch this
# worktree will fork from / merge back into, AND other worktrees already exist
# (i.e. parallel /full wt activity), every concurrent /finish merge will take
# finish-merge.sh's working-tree-touching `git merge --ff-only` path instead of
# the contention-free ref-only update — the exact setup behind the parallel-run
# corruption. We only warn; auto-detaching the main checkout would mutate the
# user's working tree, which multi-session safety forbids.
existing_wts=$(find .claude/worktrees -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "${existing_wts:-0}" -gt 0 ]; then
  echo "WARN: main checkout is on '$source_branch' (the shared source branch) while $existing_wts worktree(s) are active." >&2
  echo "  For parallel /full wt runs, park the main checkout off the source branch (e.g. 'git checkout --detach')" >&2
  echo "  so every merge takes finish-merge.sh's ref-only fast path and can't contend on the main working tree." >&2
fi

# Enable per-worktree config (idempotent).
git config extensions.worktreeConfig true

# Fetch issue title and compose branch name.
issue_title=$(linear-cli issues get "$issue_id" -o json | jq -r '.title // ""')
if [ -z "$issue_title" ]; then
  echo "ERROR: could not fetch title for $issue_id" >&2
  exit 1
fi

gh_user=$(gh api user --jq .login)
if [ -z "$gh_user" ]; then
  echo "ERROR: could not determine GitHub username (gh api user)" >&2
  exit 1
fi

# Kebab-case the title: lowercase, replace non-alphanum runs with `-`, trim
# leading/trailing dashes, cap at 40 chars, then trim any trailing dash the
# cap may have introduced.
kebab=$(printf '%s' "$issue_title" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-40 | sed -E 's/-+$//')

# If kebab is empty (e.g., title was all punctuation/emoji), omit the
# trailing dash so we get user/pl-13 instead of user/pl-13-.
branch="${gh_user}/${issue_lower}${kebab:+-$kebab}"

wt_dir=".claude/worktrees/${issue_lower}"
mkdir -p .claude/worktrees

# --- Locked critical section: create/reuse the worktree and stamp its identity. ---
# Resolve the repo lock key exactly as finish-merge.sh does (absolute git common
# dir), so /start wt and /finish merge mutually exclude on the same parent repo.
# Only this git-mutating span is locked; the slow digest fetch + pnpm install below
# stay lock-free so parallel starts still overlap on them. with-repo-lock.py
# execvp's its command (which is WHY start-wt-create.sh is a separate script), and
# prints `[finish-queue] waiting for <repo> ...` on stderr if another holder has
# the slot — surface that to the user and wait; it is not a hang.
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
  echo "ERROR: not inside a git repository (cwd: $PWD)" >&2
  exit 1
}
case "$common_dir" in
  /*) repo_key="$common_dir" ;;
  *)  repo_key=$(cd "$common_dir" 2>/dev/null && pwd -P) ;;
esac
if [ -z "$repo_key" ]; then
  echo "ERROR: could not resolve repo lock key (git-common-dir='$common_dir')" >&2
  exit 1
fi

# Capture stdout (the KEY=value contract). The helper's stderr — progress, drift
# NOTEs, lock-wait lines — flows straight through to the user. A non-zero helper
# exit propagates here via `set -e` (the create failed and the helper self-cleaned).
create_out=$("$SCRIPT_DIR/with-repo-lock.py" "$repo_key" \
  bash "$SCRIPT_DIR/start-wt-create.sh" \
  "$issue_id" "$issue_lower" "$branch" "$source_branch" "$wt_dir")

# Parse the helper's KEY=value output. Values contain no newlines and (per branch /
# path conventions) no characters needing escaping.
_wt_get() { printf '%s\n' "$create_out" | sed -n "s/^$1=//p" | head -1; }
wt_abs=$(_wt_get WT_ABS)
CREATED_WT=$(_wt_get CREATED_WT)
baseline_sha=$(_wt_get BASELINE_SHA)
owner_session=$(_wt_get OWNER_SESSION)
identity_sidecar=$(_wt_get IDENTITY_SIDECAR)

if [ -z "$wt_abs" ]; then
  echo "ERROR: worktree-create helper returned no WT_ABS; setup aborted." >&2
  exit 1
fi

# Copy files listed in .worktreeinclude from the main checkout into the new
# worktree. `git worktree add` only copies *tracked* files; anything gitignored
# (typically .env.local and other dev secrets) is left behind. The user
# maintains .worktreeinclude (one path per line, # comments allowed) to mark
# which untracked files should be carried into every worktree.
#
# Skip on reuse — the existing worktree may have user-edited values that we
# shouldn't clobber. Only runs when we just created (CREATED_WT=1).
if [ "${CREATED_WT:-0}" = "1" ] && [ -f ".worktreeinclude" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading/trailing whitespace; skip blanks and # comments.
    entry=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$entry" in
      ''|\#*) continue ;;
    esac
    if [ ! -e "$entry" ]; then
      echo "WARN: .worktreeinclude entry '$entry' not found in main checkout; skipping" >&2
      continue
    fi
    # Preserve relative path inside the worktree. Best-effort: the worktree is
    # already fully created and identity-stamped by the locked helper, so an
    # optional include-file copy failing must NOT abort setup (there is no longer
    # a parent cleanup trap to tear the worktree down).
    dst="$wt_abs/$entry"
    if mkdir -p "$(dirname "$dst")" && cp -R "$entry" "$dst"; then
      echo "Copied $entry → $dst" >&2
    else
      echo "WARN: failed to copy .worktreeinclude entry '$entry' → $dst; continuing." >&2
    fi
  done < ".worktreeinclude"
fi

# Pre-fetch the digest into the worktree's tmp/ for the subagent's Step 1.
mkdir -p "$wt_abs/tmp"
digest_file="$wt_abs/tmp/linear-context-${issue_lower}.md"
if "$SCRIPT_DIR/linear-context.sh" "$issue_id" > "$digest_file" && [ -s "$digest_file" ]; then
  :
else
  # Digest failure (non-zero exit) or empty output — non-fatal; in-worktree
  # session falls back to a live linear-context.sh fetch.
  echo "WARN: linear-context.sh failed or produced empty output; digest not pre-fetched. Subagent will fetch on demand." >&2
  rm -f "$digest_file"
  digest_file=""
fi

# (No cleanup trap to clear here — the locked start-wt-create.sh owns and clears
# its own create-failure trap. Everything from here on is best-effort and must
# never tear down the already-created, identity-stamped worktree.)

# Register this repo with the worktree reaper (reap-worktrees.sh) so its periodic launchd pass knows
# to scan here. The reaper reclaims worktrees the normal lifecycle leaves behind: a `/finish pr` whose
# PR merges later on GitHub, or an issue Canceled/Done directly in Linear with no live /start session.
# Idempotent append; best-effort so a registry hiccup never fails worktree setup.
reaper_registry="$HOME/.claude/worktree-repos.txt"
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$repo_root" ]; then
  touch "$reaper_registry" 2>/dev/null || true
  grep -qxF "$repo_root" "$reaper_registry" 2>/dev/null || printf '%s\n' "$repo_root" >> "$reaper_registry" 2>/dev/null || true
fi

# Warm-install dependencies so the worktree is immediately usable. `git worktree add` copies only tracked files, and node_modules is gitignored, so a fresh
# worktree has none. The package *contents* are already in the global store (shared, content-addressed, APFS-cloned), so this is a linking-bound warm install —
# no re-download. Runs only when node_modules is absent (covers fresh creation and resumed worktrees whose modules were never installed). Package-manager-aware
# via lockfile detection, and non-fatal: a failure leaves a valid worktree the user can install into manually. Output goes to stderr so it never pollutes the
# key=value contract on stdout. Lock-free by design — the warm install must not hold the repo lock (it is the slow step parallel starts overlap on).
if [ ! -d "$wt_abs/node_modules" ]; then
  if [ -f "$wt_abs/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
    echo "Installing dependencies (pnpm, warm path)…" >&2
    if ! pnpm -C "$wt_abs" install --prefer-offline --frozen-lockfile >&2; then
      echo "WARN: pnpm install failed; worktree is valid but deps are not installed. Run 'pnpm install' in $wt_abs." >&2
    fi
  elif [ -f "$wt_abs/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
    echo "Installing dependencies (npm ci)…" >&2
    if ! npm --prefix "$wt_abs" ci >&2; then
      echo "WARN: npm ci failed; run 'npm ci' in $wt_abs." >&2
    fi
  fi
fi

# Emit plain key=value lines for the caller (skill markdown) to read from
# the tool output and substitute into the next step's Agent prompt. Values
# are NOT eval'd — they should be visible to the orchestrator.
printf 'WT_ABS=%s\n' "$wt_abs"
printf 'BRANCH=%s\n' "$branch"
printf 'SOURCE_BRANCH=%s\n' "$source_branch"
printf 'ISSUE_ID=%s\n' "$issue_id"
printf 'DIGEST_FILE=%s\n' "$digest_file"
# Identity stamped by start-wt-create.sh (observability; /finish reads the sidecar, not these).
printf 'BASELINE_SHA=%s\n' "$baseline_sha"
printf 'OWNER_SESSION=%s\n' "$owner_session"
printf 'IDENTITY_SIDECAR=%s\n' "$identity_sidecar"
