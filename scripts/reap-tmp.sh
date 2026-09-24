#!/bin/bash
# reap-tmp.sh — reclaim aged scratch under a project's tmp/ without touching the files other skills
# still read.
#
# Every skill writes to <project>/tmp/ (CLAUDE.md § Guidelines), and most of what lands there is dead the
# moment its session ends: check logs, Linear staging bodies, fix-delta snapshots, test output. A small
# set of named files is the opposite — read later by a different skill, often from a different session
# (the /quality-review → /finish verdict, the fleet ledgers /fleet-retro measures, the triage scan → apply
# proposals), or never safe to lose at all (the fleet-metrics trend history). Age is the wrong test for
# those and the only right test for the rest, so this script classifies every top-level entry by NAME
# first and applies a per-lane rule:
#
#   never     kept whatever its age: keep/ (the user's hatch), fleet-metrics-history.jsonl, the retro inputs,
#             fleet-deadline.json, fleet-recommendation.json, auto-state-<runKey>.json (expiry is
#             /fleet-launch's, against the agents registry), triage-proposals/ (the next scan's skip check
#             reads applied/), and any registered git worktree parked under tmp/ (/reap-worktrees owns it).
#   state     deleted only when the owner's own state says consumed, and never inside SCRATCH_D days:
#               quality-review-verdict-<issue>.md — every local branch of that issue is merged into the
#                 default branch (or none exists), and the file was not written during a fleet window that
#                 /fleet-retro has not yet measured (fleet_sessions ∩ a history row's session_set is empty).
#               fleet-sequence*.json (+ its .log/.pid) — not `running` under a live runner pid, and its
#                 integration branch is gone (resume needs the branch).
#   handoff   scan-time inputs the interactive triage apply reads later; aged out at HANDOFF_D days.
#   cache     reused on presence alone with no freshness check (linear-context-*.md, triage-digest-*.md) or
#             poll markers a leftover copy would trip (*.done, wait-*.sh): aged out at CACHE_D days, because
#             a stale copy is worse than an absent one — every writer re-fetches when the file is missing.
#   scratch   everything else at the top level, plus the known scratch DIRECTORIES (qr-fix-base-*, qr-probe-*,
#             screenshots, ...): aged out at SCRATCH_D days. A directory's age is its newest file.
#   unknown   a directory not in the manifest. NEVER deleted — reported once it is UNKNOWN_D days old so
#             the operator adds a rule or removes it by hand. A top-level file is scratch by construction
#             (CLAUDE.md), so a name this manifest does not know still ages out; a directory is structure
#             someone built, so it does not.
#
# Guards that outrank every lane:
#   • FRESH: nothing modified within FRESH_H hours is touched — another session may be mid-write. While a
#     fleet is running (tmp/fleet-deadline.json not stopped, deadline in the future or launched within
#     FLEET_MAX_H hours) the guard widens to everything written since the launch.
#   • OPEN: a file some process holds open (lsof) is kept; a detached job's log is being written however
#     old its mtime looks. Without lsof the guard stands down for the pass, with one WARN.
#   • SYMLINK: never followed, never removed.
#   • The tmp/ directory itself is never removed, and `rm -rf` is issued only for a directory a scratch-dir
#     rule named — the only place a recursive delete can originate.
#
# The manifest below is the safety boundary for unattended runs (reap-tmp-cron.sh, daily under launchd),
# so reap-tmp.test.sh sweeps the corpus for every `tmp/<name>` a skill or script writes and fails when one
# resolves to the default rule rather than a named one: a new handoff file must be classified on purpose.
#
# Subcommands:
#   list [<root>]      Dry run: print the verdict for every top-level entry of <root>/tmp, mutate nothing.
#   reap [<root>]      Delete eligible entries, serialized per repo under the same common-git-dir lock
#                      /finish merge and reap-worktrees take. Prints what it removed, what needs attention,
#                      and one summary line per root.
#   classify <name> [d]  Test seam: print "<lane> <rule>" for a top-level tmp/ name (d = directory).
#   __reap_one <root>  Internal: the per-root body, invoked by `reap` under the lock.
#
# No <root> → every registered repo (~/.claude/worktree-repos.txt ∪ ~/.claude/merge-queue-repos.txt),
# plus ~/.claude and the git repo the cwd is inside, if any.

