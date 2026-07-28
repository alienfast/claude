#!/usr/bin/env bash
# Functional suite for wt-disown.sh (and the wt-identity.sh release path it drives). Builds throwaway
# repos + linked worktrees in a temp dir and drives the real scripts end to end — every case therefore
# also exercises the with-repo-lock.py re-exec, since that is unconditional.
#
# A LIVE owner is simulated with a background `node` sleeper stamped via CLAUDE_HARNESS_PID: `node` is
# in wt_owner_alive's comm allowlist and its pid+start-time round-trips exactly like a real harness. A
# DEAD owner is the same sleeper, stamped while alive and then killed and reaped.
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
# One case makes a directory unwritable on purpose; restore before rm. Kill sleeper nodes first. INT/TERM
# are trapped as well as EXIT: each spawn_live leaves a 600s node behind, so an interrupted run would
# otherwise leak every one of them plus $TMP.
trap '[ -n "$LIVE_PIDS" ] && kill $LIVE_PIDS 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

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

# Block until <pid> has really exec'd node. Two fixture hazards live in the fork window, and both are silent:
# a kill delivered there signals a COPY of this shell, which then runs this script's traps (deleting $TMP) and
# resumes the suite from the fork point; and a stamp taken there records comm=bash, which wt_owner_alive reads
# as a dead owner. `ps` costs a fork of its own, so this almost never sleeps.
await_node() { # pid
  local i=0 comm
  while [ "$i" -lt 500 ]; do
    comm=$(ps -o comm= -p "$1" 2>/dev/null | tail -1)
    case "$comm" in *node*) return 0 ;; esac
    i=$((i + 1))
    sleep 0.02
  done
  return 1
}

LIVE=""
spawn_live() { # a pid wt_owner_alive will adjudicate as a live harness
  node -e 'setTimeout(function () {}, 600000)' &
  LIVE=$!
  LIVE_PIDS="$LIVE_PIDS $LIVE"
  await_node "$LIVE"
  disown "$LIVE" 2>/dev/null || true   # out of the job table, so the trap's kill stays silent
}
DEAD=""
# Two phases so the stamp runs while the process is still ALIVE and records its start time. Killing it
# first left owner-pid-start empty, and the "dead" verdict then rested entirely on `ps` finding nothing:
# a recycled pid landing on any allowlisted comm flips the fixture to alive. With the pair recorded, the
# start-time mismatch settles it regardless of what inherits the pid.
spawn_dead() { # a pid to stamp while it still lives
  node -e 'setTimeout(function () {}, 600000)' &
  DEAD=$!
  LIVE_PIDS="$LIVE_PIDS $DEAD"   # an INT before reap_dead would otherwise leak the 600s sleeper
  await_node "$DEAD"
}
# The pid leaves the trap's kill list the instant it is reaped: this OS recycles pids, and a run forks enough
# processes to wrap the space, so a reaped pid held in that list is a signal aimed at whatever inherits it next.
reap_dead() { # ...and now positive evidence of death: exited and reaped
  local keep="" p
  kill "$DEAD" 2>/dev/null || true
  wait "$DEAD" 2>/dev/null || true
  for p in $LIVE_PIDS; do [ "$p" = "$DEAD" ] || keep="$keep $p"; done
  LIVE_PIDS="$keep"
}

stamp() { # wt_dir session_id [harness_pid]
  local wt="$1" sess="$2" hpid="${3-}" body
  body="set -e; . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    wt_identity_stamp '$wt' '$wt' test-1 issue-branch main \"\$base\" >/dev/null"
  if [ -n "$hpid" ]; then env "CLAUDE_SESSION_ID=$sess" "CLAUDE_HARNESS_PID=$hpid" bash -c "$body"
  else env "CLAUDE_SESSION_ID=$sess" bash -c "$body"; fi
}

