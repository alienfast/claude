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

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available — the live/dead owner fixtures need it."
  exit 0
fi

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
# reclaim is best-effort and guards its own inputs so it cannot abort the stages that follow it.
trap 'reclaim_locks || true; [ -n "$LIVE_PIDS" ] && kill $LIVE_PIDS 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

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