set -uo pipefail

SELF="$HOME/.claude/scripts/reap-tmp.sh"
LOCK_HELPER="$HOME/.claude/scripts/with-repo-lock.py"
WT_REGISTRY="$HOME/.claude/worktree-repos.txt"
MQ_REGISTRY="$HOME/.claude/merge-queue-repos.txt"

FRESH_H="${REAP_TMP_FRESH_H:-24}"
CACHE_D="${REAP_TMP_CACHE_D:-1}"
SCRATCH_D="${REAP_TMP_SCRATCH_D:-7}"
HANDOFF_D="${REAP_TMP_HANDOFF_D:-30}"
UNKNOWN_D="${REAP_TMP_UNKNOWN_D:-30}"
FLEET_MAX_H="${REAP_TMP_FLEET_MAX_H:-48}"

err() { echo "reap-tmp.sh: $*" >&2; }

# A non-numeric or absurd override would either disable a guard (arithmetic on '' is 0) or abort the run
# mid-pass under set -u; fall back to the default and say so.
check_num() { # <name> <value> <default> → echoes the value to use
  case "$2" in
    ''|*[!0-9]*) err "$1='$2' is not a non-negative integer; using $3"; echo "$3" ;;
    *) [ "${#2}" -le 7 ] && echo "$2" || { err "$1='$2' is out of range; using $3"; echo "$3"; } ;;
  esac
}
FRESH_H=$(check_num REAP_TMP_FRESH_H "$FRESH_H" 24)
CACHE_D=$(check_num REAP_TMP_CACHE_D "$CACHE_D" 1)
SCRATCH_D=$(check_num REAP_TMP_SCRATCH_D "$SCRATCH_D" 7)
HANDOFF_D=$(check_num REAP_TMP_HANDOFF_D "$HANDOFF_D" 30)
UNKNOWN_D=$(check_num REAP_TMP_UNKNOWN_D "$UNKNOWN_D" 30)
FLEET_MAX_H=$(check_num REAP_TMP_FLEET_MAX_H "$FLEET_MAX_H" 48)

# GNU-first is the safe order: BSD `stat -c` fails with no stdout, while GNU `stat -f %m` prints a
# filesystem block to stdout despite exiting 1 (see finish-read-verdict.sh for the measurement).
mtime_of() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0; }

# Newest mtime under a directory (files and the directory itself), so a directory still being written
# reads as fresh even when it was created long ago.
newest_in() {
  local d="$1" out
  out=$( { find "$d" -exec stat -c %Y -- {} + 2>/dev/null || find "$d" -exec stat -f %m -- {} + 2>/dev/null; } | sort -n | tail -1)
  case "$out" in ''|*[!0-9]*) mtime_of "$d" ;; *) echo "$out" ;; esac
}

