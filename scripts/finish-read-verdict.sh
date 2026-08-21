#!/bin/bash
# finish-read-verdict.sh — Locate the most-recent /quality-review verdict
# artifact for an issue and report sub-issues filed under it.
#
# Usage: finish-read-verdict.sh <ISSUE-ID>
#
# Looks for the verdict file in this order (first hit wins):
#   1. <current-worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   2. <main-checkout>/tmp/quality-review-verdict-<issue-lower>.md
#      (the main checkout when the current cwd is a linked worktree)
#
# Emits KEY=value lines on stdout:
#   VERDICT_FILE=<absolute path, or empty if file absent>
#   VERDICT_PUBLISHED_ACROSS=<0|1>
#     1 → the verdict existed only in the worktree; this run copied it to the main
#         checkout's tmp/ so it survives worktree removal (backstop for a publish
#         that reached one copy — BF-815; WARN on stderr names both paths)
#   VERDICT=passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect|malformed|none-found
#     - none-found  → no verdict file located at either probe path (file absent)
#     - malformed   → file exists but lacks a parseable `Verdict:` line, or the
#                     line contains the pipe-separated schema example, or the
#                     value is not one of the four recognized enums. /finish
#                     Step 8 must NOT proceed on this value — the user clearly
#                     ran /quality-review but something went wrong with the
#                     handoff; gate-bypass would defeat the safety check.
#   CYCLES=<integer, or empty if no verdict file was located>
#   SUB_ISSUES=<comma-separated PL-XX list of parent's current children, or empty>
#     (NOTE: these are all current children of the parent — not necessarily
#     filed by THIS /quality-review run. /finish must label accordingly.)
#   SUB_ISSUES_ERROR=<warning text if `linear-cli issues get` failed, else empty>
#   VERDICT_STALE=<0|1>
#     1 → verdict file's mtime predates HEAD's commit time. The user landed
#         additional commits AFTER /quality-review ran, so the verdict no
#         longer reflects the current code. /finish Step 8 escalates passing-
#         but-stale to refuse-with-override (same shape as malformed).
#   VERDICT_STALE_REASON=<diagnostic text when VERDICT_STALE=1, else empty>
#
# Exit codes:
#   0 = success (even when VERDICT=none-found, VERDICT=malformed, or
#       SUB_ISSUES_ERROR is populated — these are non-fatal warnings)
#   2 = missing ISSUE-ID argument or not in a git repo

set -eo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

