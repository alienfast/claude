#!/usr/bin/env bash
# Functional suite for wt-disown.sh (and the wt-identity.sh release path it drives). Builds throwaway
# repos + linked worktrees in a temp dir and drives the real scripts end to end — every case therefore
# also exercises the with-repo-lock.py re-exec, since that is unconditional.
#
# A LIVE owner is simulated with a background `node` sleeper stamped via CLAUDE_HARNESS_PID: `node` is
# in wt_owner_alive's comm allowlist and its pid+start-time round-trips exactly like a real harness.
# Only the cases that need that LIVE verdict require node, and they are guarded per case (HAVE_NODE,
# counted skips) rather than by a whole-file skip, which went green having executed nothing. A DEAD
# owner needs no interpreter: a plain `sleep` sleeper is stamped while it still lives (recording a
# genuine start time) and then killed and reaped — the verdict comes from the pid being reaped, never
# from its comm. The same un-reaped sleeper serves the owner-path cases too: wt-disown.sh admits the
# owner by session match without consulting liveness.
#
# GROW THIS SUITE, NEVER PRUNE IT. wt-disown.sh grants a worktree the right to be RESUMED by a foreign
# session — the counterpart of wt-restamp.sh's merge-rights gate — so every hole ever found in that
# gate has a case below. Add the case WITH the fix; never delete one to "clean up" — a closed hole
# with no live guard is a hole that reopens.

# THE ISOLATION PREAMBLE BELOW, AND reclaim_locks WITH IT, ARE DUPLICATED IN THE SIBLING wt-*.test.sh SUITES
# rather than sourced from a shared file — each suite has to stay runnable on its own. The copies are not
# whole-file identical (wt-identity.test.sh carries two guards this suite measured as unnecessary, and each
# file cites its own scores), but every line they DO share is kept byte-identical, reclaim_locks in full.
# Change one and change all three in the same edit — a fix applied to one copy protects only that suite.
#
# Exported shell functions are an environment channel with no variable name of their own, so the prefix sweep
# below cannot reach them: `export -f grep` arrives as an ordinary environment entry bash imports before line
# 1, and a function outranks both the builtin and $PATH — a `grep` that always succeeds turns every ck_has
# into a PASS, and one named `cd` or `export` would subvert the isolation below before it runs. Cleared
# generically rather than by name: this file has defined no function yet, so everything `declare -F` reports
# here arrived from outside. Builtins only, for the same reason. The `2>/dev/null` can only swallow the
# `readonly -f` case, which no environment can reach: a function's readonly attribute is not inherited across
# `exec`, so an imported function is always unsettable (verified — the child's `unset -f` returns 0).
#
# The sweep's own tools sit inside the surface it defends. An exported `declare` makes `declare -F` report
# nothing, so the sweep clears nothing and every other hijack rides straight through it: `declare` and `grep`
# hijacked together score 40 passed / 1 failed here. An exported `unset` then makes `unset -f declare` a no-op
# as well. The three lines below bootstrap out of that, and no COMMAND can be their first step, because any
# command word can be shadowed. A variable assignment cannot be, and assigning $POSIXLY_CORRECT is bash's
# runtime entry into POSIX mode, where special builtins — `unset` among them — are looked up BEFORE functions.
# That makes the next line's `unset -f` the real builtin whatever was imported, and it clears every command the
# bootstrap and the sweep themselves dispatch: `unset`, `builtin`, `declare`, `read`. The backslashes are
# load-bearing, not decoration: POSIX mode also switches `expand_aliases` ON, which would hand an inherited
# alias a window it does not get in a default non-interactive shell, and a backslash-quoted word is never
# alias-expanded, while quoting leaves builtin lookup untouched. Leaving POSIX mode on the third line switches
# `expand_aliases` back off.
#
# The sweep's own test is a `case` rather than the `[ -n "$_l" ]` it would otherwise read as, because `[` is the
# one command here that cannot be protected the same way: POSIX mode rejects `unset -f [` as "not a valid
# identifier". `case` needs none, being a reserved word: the parser takes the compound command before any
# command lookup happens, and bash rejects the env import of a function by that name outright. With `[`, an
# imported `[` that returns non-zero short-circuits the `&&` and the sweep then clears NOTHING: measured
# with `[` and `grep` hijacked together, both were still defined afterwards, where the `case` form clears both.
#
# The sweep runs BEFORE this file's own `set -uo pipefail`, because `set` is a command word like any other: an
# imported `set` that returns 0 leaves both options off for the whole run — 9 passed / 32 failed, measured — and
# an ancestor deciding this gate's shell options is exactly what the preamble exists to prevent. Nothing above
# needs either option, so `set` is swept with the rest and the real builtin is what runs a few lines down.
POSIXLY_CORRECT=1
\unset -f unset builtin declare read 2>/dev/null
\unset POSIXLY_CORRECT
while IFS= read -r _l; do case "$_l" in ?*) unset -f "${_l##* }" 2>/dev/null ;; esac; done <<< "$(builtin declare -F)"
unset _l

