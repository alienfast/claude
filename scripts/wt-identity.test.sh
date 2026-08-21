#!/usr/bin/env bash
# Direct functional suite for wt-identity.sh — the library every /start wt gate reads its identity
# through (start-wt-create.sh, finish-detect-mode.sh, wt-restamp.sh, wt-disown.sh, reap-worktrees.sh).
# Builds throwaway repos + linked worktrees in a temp dir and calls the library functions themselves,
# each in its own `bash -c` subshell: the WTID_* globals are process-wide, so a shared shell would let
# one case's identity satisfy the next case's assertion.
#
# The suite is not library-only. Part 5 drives start-wt-create.sh → finish-detect-mode.sh → wt-restamp.sh
# end to end, because the contract those three share — the identity one stamps and the next reads back as
# EXPECTED_* — lives in no single script and is invisible to any test that calls the library alone. BF-505
# broke exactly that seam, so it gets a pipeline test rather than another unit case.
#
# Fixture topology is load-bearing. The worktree dir is named test-1 and the stamped issue is test-1
# because wt_identity_load derives the sidecar filename from basename "$wt_dir" and lowercases nothing —
# any other name silently degrades every case to the weaker git-config-only tier while still passing.
# Repos set extensions.worktreeConfig as start-wt-setup.sh does; without it `git config --worktree`
# quietly writes --local and every per-tier assertion becomes meaningless. Detachment is produced by
# rewriting the SOURCE branch after the fork (BF-505's shape): a rebase onto an append-only source does
# NOT detach the baseline, so a case built on one would prove nothing.
#
# GROW THIS SUITE, NEVER PRUNE IT. This library had no direct tests at all until BF-548, and the three
# latent bugs BF-534 found in it — the WTID_WT_DIR reset leak, non-atomic sidecar writes, and
# wtid_pid_start aborting a caller's pipeline under pipefail — each surfaced only indirectly, through
# the restamp suite exercising it. BF-505 itself lived in the untested seam between /start's stamp and
# /finish's check. Add the case WITH the fix; never delete one to "clean up" — a closed hole with no
# live guard is a hole that reopens.

# THE ISOLATION PREAMBLE BELOW, AND reclaim_locks WITH IT, ARE DUPLICATED IN THE SIBLING wt-*.test.sh SUITES
# rather than sourced from a shared file — each suite has to stay runnable on its own. The copies are not
# whole-file identical (this one carries two guards the siblings measured as unnecessary for them, and each
# file cites its own scores), but every line they DO share is kept byte-identical, reclaim_locks in full.
# Change one and change all three in the same edit — a fix applied to one copy protects only that suite.
#
# Exported shell functions are an environment channel with no variable name of their own, so no prefix sweep
# reaches them: `export -f grep` arrives as an ordinary environment entry that bash imports before line 1,
# and a function outranks both the builtin and $PATH. A `grep` that always succeeds turns every ck_has into a
# PASS — assertions passing FALSELY, which is the dangerous direction; the gate itself still goes red (225
# passed / 1 failed, exit 1, measured with this sweep removed), so what the hijack destroys is the meaning of
# those 225 rather than the exit code — and one named `cd` or `export` would subvert the isolation below before
# it runs. Cleared generically rather than by name: this file has defined no function yet, so everything
# `declare -F` reports here arrived from outside. Builtins only, for the same reason. `unset -f` clears it for
# the children too, verified on the bash 3.2.57 here. Its `2>/dev/null` can only swallow the `readonly -f`
# case, which no environment can reach: a function's readonly attribute is not inherited across `exec`, so an
# imported function is always unsettable (verified — the child's `unset -f` returns 0 and clears it).
#
# The sweep's own tools sit inside the surface it defends. An exported `declare` makes `declare -F` report
# nothing, so the sweep clears nothing and every other hijack rides straight through it: `declare` and `grep`
# together score 225 passed / 1 failed, exactly the no-sweep number above. An exported `unset` then makes
# `unset -f declare` a no-op as well. The three lines below bootstrap out of that, and no COMMAND can be their
# first step, because any command word can be shadowed. A variable assignment cannot be, and assigning
# $POSIXLY_CORRECT is bash's runtime entry into POSIX mode, where special builtins — `unset` among them — are
# looked up BEFORE functions. That makes the next line's `unset -f` the real builtin whatever was imported, and
# it clears every command the bootstrap and the sweep themselves dispatch: `unset`, `builtin`, `declare`, `read`.
# The backslashes are load-bearing, not decoration: POSIX mode also switches `expand_aliases` ON, which would
# hand an inherited alias a window it does not get in a default non-interactive shell, and a backslash-quoted
# word is never alias-expanded, while quoting leaves builtin lookup untouched. Leaving POSIX mode on the third
# line switches `expand_aliases` back off.
#
# The sweep's own test is a `case` rather than the `[ -n "$_l" ]` it would otherwise read as, because `[` is the
# one command here that cannot be protected the same way: POSIX mode rejects `unset -f [` as "not a valid
# identifier". `case` needs none, being a reserved word: the parser takes the compound command before any
# command lookup happens, and bash rejects the env import of a function by that name outright. With `[`, an
# imported `[` that returns non-zero short-circuits the `&&` and the sweep then clears NOTHING: measured
# with `[` and `grep` hijacked together, both were still defined afterwards, where the `case` form clears both.
#
# The sweep runs BEFORE this file's own `set -uo pipefail`, because `set` is a command word like any other: an
# imported `set` that returns 0 leaves both options off for the whole run — 34 passed / 192 failed, measured —
# and an ancestor deciding this gate's shell options is exactly what the preamble exists to prevent. Nothing
# above needs either option, so `set` is swept with the rest and the real builtin is what runs a few lines down.
POSIXLY_CORRECT=1
\unset -f unset builtin declare read 2>/dev/null
\unset POSIXLY_CORRECT
while IFS= read -r _l; do case "$_l" in ?*) unset -f "${_l##* }" 2>/dev/null ;; esac; done <<< "$(builtin declare -F)"
unset _l

set -uo pipefail

# Shell-level channels, cleared ahead of the `cd` below, which runs on a RELATIVE path: package.json invokes
# this suite as `scripts/wt-identity.test.sh`, so `dirname` yields a bare `scripts`, exactly the shape `cd`
# resolves through $CDPATH. A $CDPATH holding any directory with a `scripts/` in it makes that `cd` land
# elsewhere AND echo where it landed, so $DIR captures two lines and every `. $IDLIB` fails: 34 passed /
# 192 failed, measured. $BASH_ENV is read whenever bash STARTS a non-interactive shell, so it reaches every
# `bash -c` the fixtures spawn and its output breaks the cases asserting an empty $STAMP_ERR — 225 passed /
# 1 failed. The remaining three each measure 226/0 unswept and are cleared as the same class anyway, being
# the documented twin or precondition of a live one: $ENV is $BASH_ENV's POSIX-mode form, $POSIXLY_CORRECT is
# what starts those children in POSIX mode, and $GLOBIGNORE would hide every candidate from the reclaim's
# glob — inert only because bash 3.2.57 honors it on an in-shell assignment and never on an inherited value.
unset CDPATH BASH_ENV ENV GLOBIGNORE POSIXLY_CORRECT
# $SHELLOPTS and $BASHOPTS are readonly, so their options can only be turned back OFF — and doing only that
# leaves the pair still exported, which is the half that reaches the fixtures: every `bash -c` child keeps
# inheriting nounset and pipefail, measured at 165 passed / 61 failed. `export -n` is what closes it, and it
# is legal on a readonly variable. Handled only in the EXPORTED form, the hostile one: `bash -x` on this file
# sets xtrace WITHOUT exporting $SHELLOPTS, and that deliberate debugging run must keep its trace. So the
# export attribute is read off each variable's OWN `declare -p` line, whose prefix bash generates: searching
# `export -p` output instead matched any unrelated variable whose VALUE merely contained the text, and
# DECOY='SHELLOPTS=x' killed the trace it is supposed to preserve. Anchoring to `declare -rx SHELLOPTS=` would
# not have been enough either: a value can contain that too, and does in the second decoy tested here.
#
# What this closes is precisely posix, xtrace, verbose, and inheritance of the pair via `export -n`. It is NOT
# the whole $SHELLOPTS channel, and nothing in a shell script can be: noexec and onecmd are applied by bash at
# startup, and a script that never executes a command cannot turn them off from inside. `SHELLOPTS=noexec pnpm
# check` exits 0 having run nothing at all — not even markdownlint, only pnpm's own echo of the script line —
# and onecmd behaves the same. That inerts every bash script on the machine rather than anything specific to
# this suite, so it is named here as a residual hazard rather than defended against.
_decl="$(builtin declare -p SHELLOPTS 2>/dev/null)"
case "${_decl%% SHELLOPTS=*}" in *x) set +o posix; set +x +v; export -n SHELLOPTS 2>/dev/null ;; esac
_decl="$(builtin declare -p BASHOPTS 2>/dev/null)"
case "${_decl%% BASHOPTS=*}" in *x) export -n BASHOPTS 2>/dev/null ;; esac
unset _decl

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDLIB="$DIR/wt-identity.sh"

# $WTID_TEST_TMPDIR is how a caller steers the workspace to satisfy the two guards below. It exists because
# BSD mktemp ignores $TMPDIR outright, so the obvious remedy — repointing $TMPDIR — does nothing on macOS.
if [ -n "${WTID_TEST_TMPDIR:-}" ]; then TMP="$(mktemp -d "$WTID_TEST_TMPDIR/wtid-XXXXXX")"; else TMP="$(mktemp -d)"; fi
# A failed mktemp has to be fatal here rather than merely noisy: `cd ""` SUCCEEDS and leaves the cwd
# unchanged, so an empty $TMP silently makes $TMP_PHYS the INVOKING directory — and the reclaim below would
# then match every lock recorded under it, unlinking locks live sessions hold on the real repository.
[ -n "$TMP" ] || { echo "ERROR: mktemp -d failed; refusing to run with an empty workspace path." >&2; exit 1; }
TMP_PHYS="$(cd "$TMP" && pwd -P)"
# $TMP_PHYS is guarded on its own for a second reason: `git -C ""` is not an error but a documented no-op
# that probes the INVOKING directory — verified here to answer with this checkout's own git dir — so the
# enclosure probe below would silently report on the wrong repository.
[ -n "$TMP_PHYS" ] || { echo "ERROR: could not resolve a physical path for '$TMP'; refusing to run with an empty workspace path." >&2; exit 1; }
LIVE_PIDS=""

# with-repo-lock.py keys a lock file on the repo it serialized and never deletes it, and wt-restamp.sh
# re-execs under it unconditionally — so Part 5 leaves one lock per fixture repo in the SHARED
# ~/.claude/locks/, and since every run gets a fresh mktemp -d those keys never repeat: unbounded growth
# outside the workspace. Only locks whose recorded key resolves inside THIS run's workspace may be
# reclaimed — parallel sessions and other suites hold live locks in that same directory. The whole thing
# is best-effort: a cleanup failure must never fail the suite.
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

# Cases make a directory unwritable on purpose and background processes as owner-liveness fixtures, so the
# teardown has four independent stages. Only one ordering is load-bearing — chmod before rm, or the
# unwritable fixture directories survive it. What matters for the rest is that no stage can be SKIPPED by an
# earlier one failing, which is why the reclaim guards its own inputs rather than relying on `|| true`.
trap 'reclaim_locks || true; [ -n "$LIVE_PIDS" ] && kill $LIVE_PIDS 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Space-free fixture paths are a load-bearing invariant, not a preference: stamp_env/alive/isme word-split
# their "VAR=VAL ..." argument on purpose, and wt_identity_disown word-splits its sidecar list. A spaced
# $TMPDIR — or a CI runner with a spaced workspace — would otherwise produce a cascade of failures that
# name nothing about the real cause. Fail once, legibly, instead.
case "$TMP$TMP_PHYS" in
  *[[:space:]]*)
    echo "ERROR: this suite requires a space-free temp workspace, but mktemp -d gave '$TMP' (physically '$TMP_PHYS')." >&2
    echo "       Re-run with WTID_TEST_TMPDIR=<existing whitespace-free directory>. (\$TMPDIR will not help on macOS: BSD mktemp ignores it.)" >&2
    exit 1
    ;;
esac

