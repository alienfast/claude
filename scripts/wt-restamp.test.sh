#!/usr/bin/env bash
# Functional suite for wt-restamp.sh (and the wt-identity.sh write path it drives). Builds throwaway
# repos + linked worktrees in a temp dir and drives the real script end to end — every case therefore
# also exercises the with-repo-lock.py re-exec, since that is unconditional.
#
# Detachment topology mirrors BF-505: the SOURCE branch is rewritten after the fork (content-identical
# amend, new SHA), so rebasing onto it moves HEAD to a lineage that no longer contains the stamped
# baseline. A rebase onto an append-only source does NOT detach (the fork point stays an ancestor) —
# that case needs no restamp, so a test built on it would prove nothing.
#
# GROW THIS SUITE, NEVER PRUNE IT. wt-restamp.sh grants a worktree the right to be merged, so every
# hole ever found in that gate has a case below. Add the case WITH the fix; never delete one to
# "clean up" — a closed hole with no live guard is a hole that reopens.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTAMP="$DIR/wt-restamp.sh"
IDLIB="$DIR/wt-identity.sh"

TMP="$(mktemp -d)"
# One case makes a directory unwritable on purpose; restore before rm.
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The suite's own session must not leak into ownership/sidecar resolution.
unset CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_HARNESS_PID WT_RESTAMP_LOCK_PID

G="git -c user.email=t@t -c user.name=t"
pass=0; fail=0

ck() { # want got label
  if [ "$1" = "$2" ]; then echo "PASS  $3"; pass=$((pass + 1))
  else echo "FAIL  $3 (want '$1' got '$2')"; fail=$((fail + 1)); fi
}
ck_has() { # needle haystack label
  if printf '%s' "$2" | grep -qF -- "$1"; then echo "PASS  $3"; pass=$((pass + 1))
  else echo "FAIL  $3 (no '$1' in: $(printf '%s' "$2" | tr '\n' '|'))"; fail=$((fail + 1)); fi
}

stamp() { # wt_dir session_id ("" = id-less stamp) [job_dir — stamps under a fleet job-dir identity]
  local wt="$1" sess="$2" job="${3-}" body
  body="set -e; . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    wt_identity_stamp '$wt' '$wt' test-1 issue-branch main \"\$base\" >/dev/null"
  if [ -n "$job" ]; then env "CLAUDE_JOB_DIR=$job" bash -c "$body"
  elif [ -z "$sess" ]; then env -u CLAUDE_SESSION_ID bash -c "$body"
  else env "CLAUDE_SESSION_ID=$sess" bash -c "$body"; fi
}