set -uo pipefail

# Cleared ahead of the `cd` below, which runs on a RELATIVE path: package.json invokes this suite as
# `scripts/wt-disown.test.sh`, so `dirname` yields a bare `scripts` and $CDPATH sends that `cd` elsewhere
# while echoing where it landed, leaving $DIR two lines long and every source broken. $BASH_ENV is read
# whenever bash STARTS a non-interactive shell, so it reaches every `bash -c` the fixtures spawn; $ENV is its
# POSIX-mode form, and $GLOBIGNORE would hide every candidate from the reclaim's glob (bash 3.2.57 honors it
# only on an in-shell assignment, never when inherited). $POSIXLY_CORRECT is what starts those children in
# POSIX mode, and it carries a second, load-bearing effect: bash 3.2.57 re-runs its posix-mode hook on the
# UNSET even when the variable was never set, which turns `expand_aliases` back off. That is what makes the
# $BASH_ENV alias channel inert here — a $BASH_ENV planting `shopt -s expand_aliases; alias git=...` is
# otherwise expanded in everything parsed after it. Verified by bisecting the five names: only unsetting
# $POSIXLY_CORRECT flips the shopt back.
#
# $SHELLOPTS/$BASHOPTS are readonly, so their options can only be turned back OFF — and doing only that leaves
# the pair still exported, which is the half that reaches the fixtures: the children keep inheriting nounset
# and pipefail, measured at 22 passed / 19 failed. `export -n` closes it, and is legal on a readonly variable.
# Handled only in the EXPORTED form, the hostile one: `bash -x` on this file sets xtrace WITHOUT exporting
# $SHELLOPTS, and that deliberate debugging run must keep its trace. So the export attribute is read off each
# variable's OWN `declare -p` line, whose prefix bash generates: searching `export -p` output instead matched
# any unrelated variable whose VALUE merely contained the text, and DECOY='SHELLOPTS=x' killed the trace it is
# supposed to preserve. What this closes is precisely posix, xtrace, verbose, and inheritance via `export -n` —
# NOT the whole channel: noexec and onecmd are applied by bash at startup, and a script that never executes a
# command cannot turn them off from inside, so `SHELLOPTS=noexec pnpm check` exits 0 having run nothing at all.
# That inerts every bash script on the machine rather than anything specific here; named, not defended against.
unset CDPATH BASH_ENV ENV GLOBIGNORE POSIXLY_CORRECT
_decl="$(builtin declare -p SHELLOPTS 2>/dev/null)"
case "${_decl%% SHELLOPTS=*}" in *x) set +o posix; set +x +v; export -n SHELLOPTS 2>/dev/null ;; esac
_decl="$(builtin declare -p BASHOPTS 2>/dev/null)"
case "${_decl%% BASHOPTS=*}" in *x) export -n BASHOPTS 2>/dev/null ;; esac
unset _decl

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISOWN="$DIR/wt-disown.sh"
RESTAMP="$DIR/wt-restamp.sh"
IDLIB="$DIR/wt-identity.sh"

# Guarded per case rather than suite-wide, matching wt-identity.test.sh: the whole-file form skipped
# every one of this suite's assertions on a node-less machine while `pnpm check` stayed green — a
# passing gate that verified nothing, on the script that decides whether one session may take over
# another's worktree.
HAVE_NODE=no
command -v node >/dev/null 2>&1 && HAVE_NODE=yes

TMP="$(mktemp -d)"
# `cd ""` succeeds and leaves the cwd unchanged, so an empty $TMP would make $TMP_PHYS the invoking
# directory — and the reclaim below would then unlink locks live sessions hold on the real repository.
[ -n "$TMP" ] || { echo "ERROR: mktemp -d failed; refusing to run with an empty workspace path." >&2; exit 1; }
TMP_PHYS="$(cd "$TMP" && pwd -P)"
[ -n "$TMP_PHYS" ] || { echo "ERROR: could not resolve a physical path for '$TMP'; refusing to run with an empty workspace path." >&2; exit 1; }
LIVE_PIDS=""