# Nothing an ancestor exported may decide whether this gate passes. The rule for what belongs here is not a
# list of known-bad names — three review rounds each found one more that a list had missed — but a question:
# every command these fixtures run gets its configuration from an environment PREFIX, so sweep the prefix of
# every such command and of the library itself. That is what makes this closed rather than one round longer.
#
# Each score below is what the named variable does to this suite with the sweep REMOVED — the reason the
# prefix is here, not a claim about the shipped file, which scores 226/0 under every one of them.
#
#   GIT_*      everything git reads, it reads through this. GIT_DIR does not merely fail the gate, it makes
#              the fixtures COMMIT INTO the invoking repository; GIT_INDEX_FILE scores 64/162 (git 2.51.2
#              exports it to a pre-commit, post-commit or prepare-commit-msg hook, and a filter-branch
#              --index-filter exports GIT_DIR and GIT_WORK_TREE besides); GIT_TEMPLATE_DIR carrying a live
#              pre-commit hook 65/161; GIT_COMMITTER_DATE 220/6; GIT_TRACE 214/12.
#   WTID_*     the library's own override seam — an inherited WTID_STAMP_HEAD_SHA_OVERRIDE scores 213/13.
#   CLAUDE_*   what wtid_session_ids and wtid_harness_pid resolve ownership from, and the session running
#              `pnpm test` IS a Claude session with those exported.
#   WT_*, _WITH_REPO_LOCK_HELD   the lock sentinels wt-restamp.sh and wt-disown.sh skip serialization on.
#   GREP_*     ck_has, tmpres and the release-marker count all run grep, and /usr/bin/grep (BSD grep
#              2.6.0-FreeBSD) honors GREP_OPTIONS: --invert-match scores 220/6.
#   NODE_*     the owner-liveness fixtures ARE a backgrounded `node`; NODE_OPTIONS=<bad flag> kills it before
#              it can stand in for a live harness — 223/3.
#   PYTHON*    with-repo-lock.py is python3 and Part 5's restamp re-execs under it unconditionally. Swept as
#              that interpreter's configuration prefix, not on a number: PYTHONWARNINGS, PYTHONPATH and
#              PYTHONSTARTUP each measured 226/0 unswept.
#   PS_*       the ownership verdict is parsed out of `ps -o lstart=` and `ps -o comm=`. PS_PERSONALITY is
#              the reason: procps-ng lets it reshape output and argument handling wholesale. PS_FORMAT is NOT
#              — procps-ng documents it as a DEFAULT format, applied only when no format is given, and every
#              call here passes an explicit `-o`, which wins. Swept as the prefix anyway, on that one live
#              member and on procps' documented behaviour: the BSD ps here honors neither, so there is no
#              number from this machine to cite.
#
# $WTID_TEST_TMPDIR is the caller's own steering knob and was consumed above. TEST_SHIM/MV_LOG/CFG_LOG are
# the suite's OWN controls — $SHIMPATH prepends $TEST_SHIM inside every subshell Parts 3-4 spawn, so an
# inherited one silently shims every case in the file.
for _v in "${!GIT_@}" "${!WTID_@}" "${!CLAUDE_@}" "${!WT_@}" "${!GREP_@}" "${!NODE_@}" "${!PYTHON@}" "${!PS_@}"; do
  case "$_v" in WTID_TEST_TMPDIR) ;; *) unset "$_v" ;; esac
done
unset _WITH_REPO_LOCK_HELD TEST_SHIM MV_LOG CFG_LOG

# A developer's own git config must not decide it either, and redirecting the config FILES is only half of
# that: commit.gpgsign=true (which `-c user.email`/`-c user.name` do NOT suppress) fails almost every commit
# and core.logAllRefUpdates=false removes the branch reflog wt-restamp.sh walks, while the env-borne
# channels the sweep just cleared outrank the files entirely. These two are re-exported AFTER the sweep,
# which took them with everything else.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# Left standing deliberately, each measured 226/0 with a hostile value rather than argued safe. $HOME, $PATH
# and $TMPDIR are load-bearing — the reclaim keys the shared lock dir off $HOME, the shims exec the real
# tools found through $PATH, and $TMPDIR is the documented way to steer the workspace wherever mktemp honors
# it. $LANG/$LC_*/$TZ move nothing: every assertion is on the scripts' own English strings or on git
# plumbing, both `date` calls are epoch-seconds or -u, and the ps start-time comparison is locale-symmetric —
# LC_ALL=tr_TR.UTF-8, the worst case for the library's one `tr [:upper:] [:lower:]`, still scores 226/0.
# $EMAIL is outranked by `-c user.email` and $XDG_CONFIG_HOME by the GIT_CONFIG_GLOBAL above. $PAGER,
# $EDITOR/$VISUAL and $NO_COLOR never fire: git pages nothing here, every commit and rebase is non-
# interactive, and no assertion reads a colored stream. $IFS cannot arrive at all — bash resets it to the
# default at startup regardless of what was exported.