file_count() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
size_kb() { du -sk -- "$1" 2>/dev/null | cut -f1; }
fmt_date() { # epoch → YYYY-MM-DD
  date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null || echo "epoch $1"
}
have_jq() { command -v jq >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------------------------------
# The manifest. First match wins; the argument is a top-level tmp/ entry name (one path component), except
# triage-proposals/raw, which the walker classifies separately. Prints "<lane> <rule>".
# ---------------------------------------------------------------------------------------------------------
classify() {
  local rel="$1" kind="${2:-f}"
  case "$rel" in
    keep)                              echo "never keep-hatch"; return ;;
    fleet-metrics-history.jsonl)       echo "never metrics-history"; return ;;
    fleet-linear-window.json|fleet-shipped-issues.json)
                                       echo "never retro-inputs"; return ;;
    fleet-deadline.json)               echo "never fleet-marker"; return ;;
    fleet-recommendation.json)         echo "never fleet-recommendation"; return ;;
    auto-state-*.json)                 echo "never auto-ledger"; return ;;
    auto-state.json)                   echo "scratch legacy-auto-state"; return ;;
    triage-proposals)                  echo "never triage-proposals"; return ;;
    triage-proposals/raw)              echo "scratch-dir triage-raw"; return ;;
    fleet-sequence-pr-update-*)        echo "scratch-dir orphan-pr-worktree"; return ;;
    fleet-sequence*.json)              echo "state sequence-marker"; return ;;
    fleet-sequence*.log|fleet-sequence*.pid)
                                       echo "state sequence-sidecar"; return ;;
    quality-review-verdict-no-issue.md) echo "scratch verdict-no-issue"; return ;;
    quality-review-verdict-*.md)       echo "state verdict"; return ;;
    triage-cheap.ndjson|triage-pool.ndjson|triage-head.sha|triage-commit-*.txt|triage-ls-files.txt)
                                       echo "handoff triage-scan-inputs"; return ;;
    linear-context-*.md|triage-digest-*.md)
                                       echo "cache presence-cache"; return ;;
    *.done|wait-*.sh)                  echo "cache poll-marker"; return ;;
    fleet-quota-launch.json)           echo "scratch retired"; return ;;
  esac
  if [ "$kind" = d ]; then
    case "$rel" in
      qr-fix-base-*|qr-probe-*|screenshots|triage-markers|triage-apply-bodies|pool-pages-*|epic-merge|proposal-*)
                                       echo "scratch-dir scratch-dir"; return ;;
      *)                               echo "unknown unknown-dir"; return ;;
    esac
  fi
  case "$rel" in
    linear-*.md|spec-*.md|*-comment-*.md|prd-description.md|sub-issue-description.md|sentry-*.md|epic-boundary.md|simple-escalation-*.md|triage-*.md|pr-body-*.md|integration-pr-body.md|exec-summary-*|description.md|finish-commit-*.md|git-merge-msg-*.md|verdict-body-*.md|.qr-verdict-*|linear-img.png)
                                       echo "scratch staging-body" ;;
    qr-fix-delta-*.diff|qr-simple-delta-*.diff|qr-expected-hashes.txt|quality-review-nth-*.md|deferred-*|reflect-improvement-*|wt.diff)
                                       echo "scratch review-working" ;;
    pool.json|pool.pages|pool-collisions.json|epic-graph.json|forecast-*.txt|perf.json|rank-perf.sh|testDebug_*|start-wt-verify-*.err|fleet-launch-scope.err|triage-scan-certified.out|sync-main-*.log|*.log|*.err|*.out|*.sql)
                                       echo "scratch run-output" ;;
    *)                                 echo "scratch default-file" ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------
# Per-root evaluation
# ---------------------------------------------------------------------------------------------------------
default_branch_for() {
  local repo="$1" b
  b=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); b="${b#origin/}"
  [ -n "$b" ] && { echo "$b"; return; }
  for b in main master; do git -C "$repo" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }; done
  echo main
}

# Globals the walker fills once per root.
NOW=0; FRESH_CUTOFF=0; FLEET_RUNNING=0; FLEET_LAUNCH=0; FLEET_RETROD=1; IS_GIT=0; DEFAULT_BRANCH=main
OPEN_PATHS=""; WT_PATHS=""; BRANCHES=""; REAL_TMP=""
LSOF_WARNED=0