if [ $# -ne 1 ]; then
  echo "ERROR: usage: $(basename "$0") <ISSUE-ID>" >&2
  exit 2
fi

issue_id="$1"
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$worktree_root" ]; then
  echo "ERROR: not in a git repository" >&2
  exit 2
fi

common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
main_checkout=""
if [ -n "$common_dir" ]; then
  main_checkout=$(dirname "$common_dir")
fi

verdict_file=""
for candidate in \
  "$worktree_root/tmp/quality-review-verdict-${issue_lower}.md" \
  "${main_checkout:+$main_checkout/tmp/quality-review-verdict-${issue_lower}.md}"
do
  if [ -n "$candidate" ] && [ -r "$candidate" ]; then
    verdict_file="$candidate"
    break
  fi
done

# Backstop: a verdict that exists ONLY in the worktree dies with the worktree (/finish merge, PR
# mode, and reap-worktrees-cron.sh all remove it) — BF-815 shipped with the review run and the
# verdict lost exactly this way. quality-review-write-verdict.sh writes both copies and the
# scratch-path-guard hook denies file-tool writes of this basename, so this fires only when a
# publish reached one copy anyway; it runs only when /finish runs, which is why it is the backstop
# and not the fix.
published_across=0
main_twin="${main_checkout:+$main_checkout/tmp/quality-review-verdict-${issue_lower}.md}"
if [ -n "$verdict_file" ] && [ -n "$main_twin" ] && [ "$main_checkout" != "$worktree_root" ] \
   && [ "$verdict_file" != "$main_twin" ] && [ ! -e "$main_twin" ]; then
  if mkdir -p "$main_checkout/tmp" 2>/dev/null \
     && cross_tmp=$(mktemp "$main_checkout/tmp/.qr-verdict-XXXXXX" 2>/dev/null) \
     && cp "$verdict_file" "$cross_tmp" 2>/dev/null \
     && chmod 644 "$cross_tmp" 2>/dev/null \
     && mv "$cross_tmp" "$main_twin" 2>/dev/null; then
    published_across=1
    echo "WARN: verdict existed only in the worktree — published across to $main_twin (the write-verdict stdin form writes both copies; see quality-review/SKILL.md)" >&2
  else
    echo "WARN: verdict exists only in the worktree and could not be copied to $main_twin — it will be lost when the worktree is removed" >&2
  fi
fi

verdict="none-found"
cycles=""
if [ -n "$verdict_file" ]; then
  # Default: malformed unless we positively extract a single recognized enum.
  verdict="malformed"
  vline=$(grep -m1 -E '^Verdict:' "$verdict_file" || true)
  if [ -n "$vline" ]; then
    # Reject the schema-example shape ("Verdict: passed-clean | passed-after-fixes | ...")
    # — a literal `|` after the colon means the LLM wrote the schema verbatim
    # instead of substituting a resolved value. Treat as malformed so the gate
    # refuses, rather than silently taking the first token (passed-clean).
    if printf '%s' "$vline" | grep -q '|'; then
      verdict="malformed"
    else
      raw=$(printf '%s' "$vline" | awk -F'Verdict:' '{print $2}' | awk '{print $1}')
      case "$raw" in
        passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect)
          verdict="$raw"
          ;;
        *)
          verdict="malformed"
          ;;
      esac
    fi
  fi
  # Cycles line example: "Cycles: 3" or "Cycles: 3 (initial + 2 re-reviews)"
  cline=$(grep -m1 -E '^Cycles:' "$verdict_file" || true)
  if [ -n "$cline" ]; then
    cycles=$(printf '%s' "$cline" | awk -F'Cycles:' '{print $2}' | awk '{print $1}')
  fi
fi

# Query sub-issues via linear-cli `issues get -o json`, whose `.children` is a
# {nodes:[...]} connection. Tolerate the case where the issue doesn't exist, the CLI
# isn't authenticated, or the issue has no children — none of those should abort
# /finish (auth prompt fires in Step 2; missing-issue is surfaced elsewhere). Emit
# empty SUB_ISSUES and a warning instead.
sub_issues=""
sub_issues_error=""
if json=$(linear-cli issues get "$issue_id" -o json 2>/dev/null); then
  sub_issues=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ch = d.get("children") or []
if isinstance(ch, dict):          # linear-cli returns {nodes:[...]}; tolerate a bare list too
    ch = ch.get("nodes") or []
ids = [c.get("identifier") for c in ch if isinstance(c, dict) and c.get("identifier")]
print(",".join(ids))
' 2>/dev/null || true)
else
  sub_issues_error="linear-cli issues get $issue_id failed (linear-cli installed? auth? missing issue?) — SUB_ISSUES unavailable"
  echo "WARN: $sub_issues_error" >&2
fi

# Staleness check: if the verdict file's mtime predates HEAD's commit time,
# the user landed commits AFTER /quality-review ran — the verdict no longer
# reflects current code. /finish Step 8 escalates passing-but-stale to a
# refuse-with-override path (same shape as malformed), preventing the gate
# from sailing through on a verdict produced before the latest changes.
stale=0
stale_reason=""
# fmt_epoch <epoch> → ISO-8601 local time; falls back to raw epoch if the matched dialect's
# `date` call fails (vanishingly rare). Both call sites below invoke fmt_epoch inside $(...)
# command substitutions, so the dialect is probed ONCE here at top level (into
# _fmt_epoch_dialect) before either call — a lazy-init inside the function would run in a
# subshell and never persist, re-probing on every call. We only ever invoke the matched
# dialect's flag — never fall through to the other's — because on FreeBSD/macOS, GNU's `-d`
# is BSD date's "set the kernel's DST state" flag: run as root it succeeds via settimeofday
# (mutating kernel tz_dsttime) and prints the current time instead of failing, so cross-dialect
# fallthrough would silently capture the wrong timestamp.
if date --version >/dev/null 2>&1; then
  _fmt_epoch_dialect=gnu
