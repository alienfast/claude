#!/usr/bin/env bash
# Functional suite for wt-disown.sh (and the wt-identity.sh release path it drives). Builds throwaway
# repos + linked worktrees in a temp dir and drives the real scripts end to end — every case therefore
# also exercises the with-repo-lock.py re-exec, since that is unconditional.
#
# A LIVE owner is simulated with a background `node` sleeper stamped via CLAUDE_HARNESS_PID: `node` is
# in wt_owner_alive's comm allowlist and its pid+start-time round-trips exactly like a real harness. A
# DEAD owner is a node process that has already exited and been reaped.
#
# GROW THIS SUITE, NEVER PRUNE IT. wt-disown.sh grants a worktree the right to be RESUMED by a foreign
# session — the counterpart of wt-restamp.sh's merge-rights gate — so every hole ever found in that
# gate has a case below. Add the case WITH the fix; never delete one to "clean up" — a closed hole
# with no live guard is a hole that reopens.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISOWN="$DIR/wt-disown.sh"
RESTAMP="$DIR/wt-restamp.sh"
IDLIB="$DIR/wt-identity.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available — the live/dead owner fixtures need it."
  exit 0
fi

TMP="$(mktemp -d)"
LIVE_PIDS=""
# One case makes a directory unwritable on purpose; restore before rm. Kill sleeper nodes first.
trap '[ -n "$LIVE_PIDS" ] && kill $LIVE_PIDS 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The suite's own session must not leak into ownership/sidecar resolution.
unset CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_HARNESS_PID WT_DISOWN_LOCK_PID WT_RESTAMP_LOCK_PID

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

LIVE=""
spawn_live() { # a pid wt_owner_alive will adjudicate as a live harness
  node -e 'setTimeout(function () {}, 600000)' &
  LIVE=$!
  LIVE_PIDS="$LIVE_PIDS $LIVE"
  disown "$LIVE" 2>/dev/null || true   # out of the job table, so the trap's kill stays silent
}
DEAD=""
spawn_dead() { # a pid with positive evidence of death (exited and reaped)
  node -e '' &
  DEAD=$!
  wait "$DEAD" 2>/dev/null || true
}

stamp() { # wt_dir session_id [harness_pid]
  local wt="$1" sess="$2" hpid="${3-}" body
  body="set -e; . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    wt_identity_stamp '$wt' '$wt' test-1 issue-branch main \"\$base\" >/dev/null"
  if [ -n "$hpid" ]; then env "CLAUDE_SESSION_ID=$sess" "CLAUDE_HARNESS_PID=$hpid" bash -c "$body"
  else env "CLAUDE_SESSION_ID=$sess" bash -c "$body"; fi
}