load_root_state() {
  local root="$1" tmp="$2" f stopped dl sessions hist_sessions s h
  NOW=$(date +%s)
  REAL_TMP=$(cd "$tmp" 2>/dev/null && pwd -P); [ -n "$REAL_TMP" ] || REAL_TMP="$tmp"
  FRESH_CUTOFF=$((NOW - FRESH_H * 3600))
  FLEET_RUNNING=0; FLEET_LAUNCH=0; FLEET_RETROD=1
  f="$tmp/fleet-deadline.json"
  if [ -f "$f" ] && have_jq; then
    stopped=$(jq -r '.stopped // false' "$f" 2>/dev/null)
    dl=$(jq -r '.deadline_epoch // empty' "$f" 2>/dev/null)
    FLEET_LAUNCH=$(jq -r '.launch_epoch // empty' "$f" 2>/dev/null)
    case "$FLEET_LAUNCH" in ''|*[!0-9]*) FLEET_LAUNCH=$(mtime_of "$f") ;; esac
    if [ "$stopped" != true ]; then
      if [ -n "$dl" ] && [ "$dl" -gt "$NOW" ] 2>/dev/null; then FLEET_RUNNING=1
      elif [ -z "$dl" ] && [ "$FLEET_LAUNCH" -gt $((NOW - FLEET_MAX_H * 3600)) ]; then FLEET_RUNNING=1
      fi
    fi
    [ "$FLEET_RUNNING" = 1 ] && [ "$FLEET_LAUNCH" -lt "$FRESH_CUTOFF" ] && FRESH_CUTOFF=$FLEET_LAUNCH
    # Retro'd iff some history row's session_set shares a session with the marker's fleet_sessions.
    # Ids may be recorded as prefixes on either side, so match by prefix in both directions.
    FLEET_RETROD=0
    sessions=$(jq -r '.fleet_sessions[]? // empty' "$f" 2>/dev/null)
    if [ -z "$sessions" ]; then FLEET_RETROD=1   # nothing to scope by: no window to protect
    elif [ -f "$tmp/fleet-metrics-history.jsonl" ]; then
      hist_sessions=$(jq -r '.session_set[]? // empty' "$tmp/fleet-metrics-history.jsonl" 2>/dev/null)
      for s in $sessions; do
        for h in $hist_sessions; do
          case "$s" in "$h"*) FLEET_RETROD=1 ;; esac
          case "$h" in "$s"*) FLEET_RETROD=1 ;; esac
        done
      done
    fi
  elif [ -f "$f" ]; then
    FLEET_RUNNING=1; FLEET_LAUNCH=$(mtime_of "$f"); FLEET_RETROD=0   # no jq: fail closed
    [ "$FLEET_LAUNCH" -lt "$FRESH_CUTOFF" ] && FRESH_CUTOFF=$FLEET_LAUNCH
  fi

  OPEN_PATHS=""
  if command -v lsof >/dev/null 2>&1; then
    OPEN_PATHS=$(lsof -Fn +D "$tmp" 2>/dev/null | sed -n 's/^n//p' | sort -u)
  elif [ "$LSOF_WARNED" = 0 ]; then
    echo "  WARN: lsof not found — the open-handle guard stands down for this pass"; LSOF_WARNED=1
  fi

  IS_GIT=0; WT_PATHS=""; BRANCHES=""
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    IS_GIT=1
    WT_PATHS=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    DEFAULT_BRANCH=$(default_branch_for "$root")
    BRANCHES=$(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
  fi
}

is_open() { # <abs> → 0 iff the path, or anything under it, is held open
  local p="$1" o
  [ -n "$OPEN_PATHS" ] || return 1
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    case "$o" in "$p"|"$p"/*) return 0 ;; esac
  done <<< "$OPEN_PATHS"
  return 1
}

is_worktree() { # <abs> → 0 iff a registered worktree is at or under the path
  local p="$1" w
  [ -n "$WT_PATHS" ] || return 1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$w" in "$p"|"$p"/*) return 0 ;; esac
  done <<< "$WT_PATHS"
  return 1
}

branch_merged() { # <branch> → 0 iff merged into the default branch, locally or on origin
  local root="$1" b="$2"
  git -C "$root" merge-base --is-ancestor "$b" "$DEFAULT_BRANCH" 2>/dev/null && return 0
  git -C "$root" merge-base --is-ancestor "$b" "origin/$DEFAULT_BRANCH" 2>/dev/null && return 0
  return 1
}

# Verdict for quality-review-verdict-<issue>.md. Prints "KEEP <reason>" or "OK <reason>" (OK = the state
# says consumed; the caller still applies the age floor).
verdict_state() {
  local root="$1" rel="$2" mtime="$3" issue b found=0 unmerged=""
  issue="${rel#quality-review-verdict-}"; issue="${issue%.md}"
  [ "$IS_GIT" = 1 ] || { echo "KEEP not a git repo — cannot tell whether $issue is consumed"; return; }
  if [ "$FLEET_LAUNCH" -gt 0 ] && [ "$mtime" -ge "$FLEET_LAUNCH" ] && [ "$FLEET_RETROD" = 0 ]; then
    echo "KEEP written during the fleet launched $(fmt_date "$FLEET_LAUNCH"), not yet measured by /fleet-retro"; return
  fi
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$b" in "$issue"|"$issue"-*|*/"$issue"|*/"$issue"-*) ;; *) continue ;; esac
    found=1
    branch_merged "$root" "$b" || unmerged="$b"
  done <<< "$BRANCHES"
  if [ -n "$unmerged" ]; then echo "KEEP branch $unmerged not merged into $DEFAULT_BRANCH"
  elif [ "$found" = 1 ]; then echo "OK every $issue branch is merged into $DEFAULT_BRANCH"
  else echo "OK no local branch for $issue"; fi
}