else
  _fmt_epoch_dialect=bsd
fi
fmt_epoch() {
  if [ "$_fmt_epoch_dialect" = gnu ]; then
    date -d "@$1" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || printf 'epoch %s' "$1"
  else
    date -r "$1" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || printf 'epoch %s' "$1"
  fi
}
if [ -n "$verdict_file" ]; then
  # mtime in epoch seconds. GNU-first is asymmetrically safe: BSD `stat -c`
  # rejects -c as an illegal option with no stdout output, so `||` cleanly
  # falls through. The reverse order is NOT safe — GNU `stat -f` "accepts" -f
  # as a flag (filesystem status, not BSD's format string) and treats %m as a
  # filename; it fails (exit 1) but still prints a multiline filesystem block
  # to stdout for the real file, which command substitution captures despite
  # the nonzero exit, corrupting vmtime even though `||` looks like a no-op.
  vmtime=$(stat -c %Y "$verdict_file" 2>/dev/null || stat -f %m "$verdict_file" 2>/dev/null || echo 0)
  case "$vmtime" in ''|*[!0-9]*) vmtime=0 ;; esac
  head_ctime=$(git log -1 --format=%ct HEAD 2>/dev/null || echo 0)
  # vmtime (filesystem clock) and head_ctime (committer clock) are different clock domains; a 2min
  # tolerance absorbs routine skew without weakening the gate against real staleness, which involves
  # a human doing additional work after review — minutes to hours, not seconds.
  skew_tolerance=120
  if [ "$vmtime" -gt 0 ] && [ "$head_ctime" -gt 0 ] && [ "$vmtime" -lt "$((head_ctime - skew_tolerance))" ]; then
    # A post-verdict window whose every changed path is under .claude/ is the workflow's own config
    # commit — /reflect's mandated Step 5 commit lands after /quality-review persists the verdict and
    # touches only <project>/.claude/ rule/config text, which the review never looked at. That is not
    # staleness, and treating it as such strands a passing unattended run (BF-803; /quality-review
    # Step 7's mtime-refresh bullet is the primary mitigation — this is the backstop for a missed
    # refresh). The carve-out is deliberately .claude/-only, NOT docs-or-markdown-wide: on a doc
    # deliverable the markdown IS the reviewed surface, so any broader rule would wave through real
    # staleness. Any path outside .claude/ — or an empty file list, which proves nothing — keeps the
    # gate armed.
    window_paths=$(git log --since="@$vmtime" --name-only --format='' HEAD 2>/dev/null | sed '/^$/d' | sort -u || true)
    if [ -n "$window_paths" ] && ! printf '%s\n' "$window_paths" | grep -qv '^\.claude/'; then
      echo "NOTE: commits since the verdict touch only .claude/ ($(printf '%s\n' "$window_paths" | paste -sd' ' -)) — workflow config, not treated as staleness." >&2
    else
      stale=1
      stale_reason="verdict file last written $(fmt_epoch "$vmtime"); HEAD commit landed $(fmt_epoch "$head_ctime") — additional commits since /quality-review ran"
    fi
  fi
fi

printf 'VERDICT_FILE=%s\n' "$verdict_file"
printf 'VERDICT_PUBLISHED_ACROSS=%s\n' "$published_across"
printf 'VERDICT=%s\n' "$verdict"
printf 'CYCLES=%s\n' "$cycles"
printf 'SUB_ISSUES=%s\n' "$sub_issues"
printf 'SUB_ISSUES_ERROR=%s\n' "$sub_issues_error"
printf 'VERDICT_STALE=%s\n' "$stale"
printf 'VERDICT_STALE_REASON=%s\n' "$stale_reason"