# Sets REPO and WT. The worktree dir is named for the issue, as /start's .claude/worktrees/<issue-lower>
# is — wt_identity_load derives the sidecar name from that basename, so a mismatched fixture would
# silently degrade every case to the weaker git-config-only identity.
setup() { # name [session]
  local w="$TMP/$1" sess="${2-sess-A}"
  REPO="$w/repo"; WT="$w/test-1"
  mkdir -p "$w"
  git init -q -b main "$REPO"
  git -C "$REPO" config extensions.worktreeConfig true   # start-wt-setup.sh does this in the real flow
  ( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
  ( cd "$REPO" && echo v1 > main.txt && $G add main.txt && $G commit -qm "A: pre-fork" ) >/dev/null
  git -C "$REPO" worktree add -q "$WT" -b issue-branch
  stamp "$WT" "$sess"
}

# The REAL /start setup, invoked exactly as start-wt-setup.sh does (cwd inside the repo, 5 args).
# Resume/attach fidelity is the whole point: a simulated stamp cannot reproduce WHICH TIER the script
# actually reads, and that choice is what decides whether a clobber stays visible. Sets OUT/ERR/RC.
real_start() { # [session] — operates on $REPO/$WT
  local sess="${1-sess-A}" errf="$TMP/stderr.txt"
  OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=$sess" "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

# A stamp that inherits the anchor WITHOUT its era. No real caller can do this — it exists only to
# demonstrate the property the pairing protects: an anchor and its era must travel together.
resume_stamp_head_only() { # wt_dir anchor
  env "CLAUDE_SESSION_ID=sess-A" "WTID_STAMP_HEAD_SHA_OVERRIDE=$2" bash -c "
    set -e; . '$IDLIB'
    wt_identity_stamp '$1' '$1' test-1 issue-branch main \"\$(git -C '$1' config --worktree --get start.baseline-sha)\" >/dev/null"
}

verify() { # wt_dir -> "<corruption>:<reason>"
  bash -c ". '$IDLIB'; wt_identity_load '$1' && wt_identity_verify '$1'; echo \"\$WTID_CORRUPTION:\$WTID_CORRUPTION_REASON\""
}

OUT=""; ERR=""; RC=0; REPO=""; WT=""
run() { # session args... -> OUT/ERR/RC
  local sess="$1" errf="$TMP/stderr.txt"; shift
  if [ -z "$sess" ]; then OUT=$(env -u CLAUDE_SESSION_ID "$RESTAMP" "$@" 2>"$errf")
  else OUT=$(env "CLAUDE_SESSION_ID=$sess" "$RESTAMP" "$@" 2>"$errf"); fi
  RC=$?
  ERR=$(cat "$errf")
}

# --- Part 1: the core owner-gate contract (rebase onto a rewritten source) ---
setup core
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1

ck "1:baseline-detached" "$(verify "$WT")" "rebase onto rewritten source detaches the baseline"

run sess-B "$WT"
ck "3" "$RC" "foreign session refused (exit 3)"

run sess-A "$WT"
ck "0" "$RC" "owner restamp exits 0"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "owner restamp reports ok"
ck "0:" "$(verify "$WT")" "post-restamp verify is clean"

run sess-A "$WT"
ck "RESTAMP=noop" "$(echo "$OUT" | head -1)" "second restamp is a noop"

git -C "$WT" reset -q --hard main~1
ck "1:baseline-detached" "$(verify "$WT")" "foreign reset still detected"
run sess-B "$WT"
ck "3" "$RC" "hijacker cannot self-legitimize (exit 3)"

git -C "$WT" checkout -q -b other-branch
run sess-A "$WT"
ck "4" "$RC" "branch-swapped refused (exit 4)"

# --- Part 2: work preservation (the laundering hole) ---
# A foreign session resets the branch onto source, dropping the owner's commit. The owner then
# restamps: without the preservation gate that stamp would bless the reset as its own rewrite.
setup launder
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: dropped work" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: source moves on" ) >/dev/null
git -C "$WT" reset -q --hard main
before=$(git -C "$WT" config --worktree --get start.baseline-sha)

run sess-A "$WT"
ck "5" "$RC" "foreign reset refused even for the owner (exit 5)"
ck_has "W: dropped work" "$ERR" "exit 5 names the lost commit"
ck "$before" "$(git -C "$WT" config --worktree --get start.baseline-sha)" "refused restamp left the stamp untouched"

run sess-A --acknowledge-lost "$WT"
ck "0" "$RC" "--acknowledge-lost bypasses the lost-commit refusal"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "acknowledged restamp reports ok"
ck_has "ACKNOWLEDGED_LOST=" "$OUT" "acknowledged restamp lists the dropped commits"
ck_has "W: dropped work" "$OUT" "acknowledged list names the dropped commit"

# --- Part 3: an id-less stamp can never be restamped (pid equality is not identity) ---
setup idless ""
ck "" "$(git -C "$WT" config --worktree --get start.owner-session || true)" "id-less stamp records no owner session"
run "" "$WT"
ck "3" "$RC" "id-less stamp refuses restamp from the same pid (exit 3)"
ck_has "pid equality cannot prove same-session" "$ERR" "exit 3 explains why the pid is not enough"

# --- Part 4: the noop short-circuit must not paper over a corrupt worktree ---
setup wipe
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
git -C "$WT" config --worktree --unset start.source-branch
ck "1:source-branch-config-wiped" "$(verify "$WT")" "config wipe is corruption at an unchanged baseline"
run sess-A "$WT"
ck "0" "$RC" "config-wiped worktree restamps instead of short-circuiting"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "config-wiped worktree takes the full restamp path"
ck "0:" "$(verify "$WT")" "full restamp repaired the wiped config"

# --- Part 5: an unresolvable source branch is never silently degraded to HEAD ---
setup nosrc
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
git -C "$REPO" branch -m main main-renamed
run sess-A "$WT"
ck "2" "$RC" "renamed source branch refused (exit 2)"
ck_has "does not resolve" "$ERR" "exit 2 names the unresolvable source branch"

# --- Part 6: a halted rebase is diagnosed as such, not as a branch swap ---
setup rebasing
( cd "$WT" && echo wt-side > main.txt && $G add main.txt && $G commit -qm "W: conflicting edit" ) >/dev/null
( cd "$REPO" && echo main-side > main.txt && $G add main.txt && $G commit -qm "B: conflicting edit" ) >/dev/null
( cd "$WT" && $G rebase main ) >/dev/null 2>&1
ck "" "$(git -C "$WT" symbolic-ref --quiet --short HEAD || true)" "halted rebase leaves HEAD detached"
run sess-A "$WT"
ck "2" "$RC" "mid-rebase refused (exit 2)"
ck_has "finish or abort the rebase first" "$ERR" "exit 2 says to finish or abort the rebase"

# --- Part 7: a partially written stamp is never reported as ok ---
# The repo-fallback sidecar's directory is made unwritable, so that tier keeps the OLD baseline while
# git config and the job-dir sidecar take the new one. Re-reading the identity cannot catch this: the
# job-dir tier wins the load and verifies clean, so the split is invisible until ANOTHER session — which
# only ever finds the repo-fallback tier — reads a stale baseline. Only per-tier checks see it.
setup partial
JOBDIR="$TMP/partial/jobs/sess-A"
mkdir -p "$JOBDIR"
cp "$REPO/.claude/worktree-identity/wt-identity-test-1.env" "$JOBDIR/"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
chmod a-w "$REPO/.claude/worktree-identity"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOBDIR" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "2" "$RC" "stale sidecar tier fails the restamp (exit 2)"
ck_has "is stale" "$ERR" "exit 2 names the stale tier"
ck_has "worktree-identity" "$ERR" "exit 2 names the sidecar path"

# Retry while the tier is STILL unwritable: the baseline now matches on the winning (job-dir) tier, so
# the noop short-circuit would report success over a split identity. It must keep refusing.
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOBDIR" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "2" "$RC" "retry over an unrepairable tier refuses again (exit 2)"
ck "" "$(echo "$OUT" | head -1)" "retry does not report noop"
chmod u+w "$REPO/.claude/worktree-identity"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOBDIR" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "retry after the tier becomes writable repairs it (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "repair retry takes the full restamp path"

# --- Part 8: a restamp re-baselines; it does not re-create the worktree ---
setup created
git -C "$WT" config --worktree start.created-at 2020-01-01T00:00:00Z
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "0" "$RC" "restamp succeeds on the created-at fixture"
ck "2020-01-01T00:00:00Z" "$(git -C "$WT" config --worktree --get start.created-at)" "created-at preserved in git config"
ck "2020-01-01T00:00:00Z" "$(sed -n 's/^WT_IDENTITY_CREATED_AT=//p' "$REPO/.claude/worktree-identity/wt-identity-test-1.env" | head -1)" "created-at preserved in the sidecar"

# --- Part 9: a REJECTED sidecar's worktree path never leaks into the new stamp ---
# A stale job-dir sidecar for this issue points at a different worktree, so it is rejected and the
# identity falls back to git config (repo sidecar removed) — which carries no path. The stamp must
# record the LIVE worktree, not the rejected sidecar's. Job dir is named for the session because
# wt_identity_owner prefers $CLAUDE_JOB_DIR's basename over $CLAUDE_SESSION_ID.
setup leak
JOBDIR="$TMP/leak/jobs/sess-A"
mkdir -p "$JOBDIR"
printf 'WT_IDENTITY_ISSUE=test-1\nWT_IDENTITY_BRANCH=issue-branch\nWT_IDENTITY_SOURCE_BRANCH=main\nWT_IDENTITY_BASELINE_SHA=deadbeef\nWT_IDENTITY_WT_DIR=%s\n' \
  "$TMP/leak/some-other-worktree" > "$JOBDIR/wt-identity-test-1.env"
rm -f "$REPO/.claude/worktree-identity/wt-identity-test-1.env"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOBDIR" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "restamp succeeds against a rejected stale sidecar"
ck "$(cd "$WT" && pwd -P)" "$(sed -n 's/^WT_IDENTITY_WT_DIR=//p' "$JOBDIR/wt-identity-test-1.env" | head -1)" "stamp records the live worktree, not the rejected sidecar's path"

# --- Part 10: an unresolvable harness pid degrades, it does not kill the stamp ---
# 999999 is above every platform's pid ceiling, so `ps` returns nothing for it. wtid_pid_start's
# contract is "empty if unknown"; when it instead failed the pipeline, `set -eo pipefail` killed
# the whole restamp at the &&-chained assignment — exit 1, no output, no stamp.
setup pidless
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_HARNESS_PID=999999" "$RESTAMP" "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "unresolvable harness pid still restamps (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "unresolvable harness pid reports ok"

# --- Part 11: a MULTI-STEP foreign clobber cannot walk past the gate ---
# The reflog-only gate anchored on <branch>@{1}, so a reset plus any later ref update (here the
# hijacker's own commit) left @{1} pointing PAST the damage and the restamp sanctioned it. The
# stamp-time head is immune to that: it does not move when the branch does.
setup clobber
root=$(git -C "$WT" rev-parse HEAD~1)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: owner work" ) >/dev/null
git -C "$WT" reset -q --hard "$root"
( cd "$WT" && echo f > f.txt && $G add f.txt && $G commit -qm "F: foreign commit" ) >/dev/null
run sess-A "$WT"
ck "5" "$RC" "reset-then-commit clobber refused (exit 5)"
ck_has "W: owner work" "$ERR" "exit 5 names the owner's clobbered commit"

# --- Part 12: an unusable `git cherry` fails CLOSED ---
# A PATH shim fails only on `cherry`. Piping it into sed swallowed both status and reason, so a broken
# repo read as "nothing lost" — the gate's only failure mode must be refusal.
setup cherryfail
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
SHIM="$TMP/cherryfail/shim"; mkdir -p "$SHIM"
printf '#!/bin/bash\nfor a in "$@"; do if [ "$a" = "cherry" ]; then echo "simulated cherry failure" >&2; exit 128; fi; done\nexec %s "$@"\n' \
  "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "PATH=$SHIM:$PATH" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "5" "$RC" "unusable git cherry refuses (exit 5)"
ck_has "git cherry failed" "$ERR" "exit 5 names the cherry failure"

# --- Part 13: a non-canonical <wt_dir> must not downgrade the identity tier ---
# The sidecar filename comes from basename "$wt_dir", so '.' found no sidecar and fell back to the git
# config tier — the one a hijacker can seize. Here the foreign session both swaps the branch and
# rewrites the config to match it: only the sidecar tiers still know the truth.
setup noncanon
git -C "$WT" checkout -q -b other-branch
git -C "$WT" config --worktree start.worktree-branch other-branch
run sess-A "$WT"
ck "4" "$RC" "absolute-path call refuses the seized worktree (exit 4)"
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "$RESTAMP" . 2>"$TMP/stderr.txt"); RC=$?
ck "4" "$RC" "relative '.' call behaves identically (exit 4)"

# --- Part 14: a never-moved branch still repairs a wiped config ---
# Its stamped head IS the fork point, so preservation is trivially provable — no reflog step exists
# here, and requiring one used to turn this repair into an exit 5.
setup unmoved
git -C "$WT" config --worktree --unset start.source-branch
ck "1:source-branch-config-wiped" "$(verify "$WT")" "config wipe detected on an unmoved branch"
run sess-A "$WT"
ck "0" "$RC" "unmoved branch repairs instead of refusing (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "unmoved branch takes the full restamp path"
ck "0:" "$(verify "$WT")" "unmoved branch verifies clean after repair"

# --- Part 15: the owner is recognized by ANY of this session's identifiers ---
# A fleet run stamps its job-dir basename; the same session continuing under a different job dir still
# presents that id as CLAUDE_CODE_SESSION_ID. Matching only the first-resolved id stranded the owner.
setup altid ""
JOBDIR="$TMP/altid/jobs/sess-J"; mkdir -p "$JOBDIR"
stamp "$WT" "" "$JOBDIR"
ck "sess-J" "$(git -C "$WT" config --worktree --get start.owner-session)" "fleet stamp records the job-dir basename as owner"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OTHERJOB="$TMP/altid/jobs/other-job"; mkdir -p "$OTHERJOB"
OUT=$(env "CLAUDE_JOB_DIR=$OTHERJOB" "CLAUDE_CODE_SESSION_ID=sess-J" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "owner recognized via an alternate identifier (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "alternate-identifier owner restamps"

# --- Part 16: a stamp with no recorded head cannot be restamped ---
setup legacy
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
git -C "$WT" config --worktree --unset start.head-sha
LEGACY_SIDECAR="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v '^WT_IDENTITY_HEAD_SHA=' "$LEGACY_SIDECAR" > "$LEGACY_SIDECAR.x" && mv "$LEGACY_SIDECAR.x" "$LEGACY_SIDECAR"
run sess-A "$WT"
ck "5" "$RC" "stamp without a head anchor refuses (exit 5)"
ck_has "records no rewrite anchor" "$ERR" "exit 5 explains the missing anchor"

# --- Part 17: the anchor moves with each sanctioned stamp, and still catches the next clobber ---
setup anchored
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "0" "$RC" "legitimate rebase restamps (exit 0)"
ck "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" config --worktree --get start.head-sha)" "restamp re-anchors on the rewritten tip"
( cd "$WT" && echo more > more.txt && $G add more.txt && $G commit -qm "X: post-restamp work" ) >/dev/null
git -C "$WT" reset -q --hard main~1
run sess-A "$WT"
ck "5" "$RC" "foreign reset after a sanctioned restamp still refused (exit 5)"
ck_has "W: work" "$ERR" "exit 5 names work dropped below the new anchor"

# --- Part 18: identity writes really do serialize on the repo lock ---
# WT_RESTAMP_LOCK_PID=1 stands in for a sentinel inherited from an unrelated process: PID-tied, it
# cannot match $$, so the lock is still taken and with-repo-lock.py announces the wait. A plain
# boolean sentinel would silently skip serialization here and print nothing.
setup locked
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
"$DIR/with-repo-lock.py" "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)" sleep 3 &
holder=$!
sleep 0.3
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "WT_RESTAMP_LOCK_PID=1" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
wait "$holder" 2>/dev/null
ck "0" "$RC" "restamp completes once the repo lock is released"
ck_has "waiting for" "$ERR" "a stale sentinel cannot skip repo-lock serialization"

# --- Part 19: finish-detect-mode owner attribution + the exit-4 fast-path round trip (BF-534 criterion 3) ---
DETECT="$DIR/finish-detect-mode.sh"
dm() { # session -> OUT/ERR/RC, runs detect-mode merge from inside $WT
  local sess="$1" errf="$TMP/stderr.txt"
  OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=$sess" "$DETECT" merge 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}
setup detectmode
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1

dm sess-A
ck "4" "$RC" "detect-mode exits 4 on the detached baseline"
ck_has "CORRUPTION_OWNER_IS_ME=1" "$OUT" "owner attribution field set for the stamping session"
ck_has "THIS session" "$ERR" "owner variant names self-rewrite, not a hijack"
ck_has "wt-restamp.sh" "$ERR" "owner variant points at the sanctioned restamp"

dm sess-B
ck "4" "$RC" "detect-mode exits 4 for a foreign session too (verdict never softens)"
ck_has "CORRUPTION_OWNER_IS_ME=0" "$OUT" "owner attribution field cleared for a foreign session"
ck_has "A parallel session likely" "$ERR" "foreign variant keeps the hijack framing"

run sess-A "$WT"
ck "0" "$RC" "owner restamp clears the detachment"
dm sess-A
ck "0" "$RC" "detect-mode passes after the sanctioned restamp (fast-path round trip)"
ck_has "CORRUPTION=0" "$OUT" "post-restamp detection reports a clean identity"

( cd "$WT" && $G checkout -q -b hijacker-branch ) >/dev/null 2>&1
dm sess-A
ck "4" "$RC" "branch swap still exits 4 after a successful restamp"
ck_has "branch-swapped" "$OUT" "branch swap reason surfaces"
ck_has "routes this to recovery" "$ERR" "owner-attributed non-detached reason still names the recovery route"

# --- Part 20: a clobber that lands ON the anchor's value cannot end the audit walk ---
# The foreign reset puts the branch back at exactly the stamped head SHA. A walk bounded by VALUE
# stops at that entry and never sees the commit it dropped; bounding by stamp TIME does not care what
# value the branch was reset to.
setup valuematch
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: value-match work" ) >/dev/null
git -C "$WT" reset -q --hard main
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "reset onto the anchor's own value still refused (exit 5)"
ck_has "W: value-match work" "$ERR" "exit 5 names the commit the value-match walk used to miss"

# --- Part 21: a missing reflog fails CLOSED ---
# Deleting the branch reflog is the cheapest way to erase evidence of a clobber, and it used to leave
# the walk with nothing to report. The window between the stamp and the oldest surviving entry is
# unobservable, so the only sound answer is refusal.
setup noreflog
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
rm -f "$REPO/.git/logs/refs/heads/issue-branch"
run sess-A "$WT"
ck "5" "$RC" "deleted reflog refuses (exit 5)"
ck_has "no post-stamp reflog entry exists" "$ERR" "exit 5 names the unobservable window"

# --- Part 22: a dropped MERGE is caught even though every patch survives ---
# `git cherry` compares patches and merges have none of their own, so a flattening rewrite reads as
# fully patch-preserving while the conflict-resolution record is gone.
setup mergedrop
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$WT" && $G checkout -q -b side && echo x > x.txt && $G add x.txt && $G commit -qm "S: side work" ) >/dev/null
( cd "$WT" && $G checkout -q issue-branch && $G merge -q --no-ff -m "M: merge side into issue-branch" side ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
sideS=$(git -C "$WT" rev-parse side)
workW=$(git -C "$WT" rev-parse issue-branch^1)
( cd "$WT" && $G reset -q --hard main && $G cherry-pick -q "$workW" "$sideS" ) >/dev/null 2>&1
ck "" "$(git -C "$WT" rev-list --merges HEAD | head -1)" "the flattened branch carries no merge commit"
run sess-A "$WT"
ck "5" "$RC" "flattened merge refused (exit 5)"
ck_has "M: merge side into issue-branch" "$ERR" "exit 5 names the dropped merge"
ck_has "merge commits no longer reachable" "$ERR" "exit 5 separates merge loss from patch loss"
run sess-A --acknowledge-lost "$WT"
ck "0" "$RC" "--acknowledge-lost covers a deliberately flattened merge"
ck_has "M: merge side into issue-branch" "$OUT" "acknowledged output lists the merge"

# --- Part 23: /start's resume path must not re-arm the anchor ---
# A resume re-stamps a worktree that already has work. Deriving the anchor from the current tip there
# would retroactively bless whatever moved HEAD since the original stamp — including a clobber.
# The discriminating clobber resets ONTO the anchor's own value: the anchor alone then looks intact,
# so only the preserved ERA keeps the dropped commit inside the audit window.
setup resume
orig_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
orig_era=$(git -C "$WT" config --worktree --get start.stamped-at)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: owner work" ) >/dev/null
git -C "$WT" reset -q --hard "$orig_anchor"
sleep 1   # a real resume happens later; this ages the clobber's entries below a re-armed era
real_start
ck "0" "$RC" "the real /start setup resumes the clobbered worktree"
ck "$orig_anchor" "$(git -C "$WT" config --worktree --get start.head-sha)" "resume stamp preserves the recorded anchor"
ck "$orig_era" "$(git -C "$WT" config --worktree --get start.stamped-at)" "resume stamp preserves the anchor's era"
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "clobber before a resume is still refused afterwards (exit 5)"
ck_has "W: owner work" "$ERR" "exit 5 names the commit the resume would otherwise have hidden"

# Same sequence, era re-armed while the anchor is preserved: the drop falls outside the window and
# the audit sees nothing. This is why the two values may only ever travel together.
setup resumeera
era_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: owner work" ) >/dev/null
git -C "$WT" reset -q --hard "$era_anchor"
sleep 1
resume_stamp_head_only "$WT" "$era_anchor"
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "0" "$RC" "anchor without its era cannot witness the clobber (the pair is indivisible)"

# A hostile reset wipes per-worktree config, which is precisely when a resume must not re-derive the
# stamp: the surviving sidecar still carries it, so the resume has to read through the tier chain.
setup resumewiped
wiped_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: owner work" ) >/dev/null
git -C "$WT" reset -q --hard "$wiped_anchor"
git -C "$WT" config --worktree --unset start.head-sha
git -C "$WT" config --worktree --unset start.stamped-at
git -C "$WT" config --worktree --unset start.baseline-sha
sleep 1
real_start
ck "$wiped_anchor" "$(git -C "$WT" config --worktree --get start.head-sha)" "resume recovers the anchor from the sidecar after a config wipe"
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "config-wiped resume still refuses the clobber (exit 5)"
ck_has "W: owner work" "$ERR" "exit 5 names the commit the wiped config would have lost"

# --- Part 24: detect-mode attributes the owner by ANY of the session's identifiers ---
# The session is running under a DIFFERENT job dir than the one that stamped, and presents the
# stamping id only as CLAUDE_CODE_SESSION_ID — resolving a single id would call the real owner
# foreign and print the hijack framing at it.
setup detectalt ""
JOBDIR="$TMP/detectalt/jobs/sess-J"; mkdir -p "$JOBDIR"
stamp "$WT" "" "$JOBDIR"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OTHERJOB="$TMP/detectalt/jobs/other-job"; mkdir -p "$OTHERJOB"
OUT=$(cd "$WT" && env "CLAUDE_JOB_DIR=$OTHERJOB" "CLAUDE_CODE_SESSION_ID=sess-J" "$DIR/finish-detect-mode.sh" merge 2>"$TMP/stderr.txt"); RC=$?
ck "4" "$RC" "detect-mode still exits 4 for the owner"
ck_has "CORRUPTION_OWNER_IS_ME=1" "$OUT" "owner attributed via an alternate identifier"

# --- Part 25: a long append-only reflog is skipped, not walked commit by commit ---
# Every recorded tip is an ancestor of HEAD, so none can be hiding a dropped commit. Asserted by
# outcome, not by wall clock — timing assertions rot on shared CI.
setup manyentries
for i in $(seq 1 30); do
  ( cd "$WT" && echo "$i" > "f$i.txt" && $G add "f$i.txt" && $G commit -qm "C$i" ) >/dev/null
done
git -C "$WT" config --worktree --unset start.source-branch
ck "30" "$(git -C "$WT" reflog show issue-branch | wc -l | tr -d ' ' | awk '{print $1-1}')" "fixture built a 30-commit reflog"
SHIM="$TMP/manyentries/shim"; mkdir -p "$SHIM"
printf '#!/bin/bash\nfor a in "$@"; do if [ "$a" = "cherry" ]; then echo x >> "%s"; fi; done\nexec %s "$@"\n' \
  "$TMP/cherry-calls" "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
: > "$TMP/cherry-calls"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "PATH=$SHIM:$PATH" "$RESTAMP" "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "a long ancestor-only history restamps cleanly (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "long-history restamp takes the full path"
ck "0" "$(wc -l < "$TMP/cherry-calls" | tr -d ' ')" "ancestor-only tips are skipped without one cherry call"

# --- Part 26: a back-dated reflog entry cannot hide the honest entries below it ---
# GIT_COMMITTER_DATE sets the reflog entry's time, so a clobber can be written to look pre-stamp.
# Scanning the whole reflog (rather than stopping at the first pre-stamp entry) keeps the honest
# entry that recorded the dropped work inside the window.
setup forgeddate
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: back-dated victim" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: source moves on" ) >/dev/null
GIT_COMMITTER_DATE="@1000000000" git -C "$WT" reset -q --hard main
run sess-A "$WT"
ck "5" "$RC" "back-dated clobber entry refused (exit 5)"
ck_has "W: back-dated victim" "$ERR" "exit 5 still names the dropped commit"

# --- Part 27: a stamp time pushed into the future collects nothing, and that is refusal ---
# With the sidecars stripped the seizable config tier is the identity, so a forged stamped-at puts
# every real entry outside the window. Under an honest reflog a moved HEAD always leaves one.
setup forgedera
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
rm -f "$REPO/.claude/worktree-identity/wt-identity-test-1.env"
git -C "$WT" config --worktree start.stamped-at 9999999999
run sess-A "$WT"
ck "5" "$RC" "future-dated stamp time refused (exit 5)"
ck_has "no post-stamp reflog entry exists" "$ERR" "exit 5 names the unobservable window"

# --- Part 28: a non-numeric stamp time refuses cleanly, without shell noise ---
setup badera
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
rm -f "$REPO/.claude/worktree-identity/wt-identity-test-1.env"
git -C "$WT" config --worktree start.stamped-at "not-a-number"
run sess-A "$WT"
ck "5" "$RC" "non-numeric stamp time refused (exit 5)"
ck_has "no usable stamp time" "$ERR" "exit 5 names the unusable stamp time"
ck "0" "$(printf '%s' "$ERR" | grep -c 'integer expression expected' || true)" "no raw shell errors on stderr"
git -C "$WT" config --worktree start.stamped-at 99999999999999999999999999
run sess-A "$WT"
ck "5" "$RC" "out-of-range stamp time refused (exit 5)"
ck "0" "$(printf '%s' "$ERR" | grep -c 'integer expression expected' || true)" "out-of-range value produces no shell errors either"

# --- Part 29: dominated anchors collapse instead of being audited one by one ---
# A detaching rebase leaves every pre-rebase tip off HEAD's lineage, so the per-anchor ancestor skip
# cannot help — only the maximal-element collapse keeps the cost flat.
setup collapse
for i in $(seq 1 40); do
  ( cd "$WT" && echo "$i" > "f$i.txt" && $G add "f$i.txt" && $G commit -qm "C$i" ) >/dev/null
done
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
SHIM="$TMP/collapse/shim"; mkdir -p "$SHIM"
printf '#!/bin/bash\nfor a in "$@"; do if [ "$a" = "cherry" ]; then echo x >> "%s"; fi; done\nexec %s "$@"\n' \
  "$TMP/collapse-cherry" "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
: > "$TMP/collapse-cherry"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "PATH=$SHIM:$PATH" "$RESTAMP" "$WT" 2>/dev/null); RC=$?
calls=$(wc -l < "$TMP/collapse-cherry" | tr -d ' ')
ck "0" "$RC" "a detached 40-commit history restamps cleanly (exit 0)"
ck "RESTAMP=ok" "$(echo "$OUT" | head -1)" "detached long-history restamp takes the full path"
ck "yes" "$([ "$calls" -le 2 ] && echo yes || echo "no ($calls calls)")" "41 dominated anchors collapse to at most 2 cherry calls"

# --- Part 30: ATTACH re-stamps existing history and must inherit its era too ---
# The worktree dir is gone but the branch survived, so /start re-attaches it. That is a resume of
# real history: deriving a fresh era there hides everything that happened to the branch while the
# directory was away — including the branch -f that dropped a commit.
setup attachlaunder
attach_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
attach_era=$(git -C "$WT" config --worktree --get start.stamped-at)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work lost to branch -f" ) >/dev/null
git -C "$REPO" worktree remove --force "$WT"
git -C "$REPO" worktree prune
git -C "$REPO" branch -f issue-branch "$attach_anchor"   # foreign: drops W while the dir is away
sleep 1
real_start
ck "0" "$RC" "the real /start setup attaches the surviving branch"
ck "$attach_era" "$(git -C "$WT" config --worktree --get start.stamped-at)" "attach inherits the era from the surviving sidecar"
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "clobber during an attach window is still refused (exit 5)"
ck_has "W: work lost to branch -f" "$ERR" "exit 5 names the commit dropped while the worktree was gone"

# --- Part 31: a stale job-dir sidecar must not revert a legitimately advanced baseline ---
# The two job dirs share a basename so ownership still resolves; only the sidecar CONTENT differs.
# Baseline is the one field read config-first, because config is rewritten latest-wins on every stamp.
setup stalesidecar
JOB1="$TMP/stalesidecar/a/sess-A"; JOB2="$TMP/stalesidecar/b/sess-A"
mkdir -p "$JOB1" "$JOB2"
cp "$REPO/.claude/worktree-identity/wt-identity-test-1.env" "$JOB1/"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB2" "$RESTAMP" "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "the legitimate restamp advances the identity"
advanced=$(git -C "$WT" config --worktree --get start.baseline-sha)
stale_base=$(sed -n 's/^WT_IDENTITY_BASELINE_SHA=//p' "$JOB1/wt-identity-test-1.env" | head -1)
ck "yes" "$([ "$stale_base" != "$advanced" ] && echo yes || echo no)" "the original job-dir sidecar is now stale"
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "resume under the original job dir succeeds"
ck "$advanced" "$(git -C "$WT" config --worktree --get start.baseline-sha)" "resume keeps the advanced baseline (stale sidecar does not revert it)"
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$DIR/finish-detect-mode.sh" merge 2>/dev/null); RC=$?
ck "0" "$RC" "detect-mode still reports a healthy worktree after the resume"

# --- Part 32: half a pair is not a pair ---
# The tier carries a head-sha but no era. Mixing it with config's era yields an anchor and a window
# that describe different stamps — here the mixed anchor is patch-equivalent to HEAD and witnesses
# nothing, while the config pair's anchor still holds the dropped commit.
setup pairsplice
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
sleep 1   # age the rebase entry below the restamp's era, so ONLY the anchor can witness that work
run sess-A "$WT"
ck "0" "$RC" "the legitimate restamp re-anchors on the rebased tip"
git -C "$WT" reset -q --hard main          # foreign: drops the rebased work
sleep 1
SPLICED="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v '^WT_IDENTITY_STAMPED_AT=' "$SPLICED" \
  | sed "s#^WT_IDENTITY_HEAD_SHA=.*#WT_IDENTITY_HEAD_SHA=$(git -C "$WT" rev-parse main)#" > "$SPLICED.x"
mv "$SPLICED.x" "$SPLICED"
real_start
ck "0" "$RC" "resume succeeds against a half-populated tier"
( cd "$REPO" && $G commit -q --amend -m "B2: source rewritten again" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "config pair still witnesses the drop (exit 5)"
ck_has "W: work" "$ERR" "exit 5 names the commit the spliced anchor would have missed"

# --- Part 33: a destroyed identity is announced, not silently re-armed ---
setup destroyed
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: unprotected work" ) >/dev/null
rm -f "$REPO/.claude/worktree-identity/wt-identity-test-1.env"
for k in start.head-sha start.stamped-at start.baseline-sha start.worktree-branch start.owner-session; do
  git -C "$WT" config --worktree --unset "$k" 2>/dev/null || true
done
real_start
ck "0" "$RC" "a destroyed identity still resumes (refusing would strand recoveries)"
ck_has "no rewrite anchor to inherit" "$ERR" "the destroyed identity is announced on stderr"

# --- Part 34: an identity that loads but carries no anchor pair still announces the new era ---
# A legacy stamp (branch + baseline, no anchor/era) satisfies wt_identity_load, so keying the warning
# on the load failing lets exactly this case re-arm in silence.
setup legacypair
git -C "$WT" config --worktree --unset start.head-sha
git -C "$WT" config --worktree --unset start.stamped-at
LEGACY_TIER="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v -e '^WT_IDENTITY_HEAD_SHA=' -e '^WT_IDENTITY_STAMPED_AT=' "$LEGACY_TIER" > "$LEGACY_TIER.x"
mv "$LEGACY_TIER.x" "$LEGACY_TIER"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "5" "$RC" "a pair-less identity cannot authorize a rewrite (exit 5)"
real_start
ck "0" "$RC" "a pair-less worktree still resumes"
ck_has "no rewrite anchor to inherit" "$ERR" "the pair-less resume announces its new era"

# --- Part 35: the announcement does not depend on the branch carrying commits ---
# A branch sitting back at its fork point with no identity is MORE anomalous, not less: whatever was
# reset away exists only in the reflog now.
setup destroyedfork
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: reset away" ) >/dev/null
rm -f "$REPO/.claude/worktree-identity/wt-identity-test-1.env"
for k in start.head-sha start.stamped-at start.baseline-sha start.worktree-branch start.owner-session; do
  git -C "$WT" config --worktree --unset "$k" 2>/dev/null || true
done
git -C "$WT" reset -q --hard main
ck "0" "$(git -C "$WT" rev-list --count "$(git -C "$WT" merge-base issue-branch main)..issue-branch")" "the fixture branch carries no commits"
real_start
ck_has "no rewrite anchor to inherit" "$ERR" "a destroyed identity at the fork point still warns"

# --- Part 36: an acknowledged drop stays acknowledged across a resume ---
# The original job dir's sidecar still holds the pre-acknowledgement anchor. Re-inheriting it would
# re-open drops the user already accepted and refuse an untouched worktree.
setup ackresume
JOB1="$TMP/ackresume/a/sess-A"; JOB2="$TMP/ackresume/b/sess-A"
mkdir -p "$JOB1" "$JOB2"
cp "$REPO/.claude/worktree-identity/wt-identity-test-1.env" "$JOB1/"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: acknowledged work" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: source moves on" ) >/dev/null
git -C "$WT" reset -q --hard main
sleep 1   # age the drop below the era the acknowledgement establishes, as real elapsed time would
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB2" "$RESTAMP" --acknowledge-lost "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "the drop is acknowledged under the second job dir"
ck_has "W: acknowledged work" "$OUT" "the acknowledgement names the dropped commit"
ack_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "$ack_anchor" "$(git -C "$WT" config --worktree --get start.head-sha)" "resume keeps the acknowledged anchor"
( cd "$REPO" && $G commit -q --amend -m "B2: source rewritten again" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "0" "$RC" "the next rewrite is not re-litigated (exit 0)"
ck "0" "$(printf '%s' "$ERR" | grep -c 'W: acknowledged work' || true)" "the acknowledged commit is never named again"

# --- Part 37: a squash is audited even though it never moves the merge-base ---
# Keying the short-circuit on the baseline skips the audit here entirely, and with it any
# --acknowledge-lost the caller passed.
setup squash
( cd "$WT" && echo w1 > w1.txt && $G add w1.txt && $G commit -qm "W1: wip one" ) >/dev/null
( cd "$WT" && echo w2 > w2.txt && $G add w2.txt && $G commit -qm "W2: wip two" ) >/dev/null
git -C "$WT" reset -q --soft "$(git -C "$WT" merge-base issue-branch main)"
( cd "$WT" && $G commit -qm "S: squashed" ) >/dev/null
ck "$(git -C "$WT" config --worktree --get start.baseline-sha)" "$(git -C "$WT" merge-base issue-branch main)" "the squash left the baseline untouched"
run sess-A "$WT"
ck "5" "$RC" "the squash is audited, not short-circuited (exit 5)"
ck_has "W1: wip one" "$ERR" "exit 5 names the squashed-away commits"
run sess-A --acknowledge-lost "$WT"
ck "0" "$RC" "an acknowledged squash restamps (exit 0)"
ck_has "ACKNOWLEDGED_LOST=" "$OUT" "the acknowledged squash lists what it dropped"
ck "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" config --worktree --get start.head-sha)" "the acknowledged squash advances the anchor"
run sess-A "$WT"
ck "RESTAMP=noop" "$(echo "$OUT" | head -1)" "the following restamp is a noop"

# --- Part 38: an unmoved branch needs no reflog at all ---
setup unmovednoreflog
rm -f "$REPO/.git/logs/refs/heads/issue-branch"
run sess-A "$WT"
ck "0" "$RC" "HEAD still at the anchor noops without a reflog (exit 0)"
ck "RESTAMP=noop" "$(echo "$OUT" | head -1)" "the unmoved branch reports noop"

# --- Part 39: an uncomparable reflog timestamp adds scrutiny, not shell errors ---
# Widths beyond epoch seconds cannot be compared by the shell; the tip is audited rather than judged.
setup badstamp
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
python3 - "$REPO/.git/logs/refs/heads/issue-branch" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
head, msg = lines[-1].split("\t", 1)
fields = head.split(" ")
fields[-2] = "18446744073709551615"
lines[-1] = " ".join(fields) + "\t" + msg
open(path, "w").write("\n".join(lines) + "\n")
PY
SHIM="$TMP/badstamp/shim"; mkdir -p "$SHIM"
printf '#!/bin/bash\nfor a in "$@"; do if [ "$a" = "cherry" ]; then echo x >> "%s"; fi; done\nexec %s "$@"\n' \
  "$TMP/badstamp-cherry" "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
: > "$TMP/badstamp-cherry"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "PATH=$SHIM:$PATH" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "0" "$RC" "an uncomparable reflog timestamp does not break the restamp (exit 0)"
ck "0" "$(printf '%s' "$ERR" | grep -c 'integer expression expected' || true)" "no shell errors from the corrupt timestamp"
ck "yes" "$([ "$(wc -l < "$TMP/badstamp-cherry" | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "the uncomparable entry's tip is audited"

# --- Part 40: a stale sidecar loses to a newer one, whatever tier it sits in ---
# The identity advances under a second job dir, so this session's own job-dir copy is now the OLD
# one. Attaching under it must not drag the worktree back to the identity it remembers.
setup staleattach
JOB1="$TMP/staleattach/a/sess-A"; JOB2="$TMP/staleattach/b/sess-A"
mkdir -p "$JOB1" "$JOB2"
cp "$REPO/.claude/worktree-identity/wt-identity-test-1.env" "$JOB1/"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
sleep 1   # the advancing stamp must land in a later second, or the two sidecars tie on era
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB2" "$RESTAMP" "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "the identity advances under the second job dir"
adv_base=$(git -C "$WT" config --worktree --get start.baseline-sha)
adv_anchor=$(git -C "$WT" config --worktree --get start.head-sha)
git -C "$REPO" worktree remove --force "$WT"
git -C "$REPO" worktree prune
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "0" "$RC" "attaching under the stale job dir succeeds"
ck "0" "$(printf '%s' "$ERR" | grep -c 'no rewrite anchor to inherit' || true)" "the newer tier is inherited directly, not rejected and re-derived"
ck "$adv_base" "$(git -C "$WT" config --worktree --get start.baseline-sha)" "attach keeps the advanced baseline"
ck "$adv_anchor" "$(git -C "$WT" config --worktree --get start.head-sha)" "attach keeps the advanced anchor"
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$DIR/finish-detect-mode.sh" merge 2>/dev/null); RC=$?
ck "0" "$RC" "detect-mode reports a healthy worktree after the stale-tier attach"

# --- Part 41: the same recency rule protects a restamp with no resume in between ---
# wt-restamp.sh reads its anchor through the same loader, so a stale job dir must not re-open an
# acknowledged drop even when nothing re-stamps the worktree first.
setup staledirect
JOB1="$TMP/staledirect/a/sess-A"; JOB2="$TMP/staledirect/b/sess-A"
mkdir -p "$JOB1" "$JOB2"
cp "$REPO/.claude/worktree-identity/wt-identity-test-1.env" "$JOB1/"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: acknowledged work" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: source moves on" ) >/dev/null
git -C "$WT" reset -q --hard main
sleep 1
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB2" "$RESTAMP" --acknowledge-lost "$WT" 2>/dev/null); RC=$?
ck "0" "$RC" "the drop is acknowledged under the second job dir"
( cd "$REPO" && $G commit -q --amend -m "B2: source rewritten again" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$JOB1" "$RESTAMP" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "0" "$RC" "restamping under the stale job dir is not re-litigated (exit 0)"
ck "0" "$(printf '%s' "$ERR" | grep -c 'W: acknowledged work' || true)" "the acknowledged commit is not named again"

# --- Part 42: --acknowledge-lost is never a noop ---
# The branch was reset back onto the anchor, so nothing "moved" by the short-circuit's measure — but
# the reflog still holds the dropped commit, and the caller asked for it to be recorded.
setup ackatanchor
ack_anchor2=$(git -C "$WT" config --worktree --get start.head-sha)
ack_era2=$(git -C "$WT" config --worktree --get start.stamped-at)
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: dropped at anchor" ) >/dev/null
git -C "$WT" reset -q --hard "$ack_anchor2"
run sess-A "$WT"
ck "RESTAMP=noop" "$(echo "$OUT" | head -1)" "a plain run at the anchor still noops"
ck "$ack_anchor2" "$(git -C "$WT" config --worktree --get start.head-sha)" "the noop leaves the anchor untouched"
ck "$ack_era2" "$(git -C "$WT" config --worktree --get start.stamped-at)" "the noop leaves the era untouched"
sleep 1   # the era this run writes must be strictly newer than the drop it acknowledges
run sess-A --acknowledge-lost "$WT"
ck "0" "$RC" "the acknowledged run at the anchor succeeds"
ck_has "ACKNOWLEDGED_LOST=" "$OUT" "the acknowledged run records the drop"
ck_has "W: dropped at anchor" "$OUT" "the acknowledged run names the dropped commit"
ck "yes" "$([ "$(git -C "$WT" config --worktree --get start.stamped-at)" -gt "$ack_era2" ] && echo yes || echo no)" "the acknowledged run advances the era"
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
run sess-A "$WT"
ck "0" "$RC" "the next rewrite is clean once the drop is acknowledged"

# --- Part 43: a legacy stamp may only claim "unchanged" when the branch truly never moved ---
setup legacymoved
git -C "$WT" config --worktree --unset start.head-sha
git -C "$WT" config --worktree --unset start.stamped-at
LEG="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v -e '^WT_IDENTITY_HEAD_SHA=' -e '^WT_IDENTITY_STAMPED_AT=' "$LEG" > "$LEG.x"; mv "$LEG.x" "$LEG"
run sess-A "$WT"
ck "RESTAMP=noop" "$(echo "$OUT" | head -1)" "an unmoved legacy worktree still noops"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
git -C "$WT" reset -q --hard main          # movement the legacy stamp cannot audit, baseline unchanged
run sess-A "$WT"
ck "5" "$RC" "a moved legacy worktree refuses instead of reporting noop (exit 5)"
ck_has "records no rewrite anchor" "$ERR" "the refusal is honest about why"

# --- Part 44: a baseline that no longer descends to HEAD is inherited, never quietly discarded ---
# Discarding it here would re-derive a healthy-looking baseline and erase the very signal /finish
# raises exit 4 on. The resume carries it through unchanged and detection makes the call.
setup badbaseline
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G branch -q side main~1 && $G checkout -q side && echo s > s.txt && $G add s.txt && $G commit -qm "S: unrelated" && $G checkout -q main ) >/dev/null 2>&1
foreign=$(git -C "$REPO" rev-parse side)
git -C "$WT" config --worktree start.baseline-sha "$foreign"
BAD="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
sed "s#^WT_IDENTITY_BASELINE_SHA=.*#WT_IDENTITY_BASELINE_SHA=$foreign#" "$BAD" > "$BAD.x"; mv "$BAD.x" "$BAD"
real_start
ck "0" "$RC" "a worktree with a non-descending baseline still resumes"
ck "$foreign" "$(git -C "$WT" config --worktree --get start.baseline-sha)" "the non-descending baseline is inherited verbatim"
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "$DIR/finish-detect-mode.sh" merge 2>/dev/null); RC=$?
ck "4" "$RC" "detection still flags it downstream (exit 4)"
ck_has "CORRUPTION_REASON=baseline-detached" "$OUT" "the flag names the detached baseline"

# --- Part 45: a resume never launders a hijack that detection had already caught ---
# Config is left INTACT here, so nothing about the resume looks anomalous — the only thing standing
# between the foreign reset and a clean merge is that the recorded baseline survives the resume.
setup nolaunder
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
git -C "$WT" reset -q --hard main          # foreign: onto a lineage the stamped baseline predates
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "$DIR/finish-detect-mode.sh" merge 2>/dev/null); RC=$?
ck "4" "$RC" "detection catches the foreign reset before the resume"
real_start
ck "0" "$RC" "the worktree resumes"
OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=sess-A" "$DIR/finish-detect-mode.sh" merge 2>/dev/null); RC=$?
ck "4" "$RC" "detection STILL catches it after the resume (no laundering)"
ck_has "CORRUPTION_REASON=baseline-detached" "$OUT" "the post-resume reason is unchanged"