# Verdict for fleet-sequence*.json. Same contract as verdict_state.
sequence_state() {
  local root="$1" abs="$2" status pid branch
  have_jq || { echo "KEEP jq unavailable — cannot read the marker"; return; }
  status=$(jq -r '.status // empty' "$abs" 2>/dev/null)
  pid=$(jq -r '.runner_pid // empty' "$abs" 2>/dev/null)
  branch=$(jq -r '.branch // empty' "$abs" 2>/dev/null)
  if [ "$status" = running ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "KEEP sequence running (pid $pid)"; return
  fi
  if [ -n "$branch" ] && [ "$IS_GIT" = 1 ] && git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "KEEP resumable — branch $branch still exists"; return
  fi
  echo "OK ${status:-unknown}, branch ${branch:-?} gone"
}

# One entry → prints "<STATUS>\t<rel>\t<reason>" where STATUS ∈ ELIGIBLE|KEEP|UNKNOWN|FLAG (FLAG lines are
# additional, printed before the entry's own line).
evaluate_entry() {
  local root="$1" tmp="$2" rel="$3" kind=f lane rule mtime age_d st reason limit
  local abs="$tmp/$rel"
  # git and lsof both print resolved paths (/private/var/… for a /var/… root on macOS), so match on both.
  local abs_real="$REAL_TMP/$rel"

  if [ -L "$abs" ]; then printf 'KEEP\t%s\t%s\n' "$rel" "symlink — never followed"; return; fi
  [ -d "$abs" ] && kind=d
  read -r lane rule <<< "$(classify "$rel" "$kind")"

  if is_worktree "$abs" || is_worktree "$abs_real"; then printf 'KEEP\t%s\t%s\n' "$rel" "registered git worktree — /reap-worktrees owns it"; return; fi

  if [ "$kind" = d ]; then mtime=$(newest_in "$abs"); else mtime=$(mtime_of "$abs"); fi
  age_d=$(( (NOW - mtime) / 86400 ))

  case "$lane" in
    never)
      case "$rule" in
        fleet-recommendation)
          if have_jq && [ "$(jq -r '.scope // empty' "$abs" 2>/dev/null)" != "" ] && [ "$mtime" -lt $((NOW - 86400)) ]; then
            printf 'FLAG\t%s\t%s\n' "$rel" "carries scope $(jq -r .scope "$abs") and is ${age_d}d old — a bare /fleet-launch would relaunch that epic; re-run /auto-prep or /epic-prep to refresh"
          fi ;;
        fleet-marker)
          if [ "$FLEET_RUNNING" = 0 ] && have_jq && [ "$(jq -r '.stopped // false' "$abs" 2>/dev/null)" != true ] \
             && [ -z "$(jq -r '.deadline_epoch // empty' "$abs" 2>/dev/null)" ]; then
            printf 'FLAG\t%s\t%s\n' "$rel" "no deadline, never stopped, launched $(fmt_date "$FLEET_LAUNCH") — a stale marker holds the git-permissions gate up; rm it or re-run /fleet-launch"
          fi ;;
      esac
      printf 'KEEP\t%s\t%s\n' "$rel" "$rule"; return ;;
    unknown)
      printf 'UNKNOWN\t%s\t%s\n' "$rel" "directory not in the manifest ($(file_count "$abs") files, newest $(fmt_date "$mtime")) — never deleted here; add a rule to reap-tmp.sh or remove it by hand"; return ;;
  esac

  # Guards shared by every deletable lane.
  if [ "$mtime" -gt "$FRESH_CUTOFF" ]; then
    if [ "$FLEET_RUNNING" = 1 ] && [ "$mtime" -ge "$FLEET_LAUNCH" ]; then reason="written since the running fleet launched"
    else reason="modified within ${FRESH_H}h"; fi
    printf 'KEEP\t%s\t%s\n' "$rel" "$reason"; return
  fi
  if is_open "$abs" || is_open "$abs_real"; then printf 'KEEP\t%s\t%s\n' "$rel" "held open by a process"; return; fi

  case "$lane" in
    state)
      case "$rule" in
        verdict) st=$(verdict_state "$root" "$rel" "$mtime") ;;
        sequence-marker) st=$(sequence_state "$root" "$abs") ;;
        sequence-sidecar)
          if [ -f "$tmp/${rel%.*}.json" ]; then st=$(sequence_state "$root" "$tmp/${rel%.*}.json")
          else st="OK no marker beside it"; fi ;;
      esac
      case "$st" in
        KEEP\ *) printf 'KEEP\t%s\t%s\n' "$rel" "${st#KEEP }"; return ;;
      esac
      limit=$SCRATCH_D; reason="${st#OK }" ;;
    handoff)    limit=$HANDOFF_D; reason="$rule" ;;
    cache)      limit=$CACHE_D;   reason="$rule" ;;
    scratch|scratch-dir) limit=$SCRATCH_D; reason="$rule" ;;
    *)          printf 'KEEP\t%s\t%s\n' "$rel" "unclassified lane $lane"; return ;;
  esac
  if [ "$mtime" -gt $((NOW - limit * 86400)) ]; then
    printf 'KEEP\t%s\t%s\n' "$rel" "$reason — ${age_d}d old, kept ${limit}d"
  else
    printf 'ELIGIBLE\t%s\t%s\n' "$rel" "$reason — ${age_d}d old (> ${limit}d)"
  fi
}