# Parts 3-4 build PATH shims that EXEC the real tool at the path `command -v` reports, with the shim dir
# FIRST on $PATH — so that path has to be ABSOLUTE. A relative $PATH entry is what produces a relative one
# (`PATH=tmp/bin:$PATH` gives `tmp/bin/git`, verified), and the shim then resolves it back through its own
# directory and execs itself forever: a hung suite rather than a failing case. Resolved here, ahead of the
# enclosure probe below, so an unusable `git` is reported as what it is instead of skewing that probe.
REAL_GIT=$(command -v git); REAL_MV=$(command -v mv); REAL_PS=$(command -v ps)
for _tool in "git=$REAL_GIT" "mv=$REAL_MV" "ps=$REAL_PS"; do
  case "${_tool#*=}" in
    /*) ;;
    "") echo "ERROR: '${_tool%%=*}' was not found on \$PATH at all, and the PATH shims cannot be built without it." >&2; exit 1 ;;
    *) echo "ERROR: '${_tool%%=*}' resolves to '${_tool#*=}', not an absolute path — \$PATH carries a relative entry, and the PATH shims cannot be built safely." >&2; exit 1 ;;
  esac
done

# A workspace nested inside a STAMPED worktree is the second load-bearing invariant. The `notrepo` fixture
# is a plain directory that must resolve no identity at all; inside a worktree carrying tier 3's two keys it
# inherits them and answers git-config instead — 224/2. Merely being inside a git repository is NOT the
# precondition and must not abort: a workspace inside a plain `git init` checkout scores a full 226/0, and
# aborting there would fail the gate for a CI runner with TMPDIR=$GITHUB_WORKSPACE/tmp or a developer whose
# ~ is a dotfiles repo. So the probe reads exactly the two keys the library's tier-3 gate reads, through the
# same `--worktree` path (which falls back to local config where extensions.worktreeConfig is off, and exits
# non-zero with no output where there is no repository at all). Checked after the sweep above so an
# inherited GIT_DIR cannot manufacture the enclosure. Same rule as the whitespace guard: fail once, legibly.
if [ -n "$(git -C "$TMP_PHYS" config --worktree --get start.worktree-branch 2>/dev/null)" ] &&
   [ -n "$(git -C "$TMP_PHYS" config --worktree --get start.baseline-sha 2>/dev/null)" ]; then
  echo "ERROR: this suite requires a workspace outside any stamped /start worktree, but '$TMP_PHYS' is inside one (it carries start.worktree-branch and start.baseline-sha in per-worktree config, which the notrepo fixture would inherit)." >&2
  if [ -n "${WTID_TEST_TMPDIR:-}" ]; then
    echo "       \$WTID_TEST_TMPDIR is '$WTID_TEST_TMPDIR' — point it at a directory outside any stamped worktree, or unset it." >&2
  else
    echo "       mktemp -d chose this path on its own; where it honors \$TMPDIR (GNU coreutils, verified) re-point that, otherwise set \$WTID_TEST_TMPDIR to a directory outside any stamped worktree." >&2
  fi
  exit 1
fi

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
# Part 5 runs real scripts and captures their stderr in $ERR. A bare exit-code mismatch there is
# unreadable — the script says WHY it refused on stderr and nowhere else, so surface that line.
ck_rc() { # want got label
  if [ "$1" = "$2" ]; then echo "PASS  $3"; pass=$((pass + 1))
  else echo "FAIL  $3 (want '$1' got '$2'; stderr: $(printf '%s\n' "${ERR:-}" | head -1))"; fail=$((fail + 1)); fi
}
nonempty() { [ -n "$1" ] && echo yes || echo no; }

REPO=""; WT=""; MAINROOT=""; SIDE=""

# Sets REPO, WT, MAINROOT and SIDE (the repo-fallback sidecar path). MAINROOT is the PHYSICAL main-checkout
# path because that is what _wtid_main_root derives from `git rev-parse --git-common-dir`, and on macOS
# $TMPDIR lives under a symlinked /var — asserting against the logical path would fail for the wrong
# reason. Paths stay space-free: wt_identity_disown word-splits on them, a known limitation.
mkrepo() { # name — worktree created but NOT stamped
  local w="$TMP/$1"
  REPO="$w/repo"; WT="$w/test-1"
  mkdir -p "$w"
  git init -q -b main "$REPO"
  git -C "$REPO" config extensions.worktreeConfig true   # start-wt-setup.sh does this in the real flow
  ( cd "$REPO" && echo base > base.txt && $G add base.txt && $G commit -qm "R: root" ) >/dev/null
  ( cd "$REPO" && echo v1 > main.txt && $G add main.txt && $G commit -qm "A: pre-fork" ) >/dev/null
  git -C "$REPO" worktree add -q "$WT" -b issue-branch
  MAINROOT="$(cd "$REPO" && pwd -P)"
  SIDE="$MAINROOT/.claude/worktree-identity/wt-identity-test-1.env"
}

# The era override is how recency cases stay deterministic — a real stamp reads `date +%s`, so ranking
# two tiers apart would otherwise need a sleep between them.
stamp() { # wt_dir [session] [job_dir] [stamped_at era]
  local wt="$1" sess="${2-sess-A}" job="${3-}" era="${4-}" body
  body="set -e; . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    wt_identity_stamp '$wt' '$wt' test-1 issue-branch main \"\$base\" >/dev/null"
  env ${sess:+"CLAUDE_SESSION_ID=$sess"} ${job:+"CLAUDE_JOB_DIR=$job"} \
      ${era:+"WTID_STAMP_STAMPED_AT_OVERRIDE=$era"} bash -c "$body"
}

# A second identity for the SAME worktree under a different issue slug — the only way to prove the
# two-arg load reads the slug rather than the directory basename. Session and era are pinnable for the
# same reason stamp()'s are: this fixture's two stamps write DISJOINT sidecar files, so the shared
# config tier carries the SECOND stamp's fingerprint while the basename sidecar carries the first's —
# and cross-stamp tiers corroborate only when every fingerprint field matches, the era included.
stamp_issue() { # wt_dir issue_id [session] [stamped_at era]
  local wt="$1" issue="$2" sess="${3-}" era="${4-}"
  env ${sess:+"CLAUDE_SESSION_ID=$sess"} ${era:+"WTID_STAMP_STAMPED_AT_OVERRIDE=$era"} bash -c "set -e; . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    wt_identity_stamp '$wt' '$wt' '$issue' issue-branch main \"\$base\" >/dev/null"
}

# Rewrite one key of one sidecar. A stamp writes BOTH tiers at once, so this is the only way to give
# the two tiers independent eras or recorded worktree paths.
set_key() { # file key value
  sed "s#^$2=.*#$2=$3#" "$1" > "$1.x" && mv "$1.x" "$1"
}

# Loads an identity in a pristine subshell and prints <expr>, evaluated after the load with $rc holding
# its exit status. Pass <expr> single-quoted at the call site.
idl() { # wt_dir job_dir("" = none) slug("" = derive from basename) expr
  local body=". '$IDLIB'; wt_identity_load '$1' '$3'; rc=\$?; printf '%s' \"$4\""
  if [ -n "$2" ]; then env "CLAUDE_JOB_DIR=$2" bash -c "$body"; else bash -c "$body"; fi
}

verify() { # wt_dir -> "<corruption>:<reason>"
  bash -c ". '$IDLIB'; wt_identity_load '$1' && wt_identity_verify '$1'; echo \"\$WTID_CORRUPTION:\$WTID_CORRUPTION_REASON\""
}

# --- Part 1: wt_identity_load — which identity a caller gets, and what it may contain ---

# Tier selection. Each WTID_SOURCE value must be reachable and must name the tier that actually supplied
# the fields, since callers branch on it (verify's config-wipe check only fires for a sidecar tier). One
# stamp writes both sidecar tiers, so the tiers are removed one at a time to walk the chain down.
mkrepo tiers
stamp "$WT"
JOB="$TMP/tiers/job"; mkdir -p "$JOB"
ck "0:repo-fallback" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "the repo-fallback sidecar is the tier when no job dir is set"
ck "$SIDE" "$(idl "$WT" "" "" '$WTID_SIDECAR_PATH')" "the load reports the sidecar it actually read"
ck "test-1:issue-branch:main" "$(idl "$WT" "" "" '$WTID_ISSUE:$WTID_BRANCH:$WTID_SOURCE_BRANCH')" "a sidecar identity carries the stamped issue, branch and source branch"
ck "$(git -C "$WT" merge-base issue-branch main)" "$(idl "$WT" "" "" '$WTID_BASELINE')" "a sidecar identity carries the stamped baseline"
cp "$SIDE" "$JOB/"
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "the job-dir sidecar is the tier when the session has one"
ck "$JOB/wt-identity-test-1.env" "$(idl "$WT" "$JOB" "" '$WTID_SIDECAR_PATH')" "the job-dir load reports the job-dir sidecar path"
rm -f "$JOB/wt-identity-test-1.env" "$SIDE"
ck "0:git-config" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "per-worktree git config is the tier once both sidecars are gone"
mkrepo tiersbare
ck "1:none" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "an unstamped worktree has no verifiable identity"

# The non-worktree, which the library header enumerates as an exit-1 case but which no fixture above
# reaches — every other one is a real linked worktree. A plain directory resolves no main root (so
# neither sidecar tier is even looked for) and has no per-worktree config, and all of that has to fail
# QUIETLY: finish-detect-mode.sh calls the load under `set -e` from wherever the user happened to be.
NOTREPO="$TMP/notrepo"; mkdir -p "$NOTREPO"
ck "1:none" "$(idl "$NOTREPO" "" "" '$rc:$WTID_SOURCE')" "a directory that is not a git worktree has no identity"
ck "" "$(idl "$NOTREPO" "" "" '$WTID_ISSUE$WTID_BRANCH$WTID_SOURCE_BRANCH$WTID_BASELINE$WTID_SIDECAR_PATH$WTID_STAMPED_AT')" "and every identity field comes back empty rather than half-filled"
ck "survived" "$(bash -c "set -eo pipefail; . '$IDLIB'; wt_identity_load '$NOTREPO' || true; echo survived")" "the failing git probes do not abort a set -eo pipefail caller"

# Era ranking, which BF-546 demoted from AUTHORITY to LAST-RESORT TIEBREAK. One stamp writes every reachable
# tier at once, so under honest operation they all agree and the winner is settled by corroboration before any
# era is consulted. The era only decides when no two tiers agree at all — and then only after completeness,
# because a tier no stamp could have written as it stands is damaged whatever era it still claims.
# _wtid_era_num sorts anything unusable oldest, so a damaged era never wins a contest by accident.
mkrepo recency
JOB="$TMP/recency/job"; mkdir -p "$JOB"
stamp "$WT" sess-A "$JOB" 1000
JOBFILE="$JOB/wt-identity-test-1.env"
ck "1000" "$(sed -n 's/^WT_IDENTITY_STAMPED_AT=//p' "$JOBFILE" | head -1)" "sanity: the era override reached the sidecars"
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "three agreeing tiers resolve to the strongest of them"
# The cycle-8 reproduction this design exists to close: the repo-fallback sidecar lives in the main checkout's
# working tree, writable by any local process, so a forged era there used to demote the job-dir tier the design
# calls immune. It no longer can — job-dir and git config still corroborate each other, and a lone dissenter
# loses however new it claims to be. This assertion IS the fix; flipping it back to repo-fallback reopens BF-546.
set_key "$SIDE" WT_IDENTITY_STAMPED_AT 2000
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "a forged newer era cannot outvote the corroborating pair"
ck "repo-fallback" "$(idl "$WT" "$JOB" "" '$WTID_TIER_DISSENT')" "and the tampered tier is named as the dissenter"
set_key "$SIDE" WT_IDENTITY_STAMPED_AT 999
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "an older repo-fallback era loses too"
# Now the no-majority path, the only one era still decides: all three tiers are made to disagree. The damaged
# era goes on the JOB-DIR side deliberately — on the repo side it would prove nothing, since without the guard
# `[ nan -gt 1000 ]` merely errors into the same answer the guard produces. Config is in this ranking where the
# pre-BF-546 design ranked only the two sidecars, and it holds the largest usable era, so it takes it.
set_key "$SIDE" WT_IDENTITY_STAMPED_AT 1
set_key "$JOBFILE" WT_IDENTITY_STAMPED_AT nan
ck "0:git-config" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "with no majority the largest usable era wins and a non-numeric one loses"
set_key "$JOBFILE" WT_IDENTITY_STAMPED_AT 1000
set_key "$SIDE" WT_IDENTITY_STAMPED_AT 99999999999
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "an era too wide for shell arithmetic loses every contest"
set_key "$SIDE" WT_IDENTITY_STAMPED_AT 2000
set_key "$JOBFILE" WT_IDENTITY_STAMPED_AT ""
ck "0:repo-fallback" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "an empty job-dir era loses to a usable repo-fallback era"

# Trust check (_wtid_sidecar_matches). A sidecar describes this worktree only if its recorded
# WT_IDENTITY_WT_DIR is this worktree — otherwise a stale same-issue sidecar left in $CLAUDE_JOB_DIR by a
# prior aborted /start gets read for the recreated worktree and flags it corrupt. The comparison is
# PHYSICAL (pwd -P), because the stored path may be logical while callers feed a resolved one, and a raw
# string compare would false-reject a healthy sidecar on a symlinked repo path.
mkrepo trust
JOB="$TMP/trust/job"; mkdir -p "$JOB"
stamp "$WT" sess-A "$JOB"
JOBFILE="$JOB/wt-identity-test-1.env"
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "a sidecar recording this worktree is accepted"
set_key "$JOBFILE" WT_IDENTITY_WT_DIR "$TMP/trust/some-other-worktree"
ck "0:repo-fallback" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "a sidecar recorded for a different worktree is skipped"
set_key "$JOBFILE" WT_IDENTITY_WT_DIR ""
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "a pre-field sidecar with an empty recorded path is accepted"
set_key "$JOBFILE" WT_IDENTITY_WT_DIR "$WT"
ln -s "$WT" "$TMP/trust/aliased"
ck "0:job-dir" "$(idl "$TMP/trust/aliased" "$JOB" test-1 '$rc:$WTID_SOURCE')" "a worktree reached through a symlink still matches its sidecar"

# The accept-on-unresolvable rule, from the other side: when the worktree DIRECTORY is gone the sidecar
# is the only surviving record of it, and rejecting it would blind finish-recover and the reaper to
# exactly the worktrees they exist to clean up.
mkrepo gonedir
JOB="$TMP/gonedir/job"; mkdir -p "$JOB"
stamp "$WT" sess-A "$JOB"
git -C "$REPO" worktree remove --force "$WT"
ck "0:job-dir" "$(idl "$WT" "$JOB" "" '$rc:$WTID_SOURCE')" "a removed worktree dir still loads its job-dir sidecar"

# Reset at entry — the BF-534 leak class. Every WTID_* field is cleared at the top of the load, or a rich
# identity read for one worktree survives into the next load and answers questions about a worktree it
# never described. The first field is asserted too, so a vacuous first load cannot make this pass.
mkrepo resetentry
stamp "$WT"
RICH="$WT"
mkrepo resetbare
leaked=$(bash -c ". '$IDLIB'
  wt_identity_load '$RICH'; first=\$WTID_ISSUE
  wt_identity_load '$WT'; rc=\$?
  echo \"\$first|\$rc:\$WTID_SOURCE|\$WTID_ISSUE\$WTID_BRANCH\$WTID_SOURCE_BRANCH\$WTID_BASELINE\$WTID_WT_DIR\$WTID_HEAD_SHA\$WTID_STAMPED_AT\$WTID_SIDECAR_PATH\$WTID_OWNER\$WTID_OWNER_PID\$WTID_OWNER_PID_START\$WTID_OWNER_RELEASED_AT\"")
ck "test-1|1:none|" "$leaked" "loading an unstamped worktree clears every field the previous load populated"

# The SECOND reset, the one that fires after every sidecar candidate was rejected. Reading a candidate
# populates the globals BEFORE the trust check rejects it, so without this reset the rejected sidecar's
# issue, path and owner fields ride along into the git-config result — an identity assembled from two
# tiers, one of which was ruled not to describe this worktree at all.
mkrepo secondreset
stamp "$WT"
set_key "$SIDE" WT_IDENTITY_WT_DIR "$TMP/secondreset/some-other-worktree"
ck "0:git-config" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "a rejected sidecar falls through to git config"
ck "" "$(idl "$WT" "" "" '$WTID_ISSUE$WTID_WT_DIR$WTID_SIDECAR_PATH$WTID_OWNER$WTID_OWNER_PID$WTID_OWNER_PID_START$WTID_OWNER_RELEASED_AT')" "the rejected sidecar's fields do not leak into the git-config identity"
ck "issue-branch:main" "$(idl "$WT" "" "" '$WTID_BRANCH:$WTID_SOURCE_BRANCH')" "the git-config identity still carries the config's own branch fields"

# BF-546 inverted this: wt_identity_load SCRUBS every owner global rather than preserving them. Ownership is
# arbitrated by a different rule than structural identity (git config is authoritative for it, corroboration is
# not), so the structural winner's owner claim may be outdated — publishing it, or leaving a caller's earlier
# answer in place, lets code act on a tuple nothing adjudicated. Scrubbing makes that impossible instead of
# merely discouraged; wt_owner_alive is the only sanctioned reader and it re-resolves every field from scratch.
ck "" "$(bash -c ". '$IDLIB'; WTID_OWNER_SESSION=stale-session; wt_identity_load '$WT'; printf '%s' \"\$WTID_OWNER_SESSION\"")" "wt_identity_load scrubs WTID_OWNER_SESSION rather than preserving it"

# The tier-3 gate. Config counts as an identity only when it carries BOTH new fields; a legacy pre-stamp
# worktree has just start.source-branch, and treating that as verifiable would have /finish check a
# worktree it cannot actually describe. Tier 3 also knows nothing about the issue, the worktree path or
# ownership — those exist only in a sidecar — so those fields must come back empty, not stale.
mkrepo tier3
stamp "$WT"
rm -f "$SIDE"
ck "0:git-config" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "config carrying both new fields is a verifiable identity"
ck "" "$(idl "$WT" "" "" '$WTID_ISSUE$WTID_WT_DIR$WTID_SIDECAR_PATH$WTID_OWNER$WTID_OWNER_PID$WTID_OWNER_PID_START$WTID_OWNER_RELEASED_AT')" "the git-config tier leaves issue, worktree path and ownership empty"
ck "issue-branch:main" "$(idl "$WT" "" "" '$WTID_BRANCH:$WTID_SOURCE_BRANCH')" "the git-config tier supplies the branch fields"
# Both expectations are read out of the same config the tested code reads, so an absent key would make
# these compare "" against "" and pass while proving nothing. Non-emptiness is asserted first, the same
# discipline Part 5 applies to its round-trip values.
TIER3_ERA=$(git -C "$WT" config --worktree --get start.stamped-at)
TIER3_ANCHOR=$(git -C "$WT" config --worktree --get start.head-sha)
ck "yes" "$(nonempty "$TIER3_ERA")" "sanity: the fixture's config carries an era to compare against"
ck "$TIER3_ERA" "$(idl "$WT" "" "" '$WTID_STAMPED_AT')" "the git-config tier supplies the rewrite era"
ck "yes" "$(nonempty "$TIER3_ANCHOR")" "sanity: the fixture's config carries an anchor to compare against"
ck "$TIER3_ANCHOR" "$(idl "$WT" "" "" '$WTID_HEAD_SHA')" "the git-config tier supplies the rewrite anchor"
git -C "$WT" config --worktree --unset start.worktree-branch
ck "1:none" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "config without start.worktree-branch is not verifiable"
git -C "$WT" config --worktree start.worktree-branch issue-branch
git -C "$WT" config --worktree --unset start.baseline-sha
ck "1:none" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "config without start.baseline-sha is not verifiable"

# The two-arg form, which reap-worktrees.sh uses because it inspects worktrees by issue rather than by
# path. The fixture stamps a SECOND identity for the same worktree under a different slug, so the
# directory basename and the slug disagree and only the slug can select the right file. Session and
# era are pinned equal across the two stamps: they split the tiers (basename sidecar from the first,
# shared config from the second), so the one-arg load corroborates only while their fingerprints
# match — left to the wall clock, a second-boundary straddle under load broke the match and the load
# correctly fell back to the issue-less git-config tier (BF-578's intermittent FAIL; the straddle is
# pinned deterministically as designed behavior just below).
mkrepo twoarg
TWOARG_ERA=$(date +%s)
stamp "$WT" sess-A "" "$TWOARG_ERA"
stamp_issue "$WT" other-2 sess-A "$TWOARG_ERA"
ck "test-1" "$(idl "$WT" "" "" '$WTID_ISSUE')" "the one-arg form derives the sidecar from the directory basename"
ck "other-2" "$(idl "$WT" "" other-2 '$WTID_ISSUE')" "the two-arg form selects the sidecar named for the explicit slug"
ck "$MAINROOT/.claude/worktree-identity/wt-identity-other-2.env" "$(idl "$WT" "" other-2 '$WTID_SIDECAR_PATH')" "the two-arg load reports the slug's sidecar path"

# The straddle itself, held deterministic forever (BF-578): push the config tier's era one second past
# the basename sidecar's. The two tiers now genuinely disagree — they came from different stamp calls,
# and coincidental same-second agreement was the only thing that ever made them corroborate — so the
# load must refuse corroboration, warn loudly, and proceed on the weakest tier, which by design carries
# no issue. This is the tamper-detection property itself: a partially rewritten or tampered config tier
# presents exactly this shape, and folding the era out of the fingerprint (or tolerating ±1s skew)
# would wave it through in silence.
mkrepo straddle
STRADDLE_ERA=$(date +%s)
stamp "$WT" sess-A "" "$STRADDLE_ERA"
stamp_issue "$WT" other-2 sess-A "$STRADDLE_ERA"
ck "test-1" "$(idl "$WT" "" "" '$WTID_ISSUE')" "control: era-pinned twin stamps corroborate and the sidecar supplies the issue"
git -C "$WT" config --worktree --replace-all start.stamped-at "$((STRADDLE_ERA + 1))"
ck "git-config:" "$(idl "$WT" "" "" '$WTID_SOURCE:$WTID_ISSUE')" "a one-second era straddle breaks corroboration and falls back to the issue-less config tier"
ck_has "identity tiers disagree" "$(idl "$WT" "" "" '' 2>&1)" "and the straddle is announced, never silent"

# --- Part 2: wt_identity_verify — the corruption verdict ---

# A freshly stamped worktree on its own branch at its own baseline is not corrupt, and the clean verdict
# carries an EMPTY reason: callers print the reason verbatim.
mkrepo vclean
stamp "$WT"
ck "0:" "$(verify "$WT")" "a freshly stamped worktree verifies clean"

# branch-swapped is the primary observed signature — a parallel session checks the worktree out onto its
# own branch. A detached HEAD counts as swapped too: symbolic-ref reports no branch, which is not the
# stamped branch, and a detached worktree is exactly as unsafe to merge from.
mkrepo vswap
stamp "$WT"
git -C "$WT" checkout -q -b other-branch
ck "1:branch-swapped" "$(verify "$WT")" "a worktree checked out onto another branch is branch-swapped"
mkrepo vdetach
stamp "$WT"
git -C "$WT" checkout -q --detach
ck "1:branch-swapped" "$(verify "$WT")" "a detached HEAD is branch-swapped (symbolic-ref reports no branch)"

# baseline-detached, produced the honest way: the SOURCE branch is rewritten after the fork, so rebasing
# onto it moves HEAD to a lineage the stamped baseline is not part of. A rebase onto an APPEND-ONLY
# source keeps the fork point an ancestor and must stay clean — that negative control is what stops the
# case below from passing for the wrong reason ("any rebase detaches").
mkrepo vappend
stamp "$WT"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: appended" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
ck "0:" "$(verify "$WT")" "a rebase onto an append-only source leaves the baseline attached"
mkrepo vdetached
stamp "$WT"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
ck "1:baseline-detached" "$(verify "$WT")" "a rebase onto a rewritten source detaches the stamped baseline"

# source-branch-config-wiped is proof of tampering: an immune sidecar still describes the worktree while
# the worktree's own config was cleared. It can only fire for a sidecar tier — for a git-config identity
# the config IS the identity, so its source-branch is present by construction. Both halves are asserted;
# without the negative control the check could fire on any empty source-branch and nobody would notice.
mkrepo vwipe
stamp "$WT"
git -C "$WT" config --worktree --unset start.source-branch
ck "1:source-branch-config-wiped" "$(verify "$WT")" "a wiped source-branch config is corruption under a sidecar identity"
mkrepo vwipecfg
stamp "$WT"
rm -f "$SIDE"
git -C "$WT" config --worktree --unset start.source-branch
ck "0:git-config" "$(idl "$WT" "" "" '$rc:$WTID_SOURCE')" "sanity: the wiped worktree loads through the git-config tier"
ck "0:" "$(verify "$WT")" "the wipe check cannot fire for a git-config identity"

# First match wins. The checks run branch → baseline → config and a worktree can satisfy several at once,
# but the reason is what callers route on (finish-detect-mode.sh sends branch-swapped to recovery and
# baseline-detached to wt-restamp.sh), so the earlier check must win rather than the last one to run.
mkrepo vorder
stamp "$WT"
git -C "$WT" config --worktree --unset start.source-branch
git -C "$WT" checkout -q -b other-branch
ck "1:branch-swapped" "$(verify "$WT")" "branch-swapped outranks a simultaneous config wipe"
mkrepo vorderbase
stamp "$WT"
git -C "$WT" checkout -q -b other-branch "$(git -C "$WT" rev-parse HEAD~1)"
ck "1:branch-swapped" "$(verify "$WT")" "branch-swapped outranks a simultaneously detached baseline"
mkrepo vorderwipe
stamp "$WT"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1
git -C "$WT" config --worktree --unset start.source-branch
ck "1:baseline-detached" "$(verify "$WT")" "baseline-detached outranks a simultaneous config wipe"

# A baseline whose commit does not exist locally (GC'd, or never fetched into this clone) cannot prove
# detachment, so the check is deliberately suppressed instead of failing closed — flagging every
# unresolvable baseline would condemn healthy worktrees on a shallow or pruned repo. The positive
# control is the rewritten-source case above: a baseline that IS present and off the lineage still fires.
mkrepo vgone
stamp "$WT"
set_key "$SIDE" WT_IDENTITY_BASELINE_SHA 0000000000000000000000000000000000000001
ck "0000000000000000000000000000000000000001" "$(idl "$WT" "" "" '$WTID_BASELINE')" "sanity: the unresolvable baseline is the one loaded"
ck "0:" "$(verify "$WT")" "a baseline object missing from the repo suppresses the detachment check"

# The verdict travels in WTID_CORRUPTION, never in the exit status. finish-detect-mode.sh calls verify
# under `set -e`, so a non-zero return on a corrupt worktree would abort the very script that exists to
# report the corruption — silently turning a detected hijack into a crash.
mkrepo vrc
stamp "$WT"
git -C "$WT" checkout -q -b other-branch
ck "0" "$(bash -c ". '$IDLIB'; wt_identity_load '$WT' >/dev/null; wt_identity_verify '$WT'; echo \$?")" "wt_identity_verify returns 0 on a corrupt worktree"
ck "survived" "$(bash -c "set -e; . '$IDLIB'; wt_identity_load '$WT' >/dev/null; wt_identity_verify '$WT'; echo survived")" "a caller under set -e survives the corrupt verdict"

# --- Part 3: wt_identity_stamp — what a stamp writes, and what it writes when a tier fails ---

# Parts 3 and 4 drive the stamp through env seams `stamp` does not expose: the three *_OVERRIDE vars, an
# explicit harness pid, a shimmed PATH, an id-less session. Assignments are word-split, which the
# space-free fixture paths make safe. STAMP_OUT is the stamp's own stdout with <expr> appended, so a case
# can read a WTID_STAMP_* global out of the very subshell that wrote it; STAMP_ERR carries the WARNs.
#
# A shim dir travels as $TEST_SHIM rather than as a PATH= assignment: the real PATH contains spaces, so
# word-splitting it through the assigns list would tear it apart. $SHIMPATH is what turns that variable into
# an actual PATH, so EVERY helper that spawns a subshell has to prepend it — Part 4's alive/isme/owner_fields
# included. A helper that forgets it accepts a TEST_SHIM argument and silently ignores it, which reads as
# coverage of the shimmed environment while the case actually runs against the real one.
STAMP_OUT=""; STAMP_ERR=""; STAMP_RC=0
SHIMPATH='export PATH="${TEST_SHIM:+$TEST_SHIM:}$PATH";'
stamp_env() { # "VAR=VAL ..." wt_dir [expr — pass it single-quoted]
  local assigns="$1" wt="$2" expr="${3-}" body errf="$TMP/stamp-stderr.txt"
  body="set -e; $SHIMPATH . '$IDLIB'
    base=\$(git -C '$wt' merge-base issue-branch main)
    rc=0; wt_identity_stamp '$wt' '$wt' test-1 issue-branch main \"\$base\" || rc=\$?
    printf '%s' \"$expr\"
    exit \$rc"
  STAMP_OUT=$(env $assigns bash -c "$body" 2>"$errf"); STAMP_RC=$?
  STAMP_ERR=$(cat "$errf")
}

cfg() { # key -> $WT's per-worktree value, empty when unset
  git -C "$WT" config --worktree --get "$1" 2>/dev/null || true
}
has_cfg() { # key -> yes|no — PRESENCE, which an empty-valued key still has and an unset one does not
  git -C "$WT" config --worktree --get "$1" >/dev/null 2>&1 && echo yes || echo no
}
skey() { # file key -> the sidecar's value for key
  sed -n "s/^$2=//p" "$1" | head -1
}
isnum() { case "$1" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac; }
isodate() { case "$1" in ????-??-??T??:??:??Z) echo yes ;; *) echo no ;; esac; }
tmpres() { # dir -> its .tmp.* residue, empty when every write took the rename path
  ls -A "$1" 2>/dev/null | grep -F '.tmp.' || true
}

# Two PATH shims, built once and reused by both parts. PSSHIM's `ps` always fails, which is the only
# portable way to make wtid_harness_pid resolve nothing — the suite itself runs under a claude ancestor,
# so merely unsetting CLAUDE_HARNESS_PID would still find one. GITSHIM fails `rev-parse HEAD` with no
# stdout; an unborn HEAD will not do, because rev-parse echoes the argument it could not resolve and the
# stamp would record the literal string "HEAD" instead of nothing.
PSSHIM="$TMP/shim-ps"; mkdir -p "$PSSHIM"
printf '#!/bin/bash\nexit 1\n' > "$PSSHIM/ps"; chmod +x "$PSSHIM/ps"
GITSHIM="$TMP/shim-git"; mkdir -p "$GITSHIM"
printf '#!/bin/bash\ncase " $* " in *" rev-parse HEAD "*) exit 128 ;; esac\nexec %s "$@"\n' "$REAL_GIT" > "$GITSHIM/git"
chmod +x "$GITSHIM/git"

# Two `mv` shims, because the write-then-rename contract is only observable from outside the library: a
# direct in-place write and a correct rename are indistinguishable by their result. MVSHIM records the argv
# and then EXECS the real mv, so the writes still land and no unrelated case is disturbed; MVFAILSHIM records
# and fails, which is the only way to reach the cleanup branch with the tmp file genuinely created (an
# unwritable directory never gets that far — the tmp file cannot be created at all, so nothing is left to
# clean up and the assertion cannot fail). Both log to $MV_LOG, passed per case so the log stays scoped.
MVSHIM="$TMP/shim-mv"; mkdir -p "$MVSHIM"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${MV_LOG:-/dev/null}"\nexec %s "$@"\n' "$REAL_MV" > "$MVSHIM/mv"
chmod +x "$MVSHIM/mv"
MVFAILSHIM="$TMP/shim-mv-fail"; mkdir -p "$MVFAILSHIM"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${MV_LOG:-/dev/null}"\nexit 1\n' > "$MVFAILSHIM/mv"
chmod +x "$MVFAILSHIM/mv"
MV_LOG="$TMP/mv-log.txt"

# A `git` shim that logs every argv and then EXECS the real git, so the writes still land. The stamp's
# config writes are otherwise unobservable AS A SEQUENCE — only their final state survives — and one of
# them (the release revoke before the pid claim) is a contract about ORDER, not about the end state.
GITLOGSHIM="$TMP/shim-git-log"; mkdir -p "$GITLOGSHIM"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${CFG_LOG:-/dev/null}"\nexec %s "$@"\n' "$REAL_GIT" > "$GITLOGSHIM/git"
chmod +x "$GITLOGSHIM/git"
CFG_LOG="$TMP/cfg-log.txt"

# A `ps` whose lstart output is deliberately padded — leading, trailing and internal runs of spaces, exactly
# the shape real `ps -o lstart=` produces for a single-digit day of month. Real ps only pads on some dates,
# so the normalization case below would otherwise assert nothing for most of the month. comm is answered too
# (with an allowlisted name) so the start-time comparison is reached without needing a live harness fixture.
PADSHIM="$TMP/shim-ps-pad"; mkdir -p "$PADSHIM"
printf '#!/bin/bash\ncase " $* " in\n  *" -o lstart= "*) printf "   Mon Jan  1 00:00:00 2020  \\n"; exit 0 ;;\n  *" -o comm= "*) printf "node\\n"; exit 0 ;;\nesac\nexec %s "$@"\n' "$REAL_PS" > "$PADSHIM/ps"
chmod +x "$PADSHIM/ps"

# Tier A is the ungated tier: per-worktree git config is written on every stamp, before any best-effort
# sidecar, because its later ABSENCE is what verify reads as tampering. All of it is asserted together —
# a stamp that wrote four of the five keys leaves a worktree that still loads but can no longer be
# verified. The stamp is also silent on stdout: callers capture command substitutions around it.
mkrepo stampcfg
BASE=$(git -C "$WT" merge-base issue-branch main)
stamp_env "CLAUDE_SESSION_ID=sess-A" "$WT"
ck "0" "$STAMP_RC" "wt_identity_stamp returns 0"
ck "" "$STAMP_OUT" "wt_identity_stamp prints nothing on stdout"
ck "main" "$(cfg start.source-branch)" "the stamp records the source branch in per-worktree config"
ck "issue-branch" "$(cfg start.worktree-branch)" "the stamp records the worktree branch"
ck "$BASE" "$(cfg start.baseline-sha)" "the stamp records the baseline"
ck "$(git -C "$WT" rev-parse HEAD)" "$(cfg start.head-sha)" "the stamp records the current tip as the rewrite anchor"
ck "yes" "$(isodate "$(cfg start.created-at)")" "the stamp records an ISO-8601 creation instant"
ck "yes" "$(isnum "$(cfg start.stamped-at)")" "the stamp records an epoch-seconds era"

# head-sha is the one config key a stamp will UNSET. An anchor this stamp could not resolve must not
# leave the PREVIOUS stamp's anchor looking current — wt-restamp.sh audits a rewrite against exactly
# that value, and a stale one would sanction whatever moved the branch in between.
mkrepo stamphead
stamp_env "CLAUDE_SESSION_ID=sess-A" "$WT"
ck "yes" "$(nonempty "$(cfg start.head-sha)")" "sanity: the first stamp recorded an anchor"
stamp_env "CLAUDE_SESSION_ID=sess-A TEST_SHIM=$GITSHIM" "$WT"
ck "0" "$STAMP_RC" "a stamp whose HEAD does not resolve still returns 0"
ck "no" "$(has_cfg start.head-sha)" "an unresolvable HEAD unsets the previous anchor rather than keeping it"

# owner-session is written only when this session can present an id, and is NEVER unset: a stamp by a
# session with no resolvable id must leave the last owner's attribution intact rather than erasing who
# holds the worktree. wt-restamp.sh's session gate is the only thing between a foreign session and a
# merge, and an erased owner-session opens it to nobody at all — the owner included.
mkrepo stampowner
stamp_env "CLAUDE_SESSION_ID=sess-A" "$WT"
ck "sess-A" "$(cfg start.owner-session)" "a presentable session id is recorded as the owner"
stamp_env "" "$WT"
ck "sess-A" "$(cfg start.owner-session)" "an id-less stamp leaves the previous owner attribution in place"
mkrepo stampnoowner
stamp_env "" "$WT"
ck "no" "$(has_cfg start.owner-session)" "an id-less stamp on a fresh worktree records no owner at all"

# The pid pair is written and cleared TOGETHER. A takeover stamp that cannot resolve its own harness pid
# must not leave the dead prior owner's pid behind: every other session would keep reading that worktree
# as held by a live process and refuse to touch it for that process's whole lifetime.
mkrepo stamppid
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
ck "999999" "$(cfg start.owner-pid)" "a resolved harness pid is recorded"
ck "yes" "$(has_cfg start.owner-pid-start)" "owner-pid-start is written alongside it"
stamp_env "TEST_SHIM=$PSSHIM" "$WT"
ck "no" "$(has_cfg start.owner-pid)" "an unresolvable harness pid unsets the prior owner's pid"
ck "no" "$(has_cfg start.owner-pid-start)" "owner-pid-start is unset with it"

# A stamp ALWAYS revokes a release, and revokes it BEFORE writing the pid. The ordering is the safety
# property: a crash between the two leaves no-pid + no-released, which every reader adjudicates as
# unknown — hands off. The reverse order would leave a live, re-claimed worktree advertising itself as
# released, which is a standing invitation for a foreign session to seize it.
mkrepo stamprelease
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
bash -c ". '$IDLIB'; wt_identity_disown '$WT' test-1" >/dev/null 2>&1
ck "yes" "$(nonempty "$(cfg start.owner-released-at)")" "sanity: the disown left a release marker"
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
ck "no" "$(has_cfg start.owner-released-at)" "a re-stamp revokes the release marker"
ck "999999" "$(cfg start.owner-pid)" "the re-stamp re-claims the worktree with its own pid"
bash -c ". '$IDLIB'; wt_identity_disown '$WT' test-1" >/dev/null 2>&1
ck "yes" "$(nonempty "$(cfg start.owner-released-at)")" "sanity: the second disown re-armed a release for the pid-less stamp to revoke"
stamp_env "TEST_SHIM=$PSSHIM" "$WT"
ck "no" "$(has_cfg start.owner-released-at)" "a stamp that cannot resolve its pid still revokes the release"
ck "no" "$(has_cfg start.owner-pid)" "and leaves no pid — the half-written state reads unknown, never released"

# The ORDER of those two writes, which the block above cannot see: it only observes final state, so
# moving the revoke after the pid claim leaves every assertion there green. The order IS the safety
# property — a crash between the two must leave no-pid + no-released (unknown, hands off) rather than a
# live re-claimed worktree still advertising itself as released. The logging git shim is the only way to
# observe a sequence of writes from outside the library.
mkrepo stamporder
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
bash -c ". '$IDLIB'; wt_identity_disown '$WT' test-1" >/dev/null 2>&1
ck "yes" "$(nonempty "$(cfg start.owner-released-at)")" "sanity: there is a release for the re-stamp to revoke"
: > "$CFG_LOG"
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999 TEST_SHIM=$GITLOGSHIM CFG_LOG=$CFG_LOG" "$WT"
# Matched on --unset-all/--replace-all, the forms _wtid_unstamp_cfg and _wtid_stamp_cfg actually emit: those
# helpers replaced the bare `config --worktree <key>` writes this assertion was first written against, and the
# older patterns match nothing now, which reads as a silently passing ordering check rather than a failing one.
ck "release-unset pid-write" \
   "$(sed -n -e 's/.*--unset-all start\.owner-released-at.*/release-unset/p' -e 's/.*--replace-all start\.owner-pid .*/pid-write/p' "$CFG_LOG" | tr '\n' ' ' | sed 's/ $//')" \
   "the release is revoked BEFORE the pid claim is written"

