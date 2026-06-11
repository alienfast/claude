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
#   5. Creates, attaches, or reuses a worktree at .claude/worktrees/<id-lower>.
#      Detects branch-already-checked-out-elsewhere and refuses with a clear
#      error (avoiding the silent `git worktree add` failure mode).
#   6. Records the source branch in per-worktree git config so /finish can
#      locate it (`git config --worktree start.source-branch`).
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

if [ $# -ne 1 ]; then
  echo "Usage: $0 <issue-id>" >&2
  exit 1
fi

for cmd in git gh linear jq; do
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

# Enable per-worktree config (idempotent).
git config extensions.worktreeConfig true

# Fetch issue title and compose branch name.
issue_title=$(linear i get "$issue_id" --output json | jq -r '.title // ""')
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

if [ -d "$wt_dir" ]; then
  # Reuse. Verify it's a worktree on the expected branch.
  current_wt_branch=$(git -C "$wt_dir" branch --show-current 2>/dev/null || true)
  if [ "$current_wt_branch" != "$branch" ]; then
    echo "ERROR: $wt_dir exists but is on '$current_wt_branch' (expected '$branch'). Investigate manually." >&2
    exit 1
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
    echo "  Consider: git -C \"$wt_dir\" rebase $source_branch" >&2
  fi
  echo "Resuming worktree: $wt_dir" >&2
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
else
  # Fresh: create both worktree dir and branch off current HEAD.
  git worktree add "$wt_dir" -b "$branch" HEAD >&2
  CREATED_WT=1
fi

# If we just created the worktree (vs reused), arm a cleanup trap. Any failure
# between here and the final stdout emission removes the half-prepared worktree
# so the user can re-run cleanly. Trap is cleared at the end on success.
if [ "${CREATED_WT:-0}" = "1" ]; then
  trap '
    echo "ERROR: setup failed mid-flow; removing partially-prepared worktree $wt_dir" >&2
    git worktree remove --force "$wt_dir" 2>/dev/null || rm -rf "$wt_dir"
    # Prune orphaned .git/worktrees/<id>/ admin dir left behind by rm-rf path.
    git worktree prune 2>/dev/null || true
  ' EXIT
fi

# Record source branch in per-worktree config.
git -C "$wt_dir" config --worktree start.source-branch "$source_branch"

# Compute absolute paths.
wt_abs=$(cd "$wt_dir" && pwd)

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
    # Preserve relative path inside the worktree.
    dst="$wt_abs/$entry"
    mkdir -p "$(dirname "$dst")"
    cp -R "$entry" "$dst"
    echo "Copied $entry → $dst" >&2
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

# Setup succeeded; clear the cleanup trap so the worktree persists.
trap - EXIT

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
# key=value contract on stdout. Placed after `trap - EXIT` so a failed install can never trigger the worktree-removal trap.
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