# --- Part 46: no reflog at all is no record, not proof of stillness ---
# A legacy stamp cannot tell "never moved" from "movement no longer recorded", and only the first
# earns a noop.
setup legacynoreflog
git -C "$WT" config --worktree --unset start.head-sha
git -C "$WT" config --worktree --unset start.stamped-at
LEGNR="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v -e '^WT_IDENTITY_HEAD_SHA=' -e '^WT_IDENTITY_STAMPED_AT=' "$LEGNR" > "$LEGNR.x"; mv "$LEGNR.x" "$LEGNR"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
git -C "$REPO" config core.logAllRefUpdates false
git -C "$WT" reset -q --hard main          # drops the commit; baseline unchanged
rm -rf "$REPO/.git/logs"
ck "0" "$(git -C "$WT" reflog show issue-branch 2>/dev/null | wc -l | tr -d ' ')" "the fixture leaves no reflog record"
run sess-A "$WT"
ck "5" "$RC" "a legacy stamp with no reflog refuses instead of claiming noop (exit 5)"
ck_has "no reflog" "$ERR" "the refusal names the missing record"

# --- Part 47: one reflog entry is only stillness if it is the entry that created the branch ---
# Partial expiry can leave a lone MOVEMENT entry, which counts the same as a creation entry by
# arithmetic alone — and that entry is the record of the clobber itself.
setup legacytrimmed
git -C "$WT" config --worktree --unset start.head-sha
git -C "$WT" config --worktree --unset start.stamped-at
LEGT="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
grep -v -e '^WT_IDENTITY_HEAD_SHA=' -e '^WT_IDENTITY_STAMPED_AT=' "$LEGT" > "$LEGT.x"; mv "$LEGT.x" "$LEGT"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
git -C "$WT" reset -q --hard main
( cd "$WT" && echo f > f.txt && $G add f.txt && $G commit -qm "F: foreign work" ) >/dev/null
tail -1 "$REPO/.git/logs/refs/heads/issue-branch" > "$TMP/trimmed"
mv "$TMP/trimmed" "$REPO/.git/logs/refs/heads/issue-branch"
ck "1" "$(git -C "$WT" reflog show issue-branch | wc -l | tr -d ' ')" "the fixture leaves exactly one reflog entry"
ck "yes" "$(git -C "$WT" reflog show --format='%gs' issue-branch | head -1 | grep -qv '^branch: Created' && echo yes || echo no)" "and that entry records movement, not creation"
run sess-A "$WT"
ck "5" "$RC" "a lone movement entry is not mistaken for stillness (exit 5)"
ck_has "records no rewrite anchor" "$ERR" "the refusal explains the legacy stamp cannot audit it"

echo "----------------------------------------"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