# Walk one root. mode=list prints every verdict; mode=reap deletes ELIGIBLE entries and prints only what
# changed or needs attention, then a summary line.
walk_root() {
  # One assignment per `local` where a value depends on an earlier one: `local a=$1 b=$a/x` expands every
  # word BEFORE any assignment, so `$a` there is the caller's (bash 3.2 reports it as unbound).
  local root="$1" mode="$2" rel abs status reason kind
  local tmp="$root/tmp"
  local n_reaped=0 n_kept=0 n_unknown=0 n_flag=0 kb_reaped=0 kb entries=()
  [ -d "$tmp" ] || { echo "$root: (no tmp/)"; return 0; }
  echo "$root/tmp:"
  load_root_state "$root" "$tmp"

  while IFS= read -r rel; do [ -n "$rel" ] && entries+=("$rel"); done < <(
    find "$tmp" -mindepth 1 -maxdepth 1 \( -type f -o -type d -o -type l \) 2>/dev/null | sed "s|^$tmp/||" | sort
    [ -d "$tmp/triage-proposals/raw" ] && echo "triage-proposals/raw"
  )
  [ "${#entries[@]}" -gt 0 ] || { echo "  (empty)"; return 0; }

  for rel in "${entries[@]}"; do
    abs="$tmp/$rel"
    while IFS=$'\t' read -r status _ reason; do
      [ -n "$status" ] || continue
      case "$status" in
        FLAG)     n_flag=$((n_flag+1)); echo "  FLAG      $rel — $reason" ;;
        UNKNOWN)
          n_unknown=$((n_unknown+1))
          if [ "$mode" = list ] || [ "$(newest_in "$abs")" -le $((NOW - UNKNOWN_D * 86400)) ]; then
            echo "  UNKNOWN   $rel/ — $reason"
          fi ;;
        KEEP)     n_kept=$((n_kept+1)); [ "$mode" = list ] && echo "  KEEP      $rel — $reason" ;;
        ELIGIBLE)
          if [ "$mode" = list ]; then
            echo "  ELIGIBLE  $rel — $reason"
          else
            kb=$(size_kb "$abs"); case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
            # Belt and braces around the only recursive delete in the script: the target must sit
            # directly under this tmp/, and a directory is removed only when a scratch-dir rule named it.
            case "$rel" in ''|.|..|*/..|../*|*/../*|/*) echo "  SKIP      $rel — refusing to delete an unsafe path"; continue ;; esac
            if [ -d "$abs" ] && [ ! -L "$abs" ]; then
              read -r kind _ <<< "$(classify "$rel" d)"
              [ "$kind" = scratch-dir ] || { echo "  SKIP      $rel/ — directory outside a scratch-dir rule"; continue; }
              rm -rf -- "$abs"
            else
              rm -f -- "$abs"
            fi
            if [ -e "$abs" ]; then echo "  FAILED    $rel — still present after rm"
            else n_reaped=$((n_reaped+1)); kb_reaped=$((kb_reaped+kb)); echo "  REAPED    $rel — $reason (${kb}K)"; fi
          fi ;;
      esac
    done < <(evaluate_entry "$root" "$tmp" "$rel")
  done

  if [ "$mode" = list ]; then
    echo "  summary: $(printf '%s\n' "${entries[@]}" | wc -l | tr -d ' ') entries, $n_kept kept, $n_unknown unknown, $n_flag flagged"
  else
    echo "  summary: reaped $n_reaped (${kb_reaped}K), kept $n_kept, unknown $n_unknown, flagged $n_flag"
  fi
}

# ---------------------------------------------------------------------------------------------------------
# Roots and dispatch
# ---------------------------------------------------------------------------------------------------------
resolve_roots() {
  local arg="${1:-}" cwd_root
  if [ -n "$arg" ]; then printf '%s\n' "${arg%/}"; return 0; fi
  cwd_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  { [ -f "$WT_REGISTRY" ] && cat "$WT_REGISTRY"; [ -f "$MQ_REGISTRY" ] && cat "$MQ_REGISTRY"
    echo "$HOME/.claude"; [ -n "$cwd_root" ] && echo "$cwd_root"; } 2>/dev/null | awk 'NF && !seen[$0]++'
}

repo_key_for() {
  local key
  key=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  { [ -n "$key" ] && [ "$key" != "/" ]; } || return 1
  printf '%s\n' "$key"
}

cmd_reap() {
  local roots=() root key
  while IFS= read -r root; do [ -n "$root" ] && roots+=("$root"); done < <(resolve_roots "${1:-}")
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { err "root missing, skipping: $root"; continue; }
    if [ -x "$LOCK_HELPER" ] && key=$(repo_key_for "$root"); then
      # Serialize on the SAME key finish-merge.sh and reap-worktrees.sh lock, so a sweep never runs
      # while a merge is landing in this repo. The helper re-execs SELF under the lock.
      "$LOCK_HELPER" "$key" "$SELF" __reap_one "$root"
    else
      walk_root "$root" reap
    fi
  done
}

cmd_list() {
  local roots=() root
  while IFS= read -r root; do [ -n "$root" ] && roots+=("$root"); done < <(resolve_roots "${1:-}")
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { echo "$root — MISSING (stale registry entry)"; continue; }
    walk_root "$root" list
  done
}

sub="${1:-}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  reap)        cmd_reap "$@" ;;
  __reap_one)  walk_root "$1" reap ;;
  list|"")     cmd_list "$@" ;;
  classify)    classify "$1" "${2:-f}" ;;
  *)           err "unknown subcommand: $sub (expected reap|list|classify)"; exit 1 ;;
esac