# Tier B is gated on $CLAUDE_JOB_DIR ALREADY EXISTING, deliberately asymmetric with the load side, which
# needs only the file. A job dir is the harness's to create; conjuring one here would scatter sidecars
# into directories nothing ever reads or cleans up. A missing one is not a failure and not even a WARN —
# the tier was never attempted, so there is nothing to report.
mkrepo stampjob
JOB="$TMP/stampjob/sess-A"; mkdir -p "$JOB"
stamp_env "CLAUDE_JOB_DIR=$JOB" "$WT" '$WTID_STAMP_SIDECAR'
ck "$JOB/wt-identity-test-1.env" "$STAMP_OUT" "an existing job dir takes the sidecar and is reported as the stamp's sidecar"
ck "yes" "$([ -f "$JOB/wt-identity-test-1.env" ] && echo yes || echo no)" "the job-dir sidecar is on disk"
mkrepo stampnojob
MISSINGJOB="$TMP/stampnojob/never-created"
stamp_env "CLAUDE_JOB_DIR=$MISSINGJOB" "$WT" '$WTID_STAMP_SIDECAR'
ck "0" "$STAMP_RC" "a job dir that does not exist is not a failure"
ck "no" "$([ -e "$MISSINGJOB" ] && echo yes || echo no)" "the stamp does not create the job dir"
ck "$SIDE" "$STAMP_OUT" "the repo tier supplies the sidecar instead"
ck "" "$STAMP_ERR" "a skipped job-dir tier warns about nothing"