# A THREE-tier stamp. The job dir has to exist first: wt_identity_stamp silently skips a missing one,
# which would quietly reduce a three-tier fixture to two and leave the case passing for the wrong reason.
stamp_job() { # wt_dir session harness_pid job_dir
  mkdir -p "$4"
  ( export CLAUDE_JOB_DIR="$4"; stamp "$1" "$2" "$3" )
}

# Rewrite one sidecar's recorded owner pid in place. No real stamp ever writes a pid that disagrees with the
# config it wrote in the same call; the divergence exists only so an assertion can name WHICH tier a resolved
# pid came from.
set_sidecar_pid() { # file pid
  local f="$1" p="$2"
  sed "s/^WT_IDENTITY_OWNER_PID=.*/WT_IDENTITY_OWNER_PID=$p/" "$f" > "$f.new" && mv "$f.new" "$f"
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

# One WTID_* global on $WT as a fresh process sees it. Tier arbitration happens inside the load, so the
# read has to run in a subshell that re-sources the library — otherwise a losing tier's values linger here.
probe() { # job_dir field
  env "CLAUDE_JOB_DIR=$1" bash -c ". '$IDLIB'; wt_identity_load '$WT' >/dev/null 2>&1; printf '%s' \"\$$2\""
}
owner_probe() { # job_dir field — the same read, taken through the ownership adjudicator
  env "CLAUDE_JOB_DIR=$1" bash -c ". '$IDLIB'; wt_owner_alive '$WT' >/dev/null 2>&1; printf '%s' \"\$$2\""
}
stderr_of() { # job_dir -> everything the load writes to stderr
  env "CLAUDE_JOB_DIR=$1" bash -c ". '$IDLIB'; wt_identity_load '$WT' >/dev/null" 2>&1
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
# The fixture's whole value is this pair: stamped while the owner still LIVED, so the death verdict rests on a
# start-time mismatch and not merely on `ps` finding nothing. Stamp a corpse instead and owner-pid-start comes
# out empty, at which point any recycled pid landing on an allowlisted comm flips the fixture back to alive.
ck "1" "$([ -n "$(cfg start.owner-pid-start)" ] && echo 1 || echo 0)" "the dead-owner fixture recorded a start time while the owner was alive"
reap_dead

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

# --- Part 8: a partial write fails loudly, and the release it reports is nonetheless real ---
# The config unset + released-at land while the sidecar rewrite is blocked. Ownership is read from config, so the
# worktree IS released — the non-zero exit reports INCONSISTENT TIERS for the operator to repair, never a withheld
# release. The stale tier's own hazard (a pre-takeover released-at reporting a re-claimed live worktree as up for
# grabs) is closed from the other side: every takeover re-stamp unsets released-at in the tier ownership reads.
spawn_live
setup partialdisown sess-A "$LIVE"
chmod a-w "$REPO/.claude/worktree-identity"

drun sess-A "$WT"
ck "2" "$RC" "unwritable sidecar tier fails the disown (exit 2)"
ck_has "sidecar" "$ERR" "failure names the sidecar tier"
ck "released" "$(owner_field OWNER_ALIVE)" "the half-written disown still released the worktree"

real_start sess-B
ck "0" "$RC" "a truthfully released worktree is reusable even though one tier is stale (exit 0)"
ck "sess-B" "$(cfg start.owner-session)" "the takeover re-stamped ownership to the resumer"
ck "" "$(cfg start.owner-released-at)" "the takeover revoked the release marker the stale tier still carries"
chmod -R u+rwx "$REPO/.claude/worktree-identity" 2>/dev/null || true

# --- Part 9: a lone git-config write DOES seize ownership, and cannot do it quietly ---
# ACCEPTED TRADEOFF, not an unnoticed regression. Ownership is config-authoritative because it is inherently
# latest-wins and corroboration cannot supply recency — which is how a takeover used to be outvoted and TWO
# SESSIONS ended up in one worktree. The price is that one config write locks the true owner out; that harm is
# recoverable (the work survives, audited) and the other is not. What makes it payable is that the two surviving
# tiers still corroborate a DIFFERENT owner and every operator-facing stream says so: with three tiers seeded the
# load itself stays silent (2 of 3 agree, so its dissent WARN never fires), and the only readers of that fact are
# wt-owner.sh's emitted CORROBORATION/TIER_DISSENT and the exit-4 refusal text — neither may be softened.
spawn_live
setup seize sess-A "$LIVE"
SEIZE_JOB="$TMP/seize/job/sess-A"
stamp_job "$WT" sess-A "$LIVE" "$SEIZE_JOB"
ck "3/3" "$(probe "$SEIZE_JOB" WTID_CORROBORATION)" "the seize fixture really seeds all three tiers"

# The sidecars are moved off A's live pid so the resolved tuple names the tier it came from: with every tier
# carrying one pid, a resolver splicing config's session id onto a sidecar's pid would read identically.
spawn_dead
reap_dead
set_sidecar_pid "$SIDE" "$DEAD"
set_sidecar_pid "$SEIZE_JOB/wt-identity-test-1.env" "$DEAD"

# Only the session id is rewritten, so the claim stays pointed at A's LIVE process. That is what locks A out —
# a seizure that also planted a dead pid would merely orphan the worktree, which /start lets anyone resume.
git -C "$WT" config --worktree start.owner-session sess-EVIL
ck "sess-EVIL" "$(owner_probe "$SEIZE_JOB" WTID_OWNER_SESSION)" "the lone config write takes the owner tuple"
ck "$LIVE" "$(owner_probe "$SEIZE_JOB" WTID_OWNER_PID)" "the tuple moves whole: the pid is config's, not the dead one both sidecars carry"
ck "alive" "$(owner_probe "$SEIZE_JOB" WTID_OWNER_ALIVE)" "and the seized claim reads as a live one"
seize_report=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$SEIZE_JOB" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "0" "$(printf '%s\n' "$seize_report" | sed -n 's/^OWNER_IS_ME=//p')" \
  "the true owner is locked out of its own worktree (OWNER_IS_ME=0)"
ck "git-config" "$(printf '%s\n' "$seize_report" | sed -n 's/^TIER_DISSENT=//p')" "wt-owner.sh names the seized tier to whoever reads the report"
ck "2/3" "$(printf '%s\n' "$seize_report" | sed -n 's/^CORROBORATION=//p')" "and reports the two sidecars corroborating the other owner"

# A's own /start, from A's own job dir — the seizure's real victim, and the only run where all three tiers are
# visible to the script. real_start would drop CLAUDE_JOB_DIR and reduce the scenario to two tiers, whose
# disagreement the load warns about all by itself; the refusal must carry the dissent without that help.
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$SEIZE_JOB" \
  "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ERR=$(cat "$TMP/stderr.txt")
ck "4" "$RC" "and /start refuses the true owner (exit 4) — lockout, not two sessions in one worktree"
ck "" "$(stderr_of "$SEIZE_JOB")" "the load itself is silent: two of three tiers agree, so nothing warns there"
ck_has "corroboration 2/3, dissenting: git-config" "$ERR" "so the refusal itself has to show the seized tier standing alone"
ck_has "wt-owner.sh" "$ERR" "and point at the report that names the other owner"
ck "git-config" "$(probe "$SEIZE_JOB" WTID_TIER_DISSENT)" "the seized tier is named as the dissenter"
ck "2/3" "$(probe "$SEIZE_JOB" WTID_CORROBORATION)" "the two sidecar tiers still corroborate each other"

# --- Part 10: a dead owner's worktree is still taken over, and the takeover re-corroborates every tier ---
# Corroboration must not harden a worktree against legitimate resumption: a takeover re-stamps all three
# tiers, so the resumer's identity becomes the corroborated one rather than a dissent the next load warns
# about. The resumer proves death from its OWN job dir, with no access to the dead session's.
spawn_dead
setup takeover sess-A "$DEAD"
TAKE_JOB_A="$TMP/takeover/job/sess-A"; TAKE_JOB_B="$TMP/takeover/job/sess-B"
stamp_job "$WT" sess-A "$DEAD" "$TAKE_JOB_A"
reap_dead
mkdir -p "$TAKE_JOB_B"
ck "dead" "$(owner_probe "$TAKE_JOB_B" WTID_OWNER_ALIVE)" "B proves A dead without reading A's job dir"

OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-B" "CLAUDE_JOB_DIR=$TAKE_JOB_B" \
  "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "B takes the worktree over (exit 0)"
ck "sess-B" "$(owner_probe "$TAKE_JOB_B" WTID_OWNER_SESSION)" "ownership is now B's"
ck "3/3" "$(probe "$TAKE_JOB_B" WTID_CORROBORATION)" "the takeover leaves all three tiers agreeing"
ck "" "$(probe "$TAKE_JOB_B" WTID_TIER_DISSENT)" "no tier dissents after the takeover"
ck "" "$(stderr_of "$TAKE_JOB_B")" "a corroborated identity loads in silence"

# --- Part 11: a stale corroborating PAIR cannot tell a dead session it still owns the worktree ---
# The repo-fallback tier goes unwritable (a `git clean` race, a permissions slip) while A is the owner, so
# a later takeover advances only config and B's own job dir. A's two surviving tiers then agree with each
# other perfectly — and they are both A's. Reading ownership from that majority tells A it still owns a
# worktree B is working in RIGHT NOW, and A's /start walks straight into it: two sessions, one worktree.
spawn_dead
setup stalepair sess-A "$DEAD"
PAIR_JOB_A="$TMP/stalepair/job/sess-A"; PAIR_JOB_B="$TMP/stalepair/job/sess-B"
stamp_job "$WT" sess-A "$DEAD" "$PAIR_JOB_A"
reap_dead
chmod a-w "$REPO/.claude/worktree-identity"    # A's repo-fallback tier can no longer follow a takeover
spawn_live
stamp_job "$WT" sess-B "$LIVE" "$PAIR_JOB_B" 2>/dev/null   # B takes over: config and B's job dir advance, the repo tier stays A's

ck "$PAIR_JOB_A/wt-identity-test-1.env" "$(probe "$PAIR_JOB_A" WTID_SIDECAR_PATH)" "the structural winner is A's own stale sidecar"
ck "2/3" "$(probe "$PAIR_JOB_A" WTID_CORROBORATION)" "so the structural majority really is the stale pair"
ck "sess-B" "$(owner_probe "$PAIR_JOB_A" WTID_OWNER_SESSION)" "ownership nonetheless resolves to the session that stamped last"
ck "alive" "$(owner_probe "$PAIR_JOB_A" WTID_OWNER_ALIVE)" "and reads B alive, not A dead"
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$PAIR_JOB_A" \
  "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "4" "$RC" "A's own /start refuses the worktree B is working in (exit 4)"
chmod -R u+rwx "$REPO/.claude/worktree-identity" 2>/dev/null || true

# --- Part 12: a stale released marker cannot report a re-claimed live worktree as up for grabs ---
# Same tier shape reached the other way: A disowns (every tier records the release), the repo tier then
# goes unwritable, and B resumes. Config truthfully says B is claimed and alive while two stale tiers still
# say A/released. `released` is /auto's signal to RESUME a worktree, so believing the stale pair here
# dispatches a second session onto B's live work — the one verdict that must never be inferred from age.
spawn_live
setup falsereleased sess-A "$LIVE"
FR_JOB_A="$TMP/falsereleased/job/sess-A"; FR_JOB_B="$TMP/falsereleased/job/sess-B"
stamp_job "$WT" sess-A "$LIVE" "$FR_JOB_A"
OUT=$(env "CLAUDE_SESSION_ID=sess-A" "CLAUDE_JOB_DIR=$FR_JOB_A" "$DISOWN" "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "A releases the worktree it stamped, across every tier"
chmod a-w "$REPO/.claude/worktree-identity"
spawn_live
stamp_job "$WT" sess-B "$LIVE" "$FR_JOB_B" 2>/dev/null   # B resumes the released worktree; the repo tier cannot follow

ck "1" "$(grep -c '^WT_IDENTITY_OWNER_RELEASED_AT=[0-9]' "$SIDE" || true)" "the blocked repo tier still carries A's release marker"
ck "1" "$(grep -c '^WT_IDENTITY_OWNER_RELEASED_AT=[0-9]' "$FR_JOB_A/wt-identity-test-1.env" || true)" "and so does A's own job-dir tier"
ck "alive" "$(owner_probe "$FR_JOB_A" WTID_OWNER_ALIVE)" "a reader holding both stale tiers still sees B's live claim, not 'released'"
ck "sess-B" "$(owner_probe "$FR_JOB_A" WTID_OWNER_SESSION)" "and attributes the live claim to B"
chmod -R u+rwx "$REPO/.claude/worktree-identity" 2>/dev/null || true

# --- Part 13: wt-owner.sh reports the same owner however the worktree is named ---
# The sidecar filename comes from basename "$wt_dir", so a '.' invocation looked for `wt-identity-..env`,
# found neither sidecar, and answered off the git-config tier alone — an empty owner on exactly the
# worktree whose config was wiped, which automation reads as "nobody is here".
spawn_live
setup relpath sess-A "$LIVE"
REL_JOB="$TMP/relpath/job/sess-A"
stamp_job "$WT" sess-A "$LIVE" "$REL_JOB"
for k in start.owner-session start.owner-pid start.owner-pid-start; do
  git -C "$WT" config --worktree --unset-all "$k" 2>/dev/null || true
done
ck "" "$(cfg start.owner-session)" "the fixture leaves only the sidecars able to answer"
rel_out=$(cd "$WT" && env "CLAUDE_JOB_DIR=$REL_JOB" "$DIR/wt-owner.sh" . 2>/dev/null)
ck "sess-A" "$(printf '%s\n' "$rel_out" | sed -n 's/^OWNER_SESSION=//p')" "a relative '.' resolves the sidecar tier instead of reporting no owner"
ck "alive" "$(printf '%s\n' "$rel_out" | sed -n 's/^OWNER_ALIVE=//p')" "and adjudicates the live owner it found there"

# --- Part 14: an INTERRUPTED stamp's half-written claim is not owner evidence ---
# The owner keys are written in sequence (session, then the release marker cleared, then the pid), so a /start
# killed mid-stamp leaves {session, no pid, no released}. Taken whole that tuple erases a LIVE owner into
# 'unknown', and the reuse guard admits on unknown — a second session walks straight into the worktree. A torn
# tuple must instead fall through to a path-verified sidecar, which still holds the pid config never got.
spawn_live
setup torncfg sess-A "$LIVE"
git -C "$WT" config --worktree --unset start.owner-pid
git -C "$WT" config --worktree --unset start.owner-pid-start

ck "sess-A" "$(cfg start.owner-session)" "the torn claim still names the session"
ck "" "$(cfg start.owner-pid)" "but carries no pid"
ck "" "$(cfg start.owner-released-at)" "and no release marker — the shape only an interrupted stamp leaves"
ck "$LIVE" "$(owner_probe "" WTID_OWNER_PID)" "the pid is completed from the sidecar that has one"
ck "sess-A" "$(owner_probe "" WTID_OWNER_SESSION)" "and the owner is still A"
ck "alive" "$(owner_probe "" WTID_OWNER_ALIVE)" "so A's live claim survives A's own interrupted stamp"
real_start sess-B
ck "4" "$RC" "and /start refuses B the worktree A is live in (exit 4)"

# --- Part 15: a torn claim is completed only from the LATEST session's sidecar ---
# The torn config still carries the NEWEST session id, so only that session's sidecar may complete it.
# Completing from whichever sidecar answers first lets a superseded session's stale one splice its own dead pid
# onto the current claim: B's live worktree then reads as a dead session's leftovers, which /auto resumes.
spawn_dead
setup tornlatest sess-A "$DEAD"
TL_JOB_A="$TMP/tornlatest/job/sess-A"; TL_JOB_B="$TMP/tornlatest/job/sess-B"
stamp_job "$WT" sess-A "$DEAD" "$TL_JOB_A"
reap_dead
spawn_live
stamp_job "$WT" sess-B "$LIVE" "$TL_JOB_B"   # B takes over: config, the repo tier and B's job dir all advance
git -C "$WT" config --worktree --unset start.owner-pid
git -C "$WT" config --worktree --unset start.owner-pid-start

ck "sess-B" "$(cfg start.owner-session)" "the torn claim carries B's session id, the newest one"
ck "sess-B" "$(owner_probe "$TL_JOB_A" WTID_OWNER_SESSION)" "A's own stale sidecar cannot re-claim the worktree"
ck "$LIVE" "$(owner_probe "$TL_JOB_A" WTID_OWNER_PID)" "the completing pid is B's, not the dead one A's sidecar still holds"
ck "alive" "$(owner_probe "$TL_JOB_A" WTID_OWNER_ALIVE)" "so B's live work never reads as a dead session's leftovers"

# --- Part 16: a two-line .env cannot hand an owner to a worktree that carries no identity ---
# A legacy/never-stamped worktree has no config claim at all, which is torn by definition, so the owner
# resolver reaches for sidecars. A file below the readable floor — an owner and a pid, no branch, no baseline,
# no recorded worktree path — must not be a tier: otherwise anything able to write into a job dir can claim a
# worktree it never stamped, and the true resumer is refused entry to it.
w="$TMP/plantedfloor"; REPO="$w/repo"; WT="$w/test-1"
mkdir -p "$w"
git init -q -b main "$REPO"
git -C "$REPO" config extensions.worktreeConfig true
( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
git -C "$REPO" worktree add -q "$WT" -b issue-branch
spawn_live
# The job dir's basename is one of the ids this session presents, so it must NOT be the id the plant claims:
# with both spelled sess-EVIL the planted owner would read as THIS session's own and be admitted either way.
PLANT_JOB="$w/job/sess-C"
mkdir -p "$PLANT_JOB"
printf 'WT_IDENTITY_OWNER=sess-EVIL\nWT_IDENTITY_OWNER_PID=%s\n' "$LIVE" > "$PLANT_JOB/wt-identity-test-1.env"

ck "" "$(owner_probe "$PLANT_JOB" WTID_OWNER_SESSION)" "the planted file supplies no owner"
ck "" "$(owner_probe "$PLANT_JOB" WTID_OWNER_PID)" "and no pid"
ck "unknown" "$(owner_probe "$PLANT_JOB" WTID_OWNER_ALIVE)" "so the unstamped worktree stays unowned rather than claimed by the plant"
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-B" "CLAUDE_JOB_DIR=$PLANT_JOB" \
  "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "and /start still resumes the legacy worktree (exit 0)"

# --- Part 17: wt-owner.sh emits the corroboration pair on every report, dissent or not ---
# /auto's preflight parses this report BY KEY, and a key emitted only when something is wrong is
# indistinguishable from a key whose value is empty. Dropping either one would read as "nothing contested" on
# every contested worktree the run ever meets — the seizure of Part 9 going unread by the only reader it has.
spawn_live
setup dissentreport sess-A "$LIVE"
REP_JOB="$TMP/dissentreport/job/sess-A"
stamp_job "$WT" sess-A "$LIVE" "$REP_JOB"

rep=$(env "CLAUDE_JOB_DIR=$REP_JOB" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "1" "$(printf '%s\n' "$rep" | grep -c '^CORROBORATION=')" "a corroborated report still carries the CORROBORATION key"
ck "1" "$(printf '%s\n' "$rep" | grep -c '^TIER_DISSENT=')" "and the TIER_DISSENT key, empty rather than absent"
ck "3/3" "$(printf '%s\n' "$rep" | sed -n 's/^CORROBORATION=//p')" "all three tiers agree"
ck "" "$(printf '%s\n' "$rep" | sed -n 's/^TIER_DISSENT=//p')" "and none of them dissents"

rm -f "$REP_JOB/wt-identity-test-1.env" "$SIDE"
rep=$(env "CLAUDE_JOB_DIR=$REP_JOB" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "1" "$(printf '%s\n' "$rep" | grep -c '^TIER_DISSENT=')" "a single-tier worktree emits the key too"
ck "1/1" "$(printf '%s\n' "$rep" | sed -n 's/^CORROBORATION=//p')" "with the lone readable tier counted"

# --- Part 18: the structural load publishes no owner claim at all ---
# wt_identity_load arbitrates by corroboration, which cannot establish recency, so its winner's owner fields
# can name a session that was already replaced. Publishing them put that unadjudicated tuple in front of every
# caller that loads an identity — wt-restamp.sh's ownership gate reads exactly these globals — so the load
# scrubs them and only _wtid_resolve_owner may fill them in.
spawn_live
setup scrubowner sess-A "$LIVE"
SCRUB_JOB="$TMP/scrubowner/job/sess-A"
stamp_job "$WT" sess-A "$LIVE" "$SCRUB_JOB"

ck "sess-A" "$(cfg start.owner-session)" "the fixture really does have an owner to publish"
ck "issue-branch" "$(probe "$SCRUB_JOB" WTID_BRANCH)" "the load still returns the structural identity"
for f in WTID_OWNER WTID_OWNER_SESSION WTID_OWNER_PID WTID_OWNER_PID_START WTID_OWNER_RELEASED_AT; do
  ck "" "$(probe "$SCRUB_JOB" "$f")" "the load leaves $f empty"
done
ck "sess-A" "$(owner_probe "$SCRUB_JOB" WTID_OWNER_SESSION)" "only the ownership adjudicator fills the tuple in"

# --- Part 19: admitting a seized worktree is never silent ---
# The reuse guard refuses only on `alive`, so a config seizure carrying a DEAD pid is ADMITTED — the accepted
# risk start-wt-create.sh documents. The WARN is the whole mitigation, and nothing else reports it, so it needs
# a case of its own: deleting it left both suites green when this was first written.
spawn_dead
setup admitwarn sess-A "$DEAD"
reap_dead
git -C "$WT" config --worktree --replace-all start.owner-session sess-Z

real_start sess-B
ck "0" "$RC" "a seized worktree with a dead pid is admitted (exit 0)"
# Both needles are anchored inside the reuse WARN's own sentence: the load emits a SEPARATE no-majority WARN
# carrying the same corroboration ratio and tier name, so a bare "dissenting: git-config" passes with this
# warning deleted.
ck_has "WARN: reusing" "$ERR" "but never silently"
ck_has "owner verdict while identity tiers disagree (corroboration 1/2; dissenting: git-config)" "$ERR" \
  "and names the seized tier as the one out of step"

# --- Part 22: a release leaves no owner-pid-start behind ---
# owner-pid-start is inside the compared fingerprint, so a survivor would leave the worktree permanently
# dissenting from the sidecars the same release DID rewrite — a disown that reports ok while parking its target.
spawn_live
setup relpidstart sess-A "$LIVE"

drun sess-A "$WT"
ck "0" "$RC" "owner disown exits 0"
ck "" "$(cfg start.owner-pid-start)" "and clears owner-pid-start, not just owner-pid"
ck "" "$(owner_field TIER_DISSENT)" "so the released worktree corroborates rather than dissents"


echo
echo "wt-disown: $pass passed, $fail failed"
[ "$fail" = 0 ]
