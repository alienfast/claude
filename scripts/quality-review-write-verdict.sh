#!/bin/bash
# quality-review-write-verdict.sh — Persist the /quality-review verdict block
# so /finish (and /start Step 10) can find it across worktrees and sessions.
#
# Usage: quality-review-write-verdict.sh <ISSUE-ID> [<VERDICT-BODY-FILE>|-]
#
#   -           read the body from stdin (heredoc) — ONE call, no staging file
#   omitted     default to <worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   <file>      read the body from that path
#
# PREFER STDIN. A staged file that is never published is invisible: it lives in
# the worktree, and /finish merge deletes the worktree with it. Measured on the
# 2026-08-03 fleet, 4 of 12 shipped issues lost their verdict exactly that way —
# every one had staged the file correctly and simply never made the second call.
# Stdin removes the intermediate state that failure needs.
#
# In a /start wt worktree the harness BLOCKS a direct write to the main
# checkout's tmp/ ("this session is now isolated in <worktree>"). This script is
# the sanctioned way across that boundary — it is not subject to the guard.
#
# Writes the verdict body atomically (mktemp + mv) to:
#   1. <current-worktree>/tmp/quality-review-verdict-<issue-lower>.md
#   2. <main-checkout>/tmp/quality-review-verdict-<issue-lower>.md
#      (only if different from #1 — happens when invoked from a /start wt
#      worktree, so /finish run from the main checkout can still find it)
#
# Idempotent: re-running with the same inputs overwrites both files atomically.
#
# Exit codes:
#   0 = both writes succeeded (or only #1 if main checkout == current worktree)
#   1 = not in a git repo
#   2 = missing or unreadable inputs, or an empty body
#   3 = published, but the body is off-schema — one or more of the Output block's seven
#       field lines is missing or unparseable (stderr names which). The copies WERE
#       written: /finish Step 1.5 needs the file to exist, and in auto mode an absent
#       file aborts the ship, so refusing the write would turn a lost audit record into
#       a blocked ship. Fix the block and re-run; the overwrite is idempotent.

set -eo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "ERROR: usage: $(basename "$0") <ISSUE-ID> [<VERDICT-BODY-FILE>|-]" >&2
  exit 2
fi

issue_id="$1"
body_file="${2-}"

issue_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$worktree_root" ]; then
  echo "ERROR: not in a git repository" >&2
  exit 1
fi

# Body resolution happens here, not at argument parsing, because the default
# path is relative to the worktree root discovered above.
stdin_tmp=""
# The `return 0` is load-bearing: an EXIT trap's final status becomes the script's
# exit status, so without it every non-stdin run ends on the failed [ -n "" ] test
# and reports 1 — turning a successful publish, and a deliberate exit 2, into 1.
cleanup() { [ -n "$stdin_tmp" ] && rm -f "$stdin_tmp"; return 0; }
trap cleanup EXIT

if [ -z "$body_file" ]; then
  body_file="$worktree_root/tmp/quality-review-verdict-${issue_lower}.md"
elif [ "$body_file" = "-" ]; then
  stdin_tmp=$(mktemp "${TMPDIR:-/tmp}/qr-verdict-stdin-XXXXXX")
  cat > "$stdin_tmp"
  body_file="$stdin_tmp"
fi

if [ ! -r "$body_file" ]; then
  echo "ERROR: verdict body file not readable: $body_file" >&2
  exit 2
fi

# An empty body is always a caller bug — an unquoted heredoc that expanded to
# nothing, or a staging file that was never written. Publishing it would satisfy
# /finish Step 1.5's existence check with a file carrying no Verdict: line,
# which finish-read-verdict.sh reports as none-found anyway. Fail loudly instead.
if [ ! -s "$body_file" ]; then
  echo "ERROR: verdict body is empty: $body_file" >&2
  exit 2
fi

# git-common-dir's parent is the main checkout's working tree (for a regular
# clone, it's the same as worktree_root; for a linked worktree, it differs).
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
main_checkout=""
if [ -n "$common_dir" ]; then
  # common_dir is .../<main>/.git ; its parent is the main working tree.
  main_checkout=$(dirname "$common_dir")
fi

write_atomic() {
  local dest_dir="$1"
  local dest_file="$dest_dir/quality-review-verdict-${issue_lower}.md"
  mkdir -p "$dest_dir"
  local tmp
  tmp=$(mktemp "${dest_dir}/.qr-verdict-XXXXXX")
  cp "$body_file" "$tmp"
  # mktemp creates 0600; without this, the atomic mv preserves 0600 on the
  # final artifact, which surprises any other user/process expecting the
  # umask default. Force 0644 so the file is readable to group/other (verdict
  # files are review findings, not secrets, and other processes/users on a
  # shared machine may want to inspect them).
  chmod 644 "$tmp"
  mv "$tmp" "$dest_file"
  printf 'wrote %s\n' "$dest_file"
}