# Tier C is the one any session can find, so it is also the one most likely to be committed by accident
# in a repo that does not already ignore .claude/*. The stamp makes the directory self-ignoring on
# creation and never afterwards: clobbering an existing .gitignore would silently discard whatever
# broader rule a project put there.
mkrepo stamprepo
stamp_env "CLAUDE_SESSION_ID=sess-A" "$WT" '$WTID_STAMP_SIDECAR'
ck "$SIDE" "$STAMP_OUT" "the repo tier lands under the MAIN checkout's .claude/worktree-identity/"
ck "yes" "$([ -f "$SIDE" ] && echo yes || echo no)" "the repo-level sidecar is on disk"
ck "*" "$(cat "$MAINROOT/.claude/worktree-identity/.gitignore")" "the repo tier is made self-ignoring"
mkrepo stampgitignore
mkdir -p "$MAINROOT/.claude/worktree-identity"
printf 'sentinel\n' > "$MAINROOT/.claude/worktree-identity/.gitignore"
stamp_env "CLAUDE_SESSION_ID=sess-A" "$WT"
ck "sentinel" "$(cat "$MAINROOT/.claude/worktree-identity/.gitignore")" "an existing .gitignore is left alone"

# The three env seams /start's resume path and wt-restamp.sh stamp through. Each must reach BOTH tiers:
# a value that lands in config while the sidecar keeps the computed one splits the identity, and the
# sidecar tier is the one every OTHER session reads. They are consumed via ${VAR:-default}, so an EMPTY
# override is treated as unset — a caller passing through an unset variable gets the computed value, not
# a blank field that would read as "this stamp recorded no anchor".
mkrepo stampoverride
stamp_env "CLAUDE_SESSION_ID=sess-A WTID_STAMP_HEAD_SHA_OVERRIDE=deadbeefdeadbeef WTID_STAMP_STAMPED_AT_OVERRIDE=1234567890 WTID_STAMP_CREATED_AT_OVERRIDE=2020-01-01T00:00:00Z" "$WT"
ck "deadbeefdeadbeef" "$(cfg start.head-sha)" "the head-sha override lands in config"
ck "1234567890" "$(cfg start.stamped-at)" "the stamped-at override lands in config"
ck "2020-01-01T00:00:00Z" "$(cfg start.created-at)" "the created-at override lands in config"
ck "deadbeefdeadbeef" "$(skey "$SIDE" WT_IDENTITY_HEAD_SHA)" "the head-sha override lands in the sidecar"
ck "1234567890" "$(skey "$SIDE" WT_IDENTITY_STAMPED_AT)" "the stamped-at override lands in the sidecar"
ck "2020-01-01T00:00:00Z" "$(skey "$SIDE" WT_IDENTITY_CREATED_AT)" "the created-at override lands in the sidecar"
mkrepo stampemptyoverride
stamp_env "CLAUDE_SESSION_ID=sess-A WTID_STAMP_HEAD_SHA_OVERRIDE= WTID_STAMP_STAMPED_AT_OVERRIDE= WTID_STAMP_CREATED_AT_OVERRIDE=" "$WT"
ck "$(git -C "$WT" rev-parse HEAD)" "$(cfg start.head-sha)" "an empty head-sha override falls back to the current tip"
ck "yes" "$(isnum "$(cfg start.stamped-at)")" "an empty stamped-at override falls back to the computed era"
ck "yes" "$(isodate "$(cfg start.created-at)")" "an empty created-at override falls back to the computed instant"

# The sidecar's key set and ORDER are part of the on-disk contract, not an implementation detail: the
# disown path rewrites this file line by line and appends its release key at the END, and wt-disown's
# suite asserts the non-owner lines are byte-identical across that transform. A stamp itself never
# writes a release marker — only a disown does, which is what keeps a fresh stamp from reading released.
mkrepo stampformat
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
ck "WT_IDENTITY_VERSION=1" "$(head -1 "$SIDE")" "the sidecar declares its format version first"
ck "VERSION ISSUE BRANCH SOURCE_BRANCH BASELINE_SHA HEAD_SHA STAMPED_AT WT_DIR OWNER CREATED_AT OWNER_PID OWNER_PID_START OWNER_CLAIMED_AT" \
   "$(sed 's/^WT_IDENTITY_//; s/=.*//' "$SIDE" | tr '\n' ' ' | sed 's/ $//')" "the sidecar carries exactly the stamped key set, in order"
ck "0" "$(grep -c '^WT_IDENTITY_OWNER_RELEASED_AT=' "$SIDE" || true)" "a stamp never writes a release marker into the sidecar"

# The silent-partial-failure class. Both sidecar tiers are best-effort, so a stamp that wrote only one of
# them — or neither — still returns 0 and still reports success to its caller. That contract is exactly
# why wt-restamp.sh implements its own tiers_consistent audit: the library will not surface a split
# identity, and the tier that failed is the one another session may be the only one to read.
mkrepo stampjobfail
JOB="$TMP/stampjobfail/sess-A"; mkdir -p "$JOB"; chmod a-w "$JOB"
stamp_env "CLAUDE_JOB_DIR=$JOB" "$WT" '$WTID_STAMP_SIDECAR'
ck "0" "$STAMP_RC" "an unwritable job-dir tier still returns 0"
ck_has "could not write identity sidecar under" "$STAMP_ERR" "the failed job-dir tier is named on stderr"
ck "$SIDE" "$STAMP_OUT" "WTID_STAMP_SIDECAR falls back to the repo tier"
ck "yes" "$([ -f "$SIDE" ] && echo yes || echo no)" "the repo tier is written even though the job-dir tier failed"
chmod u+w "$JOB"

mkrepo stamprepofail
JOB="$TMP/stamprepofail/sess-A"; mkdir -p "$JOB"
mkdir -p "$MAINROOT/.claude/worktree-identity"; chmod a-w "$MAINROOT/.claude/worktree-identity"
stamp_env "CLAUDE_JOB_DIR=$JOB" "$WT" '$WTID_STAMP_SIDECAR'
ck "0" "$STAMP_RC" "an unwritable repo tier still returns 0"
ck_has "could not write repo-level identity sidecar" "$STAMP_ERR" "the failed repo tier is named on stderr"
ck "$JOB/wt-identity-test-1.env" "$STAMP_OUT" "WTID_STAMP_SIDECAR names the job-dir tier — the first success wins"
chmod u+w "$MAINROOT/.claude/worktree-identity"

mkrepo stampbothfail
JOB="$TMP/stampbothfail/sess-A"; mkdir -p "$JOB"; chmod a-w "$JOB"
mkdir -p "$MAINROOT/.claude/worktree-identity"; chmod a-w "$MAINROOT/.claude/worktree-identity"
stamp_env "CLAUDE_JOB_DIR=$JOB" "$WT" '$WTID_STAMP_SIDECAR'
ck "0" "$STAMP_RC" "a stamp with NO writable sidecar tier still returns 0"
ck "" "$STAMP_OUT" "WTID_STAMP_SIDECAR is empty when no tier took the write"
ck_has "no identity sidecar could be written" "$STAMP_ERR" "the total sidecar failure is announced"
ck_has "git-config-only identity" "$STAMP_ERR" "the announcement names the degraded identity the worktree is left with"
ck "issue-branch" "$(cfg start.worktree-branch)" "the mandatory config tier is written regardless"
chmod u+w "$JOB" "$MAINROOT/.claude/worktree-identity"

# Atomicity (one of the three BF-534 bugs). _wtid_write_sidecar writes to "<path>.tmp.$$" and renames within
# the same directory, so a concurrent reader never sees a half-written block — missing keys parse as an
# all-empty identity, which verifies CLEAN. The rename itself is what has to be pinned, and it is only
# visible from outside: an in-place write and a correct rename produce the same file and the same (absent)
# residue, so residue alone proves nothing about which path ran. The mv shim's log is the direct evidence;
# residue is the secondary check, that neither path leaves litter behind.
mkrepo stampatomic
JOB="$TMP/stampatomic/sess-A"; mkdir -p "$JOB"
: > "$MV_LOG"
stamp_env "CLAUDE_JOB_DIR=$JOB TEST_SHIM=$MVSHIM MV_LOG=$MV_LOG" "$WT"
RENAMES=$(sed 's/\.tmp\.[0-9][0-9]*/.tmp.PID/g' "$MV_LOG")
ck_has "$JOB/wt-identity-test-1.env.tmp.PID $JOB/wt-identity-test-1.env" "$RENAMES" "the job-dir sidecar reaches its final path by renaming its own tmp file"
ck_has "$SIDE.tmp.PID $SIDE" "$RENAMES" "the repo-tier sidecar reaches its final path the same way"
ck "" "$(tmpres "$JOB")" "a successful job-dir write leaves no tmp file behind"
ck "" "$(tmpres "$MAINROOT/.claude/worktree-identity")" "a successful repo-tier write leaves no tmp file behind"

