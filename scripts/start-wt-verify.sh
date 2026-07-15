#!/bin/bash
# start-wt-verify.sh — verify a /start worktree session before implementation begins.
#
# Why this exists: extends the wt-baseline.sh extraction (see that script's header) — skills carry
# policy, scripts carry machinery. This was /start Step 0 sub-step 3's "merged verification block"
# (cwd confirm → baseline verify → claim → source-branch probe → pnpm check), previously re-emitted
# verbatim in skill markdown every session; that transcription was itself a failure mode. This script
# is the single tested implementation. The skill keeps only the policy: which claim flag to pass, and
# what each FAILED-* verdict routes to (BLOCKED-ON-REVIEW tags, auto-mode bounds) — see
# skills/start/SKILL.md Step 0 sub-step 3.
#
# Usage:
#   start-wt-verify.sh <wt-abs-path> <ISSUE-ID> (--claim|--no-claim) [--baseline-file <path>]
#
# --claim|--no-claim is REQUIRED, no default — it carries the orchestrator's Step 3 availability
# decision (claim now vs. idempotent resumption already claimed by me). This script never guesses it;
# a missing flag is a usage error.
# --baseline-file <path>: when given with a non-empty path, verified with `[ -r ]` — a zero-byte file
# is the CORRECT capture result for a clean main checkout, so readability is the test, not size. When
# omitted (or given empty), this script re-captures via the sibling wt-baseline.sh and requires its
# CAPTURED verdict.
#
# stdout contract — the FIRST line of stdout is the verdict; orchestrators branch on it:
#   VERIFIED                            exit 0
#   FAILED-USAGE: <reason>              exit 1   (stage 1: bad args)
#   FAILED-CWD: <reason>                exit 1   (stage 2: cwd confirm)
#   FAILED-BASELINE: <reason>           exit 1   (stage 3: baseline verify/re-capture)
#   FAILED-CLAIM: <reason>              exit 1   (stage 4: linear-cli claim)
#   FAILED-SOURCE-BRANCH: <reason>      exit 1   (stage 5: source-branch probe)
#   FAILED-CHECK: <reason>              exit 1   (stage 6: pnpm check)
#
# Everything else — stage markers (`== ... ==`, so a mid-stage failure is attributable in logs), the
# `SOURCE_BRANCH=<value>` diagnostic, and ALL `pnpm check` output — goes to stderr. The FAILED-* line
# mirrors to stderr too (like wt-baseline.sh's fail()). Routing each FAILED-* verdict to a
# BLOCKED-ON-REVIEW tag (and any auto-mode bound) is skill policy, not this script's concern.

set -uo pipefail

fail() {
  # A caller-supplied argument (e.g. an unknown-argument usage error) can contain a newline; flatten it
  # so the verdict is still exactly the first line of stdout, per the contract above.
  msg=$(printf '%s' "$1" | tr '\n' ' ')
  echo "$msg"
  echo "$msg" >&2
  exit 1
}

usage() {
  fail "FAILED-USAGE: $1"
}

[ $# -ge 3 ] || usage "usage: start-wt-verify.sh <wt-abs-path> <ISSUE-ID> (--claim|--no-claim) [--baseline-file <path>]"

wt_arg=$1
issue_arg=$2
shift 2

claim_flag=""
baseline_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --claim)
      [ -z "$claim_flag" ] || usage "--claim/--no-claim given more than once"
      claim_flag="claim"
      shift
      ;;
    --no-claim)
      [ -z "$claim_flag" ] || usage "--claim/--no-claim given more than once"
      claim_flag="no-claim"
      shift
      ;;
    --baseline-file)
      [ $# -ge 2 ] || usage "--baseline-file requires a value"
      baseline_file=$2
      shift 2
      ;;
    *)
      usage "unknown argument '$1'"
      ;;
  esac
done

[ -n "$claim_flag" ] || usage "exactly one of --claim or --no-claim is required"

# Canonicalize before comparing (stage 2 reuses this) — a symlinked path component would otherwise
# make an identical directory compare unequal.
[ -n "$wt_arg" ] && [ -d "$wt_arg" ] || usage "wt-abs path '$wt_arg' unset or not a directory"
WT_ABS=$(cd "$wt_arg" && pwd -P) || usage "could not canonicalize '$wt_arg'"

# Normalize issue ID exactly like start-wt-setup.sh: strip whitespace, uppercase, validate.
issue_input=$(printf '%s' "$issue_arg" | tr -d '[:space:]')
issue_id=$(printf '%s' "$issue_input" | tr '[:lower:]' '[:upper:]')
[[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]] || usage "issue ID '$issue_id' does not match ^[A-Z]+-[0-9]+\$"
issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "== cwd confirm ==" >&2
# The script inherits the Bash session's cwd — there is no direct way to query harness-level
# registration state, so comparing cwd against the canonicalized worktree root is the only proxy
# available for confirming EnterWorktree's registration actually took.
[ "$(pwd -P)" = "$WT_ABS" ] || fail "FAILED-CWD: cwd is not the worktree — EnterWorktree registration did not take"

echo "== baseline verify ==" >&2
if [ -n "$baseline_file" ]; then
  [ -r "$baseline_file" ] || fail "FAILED-BASELINE: baseline file '$baseline_file' missing/unreadable"
else
  if ! capture_out=$("$SCRIPT_DIR/wt-baseline.sh" capture "$(pwd -P)" "$issue_lower"); then
    fail "FAILED-BASELINE: baseline re-capture failed"
  fi
  case "$capture_out" in
    CAPTURED\ *) ;;
    *) fail "FAILED-BASELINE: baseline re-capture returned unexpected output" ;;
  esac
fi

if [ "$claim_flag" = "claim" ]; then
  echo "== claim ==" >&2
  # linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
  export PATH="$HOME/.cargo/bin:$PATH"
  # Redirect linear-cli's own stdout to our stderr — it must never leak onto this script's
  # single-line stdout verdict contract. Its stderr passes through unredirected.
  if ! linear-cli issues update "$issue_id" --assignee me --state "In Progress" >&2; then
    fail "FAILED-CLAIM: claim update failed — do not proceed unclaimed"
  fi
fi

echo "== source-branch probe ==" >&2
source_branch=$(git config --worktree --get start.source-branch 2>/dev/null || true)
# Recorded by start-wt-setup.sh this session; a missing value is a possible hijack/corruption signal.
[ -n "$source_branch" ] || fail "FAILED-SOURCE-BRANCH: start.source-branch missing from worktree config"
echo "SOURCE_BRANCH=$source_branch" >&2

echo "== pnpm check ==" >&2
pnpm check >&2 || fail "FAILED-CHECK: pnpm check failed"

echo "VERIFIED"
exit 0
