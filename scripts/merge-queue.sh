#!/bin/bash
# merge-queue.sh — local deferred-merge queue for `/finish` worktree merges.
#
# When finish-merge.sh cannot advance the source branch right now but could later
# (a transient block — see its exit code 3), it self-enqueues a marker here; a
# local scheduler (launchd → drain-merge-queue.sh) drains the queue until each
# merge lands. The merge target, the unpushed worktree branches, and the blocking
# WIP are all local-only, so this is deliberately pure shell + git + jq with no
# network and no LLM in the happy path.
#
# Markers live at <repo-root>/.claude/merge-queue/<issue-lower>.json (co-located
# with .claude/worktrees/, gitignored the same way). The set of repos to scan is a
# self-registering newline list at ~/.claude/merge-queue-repos.txt.
#
# Subcommands:
#   add <issue> <wt_dir> <source_branch> <worktree_branch> <message_file> <repo_root> <reason>
#       Upsert a marker (preserves attempts / enqueued time / notified state across
#       re-enqueues; clears the conflict/hard-fail flags since a transient enqueue
#       supersedes them). Registers <repo_root>. Called by finish-merge.sh on exit 3.
#   remove <issue> <repo_root>
#       Delete a marker. Called by finish-merge.sh on exit 0 (self-dequeue) so
#       whichever path completes the merge — drainer or a live /finish — cleans up.
#   drain [repo_root]
#       Re-run finish-merge.sh for every marker (one repo, or all registered repos).
#       Serialized per repo via with-repo-lock.py on the queue dir so two drainers
#       never corrupt markers. Maps finish-merge.sh's exit to the marker:
#         0 → marker already removed by finish-merge (DRAINED)
#         3 → marker already refreshed by finish-merge; bump attempts (STILL-BLOCKED)
#         2 → flag needs_resolution + notify         (NEEDS-RESOLUTION)
#         1 → flag hard_failed + notify              (HARD-FAIL)
#   list [repo_root]
#       Human-readable table of pending markers (one repo, or all registered).
#
# Notifications are local macOS desktop notifications (osascript), fired only on a
# state transition into a needs-human condition — never for routine retries.

set -eo pipefail

SELF="$HOME/.claude/scripts/merge-queue.sh"
FINISH_MERGE="$HOME/.claude/scripts/finish-merge.sh"
LOCK_HELPER="$HOME/.claude/scripts/with-repo-lock.py"
QUEUE_SUBDIR=".claude/merge-queue"
REGISTRY="$HOME/.claude/merge-queue-repos.txt"
STUCK_THRESHOLD=20