# The cleanup half, which only a FAILING rename can reach: the tmp file is created (the directory is
# writable) and then stranded. An unwritable directory cannot exercise this at all — the write never gets far
# enough to create a tmp file, so no cleanup can be missing. The empty-directory sanity is what stops the
# residue check from silently reading an earlier successful write instead of this failure's leftovers.
mkrepo stampatomicfail
JOB="$TMP/stampatomicfail/sess-A"; mkdir -p "$JOB"
: > "$MV_LOG"
stamp_env "CLAUDE_JOB_DIR=$JOB TEST_SHIM=$MVFAILSHIM MV_LOG=$MV_LOG" "$WT"
ck "0" "$STAMP_RC" "a stamp whose renames all fail still returns 0"
ck_has "$JOB/wt-identity-test-1.env.tmp." "$(cat "$MV_LOG")" "sanity: the tmp file was created and its rename was attempted"
ck "no" "$([ -f "$JOB/wt-identity-test-1.env" ] && echo yes || echo no)" "sanity: no sidecar landed, so nothing here predates the failure"
ck "" "$(tmpres "$JOB")" "a write whose rename fails removes its own tmp file"
ck "" "$(tmpres "$MAINROOT/.claude/worktree-identity")" "the repo tier cleans up after its failed rename too"
ck_has "no identity sidecar could be written" "$STAMP_ERR" "both tiers report the failure rather than swallowing it"

mkrepo stampatomicunwritable
JOB="$TMP/stampatomicunwritable/sess-A"; mkdir -p "$JOB"; chmod a-w "$JOB"
stamp_env "CLAUDE_JOB_DIR=$JOB" "$WT"
ck "" "$(tmpres "$JOB")" "a tier that cannot even create its tmp file leaves the directory untouched"
ck "" "$(tmpres "$MAINROOT/.claude/worktree-identity")" "the surviving tier is still clean after the other one failed"
chmod u+w "$JOB"

# --- Part 4: owner liveness — who holds a worktree, and whether they are still there ---

# The node fixtures are guarded per case rather than suite-wide: Parts 1-3 need no node, and skipping
# the whole file over a missing interpreter would silently drop every one of them. `node` is in
# wt_owner_alive's comm allowlist, so a backgrounded sleeper round-trips pid + start time exactly like a
# real harness — and it is deliberately NOT in wtid_harness_pid's allowlist, which is what stops the
# fixture from also being mistaken for this session's own harness.
HAVE_NODE=no
command -v node >/dev/null 2>&1 && HAVE_NODE=yes
# A skip drops coverage, so it has to be visible in the tally: on a node-less or python3-less machine the
# footer would otherwise be indistinguishable from a run that verified everything, and this suite gates
# `pnpm check`. Counted, never fatal — a missing interpreter is not a regression.
skip() { echo "SKIP  $1"; skipped=$((skipped + 1)); }

LIVE=""; DEAD=""
spawn_live() { # a pid wt_owner_alive will adjudicate as a live harness
  node -e 'setTimeout(function () {}, 600000)' &
  LIVE=$!
  LIVE_PIDS="$LIVE_PIDS $LIVE"
  disown "$LIVE" 2>/dev/null || true   # out of the job table, so the trap's kill stays silent
}
# Deliberately NOT node: the verdict here comes from the pid being reaped, not from its comm, so requiring
# an interpreter would gate a node-free contract behind one. Every dead-pid case uses this instead of a
# hardcoded "high" pid — systemd sets kernel.pid_max to 4194304 on 64-bit Linux, so pids in the millions
# are routinely allocated and a hardcoded one is a coin flip, not a constant.
spawn_dead() { # a pid with positive evidence of death (exited and reaped)
  ( exit 0 ) &
  DEAD=$!
  wait "$DEAD" 2>/dev/null || true
}
# The reap frees the pid, and the fixtures fork `env`, `bash` and several `git` processes before the
# verdict is read — any of which could land on it and turn a deterministic 'dead' into a flake. Asserted
# immediately before each verdict so a recycled pid fails loudly here instead of silently there.
pid_gone() { # pid -> yes when nothing holds it
  ps -o comm= -p "$1" >/dev/null 2>&1 && echo no || echo yes
}
OTHER=""
spawn_other() { # a LIVE pid whose comm is deliberately outside wt_owner_alive's harness allowlist
  sleep 600 &
  OTHER=$!
  LIVE_PIDS="$LIVE_PIDS $OTHER"
  disown "$OTHER" 2>/dev/null || true
}

# Prints "<rc>:<verdict>" from a pristine subshell. Both are load-bearing and callers split across them:
# wt-disown.sh branches on the return code, wt-owner.sh reports the verdict string.
alive() { # wt_dir ["VAR=VAL ..."]
  local wt="$1" assigns="${2-}"
  env $assigns bash -c "$SHIMPATH . '$IDLIB'; wt_owner_alive '$wt'; rc=\$?; printf '%s:%s' \"\$rc\" \"\$WTID_OWNER_ALIVE\""
}
owner_fields() { # wt_dir ["VAR=VAL ..."] -> "<session>:<pid>" as wt_owner_alive resolved them
  local wt="$1" assigns="${2-}"
  env $assigns bash -c "$SHIMPATH . '$IDLIB'; wt_owner_alive '$wt' >/dev/null 2>&1; printf '%s:%s' \"\$WTID_OWNER_SESSION\" \"\$WTID_OWNER_PID\""
}
isme() { # wt_dir ["VAR=VAL ..."] -> wt_owner_is_me's status, resolved after wt_owner_alive as required
  local wt="$1" assigns="${2-}"
  env $assigns bash -c "$SHIMPATH . '$IDLIB'; wt_owner_alive '$wt' >/dev/null 2>&1; wt_owner_is_me; echo \$?"
}

# The four verdicts and their four distinct return codes. Automation routes on all four differently —
# alive is hands-off, dead and released are resumable, unknown must fail safe — so collapsing any two of
# them silently changes what a parallel session is allowed to do to a worktree it does not own.
if [ "$HAVE_NODE" = yes ]; then
  mkrepo ownerlive
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  ck "0:alive" "$(alive "$WT")" "a running harness process adjudicates alive (rc 0)"
else
  skip "node not available — the live-owner fixture needs an allowlisted long-running process"
fi
mkrepo ownerdead
spawn_dead
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$DEAD" "$WT"
ck "yes" "$(pid_gone "$DEAD")" "sanity: the reaped pid is still unallocated, so 'dead' is a real verdict"
ck "1:dead" "$(alive "$WT")" "an exited, reaped owner adjudicates dead (rc 1)"
mkrepo ownerunknown
stamp_env "TEST_SHIM=$PSSHIM" "$WT"
ck "2:unknown" "$(alive "$WT")" "no owner pid and no release marker adjudicates unknown (rc 2)"

# Broken ps visibility, the BF-510 shape: a sandboxed background-job shell whose ps sees only its own
# sandbox returns empty for a pid that is genuinely alive outside it — four live siblings read "dead" in
# one /auto preflight, and one was resumed mid-run. "dead" needs POSITIVE evidence, and an empty result
# from a blind ps is not it: the PID-1 canary (alive on every host, visible to any unsandboxed ps) is what
# separates "the owner is gone" from "this shell cannot see". The stamp lands under a REAL ps — only the
# adjudication runs under the all-failing shim, exactly the asymmetry of the observed incident.
mkrepo ownerblindps
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$$" "$WT"
ck "yes" "$(nonempty "$(cfg start.owner-pid)")" "sanity: the blind-ps fixture stamped a live owner pid"
ck "2:unknown" "$(alive "$WT" "TEST_SHIM=$PSSHIM")" "an owner pid a blind ps cannot see adjudicates unknown, never dead"

# Death by RECYCLING, the case a bare "is the pid still there" test cannot see: the owning harness exited and
# the OS handed its pid to something else entirely. The reaped-pid fixture above exits on the empty comm and
# never reaches the allowlist, so without this the branch is dead code — and a broken one reports every
# recycled pid as alive, locking every other session out of a long-dead worktree for that pid's lifetime.
mkrepo ownerrecycled
spawn_other
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$OTHER" "$WT"
ck "yes" "$(nonempty "$(cfg start.owner-pid)")" "sanity: the recycled-pid fixture stamped a pid that is genuinely running"
ck "1:dead" "$(alive "$WT")" "a live pid running something that is not a harness is a recycled pid, not the owner"

# The subtler recycling: the pid was handed to ANOTHER harness, so comm still passes the allowlist and only
# the start time tells the two apart. This is the entire reason owner-pid-start is stamped at all. Both
# fixtures elsewhere are self-consistent by construction — the same wtid_pid_start call on the same pid at
# stamp and at check — so a stored value that DISAGREES with the running process exists only here.
if [ "$HAVE_NODE" = yes ]; then
  mkrepo ownerrestarted
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  ck "0:alive" "$(alive "$WT")" "sanity: the fixture reads alive while the stamped start time is the true one"
  git -C "$WT" config --worktree start.owner-pid-start 'Mon Jan  1 00:00:00 2020'
  ck "1:dead" "$(alive "$WT")" "a running harness whose start time is not the stamped one is a recycled pid"
else
  skip "node not available — the recycled-into-another-harness fixture needs a live allowlisted process"
fi

# Start times are compared as strings, so the stamped side and the checked side must be normalized the same
# way — real `ps -o lstart=` pads a single-digit day with an extra space and some platforms indent the whole
# field, and a raw comparison would then read the owner's own live process as a recycled one and hand its
# worktree away. The shim always emits the padded shape; the stored value is the normalized form of it. An
# EMPTY stored value makes the library skip the start-time comparison entirely and fall through to alive on
# comm alone, so the case would still read 0:alive while proving nothing — hence the sanity assertion.
mkrepo ownerpidstartws
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=424242" "$WT"
git -C "$WT" config --worktree start.owner-pid-start 'Mon Jan 1 00:00:00 2020'
ck "yes" "$(nonempty "$(cfg start.owner-pid-start)")" "sanity: a start time is stored, so the comparison is actually reached"
ck "0:alive" "$(alive "$WT" "TEST_SHIM=$PADSHIM")" "a start time that matches only after whitespace normalization still reads alive"
mkrepo ownerreleased
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
bash -c ". '$IDLIB'; wt_identity_disown '$WT' test-1" >/dev/null 2>&1
ck "3:released" "$(alive "$WT")" "a deliberate release with no surviving pid adjudicates released (rc 3)"

# A resolvable pid ALWAYS outranks a release marker. Half-written releases and half-written stamps both
# produce this state, and the only unsafe direction is a false "released": it hands a worktree another
# session may still be working to whoever asks next. Degrading to alive or unknown merely delays.
mkrepo ownerhalf
spawn_dead
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$DEAD" "$WT"
git -C "$WT" config --worktree start.owner-released-at 1700000000
ck "yes" "$(pid_gone "$DEAD")" "sanity: the stamped pid is unallocated, so the verdict turns on the pid rather than on luck"
ck "1:dead" "$(alive "$WT")" "a stale pid beside a release marker adjudicates dead, never released"
if [ "$HAVE_NODE" = yes ]; then
  mkrepo ownerhalflive
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  git -C "$WT" config --worktree start.owner-released-at 1700000000
  ck "0:alive" "$(alive "$WT")" "a LIVE pid beside a release marker keeps the worktree claimed"
else
  skip "node not available — the live-pid-beats-released fixture needs it"
fi

# --- Session-scoped liveness (BF-1103): the owner's job dir answers at session granularity, and it
# outranks the pid walk in BOTH directions. A fleet's pid tier is root-shared — a live root strands a
# done session's worktree, and a root exit (or a pool chain reparented to pid 1, which stamps a BLANK
# pid) false-orphans live ones — so the daemon's per-session state.json/timeline.jsonl is the ground
# truth wherever it exists. CLAUDE_JOB_DIR pins the jobs root inside $TMP for these cases:
# _wtid_jobs_root reads the owner's dir as a SIBLING of the probing session's own.
JOBSROOT="$TMP/jobs"
mkdir -p "$JOBSROOT/self"
mkjob() { # session state — (re)writes $JOBSROOT/<session>/state.json with a fresh mtime
  mkdir -p "$JOBSROOT/$1"
  printf '{"state": "%s", "tempo": "idle"}\n' "$2" > "$JOBSROOT/$1/state.json"
}

# Terminal session state is positive death evidence and must beat a pid the walk calls alive — the
# shared fleet root outliving a done session is the stranding direction.
if [ "$HAVE_NODE" = yes ]; then
  mkrepo sessdone
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  mkjob sess-A done
  ck "1:dead" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "a terminal session state adjudicates dead even while the stamped pid is a live harness"

  # `stopped` is the harness's user/operator-stop terminal spelling (its own terminal set is
  # done|failed|stopped — BF-1248); a dead set missing it read the stopped owner as alive through
  # the shared fleet root pid, which is exactly what this live-pid fixture would reproduce.
  mkrepo sessstopped
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  mkjob sess-A stopped
  ck "1:dead" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "a stopped session adjudicates dead even while the stamped pid is a live harness"

  # `crashed` is in the daemon's vocabulary but NOT its terminal set (auto-resume exists): it must
  # answer alive on fresh evidence, never dead — mapping it dead would hand a resuming session's
  # worktree to a sibling.
  mkrepo sesscrashed
  spawn_live
  stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$LIVE" "$WT"
  mkjob sess-A crashed
  ck "0:alive" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "a crashed (auto-resumable) session with fresh evidence stays non-terminal"