# Sets REPO, WT, SIDE. The worktree dir is named for the issue, as /start's .claude/worktrees/<issue-lower>
# is — wt_identity_load derives the sidecar name from that basename, so a mismatched fixture would
# silently degrade every case to the weaker git-config-only identity.
setup() { # name [session] [harness_pid]
  local w="$TMP/$1" sess="${2-sess-A}" hpid="${3-}"
  REPO="$w/repo"; WT="$w/test-1"; SIDE=""
  mkdir -p "$w"
  git init -q -b main "$REPO"
  git -C "$REPO" config extensions.worktreeConfig true   # start-wt-setup.sh does this in the real flow
  ( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
  ( cd "$REPO" && echo v1 > main.txt && $G add main.txt && $G commit -qm "A: pre-fork" ) >/dev/null
  git -C "$REPO" worktree add -q "$WT" -b issue-branch
  stamp "$WT" "$sess" "$hpid"
  SIDE="$REPO/.claude/worktree-identity/wt-identity-test-1.env"
}

# The REAL /start setup, invoked exactly as start-wt-setup.sh does (cwd inside the repo, 5 args).
real_start() { # [session] — operates on $REPO/$WT; sets OUT/ERR/RC
  local sess="${1-sess-A}" errf="$TMP/stderr.txt"
  OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=$sess" "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

OUT=""; ERR=""; RC=0; REPO=""; WT=""; SIDE=""
drun() { # session args... -> OUT/ERR/RC
  local sess="$1" errf="$TMP/stderr.txt"; shift
  OUT=$(env "CLAUDE_SESSION_ID=$sess" "$DISOWN" "$@" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}
owner_field() { # key -> value from wt-owner.sh's report on $WT
  "$DIR/wt-owner.sh" "$WT" 2>/dev/null | sed -n "s/^$1=//p"
}
cfg() { # key -> per-worktree config value or empty
  git -C "$WT" config --worktree --get "$1" 2>/dev/null || true
}

# --- Part 1: the BF-525 round trip — live foreign owner blocks, release unblocks, takeover revokes ---
spawn_live
setup roundtrip sess-A "$LIVE"

real_start sess-B
ck "4" "$RC" "live foreign owner refuses reuse (exit 4)"
ck_has "owned by another live session" "$ERR" "refusal names the live-owner mapping"

drun sess-A "$WT"
ck "0" "$RC" "owner disown exits 0"
ck "DISOWN=ok" "$(echo "$OUT" | head -1)" "owner disown reports ok"
ck "released" "$(owner_field OWNER_ALIVE)" "released verdict after disown"
ck "sess-A" "$(owner_field OWNER_SESSION)" "owner-session kept as last-owner attribution"
rel=$(owner_field OWNER_RELEASED_AT)
ck "1" "$([ -n "$rel" ] && echo 1 || echo 0)" "OWNER_RELEASED_AT reported non-empty"

real_start sess-B
ck "0" "$RC" "released worktree falls through to reuse (exit 0)"
ck "sess-B" "$(cfg start.owner-session)" "takeover re-stamped ownership to the resumer"
ck "" "$(cfg start.owner-released-at)" "takeover re-stamp revoked the release marker"

# --- Part 2: a foreign session cannot release a live owner's claim ---
spawn_live
setup foreign sess-A "$LIVE"

drun sess-B "$WT"
ck "3" "$RC" "foreign disown of a live owner refused (exit 3)"
ck_has "sess-A" "$ERR" "refusal names the stamped owner"
ck "$LIVE" "$(cfg start.owner-pid)" "refused disown left the stamped pid untouched"
ck "" "$(cfg start.owner-released-at)" "refused disown wrote no release marker"

# --- Part 3: provable death releases without --force; --force overrides a live foreign owner ---
spawn_dead
setup deadowner sess-A "$DEAD"

drun sess-B "$WT"
ck "0" "$RC" "provably dead owner disowns without --force"
ck "DISOWN=ok" "$(echo "$OUT" | head -1)" "dead-owner disown reports ok"
ck "released" "$(owner_field OWNER_ALIVE)" "dead-owner release adjudicates released"

spawn_live
setup forced sess-A "$LIVE"

drun sess-B "$WT"
ck "3" "$RC" "sanity: live foreign owner still refused without --force"
drun sess-B --force "$WT"
ck "0" "$RC" "--force releases a live foreign owner (the /start stalled-takeover path)"
ck "released" "$(owner_field OWNER_ALIVE)" "forced release adjudicates released"

# --- Part 4: sidecar transform is surgical, and a config wipe still reads released via the sidecar ---
spawn_live
setup sidecar sess-A "$LIVE"

before_identity=$(grep -v '^WT_IDENTITY_OWNER' "$SIDE")
drun sess-A "$WT"
ck "0" "$RC" "owner disown with a repo-fallback sidecar"
after_identity=$(grep -v '^WT_IDENTITY_OWNER' "$SIDE")
ck "$before_identity" "$after_identity" "baseline/head/era sidecar lines byte-identical across disown"
ck "" "$(sed -n 's/^WT_IDENTITY_OWNER_PID=//p' "$SIDE" | head -1)" "sidecar owner pid emptied"
ck "1" "$(grep -c '^WT_IDENTITY_OWNER_RELEASED_AT=' "$SIDE")" "sidecar carries the released key"

git -C "$WT" config --worktree --unset start.owner-session
git -C "$WT" config --worktree --unset start.owner-released-at
ck "released" "$(owner_field OWNER_ALIVE)" "config-wiped worktree still reads released via the repo sidecar"

# --- Part 5: a re-stamp revokes the release and inherits the era (anchor+era undisturbed) ---
spawn_live
setup restampclear sess-A "$LIVE"
head_before=$(cfg start.head-sha)
era_before=$(cfg start.stamped-at)

drun sess-A "$WT"
real_start sess-B
ck "0" "$RC" "takeover after release succeeds"
ck "" "$(cfg start.owner-released-at)" "config release marker cleared by the re-stamp"
ck "" "$(sed -n 's/^WT_IDENTITY_OWNER_RELEASED_AT=//p' "$SIDE" | head -1)" "sidecar release key dropped by the full rewrite"
ck "$head_before" "$(cfg start.head-sha)" "anchor unchanged across release + takeover"
ck "$era_before" "$(cfg start.stamped-at)" "era unchanged across release + takeover"

# --- Part 6: the kept owner-session still passes wt-restamp's gate after a release ---
setup restampgate sess-A
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1

drun sess-A "$WT"
ck "0" "$RC" "owner disown before the sanctioned rewrite"
errf="$TMP/stderr.txt"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "$RESTAMP" "$WT" 2>"$errf"); RC=$?
ERR=$(cat "$errf")
ck "0" "$RC" "kept owner-session passes wt-restamp's session gate after a release"
ck "" "$(cfg start.owner-released-at)" "restamp re-claims: release marker revoked"

# --- Part 7: idempotency — released and never-stamped are noops ---
setup idem sess-A
drun sess-A "$WT"
ck "0" "$RC" "first disown ok"
drun sess-B "$WT"
ck "0" "$RC" "second disown is a noop even for a foreign caller (nothing left to release)"
ck "DISOWN=noop" "$(echo "$OUT" | head -1)" "second disown reports noop"

w="$TMP/nostamp"; REPO="$w/repo"; WT="$w/test-1"
mkdir -p "$w"
git init -q -b main "$REPO"
git -C "$REPO" config extensions.worktreeConfig true
( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
git -C "$REPO" worktree add -q "$WT" -b issue-branch
drun sess-A "$WT"
ck "0" "$RC" "never-stamped worktree is a noop (no claim to release)"
ck "DISOWN=noop" "$(echo "$OUT" | head -1)" "never-stamped disown reports noop"

# --- Part 8: a partial write fails loudly and leaves NO half-open gate ---
# Config unsets land but the sidecar rewrite is blocked: the sidecar still carries the live pid, and
# pid-beats-released precedence means every reader still adjudicates alive — hands-off, never falsely
# resumable. The disown must exit non-zero naming the tier so the caller knows the release didn't take.
spawn_live
setup partial sess-A "$LIVE"
chmod a-w "$REPO/.claude/worktree-identity"

drun sess-A "$WT"
ck "2" "$RC" "unwritable sidecar tier fails the disown (exit 2)"
ck_has "sidecar" "$ERR" "failure names the sidecar tier"

real_start sess-B
ck "4" "$RC" "half-disowned worktree still refuses foreign reuse (pid outranks released-at)"
chmod -R u+rwx "$REPO/.claude/worktree-identity" 2>/dev/null || true

echo
echo "wt-disown: $pass passed, $fail failed"
[ "$fail" = 0 ]