err() { echo "merge-queue.sh: $*" >&2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

require_jq() {
  command -v jq >/dev/null 2>&1 || { err "jq is required but not found on PATH"; exit 1; }
}

queue_dir_for() { printf '%s/%s' "$1" "$QUEUE_SUBDIR"; }

# Local desktop notification (best-effort; never fails the caller).
notify() {
  local title="$1" msg="$2"
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
}

# Atomically rewrite a marker by applying a jq filter to its current contents.
update_marker() {
  local marker="$1" filter="$2" tmp
  tmp=$(mktemp "$(dirname "$marker")/.upd.XXXXXX")
  if jq "$filter" "$marker" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$marker"
  else
    rm -f "$tmp"
    # Non-fatal: one marker's bookkeeping failure must not abort the whole drain
    # pass under set -e and starve sibling markers. The marker keeps its prior
    # contents; the next pass retries.
    echo "WARN: could not update marker $marker (left unchanged)" >&2
  fi
}

register_repo() {
  local repo_root="$1"
  mkdir -p "$(dirname "$REGISTRY")"
  touch "$REGISTRY"
  grep -qxF "$repo_root" "$REGISTRY" 2>/dev/null || printf '%s\n' "$repo_root" >> "$REGISTRY"
}

cmd_add() {
  require_jq
  [ $# -eq 7 ] || { err "usage: add <issue> <wt_dir> <source_branch> <worktree_branch> <message_file> <repo_root> <reason>"; exit 1; }
  local issue_in="$1" wt_dir="$2" source_branch="$3" worktree_branch="$4" message_file="$5" repo_root="$6" reason="$7"
  local slug display qdir marker tmp
  local prev_attempts prev_enq_iso prev_enq_epoch prev_notified
  slug=$(printf '%s' "$issue_in" | tr '[:upper:]' '[:lower:]')
  display=$(printf '%s' "$issue_in" | tr '[:lower:]' '[:upper:]')
  qdir=$(queue_dir_for "$repo_root")
  mkdir -p "$qdir"
  marker="$qdir/$slug.json"

  prev_attempts=0
  prev_enq_iso=$(now_iso)
  prev_enq_epoch=$(now_epoch)
  prev_notified="none"
  # Read prior fields defensively: a corrupt/partial marker (disk-full mid-write,
  # manual edit, crash) makes jq exit non-zero and the field empty. Each read
  # falls back to a default, so a re-enqueue *overwrites* the corrupt marker with
  # a valid one (self-healing) rather than propagating the empty value into the
  # `jq -n` below — where an empty `--argjson attempts` would abort the whole add
  # under set -e and silently drop the enqueue (finish-merge swallows it via `|| true`).
  if [ -f "$marker" ]; then
    prev_attempts=$(jq -r '.attempts // 0' "$marker" 2>/dev/null || true)
    prev_enq_iso=$(jq -r '.enqueued_at // empty' "$marker" 2>/dev/null || true)
    prev_enq_epoch=$(jq -r '.enqueued_epoch // empty' "$marker" 2>/dev/null || true)
    prev_notified=$(jq -r '.notified_state // "none"' "$marker" 2>/dev/null || true)
    # Every persisted value reaching a `--argjson` below MUST pass a numeric guard,
    # not just an emptiness check: a present-but-non-numeric field (e.g. "abc") slips
    # past `// empty` and `[ -n ]`, then aborts `jq -n` and silently drops the enqueue.
    { [ -n "$prev_attempts" ] && [ "$prev_attempts" -ge 0 ]; } 2>/dev/null || prev_attempts=0
    { [ -n "$prev_enq_epoch" ] && [ "$prev_enq_epoch" -ge 0 ]; } 2>/dev/null || prev_enq_epoch=$(now_epoch)
    [ -n "$prev_enq_iso" ] || prev_enq_iso=$(now_iso)
    [ -n "$prev_notified" ] || prev_notified="none"
  fi

  tmp=$(mktemp "$qdir/.$slug.json.XXXXXX")
  jq -n \
    --arg issue "$display" \
    --arg wt_dir "$wt_dir" \
    --arg source_branch "$source_branch" \
    --arg worktree_branch "$worktree_branch" \
    --arg message_file "$message_file" \
    --arg repo_root "$repo_root" \
    --arg enqueued_at "$prev_enq_iso" \
    --argjson enqueued_epoch "$prev_enq_epoch" \
    --arg last_attempt_at "$(now_iso)" \
    --argjson last_attempt_epoch "$(now_epoch)" \
    --argjson attempts "$prev_attempts" \
    --arg last_reason "$reason" \
    --arg notified_state "$prev_notified" \
    '{issue:$issue, wt_dir:$wt_dir, source_branch:$source_branch, worktree_branch:$worktree_branch,
      message_file:$message_file, repo_root:$repo_root, enqueued_at:$enqueued_at,
      enqueued_epoch:$enqueued_epoch, last_attempt_at:$last_attempt_at,
      last_attempt_epoch:$last_attempt_epoch, attempts:$attempts, last_reason:$last_reason,
      needs_resolution:false, hard_failed:false, notified_state:$notified_state}' \
    > "$tmp"
  mv -f "$tmp" "$marker"
  register_repo "$repo_root"
  echo "QUEUED: $display — $reason"
}

cmd_remove() {
  [ $# -eq 2 ] || { err "usage: remove <issue> <repo_root>"; exit 1; }
  local slug qdir
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  qdir=$(queue_dir_for "$2")
  rm -f "$qdir/$slug.json"
}

# Process one marker: re-run finish-merge.sh and reconcile the marker with the result.
# Assumes the per-repo queue lock is already held (see cmd_drain).
process_marker() {
  require_jq
  local marker="$1"
  [ -f "$marker" ] || return 0
  local issue wt_dir source_branch worktree_branch message_file repo_root prev_state rc attempts
  issue=$(jq -r '.issue // empty' "$marker" 2>/dev/null || true)
  wt_dir=$(jq -r '.wt_dir // empty' "$marker" 2>/dev/null || true)
  source_branch=$(jq -r '.source_branch // empty' "$marker" 2>/dev/null || true)
  worktree_branch=$(jq -r '.worktree_branch // empty' "$marker" 2>/dev/null || true)
  message_file=$(jq -r '.message_file // empty' "$marker" 2>/dev/null || true)
  repo_root=$(jq -r '.repo_root // empty' "$marker" 2>/dev/null || true)
  prev_state=$(jq -r '.notified_state // "none"' "$marker" 2>/dev/null || true)

  # Quarantine a corrupt/partial marker rather than running finish-merge.sh with
  # empty args (which would `cd ""` → exit 1 → falsely flag a HARD-FAIL).
  if [ -z "$issue" ] || [ -z "$wt_dir" ] || [ -z "$source_branch" ] || [ -z "$worktree_branch" ] || [ -z "$message_file" ] || [ -z "$repo_root" ]; then
    echo "SKIP: malformed merge-queue marker (missing fields): $marker" >&2
    return 0
  fi

  set +e
  ( cd "$repo_root" && "$FINISH_MERGE" "$wt_dir" "$source_branch" "$worktree_branch" "$message_file" )
  rc=$?
  set -e

  case "$rc" in
    0)
      # Merge landed. The merge OWNS the Ready-For-Release transition (Linear must
      # never show Ready For Release for code that isn't merged), so mark it now —
      # best-effort: the merge already succeeded; a Linear hiccup must not undo it.
      rm -f "$marker"   # finish-merge.sh self-dequeued on success; belt-and-suspenders
      if "$HOME/.claude/scripts/mark-ready-for-release.sh" "$issue" >/dev/null 2>&1; then
        echo "DRAINED: $issue (marked Ready For Release)"
      else
        echo "DRAINED: $issue — WARNING: merged, but could not mark Ready For Release; set it manually" >&2
        notify "Merge landed: $issue" "Merged, but the Linear state update failed — mark $issue Ready For Release manually."
      fi
      ;;
    3)
      # finish-merge.sh self-enqueued (refreshed reason/timestamps, preserved attempts). Bump attempts.
      # tonumber? // 0 coerces a string-typed or missing .attempts to a number so the
      # increment can't throw (a thrown filter would freeze the counter and defeat the
      # stuck-threshold notification) — closing the non-numeric bug class at the write site too.
      update_marker "$marker" ".attempts = (((.attempts // 0) | tonumber? // 0) + 1) | .last_attempt_at = \"$(now_iso)\" | .last_attempt_epoch = $(now_epoch)"
      attempts=$(jq -r '.attempts // 0' "$marker" 2>/dev/null || echo 0)
      { [ "$attempts" -ge 0 ]; } 2>/dev/null || attempts=0   # non-numeric → 0 (keeps the -ge test below quiet)
      echo "STILL-BLOCKED: $issue (attempt $attempts) — $(jq -r '.last_reason // "(unknown)"' "$marker" 2>/dev/null || echo '(unknown)')"
      if [ "$attempts" -ge "$STUCK_THRESHOLD" ] && [ "$prev_state" != "stuck" ]; then
        update_marker "$marker" '.notified_state = "stuck"'
        notify "Merge stuck: $issue" "Deferred merge has retried $attempts times. Run /merge-queue."
      fi
      ;;
    2)
      update_marker "$marker" ".needs_resolution = true | .last_attempt_at = \"$(now_iso)\" | .last_attempt_epoch = $(now_epoch) | .last_reason = \"merge conflict — needs manual resolution in the worktree\""
      echo "NEEDS-RESOLUTION: $issue"
      if [ "$prev_state" != "needs_resolution" ]; then
        update_marker "$marker" '.notified_state = "needs_resolution"'
        notify "Merge conflict: $issue" "Resolve in the worktree, then run /merge-queue $issue."
      fi
      ;;
    *)
      update_marker "$marker" ".hard_failed = true | .last_attempt_at = \"$(now_iso)\" | .last_attempt_epoch = $(now_epoch) | .last_reason = \"hard failure (exit $rc) — see merge-queue drain log\""
      echo "HARD-FAIL: $issue (exit $rc)"
      if [ "$prev_state" != "hard_failed" ]; then
        update_marker "$marker" '.notified_state = "hard_failed"'
        notify "Merge failed: $issue" "Deferred merge hit a hard error (exit $rc). Run /merge-queue $issue."
      fi
      ;;
  esac
}