else
  skip "node not available — the terminal-state-beats-live-pid fixture needs a live allowlisted process"
fi

# Fresh activity on a non-terminal session is positive life evidence and must beat a dead pid — the
# false-orphaning direction, which the create gate would otherwise turn into a takeover of live work.
mkrepo sessalive
spawn_dead
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$DEAD" "$WT"
mkjob sess-A running
ck "yes" "$(pid_gone "$DEAD")" "sanity: the stamped pid is unallocated, so the verdict below comes from the session probe"
ck "0:alive" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "fresh non-terminal session activity adjudicates alive over a dead stamped pid"

# A stale non-terminal job dir answers nothing: fall through to the pid tier, and with nothing there
# either, the verdict is unknown — which start-wt-create.sh now REFUSES for a foreign claim (fail closed).
mkrepo sessstale
stamp_env "TEST_SHIM=$PSSHIM CLAUDE_SESSION_ID=sess-A" "$WT"
mkjob sess-A running
touch -t 202001010000 "$JOBSROOT/sess-A/state.json"
ck "2:unknown" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "a stale non-terminal job dir proves nothing — unknown, never alive or dead"

# released is adjudicated before the session probe: a releaser that is still alive (it deliberately
# walked away and moved on to other work) must not resurrect its own handoff to 'alive'.
mkrepo sessreleased
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
bash -c ". '$IDLIB'; wt_identity_disown '$WT' test-1" >/dev/null 2>&1
mkjob sess-A running
ck "3:released" "$(alive "$WT" "CLAUDE_JOB_DIR=$JOBSROOT/self")" "a deliberate release stays released while the releasing session is demonstrably alive"

# Per-worktree git config is authoritative for ownership because every stamp rewrites it latest-wins: a
# stale same-issue sidecar sitting in OUR job dir must not shadow another session's takeover.
#
# BF-546 removed the per-FIELD gap-fill this block used to pin. Filling field by field is what CREATES the
# splice — a pid from one stamp landing beside a session id from another asserts an owner no stamp ever wrote,
# and wt_owner_is_me and wt-disown's session gate would then adjudicate a fiction. The tuple now moves WHOLE
# or not at all: config is consulted first, and it is consulted only when COMPLETE (a pid, or a released
# marker). Anything else is a torn write — the shape an interrupted /start leaves — and falls through to a
# path-verified sidecar taken entire, constrained to the newest session id so a superseded owner cannot
# resurrect itself. Measured before the gate existed: a torn {session, no pid} erased a LIVE owner into
# `unknown`, and the reuse guard admits on unknown, so a second session entered the worktree.
mkrepo ownerauthority
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
set_key "$SIDE" WT_IDENTITY_OWNER sidecar-session
set_key "$SIDE" WT_IDENTITY_OWNER_PID 424242
ck "sidecar-session" "$(skey "$SIDE" WT_IDENTITY_OWNER)" "sanity: the sidecar now disagrees with config"
ck "sess-A:999999" "$(owner_fields "$WT")" "a COMPLETE config tuple wins outright over a divergent sidecar"
git -C "$WT" config --worktree --unset start.owner-session
ck ":999999" "$(owner_fields "$WT")" "a config carrying a pid is COMPLETE, so an absent session id stays absent rather than borrowed"
git -C "$WT" config --worktree start.owner-session sess-A
git -C "$WT" config --worktree --unset start.owner-pid
ck "sess-A:" "$(owner_fields "$WT")" "and a torn config is completed only from ITS OWN session's sidecar, never a foreign one"

# wt_owner_alive re-enters wt_identity_load to reach the sidecar, so it overwrites EVERY identity global
# the caller had loaded. wt-restamp.sh:99-105 snapshots baseline/branch/issue/source/anchor/era around
# the call for exactly this reason; pinning the side effect means a refactor that changes it breaks a
# test rather than a caller that reads a stale-looking global back.
mkrepo ownerclobber
BASE=$(git -C "$WT" merge-base issue-branch main)
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
git -C "$WT" config --worktree --unset start.owner-session   # forces the gap-fill path, which is what re-loads
clobbered=$(bash -c ". '$IDLIB'
  WTID_SOURCE=sentinel; WTID_ISSUE=sentinel; WTID_BRANCH=sentinel; WTID_BASELINE=sentinel
  wt_owner_alive '$WT' >/dev/null 2>&1
  printf '%s|%s|%s|%s' \"\$WTID_SOURCE\" \"\$WTID_ISSUE\" \"\$WTID_BRANCH\" \"\$WTID_BASELINE\"")
ck "repo-fallback|test-1|issue-branch|$BASE" "$clobbered" "wt_owner_alive overwrites the caller's loaded identity"

# Session ids come first, and ANY of the three counts: a fleet run stamps its job-dir basename, and the
# same session continuing under a different job dir presents that same id as CLAUDE_CODE_SESSION_ID.
# Matching only the first-resolved id strands the real owner outside its own worktree.
mkrepo ismealt
JOB="$TMP/ismealt/sess-J"; mkdir -p "$JOB"
stamp_env "CLAUDE_JOB_DIR=$JOB CLAUDE_HARNESS_PID=999999" "$WT"
ck "sess-J" "$(cfg start.owner-session)" "sanity: the fleet stamp records the job-dir basename as owner"
OTHERJOB="$TMP/ismealt/other-job"; mkdir -p "$OTHERJOB"
ck "0" "$(isme "$WT" "CLAUDE_JOB_DIR=$OTHERJOB CLAUDE_CODE_SESSION_ID=sess-J")" "the owner is recognized through an alternate identifier"

# The foreign-id short-circuit, and the fixture is built so ONLY it can produce the refusal: the checking
# session presents the very pid the stamp recorded, so the pid fallback underneath would answer "me". A
# stamped id we cannot present must therefore be decisive by itself — in a fleet every sibling session's
# harness walk collapses to one shared root pid, so a leaky short-circuit hands each sibling the others'
# worktrees. The pid is a reaped one, which is nobody's regardless of what the OS has since allocated.
mkrepo ismeforeign
spawn_dead
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=$DEAD" "$WT"
ck "0" "$(isme "$WT" "CLAUDE_HARNESS_PID=$DEAD")" "sanity: presenting no id of our own, the shared pid alone makes us the owner"
ck "1" "$(isme "$WT" "CLAUDE_SESSION_ID=sess-B CLAUDE_HARNESS_PID=$DEAD")" "a session presenting only foreign ids is not the owner, even where the pid would have matched"

# The pid fallback, both directions. It exists for environments where no session id was stamped or none
# is resolvable here — and in a fleet the harness walk collapses to the shared root, so this path can
# only ever be reached when session ids cannot decide.
mkrepo ismepid
stamp_env "CLAUDE_HARNESS_PID=999999" "$WT"
ck "no" "$(has_cfg start.owner-session)" "sanity: the id-less stamp left no owner session to compare"
ck "0" "$(isme "$WT" "CLAUDE_HARNESS_PID=999999")" "with no stamped session id, pid equality decides"
ck "1" "$(isme "$WT" "CLAUDE_HARNESS_PID=424242")" "a different harness pid is a foreign session"
mkrepo ismenoid
stamp_env "CLAUDE_SESSION_ID=sess-A CLAUDE_HARNESS_PID=999999" "$WT"
ck "0" "$(isme "$WT" "CLAUDE_HARNESS_PID=999999")" "a session that can present NO id of its own falls back to the pid"
ck "1" "$(isme "$WT" "CLAUDE_HARNESS_PID=424242")" "and is foreign when the pid differs too"
mkrepo ismeblank
stamp_env "TEST_SHIM=$PSSHIM" "$WT"
ck "1" "$(isme "$WT" "TEST_SHIM=$PSSHIM")" "an unattributable owner and an unidentifiable session is not a match"

# wtid_session_ids is the input to every ownership comparison, so its silence has to be safe: it may
# legitimately print nothing, and a non-zero exit there would abort a caller running under set -e
# before the pid fallback it exists to reach.
IDENV="CLAUDE_JOB_DIR=$TMP/ids/job-base CLAUDE_CODE_SESSION_ID=sess-code CLAUDE_SESSION_ID=sess-plain"
ck "$(printf 'job-base\nsess-code\nsess-plain')" "$(env $IDENV bash -c ". '$IDLIB'; wtid_session_ids")" "the three identifiers print in the documented order"
ck "sess-plain" "$(env "CLAUDE_SESSION_ID=sess-plain" bash -c ". '$IDLIB'; wtid_session_ids")" "unset identifiers are skipped, not printed as blanks"
ck "0:" "$(bash -c ". '$IDLIB'; out=\$(wtid_session_ids); printf '%s:%s' \"\$?\" \"\$out\"")" "a session with no identifiers prints nothing and still exits 0"

# wtid_owner_session_matches is the STRICT gate — exact equality, no pid fallback — and wt-restamp.sh and
# wt-disown.sh depend on that strictness: in a `claude agents` fleet every sibling session's harness walk
# lands on the same root pid, so the lenient wt_owner_is_me would call every sibling's worktree its own.
# The last pair is the contrast: identical state, opposite answers.
ck "1" "$(env "CLAUDE_SESSION_ID=sess-A" bash -c ". '$IDLIB'; WTID_OWNER_SESSION=''; wtid_owner_session_matches; echo \$?")" "an empty owner session matches nothing, however many ids we present"
ck "0" "$(env "CLAUDE_SESSION_ID=sess-A" bash -c ". '$IDLIB'; WTID_OWNER_SESSION=sess-A; wtid_owner_session_matches; echo \$?")" "an exact id match is a match"
ck "1" "$(env "CLAUDE_SESSION_ID=sess-A-2" bash -c ". '$IDLIB'; WTID_OWNER_SESSION=sess-A; wtid_owner_session_matches; echo \$?")" "matching is exact string equality, not a prefix test"
ck "1" "$(env "CLAUDE_HARNESS_PID=999999" bash -c ". '$IDLIB'; WTID_OWNER_SESSION=foreign; WTID_OWNER_PID=999999; wtid_owner_session_matches; echo \$?")" "the strict gate refuses a matching pid under a foreign session id"
ck "0" "$(env "CLAUDE_HARNESS_PID=999999" bash -c ". '$IDLIB'; WTID_OWNER_SESSION=foreign; WTID_OWNER_PID=999999; wt_owner_is_me; echo \$?")" "sanity: on identical state wt_owner_is_me is the lenient one"

# wtid_pid_start must never fail (one of the three BF-534 bugs): a bare `ps` failure propagated through
# the pipeline and, under a caller's `set -eo pipefail`, aborted the whole stamp with no output and no
# identity written. The flags are set here so a regression reproduces that original abort rather than
# just returning the wrong string. The pid is a reaped one rather than a "high" constant: on 64-bit Linux
# systemd raises kernel.pid_max to 4194304, so seven-digit pids are routinely allocated.
spawn_dead
ck "yes" "$(pid_gone "$DEAD")" "sanity: the pid handed to wtid_pid_start really does resolve to nothing"
ck "survived:" "$(bash -c "set -eo pipefail; . '$IDLIB'; s=\$(wtid_pid_start $DEAD); printf 'survived:%s' \"\$s\"")" "an unresolvable pid returns empty without aborting a set -eo pipefail caller"
ck "yes" "$(bash -c ". '$IDLIB'; [ -n \"\$(wtid_pid_start \$\$)\" ] && echo yes || echo no")" "a resolvable pid returns its start time"

# wtid_harness_pid short-circuits on a pre-resolved CLAUDE_HARNESS_PID without validating it — that is
# what lets the node fixtures above stand in for a harness. When the walk finds no claude ancestor it
# must exit 1 with NO output: callers treat empty as "unknown", and a stray line would become a pid.
ck "0:424242" "$(env "CLAUDE_HARNESS_PID=424242" bash -c ". '$IDLIB'; out=\$(wtid_harness_pid); printf '%s:%s' \"\$?\" \"\$out\"")" "a pre-resolved harness pid short-circuits the ancestor walk"
ck "1:" "$(env "PATH=$PSSHIM:$PATH" bash -c ". '$IDLIB'; out=\$(wtid_harness_pid); printf '%s:%s' \"\$?\" \"\$out\"")" "an unwalkable ancestry exits 1 with no output"

# wt_identity_owner picks the first available id in the same order wtid_session_ids prints them, so the
# id a stamp RECORDS is always one the same session will later present. No id is not an error: identity
# still works, ownership just is not attributable.
ck "job-base" "$(env "CLAUDE_JOB_DIR=$TMP/ids/job-base" "CLAUDE_CODE_SESSION_ID=sess-code" "CLAUDE_SESSION_ID=sess-plain" bash -c ". '$IDLIB'; wt_identity_owner")" "the job-dir basename is the preferred owner id"
ck "sess-code" "$(env "CLAUDE_CODE_SESSION_ID=sess-code" "CLAUDE_SESSION_ID=sess-plain" bash -c ". '$IDLIB'; wt_identity_owner")" "CLAUDE_CODE_SESSION_ID is next"
ck "sess-plain" "$(env "CLAUDE_SESSION_ID=sess-plain" bash -c ". '$IDLIB'; wt_identity_owner")" "CLAUDE_SESSION_ID is last"
ck "0:" "$(bash -c ". '$IDLIB'; out=\$(wt_identity_owner); printf '%s:%s' \"\$?\" \"\$out\"")" "a session with no identifiers yields no owner and still exits 0"

# --- Part 5: the cross-script pipeline contract — /start's stamp, /finish's check, the sanctioned restamp ---