write_atomic "$worktree_root/tmp"

if [ -n "$main_checkout" ] && [ "$main_checkout" != "$worktree_root" ]; then
  write_atomic "$main_checkout/tmp"
fi

# Schema guard — publish-then-warn, never refuse. Runs AFTER the writes because an off-schema body
# is still a real audit record where an empty one is not (the exit-2 guard above), and /finish
# needs the file to exist. Anchored exactly like fleet-metrics.py's V_VERDICT/V_CYCLES/V_RESOLVED/
# V_FILED_LINE regexes, so "parseable" here cannot drift from what the retro's consumer reads: the
# 2026-08-06 fleet published 3 of 15 verdicts this check would have caught, and their findings data
# was unrecoverable by the time fleet-metrics.py flagged the breach. Value forms matter, not mere
# presence — a literal "Cycles: N" or a pipe-carrying unsubstituted "Verdict: <one of: a | b>" is
# exactly what slipped through, and "## Findings resolved" as a heading fails the line-start colon.
schema_missing=""
miss() { schema_missing="${schema_missing:+$schema_missing, }$1"; }
has() { grep -Eq "$1" "$body_file"; }

# WARN (exit-0 stderr, deliberately outside the exit-3 schema set) when the verdict filed issues but
# records nothing about sibling collision edges: SKILL.md mandates annotating only a FAILED
# `relations add`, so a never-attempted wiring was indistinguishable from none-owed — and unwired
# same-mechanism siblings recurred on two consecutive fleets, every edge wired by hand at retro
# (BF-1226). `Collision edges: none owed` satisfies the disjoint-file and evidence-append cases.
# Paired with fleet-metrics.py's V_EDGES_LINE flag, which surfaces the same omission at retro.
if grep -Eq '^Deferred filed as issues:.*[A-Z]+-[0-9]+' "$body_file" \
   && ! grep -Eq '^Collision edges:[[:space:]]*[^[:space:]]' "$body_file"; then
  echo "WARN: verdict files issues but has no 'Collision edges:' line — record the wired edges (or 'none owed'); see quality-review/SKILL.md Output" >&2
fi

# WARN when the 'Collision edges:' line satisfies the presence check above with a TOOLING-UNAVAILABILITY
# excuse. The capability exists: `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`, documented in
# skills/linear/SKILL.md's command map (gotcha #10 covers only `-r blocked-by`, which 400s; `blocks`,
# `related` and `duplicate` all work). Measured 2026-08-21 on JA-148, whose verdict read "could not be
# created with available tooling. linear-cli exposes no relation subcommand" and skipped a mandated step
# on that basis — then recommended a /reflect to fix the toolchain, which would have filed config work
# against a gap that does not exist. One `--help` call settles it. This is the failure mode prose cannot
# reach: the agent did not ignore the rule, it concluded compliance was impossible and documented the
# reasoning persuasively enough to pass its own review.
if grep -Eqi '^Collision edges:.*(could not|cannot|unable to|no (relation|tooling)|not (available|possible|supported)|toolchain)' "$body_file"; then
  echo "WARN: 'Collision edges:' claims the tooling cannot wire edges — it can: linear-cli relations add <BLOCKER> <BLOCKED> -r blocks (see skills/linear/SKILL.md). Verify with 'linear-cli relations --help' before recording an unavailability claim; if a specific call genuinely failed, quote the command and its error instead." >&2
fi

has '^Verdict:[[:space:]]*(passed-clean|passed-after-fixes|terminated-with-open-items|escalated-to-architect)([[:space:]][^|]*)?$' || miss "Verdict"
has '^Cycles:[[:space:]]*[0-9]+' || miss "Cycles"
has '^Findings resolved:[[:space:]]*([0-9]+|none)' || miss "Findings resolved"
has '^Deferred fixed in-session:' || miss "Deferred fixed in-session"
has '^Deferred filed as issues:[[:space:]]*[^[:space:]]' || miss "Deferred filed as issues"
has '^Deferred dropped:' || miss "Deferred dropped"
has '^Open items:' || miss "Open items"

if [ -n "$schema_missing" ]; then
  echo "ERROR: verdict published but off-schema: missing/unparseable lines: $schema_missing" >&2
  echo "ERROR: the copies above were still written; re-run with the corrected block (see quality-review/SKILL.md Output)." >&2
  exit 3
fi
