#!/usr/bin/env bash
# Regression suite for start-wt-verify.sh — focused on the stage-3 claim routing, the stage this script's
# `FAILED-CLAIM: … do not proceed unclaimed` verdict makes a promise about. Before the claim was verified
# it gated on linear-cli's exit status alone, so a write that reported success and landed nothing
# (skills/linear/SKILL.md gotcha #8) passed the stage silently; case 2 below is that regression.
#
# linear-claim.sh is stubbed per case so all three of its outcomes are exercised without touching Linear.
# The later stages are deliberately NOT satisfied (no git worktree config, no pnpm project), so a run that
# clears the claim reaches FAILED-SOURCE-BRANCH — which is exactly the signal that stage 3 passed.
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_pre() { # ck_pre <label> <expected-prefix> <actual>
  case "$3" in "$2"*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: $1 — expected prefix [$2] got [$3]" ;; esac
}
ck_err() { # ck_err <label> <needle>
  if grep -qF -- "$2" "$WORK/err"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — stderr missing [$2]"; fi
}
ck_noerr() { # ck_noerr <label> <needle>
  if grep -qF -- "$2" "$WORK/err"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — stderr should not contain [$2]"; else PASS=$((PASS+1)); fi
}

S="$WORK/s"; WT="$WORK/wt"; mkdir -p "$S" "$WT"
cp "$SRC/start-wt-verify.sh" "$SRC/wt-path.sh" "$S/"

mk_claim() { # mk_claim <verdict-line> <exit>
  printf '%s\n' '#!/bin/bash' 'echo "== stub claim ==" >&2' "echo \"$1\"" "exit $2" > "$S/linear-claim.sh"
  chmod +x "$S/linear-claim.sh"
}
run() { ( cd "$WT" && "$S/start-wt-verify.sh" "$WT" TT-1 --claim ) 2>"$WORK/err"; }

# --- usage: the flag carries the orchestrator's decision and is never guessed ---
out=$("$S/start-wt-verify.sh" 2>/dev/null); ck_pre "usage: no args" "FAILED-USAGE:" "$out"
out=$("$S/start-wt-verify.sh" "$WT" TT-1 2>/dev/null); ck_pre "usage: claim flag required" "FAILED-USAGE:" "$out"
out=$("$S/start-wt-verify.sh" "$WT" TT-1 --claim --no-claim 2>/dev/null); ck_pre "usage: both flags" "FAILED-USAGE:" "$out"
out=$("$S/start-wt-verify.sh" "$WT" "nope" --claim 2>/dev/null); ck_pre "usage: bad issue ID" "FAILED-USAGE:" "$out"
ck "usage: exit 1" "1" "$(("$S/start-wt-verify.sh" >/dev/null 2>&1); echo $?)"

# --- cwd confirm precedes the claim: a wrong cwd must never reach Linear ---
mk_claim "CLAIMED TT-1 assignee=me state=In Progress" 0
out=$( ( cd "$WORK" && "$S/start-wt-verify.sh" "$WT" TT-1 --claim ) 2>"$WORK/err" )
ck_pre "cwd mismatch: verdict" "FAILED-CWD:" "$out"
ck_noerr "cwd mismatch: claim not attempted" "== stub claim =="

# --- case 1: claim CONFIRMED -> stage 3 passes, run advances to the source-branch probe ---
mk_claim "CLAIMED TT-1 assignee=me state=In Progress" 0
out=$(run)
ck_pre "confirmed: advances past claim" "FAILED-SOURCE-BRANCH:" "$out"
ck_err "confirmed: claim stage ran" "== stub claim =="

# --- case 2: claim CONFIRMED NOT landed -> FAILED-CLAIM, carrying the helper's reason.
#     THE REGRESSION: this case used to pass the stage silently. ---
mk_claim "NOT-CLAIMED TT-1: assignee reads 'none', wanted 'me'" 2
out=$(run); rc=$?
ck_pre "not-claimed: FAILED-CLAIM verdict" "FAILED-CLAIM:" "$out"
ck "not-claimed: exit 1" "1" "$rc"
case "$out" in *"assignee reads 'none'"*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: not-claimed — verdict drops the helper's reason" ;; esac
case "$out" in *"do not proceed unclaimed"*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: not-claimed — verdict drops the routing phrase" ;; esac
ck_noerr "not-claimed: run stopped at stage 3" "source-branch probe"

# --- case 3: UNCONFIRMED -> WARN and PROCEED. An unconfirmable claim is not a failed one; failing
#     here would turn a transient read blip into a dead session. ---
mk_claim "UNCONFIRMED TT-1: assignee read-back failed — the write may have landed" 3
out=$(run)
ck_pre "unconfirmed: proceeds past claim" "FAILED-SOURCE-BRANCH:" "$out"
ck_err "unconfirmed: WARN emitted" "WARN: UNCONFIRMED TT-1"
case "$out" in FAILED-CLAIM*) FAIL=$((FAIL+1)); echo "FAIL: unconfirmed must not read as FAILED-CLAIM" ;; *) PASS=$((PASS+1)) ;; esac

# --- --no-claim skips the stage entirely (idempotent resumption, already claimed by me) ---
mk_claim "NOT-CLAIMED TT-1: should not run" 2
out=$( ( cd "$WT" && "$S/start-wt-verify.sh" "$WT" TT-1 --no-claim ) 2>"$WORK/err" )
ck_pre "no-claim: skips to source-branch" "FAILED-SOURCE-BRANCH:" "$out"
ck_noerr "no-claim: claim not attempted" "== stub claim =="

# --- the verdict is always exactly the first line of stdout ---
mk_claim "NOT-CLAIMED TT-1: reason" 2
ck "stdout is a single verdict line" "1" "$(run | wc -l | tr -d ' ')"

echo "--- start-wt-verify.test.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