# Parts 1-4 call the library directly and therefore cannot reach the seam BF-505 actually broke: the
# identity start-wt-create.sh WRITES versus the values finish-detect-mode.sh reads back and hands to
# finish-recover.sh. Part 5 runs the three real scripts in the order the BF-534 loop runs them and asserts
# both the exit code and the stdout KEY=value contract at every step. start-wt-setup.sh — the parent — is
# deliberately not invoked: it needs gh + linear-cli, reaches the network, and refuses to run from inside a
# worktree. Its locked child start-wt-create.sh is the stub boundary, and it runs the identical stamp path.
CREATE="$DIR/start-wt-create.sh"
DETECT="$DIR/finish-detect-mode.sh"
RESTAMP="$DIR/wt-restamp.sh"

# wt-restamp.sh re-execs under with-repo-lock.py unconditionally, so python3 is a hard dependency of every
# case that calls it — guarded per case like node above, so a missing interpreter cannot also drop the
# detect-mode half of this part.
HAVE_PY=no
command -v python3 >/dev/null 2>&1 && HAVE_PY=yes

OUT=""; ERR=""; RC=0

# start-wt-create.sh's FRESH path is the only mode that establishes a NEW identity, and it requires both the
# worktree dir and the branch to be absent — mkrepo pre-creates them for the library cases, so they are
# removed again here. Everything else about the fixture has to survive: the test-1 naming and
# extensions.worktreeConfig are what keep the sidecar and per-worktree tiers reachable at all.
mkrepo_nowt() { # name — repo only; start-wt-create.sh creates the worktree itself
  mkrepo "$1"
  git -C "$REPO" worktree remove --force "$WT"
  git -C "$REPO" branch -D issue-branch >/dev/null
}

# The real /start create, invoked exactly as start-wt-setup.sh invokes it under the repo lock: cwd inside
# the repo, 5 args. stderr goes to a file rather than 2>&1 so stdout stays a parseable KEY=value contract.
real_start() { # [session] — operates on $REPO/$WT
  local sess="${1-sess-A}" errf="$TMP/stderr.txt"
  OUT=$(cd "$REPO" && env "CLAUDE_SESSION_ID=$sess" "$CREATE" test-1 test-1 issue-branch main "$WT" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

# finish-detect-mode.sh resolves the worktree from its own cwd (git config --worktree and rev-parse, with no
# -C), so it must run from INSIDE the worktree or it would report on the main checkout instead.
dm() { # session — detect-mode merge on $WT
  local sess="$1" errf="$TMP/stderr.txt"
  OUT=$(cd "$WT" && env "CLAUDE_SESSION_ID=$sess" "$DETECT" merge 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

run_restamp() { # session args...
  local sess="$1" errf="$TMP/stderr.txt"; shift
  OUT=$(env "CLAUDE_SESSION_ID=$sess" "$RESTAMP" "$@" 2>"$errf"); RC=$?
  ERR=$(cat "$errf")
}

kv() { # key -> its value on the last captured stdout
  printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1
}

# Step 1 — the stamp. Every emitted key is asserted, not just the exit code: the parent parses this block
# and a silently dropped line degrades /start to a worktree with no recorded identity at all. CREATED_WT is
# the one key nothing else in the pipeline reads back, so only an assertion here holds it — start-wt-setup.sh
# gates both the warm `pnpm install` and its own cleanup trap on it, and mkrepo_nowt forces the fresh path,
# which is exactly the path that must report 1.
mkrepo_nowt pipeline
real_start sess-A
ck_rc "0" "$RC" "the real /start create stamps a fresh worktree"
ck "1" "$(kv CREATED_WT)" "/start reports that it created the worktree rather than reusing one"
ck "$WT" "$(kv WT_ABS)" "/start reports the worktree it created"
ck "issue-branch" "$(kv BRANCH)" "/start reports the branch"
ck "main" "$(kv SOURCE_BRANCH)" "/start reports the source branch"
ck "$(git -C "$WT" rev-parse HEAD)" "$(kv BASELINE_SHA)" "/start reports the fork point as the baseline"
ck "sess-A" "$(kv OWNER_SESSION)" "/start reports the owning session"
ck "$SIDE" "$(kv IDENTITY_SIDECAR)" "/start reports the immune sidecar it wrote"
START_BASELINE=$(kv BASELINE_SHA); START_BRANCH=$(kv BRANCH); START_SOURCE=$(kv SOURCE_BRANCH)

# Step 2 — /finish's check on the worktree /start just handed it. IDENTITY_SOURCE is asserted too: a
# detection that fell through to `none` reports CORRUPTION=0 for the trivial reason that it checked nothing.
dm sess-A
ck_rc "0" "$RC" "detection passes on the worktree /start just stamped"
ck "0" "$(kv CORRUPTION)" "the fresh worktree reports no corruption"
ck "repo-fallback" "$(kv IDENTITY_SOURCE)" "detection read a real identity tier rather than none"

# Step 3 — the rewrite. The amend is what makes this a rewrite rather than an advance, and it is essential:
# rebasing onto an APPEND-ONLY source leaves the fork point an ancestor of HEAD, so the baseline stays
# attached, detection stays green, and the entire exit-4 half of this pipeline would never fire.
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
( cd "$WT" && $G rebase -q main ) >/dev/null 2>&1

# Step 4 — the gate closes.
dm sess-A
ck_rc "4" "$RC" "the rewrite turns detection into the exit-4 gate"
ck "1" "$(kv CORRUPTION)" "the exit-4 report flags corruption"
ck "baseline-detached" "$(kv CORRUPTION_REASON)" "the reason names the detached baseline, which is what routes to the restamp"
ck "1" "$(kv CORRUPTION_OWNER_IS_ME)" "the stamping session is attributed as the owner"

# The value round trip — the seam itself, and the reason this part exists. EXPECTED_BASELINE, EXPECTED_BRANCH
# and EXPECTED_SOURCE_BRANCH are precisely the arguments /finish hands to finish-recover.sh, so a drift
# anywhere between the two scripts is a recovery run against the wrong worktree. Non-emptiness is asserted
# separately: two empty strings compare equal, so an equality-only test would also pass on a contract where
# neither side carried anything at all.
ck "yes" "$(nonempty "$START_BASELINE")" "sanity: /start emitted a baseline to round-trip"
ck "yes" "$(nonempty "$START_BRANCH")" "sanity: /start emitted a branch to round-trip"
ck "yes" "$(nonempty "$START_SOURCE")" "sanity: /start emitted a source branch to round-trip"
ck "$START_BASELINE" "$(kv EXPECTED_BASELINE)" "the stamped baseline comes back byte-identical to /finish"
ck "$START_BRANCH" "$(kv EXPECTED_BRANCH)" "the stamped branch comes back byte-identical to /finish"
ck "$START_SOURCE" "$(kv EXPECTED_SOURCE_BRANCH)" "the stamped source branch comes back byte-identical to /finish"

# Attribution across the seam. A foreign session sees the same verdict — owner-is-me at check time cannot
# prove the owner moved HEAD, so the field changes the advice printed on stderr and nothing else.
dm sess-B
ck_rc "4" "$RC" "the verdict never softens for a foreign session"
ck "0" "$(kv CORRUPTION_OWNER_IS_ME)" "a foreign session is not attributed as the owner"
ck "baseline-detached" "$(kv CORRUPTION_REASON)" "and the reason is unchanged by who is asking"

# Steps 5-7 — the sanctioned rewrite is blessed, detection goes green again, and re-running the restamp
# changes nothing. The closing noop is what makes the loop safe to re-enter: /finish may run detection more
# than once, and a restamp that re-baselined on every call would advance the audit window each time.
if [ "$HAVE_PY" = yes ]; then
  run_restamp sess-A "$WT"
  ck_rc "0" "$RC" "the owner's restamp sanctions the rewrite"
  ck "RESTAMP=ok" "$(printf '%s\n' "$OUT" | head -1)" "the restamp reports ok on its first stdout line"
  dm sess-A
  ck_rc "0" "$RC" "detection passes again — the round trip closes"
  ck "0" "$(kv CORRUPTION)" "the restamped worktree reports no corruption"
  # The same rule step 2 states, and it matters more here: a restamp that DESTROYED the identity makes the
  # load fail, detection fall through to none, and CORRUPTION=0 — so "passes again" would pass precisely
  # because nothing was checked. The tier is repo-fallback because dm exports no job dir.
  ck "repo-fallback" "$(kv IDENTITY_SOURCE)" "the restamped worktree still has a real identity tier to be checked against"
  run_restamp sess-A "$WT"
  ck "RESTAMP=noop" "$(printf '%s\n' "$OUT" | head -1)" "a second restamp is a noop"
else
  skip "python3 not available — the restamp half of the pipeline needs with-repo-lock.py"
fi

# The pipeline's gate cannot be cleared by simply re-running the restamp, which is the property BF-534 was
# about. A hostile reset reaches detection looking exactly like the sanctioned rewrite above — same exit
# code, same reason — and only the preservation audit inside wt-restamp.sh tells them apart. Laundering here
# would hand a merge to whichever session reset the worktree last.
mkrepo_nowt phijack
real_start sess-A
ck_rc "0" "$RC" "the real /start create stamps the hijack fixture"
HIJACK_BASELINE=$(kv BASELINE_SHA)
ck "yes" "$(nonempty "$HIJACK_BASELINE")" "sanity: /start emitted a baseline the refusal must leave untouched"
( cd "$WT" && echo work > work.txt && $G add work.txt && $G commit -qm "W: hijacked work" ) >/dev/null
( cd "$REPO" && $G commit -q --amend -m "A2: rewritten pre-fork" ) >/dev/null
( cd "$REPO" && echo b > b.txt && $G add b.txt && $G commit -qm "B: post-rewrite" ) >/dev/null
git -C "$WT" reset -q --hard main
dm sess-A
ck_rc "4" "$RC" "a reset onto the rewritten source reaches detection as exit 4 too"
ck "baseline-detached" "$(kv CORRUPTION_REASON)" "and is indistinguishable from the sanctioned rewrite at the gate"
if [ "$HAVE_PY" = yes ]; then
  run_restamp sess-A "$WT"
  ck_rc "5" "$RC" "the restamp refuses to launder a reset that dropped work (exit 5)"
  ck_has "W: hijacked work" "$ERR" "the refusal names the commit that would have been laundered away"
  ck "$HIJACK_BASELINE" "$(git -C "$WT" config --worktree --get start.baseline-sha)" "the refused restamp left the stamped baseline untouched"
  dm sess-A
  ck_rc "4" "$RC" "the worktree is still gated after the refusal"
else
  skip "python3 not available — the hijack refusal needs the real restamp"
fi

# A branch swap is refused by a DIFFERENT gate (exit 4, the branch check) before the preservation audit ever
# runs — checking a worktree out onto another branch is not a self-rebase, whatever it preserved.
mkrepo_nowt pswap
real_start sess-A
ck_rc "0" "$RC" "the real /start create stamps the branch-swap fixture"
( cd "$WT" && $G checkout -q -b other-branch ) >/dev/null 2>&1
dm sess-A
ck_rc "4" "$RC" "a branch swap is exit 4 at detection"
ck "branch-swapped" "$(kv CORRUPTION_REASON)" "the reason distinguishes a swap from a detached baseline"
if [ "$HAVE_PY" = yes ]; then
  run_restamp sess-A "$WT"
  ck_rc "4" "$RC" "the restamp refuses a branch swap (exit 4)"
  ck_has "branch-swapped is not a self-rebase" "$ERR" "the refusal names the gate that fired"
else
  skip "python3 not available — the branch-swap refusal needs the real restamp"
fi

# The third reason routes the opposite way, and that contrast is the point: a wiped source-branch config is
# tampering the restamp REPAIRS rather than refuses, because nothing about the history moved. A suite that
# only covered baseline-detached would leave both of the other reasons free to change outcome unnoticed.
mkrepo_nowt pwipe
real_start sess-A
ck_rc "0" "$RC" "the real /start create stamps the config-wipe fixture"
git -C "$WT" config --worktree --unset start.source-branch
dm sess-A
ck_rc "4" "$RC" "a wiped source-branch config is exit 4 at detection"
ck "source-branch-config-wiped" "$(kv CORRUPTION_REASON)" "the reason names the wipe"
# This fixture is the only one that reaches detect-mode's sidecar SOURCE_BRANCH fallback: the config key
# it normally reads is gone, so the emitted value can only come from the loaded identity. Nothing else
# asserts it, and without it the fallback could be deleted outright — handing recovery an empty source
# branch — with the reason and exit code below still green.
ck "main" "$(kv SOURCE_BRANCH)" "the sidecar's source branch substitutes for the wiped config key"
if [ "$HAVE_PY" = yes ]; then
  run_restamp sess-A "$WT"
  ck_rc "0" "$RC" "the restamp repairs a wipe instead of refusing it"
  ck "RESTAMP=ok" "$(printf '%s\n' "$OUT" | head -1)" "the repair is a real re-stamp, never a noop"
  ck "main" "$(git -C "$WT" config --worktree --get start.source-branch)" "the wiped config key is written back"
  dm sess-A
  ck_rc "0" "$RC" "detection goes clean after the repair"
  ck "0" "$(kv CORRUPTION)" "and reports no corruption"
  ck "repo-fallback" "$(kv IDENTITY_SOURCE)" "the repaired worktree still has a real identity tier, so the clean verdict is a real one"
else
  skip "python3 not available — the config-wipe repair needs the real restamp"
fi

echo "----------------------------------------"
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ]