# Internal: drain a repo's queue (all markers, or just $2 when given a single
# issue slug). The caller wraps this in the queue lock.
cmd_drain_one() {
  local repo_root="$1" only_slug="${2:-}" qdir marker had_any=0
  qdir=$(queue_dir_for "$repo_root")
  [ -d "$qdir" ] || return 0
  if [ -n "$only_slug" ]; then
    marker="$qdir/$only_slug.json"
    if [ -f "$marker" ]; then process_marker "$marker"; else echo "merge-queue: $repo_root — no marker for $only_slug"; fi
    return 0
  fi
  # Snapshot the marker list first — process_marker removes/refreshes files in place.
  shopt -s nullglob
  local markers=("$qdir"/*.json)
  shopt -u nullglob
  for marker in "${markers[@]}"; do
    had_any=1
    process_marker "$marker"
  done
  [ "$had_any" = 1 ] || echo "merge-queue: $repo_root — queue empty"
}

# Run a locked drain of one repo (optionally scoped to a single issue slug).
drain_repo_locked() {
  local repo_root="$1" only_slug="${2:-}" qdir
  qdir=$(queue_dir_for "$repo_root")
  mkdir -p "$qdir"   # with-repo-lock.py requires the key path to exist
  # Serialize drainers per repo (crash-safe flock via the lock helper). Keyed on
  # the queue dir, which is distinct from finish-merge.sh's common-git-dir key —
  # so re-running finish-merge.sh under this lock never deadlocks against itself.
  "$LOCK_HELPER" "$qdir" "$SELF" __drain_one "$repo_root" "$only_slug"
}

# drain [<repo_root> | <ISSUE-ID>]
#   - no arg          → every registered repo (the launchd path)
#   - a directory     → that repo's whole queue
#   - an ISSUE-ID     → just that issue (repo resolved from the registry by marker)
cmd_drain() {
  local target="${1:-}"
  # Check the ISSUE-ID pattern FIRST, independent of any same-named directory in
  # cwd: a repo path is always absolute and never matches, so an incidental dir
  # like ./PL-99 can't shadow a `drain PL-99` into a silent no-op.
  if [ -n "$target" ] && printf '%s' "$target" | grep -qiE '^[a-z]+-[0-9]+$'; then
    local slug found_repo="" repo
    slug=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
    if [ -f "$REGISTRY" ]; then
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        if [ -f "$(queue_dir_for "$repo")/$slug.json" ]; then found_repo="$repo"; break; fi
      done < "$REGISTRY"
    fi
    [ -n "$found_repo" ] || { echo "merge-queue: no queued marker for $target in any registered repo"; return 0; }
    drain_repo_locked "$found_repo" "$slug"
    return 0
  fi

  local repos=()
  if [ -n "$target" ]; then
    repos=("$target")
  elif [ -f "$REGISTRY" ]; then
    while IFS= read -r line; do [ -n "$line" ] && repos+=("$line"); done < "$REGISTRY"
  fi
  [ "${#repos[@]}" -gt 0 ] || { echo "merge-queue: no repos registered ($REGISTRY)"; return 0; }

  local repo_root
  for repo_root in "${repos[@]}"; do
    [ -d "$repo_root" ] || { err "registered repo missing, skipping: $repo_root"; continue; }
    drain_repo_locked "$repo_root"
  done
}

cmd_list() {
  require_jq
  local repos=()
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    repos=("$1")
  elif [ -f "$REGISTRY" ]; then
    while IFS= read -r line; do [ -n "$line" ] && repos+=("$line"); done < "$REGISTRY"
  fi
  [ "${#repos[@]}" -gt 0 ] || { echo "merge-queue: no repos registered ($REGISTRY)"; return 0; }

  local repo_root qdir marker found=0 now flags age_min
  now=$(now_epoch)
  printf '%-10s %-26s %8s %5s  %s\n' "ISSUE" "REPO" "AGE(min)" "TRIES" "STATUS / REASON"
  for repo_root in "${repos[@]}"; do
    qdir=$(queue_dir_for "$repo_root")
    [ -d "$qdir" ] || continue
    shopt -s nullglob
    for marker in "$qdir"/*.json; do
      found=1
      local issue attempts enq_epoch reason nr hf
      # Read defensively (2>/dev/null || true): a single corrupt marker must not
      # crash the listing — the diagnostic command must still surface the rest.
      issue=$(jq -r '.issue // empty' "$marker" 2>/dev/null || true)
      if [ -z "$issue" ]; then
        printf '%-10s %-26s %8s %5s  %s\n' "(corrupt)" "$(basename "$repo_root")" "?" "?" "unreadable marker: $(basename "$marker")"
        continue
      fi
      attempts=$(jq -r '.attempts // 0' "$marker" 2>/dev/null || echo 0)
      enq_epoch=$(jq -r '.enqueued_epoch // 0' "$marker" 2>/dev/null || echo 0)
      reason=$(jq -r '.last_reason // ""' "$marker" 2>/dev/null || true)
      nr=$(jq -r '.needs_resolution // false' "$marker" 2>/dev/null || echo false)
      hf=$(jq -r '.hard_failed // false' "$marker" 2>/dev/null || echo false)
      # Numeric guards: `// 0` only covers a missing/null field — a present-but-
      # non-numeric value (e.g. "12abc" from a partial write) survives jq and would
      # abort the `$(( ))` arithmetic below under set -e, crashing the whole listing.
      { [ "$enq_epoch" -ge 0 ]; } 2>/dev/null || enq_epoch=0
      { [ "$attempts" -ge 0 ]; } 2>/dev/null || attempts=0
      flags="queued"
      [ "$nr" = "true" ] && flags="NEEDS-RESOLUTION"
      [ "$hf" = "true" ] && flags="HARD-FAIL"
      age_min=$(( (now - enq_epoch) / 60 ))
      printf '%-10s %-26s %8s %5s  %s — %s\n' "$issue" "$(basename "$repo_root")" "$age_min" "$attempts" "$flags" "$reason"
    done
    shopt -u nullglob
  done
  [ "$found" = 1 ] || echo "(queue empty)"
}

sub="${1:-}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  add)         cmd_add "$@" ;;
  remove)      cmd_remove "$@" ;;
  drain)       cmd_drain "$@" ;;
  __drain_one) cmd_drain_one "$@" ;;   # internal: invoked under the queue lock by cmd_drain
  list|"")     cmd_list "$@" ;;
  *)           err "unknown subcommand: $sub (expected add|remove|drain|list)"; exit 1 ;;
esac