# Every case here re-execs under with-repo-lock.py, which keys a lock file on the repo and never deletes
# it — so each run leaves one lock per fixture repo in the SHARED ~/.claude/locks/, and since every run
# gets a fresh mktemp -d those keys never repeat: unbounded growth outside the workspace. Only locks whose
# recorded key resolves inside THIS run's workspace may be reclaimed; parallel sessions hold live locks in
# that same directory, so the first-line key test below is what decides and the glob only enumerates.
# Deliberately duplicated from wt-identity.test.sh rather than sourced: these suites stay self-contained.
reclaim_locks() {
  # An UNQUOTED tilde, deliberately, and not "${HOME:-}": this has to resolve the same directory
  # with-repo-lock.py writes to, and that script uses Python's os.path.expanduser, which falls back to the
  # passwd database when HOME is unset. "${HOME:-}/.claude/locks" instead yields /.claude/locks, the `-d` test
  # below fails, and this returns 0 having reclaimed nothing while the locks keep landing in the real shared
  # directory — `env -u HOME` on a wt suite left 10 orphans there in one run, measured, which is precisely the
  # unbounded growth this function exists to stop, now invisible. Bash's tilde takes the same passwd fallback,
  # so the two agree on all four states of HOME — set, unset, empty, pointing nowhere — verified against
  # expanduser on this machine. It must stay unquoted ("~/..." is a literal), and unquoted is safe: tilde
  # expansion is not a parameter expansion, so set -u has nothing to fire on, and an assignment word is not
  # field-split, so a HOME containing spaces survives intact.
  local dir=~/.claude/locks f key
  # An empty $TMP_PHYS would make the pattern below "/*" and match every lock on the machine. It cannot
  # happen past the mktemp guard above, but this function UNLINKS files in a directory shared with live
  # sessions, so it refuses on its own evidence rather than on a caller's.
  [ -n "$TMP_PHYS" ] || return 0
  [ -d "$dir" ] || return 0
  # Every candidate path stays inside the shell as a single word, start to finish. No `xargs`, no `sh -c`,
  # no process substitution: each of those re-parses the paths it is handed, and the candidates derive from
  # $HOME, so a space or an apostrophe there mangled every one of them — measured as 4 locks silently left
  # behind per run, the exact unbounded growth this function exists to stop. `read` in place of a `head`
  # fork per file is what keeps that safe version fast: over a 13,560-file directory it costs 0.9s against
  # 23.5s for the fork-per-file loop. `key` is re-emptied each pass because an unreadable file leaves the
  # redirect unexecuted, which would otherwise carry the PREVIOUS file's key into this file's verdict.
  for f in "$dir"/repo-*.lock; do
    [ -f "$f" ] || continue
    key=""
    { IFS= read -r key < "$f"; } 2>/dev/null
    key=${key#*" key="}
    case "$key" in "$TMP_PHYS"/*) rm -f "$f" 2>/dev/null || true ;; esac
  done
  return 0
}

# One case makes a directory unwritable on purpose; restore before rm. Kill sleeper nodes first. The
# reclaim is best-effort and guards its own inputs so it cannot abort the stages that follow it. INT/TERM are
# trapped as well as EXIT: each spawn_live leaves a 600s node behind, so an interrupted run would otherwise
# leak every one of them, plus $TMP and this run's lock files.
trap 'reclaim_locks || true; [ -n "$LIVE_PIDS" ] && kill $LIVE_PIDS 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

# Nothing an ancestor exported may decide whether this gate passes. The rule for what belongs here is not a
# list of known-bad names — a list kept missing one more each review round — but a question: every command
# these fixtures run gets its configuration from an environment PREFIX, so sweep the prefix of every such
# command and of the library itself. GIT_* is everything git reads, and an inherited GIT_DIR does not merely
# fail the gate, it makes the fixtures COMMIT INTO the invoking repository (GIT_INDEX_FILE alone, which git
# 2.51.2 exports to a pre-commit hook, took this suite to 10 passed / 31 failed). NODE_* decides whether the
# backgrounded `node` that IS the live-owner fixture ever starts: NODE_OPTIONS=<bad flag> scores 28/13.
# GREP_* reaches ck_has, which /usr/bin/grep honors: GREP_OPTIONS=--invert-match scores 38/3. PYTHON* is
# with-repo-lock.py's interpreter, which every case here re-execs under. PS_* is procps' `ps` configuration,
# which the library's ownership verdict is parsed out of: PS_PERSONALITY is the live member — PS_FORMAT is only
# procps-ng's DEFAULT format, outranked by the explicit `-o` every call in the library passes. Unmeasurable
# against the BSD ps here, so swept on the documented behaviour. WTID_* is the library's own override seam,
# CLAUDE_* is what wtid_session_ids and wtid_harness_pid resolve ownership from, and WT_*/_WITH_REPO_LOCK_HELD
# are the lock sentinels an inherited copy of which lets wt-disown.sh skip the serialization every case here
# exercises.
for _v in "${!GIT_@}" "${!WTID_@}" "${!CLAUDE_@}" "${!WT_@}" "${!GREP_@}" "${!NODE_@}" "${!PYTHON@}" "${!PS_@}"; do unset "$_v"; done
unset _WITH_REPO_LOCK_HELD
# A developer's own git config must not decide it either: commit.gpgsign=true (which `-c user.email`/`-c
# user.name` do not suppress) or core.logAllRefUpdates=false fails the fixtures wholesale. Re-exported after
# the sweep, which took these two with the rest of GIT_*. $HOME, $PATH, $TMPDIR and $LANG/$LC_*/$TZ are left
# standing deliberately — the reclaim keys on $HOME, the node fixtures run through $PATH, and the assertions
# here are on the scripts' own English strings and on git plumbing, neither of which the locale moves.
#
# Two of wt-identity.test.sh's guards are deliberately absent: this suite quotes every fixture path rather
# than word-splitting an assigns list, and it has no fixture that must resolve NO identity. Measured — a
# workspace with a space in it and a workspace nested inside a stamped /start worktree both score 41/0.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

G="git -c user.email=t@t -c user.name=t"
pass=0; fail=0; skipped=0

ck() { # want got label
  if [ "$1" = "$2" ]; then echo "PASS  $3"; pass=$((pass + 1))
  else echo "FAIL  $3 (want '$1' got '$2')"; fail=$((fail + 1)); fi
}
ck_has() { # needle haystack label
  if printf '%s' "$2" | grep -qF -- "$1"; then echo "PASS  $3"; pass=$((pass + 1))
  else echo "FAIL  $3 (no '$1' in: $(printf '%s' "$2" | tr '\n' '|'))"; fail=$((fail + 1)); fi
}
# A skip drops coverage, so it has to be visible in the tally: on a node-less machine the footer would
# otherwise be indistinguishable from a run that verified everything, and this suite gates `pnpm check`.
# Counted, never fatal — a missing interpreter is not a regression.
skip() { echo "SKIP  $1"; skipped=$((skipped + 1)); }

# Block until <pid> has really exec'd its target. Two fixture hazards live in the fork window, and both are
# silent: a kill delivered there signals a COPY of this shell, which then runs this script's traps (deleting
# $TMP) and resumes the suite from the fork point; and a stamp taken there records comm=bash, which
# wt_owner_alive reads as a dead owner. `ps` costs a fork of its own, so this almost never sleeps.
await_exec() { # pid comm-pattern
  local i=0 comm
  while [ "$i" -lt 500 ]; do
    comm=$(ps -o comm= -p "$1" 2>/dev/null | tail -1)
    case "$comm" in $2) return 0 ;; esac
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
  await_exec "$LIVE" "*node*"
  disown "$LIVE" 2>/dev/null || true   # out of the job table, so the trap's kill stays silent
}
# A live process deliberately OUTSIDE the harness comm allowlist, so no interpreter is needed: liveness
# reads it dead-on-comm, but it is genuinely running, so a stamp taken while it lives records a real
# start time. Owner-path cases use it directly — wt-disown.sh admits the owner by session match without
# consulting liveness — and the dead fixture below builds on it.
SLEEPER=""
spawn_sleeper() {
  sleep 600 &
  SLEEPER=$!
  LIVE_PIDS="$LIVE_PIDS $SLEEPER"   # an INT would otherwise leak the 600s sleeper
  await_exec "$SLEEPER" "*sleep*"
}
DEAD=""
# Two phases so the stamp runs while the process is still ALIVE and records its start time. Killing it
# first left owner-pid-start empty, and the "dead" verdict then rested entirely on `ps` finding nothing:
# a recycled pid landing on any allowlisted comm flips the fixture to alive. With the pair recorded, the
# start-time mismatch settles it regardless of what inherits the pid. No node here (BF-548's finding):
# the verdict comes from the pid being reaped, not from its comm, so the plain sleeper suffices.
spawn_dead() { # a pid to stamp while it still lives
  spawn_sleeper
  DEAD="$SLEEPER"
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
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 1's live-foreign-owner refusal needs an allowlisted live process"
fi

# --- Part 2: a foreign session cannot release a live owner's claim ---
if [ "$HAVE_NODE" = yes ]; then
  spawn_live
  setup foreign sess-A "$LIVE"

  drun sess-B "$WT"
  ck "3" "$RC" "foreign disown of a live owner refused (exit 3)"
  ck_has "sess-A" "$ERR" "refusal names the stamped owner"
  ck "$LIVE" "$(cfg start.owner-pid)" "refused disown left the stamped pid untouched"
  ck "" "$(cfg start.owner-released-at)" "refused disown wrote no release marker"
else
  skip "node not available — Part 2's live-owner refusal needs an allowlisted live process"
fi

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

if [ "$HAVE_NODE" = yes ]; then
  spawn_live
  setup forced sess-A "$LIVE"

  drun sess-B "$WT"
  ck "3" "$RC" "sanity: live foreign owner still refused without --force"
  drun sess-B --force "$WT"
  ck "0" "$RC" "--force releases a live foreign owner (the /start stalled-takeover path)"
  ck "released" "$(owner_field OWNER_ALIVE)" "forced release adjudicates released"
else
  skip "node not available — the --force-over-a-live-owner half needs an allowlisted live process"
fi

# --- Part 4: sidecar transform is surgical, and a config wipe still reads released via the sidecar ---
# Owner path — no allowlisted process needed: the disown gate admits sess-A by session match.
spawn_sleeper
setup sidecar sess-A "$SLEEPER"

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
# Owner path again, and the takeover reads `released`, which short-circuits before any liveness check.
spawn_sleeper
setup restampclear sess-A "$SLEEPER"
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
spawn_sleeper
setup partialdisown sess-A "$SLEEPER"
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
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 9's seizure victim must read as a LIVE owner"
fi

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
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 11's takeover session must read as a LIVE owner"
fi

# --- Part 12: a stale released marker cannot report a re-claimed live worktree as up for grabs ---
# Same tier shape reached the other way: A disowns (every tier records the release), the repo tier then
# goes unwritable, and B resumes. Config truthfully says B is claimed and alive while two stale tiers still
# say A/released. `released` is /auto's signal to RESUME a worktree, so believing the stale pair here
# dispatches a second session onto B's live work — the one verdict that must never be inferred from age.
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 12's re-claimed worktree must read as a LIVE claim"
fi

# --- Part 13: wt-owner.sh reports the same owner however the worktree is named ---
# The sidecar filename comes from basename "$wt_dir", so a '.' invocation looked for `wt-identity-..env`,
# found neither sidecar, and answered off the git-config tier alone — an empty owner on exactly the
# worktree whose config was wiped, which automation reads as "nobody is here".
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 13's sidecar-resolved owner must adjudicate alive"
fi

# --- Part 14: an INTERRUPTED stamp's half-written claim is not owner evidence ---
# The owner keys are written in sequence (session, then the release marker cleared, then the pid), so a /start
# killed mid-stamp leaves {session, no pid, no released}. Taken whole that tuple erases a LIVE owner into
# 'unknown', and the reuse guard admits on unknown — a second session walks straight into the worktree. A torn
# tuple must instead fall through to a path-verified sidecar, which still holds the pid config never got.
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 14's interrupted stamp must leave a LIVE owner to protect"
fi

# --- Part 15: a torn claim is completed only from the LATEST session's sidecar ---
# The torn config still carries the NEWEST session id, so only that session's sidecar may complete it.
# Completing from whichever sidecar answers first lets a superseded session's stale one splice its own dead pid
# onto the current claim: B's live worktree then reads as a dead session's leftovers, which /auto resumes.
if [ "$HAVE_NODE" = yes ]; then
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
else
  skip "node not available — Part 15's completed tuple must adjudicate B as a LIVE owner"
fi

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
# The planted pid's liveness is irrelevant when the floor holds — the file must never be read at all — and
# a broken floor still fails the owner/session assertions whatever the pid resolves to, so a reaped pid
# keeps the case interpreter-free without weakening it.
spawn_dead
reap_dead
# The job dir's basename is one of the ids this session presents, so it must NOT be the id the plant claims:
# with both spelled sess-EVIL the planted owner would read as THIS session's own and be admitted either way.
PLANT_JOB="$w/job/sess-C"
mkdir -p "$PLANT_JOB"
printf 'WT_IDENTITY_OWNER=sess-EVIL\nWT_IDENTITY_OWNER_PID=%s\n' "$DEAD" > "$PLANT_JOB/wt-identity-test-1.env"

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
# The assertions here are on report keys, never on liveness, so the non-allowlisted sleeper serves.
spawn_sleeper
setup dissentreport sess-A "$SLEEPER"
REP_JOB="$TMP/dissentreport/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$REP_JOB"

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
# The scrub is about which fields the LOAD publishes, not about liveness — the sleeper serves.
spawn_sleeper
setup scrubowner sess-A "$SLEEPER"
SCRUB_JOB="$TMP/scrubowner/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$SCRUB_JOB"

ck "sess-A" "$(cfg start.owner-session)" "the fixture really does have an owner to publish"
ck "issue-branch" "$(probe "$SCRUB_JOB" WTID_BRANCH)" "the load still returns the structural identity"
for f in WTID_OWNER WTID_OWNER_SESSION WTID_OWNER_PID WTID_OWNER_PID_START WTID_OWNER_RELEASED_AT WTID_OWNER_CLAIMED_AT; do
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
# Owner path — the sleeper is alive at stamp time, so a genuine start time is recorded for the clear
# below to be a real clear rather than a vacuous one.
spawn_sleeper
setup relpidstart sess-A "$SLEEPER"

ck "1" "$([ -n "$(cfg start.owner-pid-start)" ] && echo 1 || echo 0)" "sanity: a start time was recorded, so the clear below clears something"
drun sess-A "$WT"
ck "0" "$RC" "owner disown exits 0"
ck "" "$(cfg start.owner-pid-start)" "and clears owner-pid-start, not just owner-pid"
ck "" "$(owner_field TIER_DISSENT)" "so the released worktree corroborates rather than dissents"

# --- Part 23: the ownership claim epoch — every tier, never overridable, the frozen pair untouched ---
# BF-575: start.stamped-at is FROZEN across every reuse (it anchors wt-restamp's preservation audit),
# which made a legitimate takeover and a config seizure byte-identical on every persisted field. The
# claim epoch is ownership's own recency: advanced by every stamp, decoupled from the era anchor, and
# honoring NO override — an overridable claim epoch would be freezable, the exact property that made
# stamped-at unusable for ownership.
spawn_sleeper
setup claimepoch sess-A "$SLEEPER"
CE_JOB="$TMP/claimepoch/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$CE_JOB"
claim1=$(cfg start.owner-claimed-at)
ck "1" "$([ -n "$claim1" ] && echo 1 || echo 0)" "a stamp writes the claim epoch to git config"
ck "$claim1" "$(sed -n 's/^WT_IDENTITY_OWNER_CLAIMED_AT=//p' "$SIDE" | head -1)" "and the same value to the repo-fallback sidecar"
ck "$claim1" "$(sed -n 's/^WT_IDENTITY_OWNER_CLAIMED_AT=//p' "$CE_JOB/wt-identity-test-1.env" | head -1)" "and to the job-dir sidecar"

head_before=$(cfg start.head-sha)
era_before=$(cfg start.stamped-at)
real_start sess-A
ck "0" "$RC" "the owner's reuse through the real create succeeds"
ck "$head_before" "$(cfg start.head-sha)" "reuse keeps head-sha frozen (the restamp anchor)"
ck "$era_before" "$(cfg start.stamped-at)" "and stamped-at frozen (the era that anchor opens)"
claim2=$(cfg start.owner-claimed-at)
ck "1" "$([ -n "$claim2" ] && [ "$claim2" -ge "$claim1" ] && echo 1 || echo 0)" "while the claim epoch is re-asserted, decoupled from the frozen pair"

# The override seam that freezes the pair must not reach the claim epoch.
env "CLAUDE_SESSION_ID=sess-A" "WTID_STAMP_OWNER_CLAIMED_AT_OVERRIDE=9999999999" bash -c "
  set -e; . '$IDLIB'
  base=\$(git -C '$WT' merge-base issue-branch main)
  wt_identity_stamp '$WT' '$WT' test-1 issue-branch main \"\$base\" >/dev/null"
ck "1" "$([ "$(cfg start.owner-claimed-at)" != "9999999999" ] && echo 1 || echo 0)" "the claim epoch honors no override"

claim3=$(cfg start.owner-claimed-at)
drun sess-A "$WT"
ck "0" "$RC" "owner disown exits 0"
ck "$claim3" "$(cfg start.owner-claimed-at)" "a release leaves the claim epoch intact in config — a release is not a new claim"
ck "$claim3" "$(sed -n 's/^WT_IDENTITY_OWNER_CLAIMED_AT=//p' "$SIDE" | head -1)" "and intact in the sidecar the release rewrote"

# --- Part 24: the claim epoch separates a config seizure from a legitimate takeover (BF-546's killed repro) ---
# The two states are byte-identical on every pre-BF-575 field: stamped-at is frozen, so in both a
# different-owner tier carries an era equal to config's. The contest rule breaks the tie two ways: a
# rival counts on an EQUAL-or-newer claim epoch (-ge, never -gt — a seizure that leaves the epoch alone
# is only visible on equality), and config's claim is cleared by a same-stamp witness — a sidecar
# recording the same owner AND the same claim epoch, which only the takeover's own stamp writes, and
# which also keeps a same-second takeover from reading as a contest.
spawn_sleeper
setup contest sess-A "$SLEEPER"
CT_JOB_A="$TMP/contest/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$CT_JOB_A"
git -C "$WT" config --worktree start.owner-session sess-EVIL
seize_rep=$(env "CLAUDE_JOB_DIR=$CT_JOB_A" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "1" "$(printf '%s\n' "$seize_rep" | sed -n 's/^OWNER_CONTEST=//p')" "a config-write seizure raises the contest signal"
ck_has "sess-A" "$(printf '%s\n' "$seize_rep" | sed -n 's/^OWNER_CONTEST_DETAIL=//p')" "and the detail names the rival owner the seized tier displaced"

spawn_dead
setup handoff sess-A "$DEAD"
HO_JOB_A="$TMP/handoff/job/sess-A"; HO_JOB_B="$TMP/handoff/job/sess-B"
stamp_job "$WT" sess-A "$DEAD" "$HO_JOB_A"
reap_dead
mkdir -p "$HO_JOB_B"
# Driven through the REAL create: a direct wt_identity_stamp here would advance the era and certify a
# code path production never takes — how BF-546's first attempt passed while the bug reproduced.
OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=sess-B" "CLAUDE_JOB_DIR=$HO_JOB_B" \
  "$DIR/start-wt-create.sh" test-1 test-1 issue-branch main "$WT" 2>"$TMP/stderr.txt"); RC=$?
ck "0" "$RC" "the dead-owner takeover is admitted (exit 0)"
ck "$(cfg start.stamped-at)" "$(sed -n 's/^WT_IDENTITY_STAMPED_AT=//p' "$HO_JOB_A/wt-identity-test-1.env" | head -1)" "sanity: the superseded tier's era EQUALS config's — the pre-BF-575 fields really cannot separate the states"
ho_b=$(env "CLAUDE_JOB_DIR=$HO_JOB_B" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "0" "$(printf '%s\n' "$ho_b" | sed -n 's/^OWNER_CONTEST=//p')" "no contest from the resumer's seat"
ho_a=$(env "CLAUDE_JOB_DIR=$HO_JOB_A" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "0" "$(printf '%s\n' "$ho_a" | sed -n 's/^OWNER_CONTEST=//p')" "and none from the superseded owner's seat — an older rival claim is supersession"
ck "job-dir" "$(printf '%s\n' "$ho_a" | sed -n 's/^TIER_DISSENT=//p')" "while the stale tier still dissents structurally — dissent and contest are now separate signals"

# The same-second takeover: the rival's claim epoch EQUALS config's by clock coincidence, not by seizure —
# the state a takeover landing inside the stamp's second leaves naturally (BF-578's straddle lesson applied
# to the claim epoch, which honors no pin). Synthesized deterministically by rewinding both of the
# takeover's own tiers to the superseded claim's epoch; the same-stamp witness is what keeps it out of the
# signal, since on equality the -ge rival test alone cannot.
a_claim=$(sed -n 's/^WT_IDENTITY_OWNER_CLAIMED_AT=//p' "$HO_JOB_A/wt-identity-test-1.env" | head -1)
git -C "$WT" config --worktree start.owner-claimed-at "$a_claim"
sed "s/^WT_IDENTITY_OWNER_CLAIMED_AT=.*/WT_IDENTITY_OWNER_CLAIMED_AT=$a_claim/" "$SIDE" > "$SIDE.new" && mv "$SIDE.new" "$SIDE"
ho_same=$(env "CLAUDE_JOB_DIR=$HO_JOB_A" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "0" "$(printf '%s\n' "$ho_same" | sed -n 's/^OWNER_CONTEST=//p')" "a same-second takeover is witnessed by its own stamp — equal epochs alone are not a seizure"

# --- Part 25: an interrupted disown dissents but never contests — same owner on every tier ---
spawn_sleeper
setup halfdisown sess-A "$SLEEPER"
HD_JOB="$TMP/halfdisown/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$HD_JOB"
chmod a-w "$REPO/.claude/worktree-identity"
drun sess-A "$WT"
ck "2" "$RC" "the blocked sidecar fails the disown loudly (exit 2)"
hd=$(env "CLAUDE_JOB_DIR=$HD_JOB" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "released" "$(printf '%s\n' "$hd" | sed -n 's/^OWNER_ALIVE=//p')" "config's release took"
ck "1" "$([ -n "$(printf '%s\n' "$hd" | sed -n 's/^TIER_DISSENT=//p')" ] && echo 1 || echo 0)" "the un-rewritten tiers dissent"
ck "0" "$(printf '%s\n' "$hd" | sed -n 's/^OWNER_CONTEST=//p')" "but the same owner on every tier is never a contest"
chmod -R u+rwx "$REPO/.claude/worktree-identity" 2>/dev/null || true

# --- Part 26: fresh and never-stamped worktrees are trivially contest-free, and the keys always emit ---
# Parsed BY KEY like Part 17's pair: a key emitted only when something is wrong is indistinguishable
# from a key whose value is empty.
spawn_sleeper
setup freshclean sess-A "$SLEEPER"
FC_JOB="$TMP/freshclean/job/sess-A"
stamp_job "$WT" sess-A "$SLEEPER" "$FC_JOB"
fc=$(env "CLAUDE_JOB_DIR=$FC_JOB" "$DIR/wt-owner.sh" "$WT" 2>/dev/null)
ck "1" "$(printf '%s\n' "$fc" | grep -c '^OWNER_CONTEST=')" "a clean report still carries the OWNER_CONTEST key"
ck "1" "$(printf '%s\n' "$fc" | grep -c '^OWNER_CLAIMED_AT=')" "and the OWNER_CLAIMED_AT key"
ck "0" "$(printf '%s\n' "$fc" | sed -n 's/^OWNER_CONTEST=//p')" "a freshly stamped worktree carries no contest"
ck "" "$(printf '%s\n' "$fc" | sed -n 's/^TIER_DISSENT=//p')" "and no dissent"

w="$TMP/nostampcontest"; REPO="$w/repo"; WT="$w/test-1"
mkdir -p "$w"
git init -q -b main "$REPO"
git -C "$REPO" config extensions.worktreeConfig true
( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
git -C "$REPO" worktree add -q "$WT" -b issue-branch
ck "0" "$("$DIR/wt-owner.sh" "$WT" 2>/dev/null | sed -n 's/^OWNER_CONTEST=//p')" "a never-stamped worktree has no claim to contest"

# --- Part 12: --reclaim — the owner withdraws its own release in place (BF-994) ---
# The shape: /auto disowns on a halt, a human attributes it, and the SAME session resumes. Without a
# reclaim that worktree stays advertised as up for grabs (/auto adjudicates `released` ahead of
# OWNER_IS_ME; reap-worktrees.sh treats released + zero-commit as reap-eligible). The gate is
# session-id equality with the KEPT attribution; identity — branch, source, baseline, anchor era —
# is inherited verbatim, so only ownership and the claim epoch change.
#
# CLAUDE_HARNESS_PID is pinned wherever the reclaim STAMPS: unset, wtid_harness_pid walks ancestry,
# so the recorded pid (and every post-reclaim liveness assertion) would depend on whether the suite
# itself runs under a live `claude` process.
drun_h() { # session harness_pid args... -> OUT/ERR/RC
  local sess="$1" hpid="$2" errf="$TMP/stderr.txt"; shift 2
  OUT=$(env "CLAUDE_SESSION_ID=$sess" "CLAUDE_HARNESS_PID=$hpid" "$DISOWN" "$@" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

spawn_sleeper
setup reclaimown sess-A
drun sess-A "$WT"
ck "0" "$RC" "release before reclaim ok"
head_before=$(cfg start.head-sha); era_before=$(cfg start.stamped-at)
base_before=$(cfg start.baseline-sha); claim_before=$(cfg start.owner-claimed-at)
drun_h sess-A "$SLEEPER" --reclaim "$WT"
ck "0" "$RC" "owner reclaim exits 0"
ck "RECLAIM=ok" "$(echo "$OUT" | head -1)" "reclaim reports ok"
ck "" "$(cfg start.owner-released-at)" "config release marker revoked"
ck "sess-A" "$(cfg start.owner-session)" "ownership re-stamped to the reclaiming owner"
ck "$head_before" "$(cfg start.head-sha)" "anchor unchanged across reclaim"
ck "$era_before" "$(cfg start.stamped-at)" "era unchanged across reclaim"
ck "$base_before" "$(cfg start.baseline-sha)" "baseline inherited verbatim"
ck "1" "$([ -n "$(cfg start.owner-claimed-at)" ] && [ "$(cfg start.owner-claimed-at)" -ge "$claim_before" ] && echo 1 || echo 0)" "claim epoch re-asserted, never rolled back"
ck "" "$(sed -n 's/^WT_IDENTITY_OWNER_RELEASED_AT=//p' "$SIDE" | head -1)" "sidecar release key dropped by the reclaim stamp"
# The pinned sleeper's comm is outside the harness allowlist, so the re-claimed worktree reads
# `dead`, not `released` — and a second reclaim refuses: only `released` (or live-mine) passes.
drun_h sess-A "$SLEEPER" --reclaim "$WT"
ck "3" "$RC" "second reclaim refuses on a non-released state"

setup reclaimforeign sess-A
drun sess-A "$WT"
drun sess-B --reclaim "$WT"
ck "3" "$RC" "foreign session's reclaim refused (exit 3)"
ck_has "released by session 'sess-A'" "$ERR" "refusal names the recorded owner"
ck "released" "$(owner_field OWNER_ALIVE)" "the worktree stays released for the real resumption paths"

setup reclaimseized sess-A
drun sess-A "$WT"
real_start sess-B
ck "0" "$RC" "takeover of the released worktree succeeds"
drun sess-A --reclaim "$WT"
ck "3" "$RC" "original owner's reclaim refused after a takeover"
ck "sess-B" "$(cfg start.owner-session)" "the takeover's ownership stands"

drun sess-A --reclaim --force "$WT"
ck "2" "$RC" "--reclaim with --force is a usage error"
ck_has "seizure" "$ERR" "the refusal names why and where to go instead"

w="$TMP/reclaimnostamp"; REPO="$w/repo"; WT="$w/test-1"
mkdir -p "$w"
git init -q -b main "$REPO"
git -C "$REPO" config extensions.worktreeConfig true
( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
git -C "$REPO" worktree add -q "$WT" -b issue-branch
drun sess-A --reclaim "$WT"
ck "3" "$RC" "never-stamped reclaim refused — unlike disown, there is nothing to withdraw"

if [ "$HAVE_NODE" = yes ]; then
  spawn_live
  setup reclaimnoop sess-A "$LIVE"
  drun sess-A --reclaim "$WT"
  ck "0" "$RC" "live self-owned reclaim is a noop (exit 0)"
  ck "RECLAIM=noop" "$(echo "$OUT" | head -1)" "noop reported"
  ck "sess-A" "$(cfg start.owner-session)" "ownership untouched by the noop"
else
  skip "reclaim noop-on-live-self case needs node"
fi

if [ "$HAVE_NODE" = yes ]; then
  spawn_live
  setup reclaimalien sess-A "$LIVE"
  drun sess-B --reclaim "$WT"
  ck "3" "$RC" "reclaim of another session's LIVE worktree refused"
  ck "sess-A" "$(cfg start.owner-session)" "the live owner keeps the claim"
else
  skip "reclaim live-foreign case needs node"
fi


echo
echo "wt-disown: $pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ]
