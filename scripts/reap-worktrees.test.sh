#!/usr/bin/env bash
# Functional suite for reap-worktrees.sh — the completion-evidence and liveness gates that decide whether
# a /start wt worktree is destroyed. Builds throwaway repos with real linked worktrees and drives the real
# script end to end (so `reap` also exercises the with-repo-lock.py re-exec, which is unconditional).
#
# GROW THIS SUITE, NEVER PRUNE IT. This script deletes work; every hole ever found in its gates belongs
# below as a case, added WITH the fix. The PL-459 case in particular is not a hypothetical — the reaper
# once removed a live, freshly-forked worktree, and its session's edits then landed in the main checkout.
#
# TWO ENVIRONMENT FACTS THE CASES DEPEND ON, both easy to get silently wrong:
#   • extensions.worktreeConfig must be on, exactly as start-wt-setup.sh does it. Without it
#     `git config --worktree` fails outright, no start.baseline-sha is recorded, and the zero-commit guard
#     no-ops — every zero-commit case then falls through to "branch merged" and passes for the wrong reason.
#   • HOME is faked. linear_state_type() prepends $HOME/.cargo/bin to PATH, so the REAL linear-cli outranks
#     a stub placed anywhere else and every issue state resolves against live Linear. $HOME/.cargo/bin IS
#     the stub dir here; $HOME/.claude symlinks to the checkout under test so $SELF, with-repo-lock.py,
#     and wt-identity.sh still resolve. Cases pass an explicit repo arg, so the repo registries are never read.

set -uo pipefail

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/scripts/reap-worktrees.sh"
IDLIB="$CLAUDE_DIR/scripts/wt-identity.sh"
ROOT=$(mktemp -d)
# The live-owner sleepers are spawned inside build_case, which every caller runs under command substitution —
# a shell variable set there dies with that subshell and the trap would never see the pid. A file crosses it.
OWNER_PIDS="$ROOT/owner-pids"; : > "$OWNER_PIDS"
# INT/TERM too: the owner fixtures leave 600s sleepers behind, so an interrupted run would leak every one.
# The signal handler must EXIT, not just clean up — a bare cleanup trap resumes the interrupted statement
# against deleted fixtures, producing a wall of spurious FAILs and a second rm -rf from the EXIT trap.
trap '_p=$(cat "$OWNER_PIDS" 2>/dev/null); [ -n "$_p" ] && kill $_p 2>/dev/null; rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

BIN="$ROOT/home/.cargo/bin"; mkdir -p "$BIN"
ln -s "$CLAUDE_DIR" "$ROOT/home/.claude"
export HOME="$ROOT/home"

# Nothing an ancestor exported may decide the owner verdicts below: WTID_* is wt-identity.sh's own override
# seam, and CLAUDE_HARNESS_PID is the canary wt_owner_alive uses to decide whether `ps` can be trusted at all —
# inheriting one this shell cannot see turns every provably-dead owner into "unknown" and inverts the fixtures.
for _v in "${!WTID_@}" "${!CLAUDE_@}"; do unset "$_v"; done

# Stub linear-cli: the issue's state type is whatever the file named after the issue id holds.
cat > "$BIN/linear-cli" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in id=*) issue="${a#id=}" ;; esac; done
printf '{"data":{"issue":{"state":{"type":"%s"}}}}' "$(cat "$LINEAR_STUB_DIR/$issue" 2>/dev/null || true)"
EOF
# Stub gh: never a merged PR, so the Linear tier is what decides in the cases below.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/linear-cli" "$BIN/gh"
export LINEAR_STUB_DIR="$ROOT/linear"; mkdir -p "$LINEAR_STUB_DIR"

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}

# A live owner needs a process whose comm clears wt_owner_alive's harness-name allowlist, so the fixture has to
# be named `claude`. A COPY of the sleep binary under that name is SIGKILLed on Apple Silicon (the copy
# invalidates Apple's signature — measured, exit 137), so it is exec'd through a SYMLINK instead: the real
# signed binary runs, `ps -o comm=` reports the symlink path, and the start time round-trips like a real
# stamp's.
CLAUDE_SLEEPER="$ROOT/owner-bin/claude"; mkdir -p "$ROOT/owner-bin"
ln -s "$(command -v sleep)" "$CLAUDE_SLEEPER"

# Block until <pid> has really exec'd its target: a pid stamped inside the fork window still reports comm=bash,
# which wt_owner_alive adjudicates as dead — silently inverting an alive fixture.
await_comm() { # pid comm-pattern
  local i=0 comm
  while [ "$i" -lt 500 ]; do
    comm=$(ps -o comm= -p "$1" 2>/dev/null | tail -1)
    case "$comm" in $2) return 0 ;; esac
    i=$((i+1)); sleep 0.02
  done
  return 1
}

# The owner keys a completed wt_identity_stamp leaves in per-worktree config. Start time comes from the library
# itself, so the recorded value is byte-identical to what wt_owner_alive compares against; a mismatched format
# would read as a recycled pid and turn every live owner dead.
stamp_owner() { # wt pid
  git -C "$1" config --worktree start.owner-session sess-fixture
  git -C "$1" config --worktree start.owner-pid "$2"
  git -C "$1" config --worktree start.owner-pid-start "$(bash -c '. "$1"; wtid_pid_start "$2"' _ "$IDLIB" "$2")"
}

# build_case <name> <issue> <linear-state> <commits:0|1> <dirty:0|1> <age:fresh|idle> [owner] → repo path
# age=idle backdates the worktree's index so liveness guard B sees no session; fresh leaves it now.
# owner (default none) stamps the identity tier wt_owner_alive adjudicates: none|alive|dead|released.
build_case() {
  local name="$1" issue="$2" state="$3" commits="$4" dirty="$5" age="$6" owner="${7:-none}"
  local repo="$ROOT/$name" slug wt base opid
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$repo" config extensions.worktreeConfig true   # start-wt-setup.sh does this in the real flow
  printf '%s' "$state" > "$LINEAR_STUB_DIR/$issue"
  slug=$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')
  wt="$repo/.claude/worktrees/$slug"
  git -C "$repo" worktree add -q -b "user/$slug" "$wt" main
  base=$(git -C "$repo" rev-parse main)
  git -C "$wt" config --worktree start.source-branch main
  git -C "$wt" config --worktree start.baseline-sha "$base"
  [ "$commits" = 1 ] && { echo x > "$wt/f"; git -C "$wt" add f
    git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m work; }
  [ "$dirty" = 1 ] && echo scratch > "$wt/untracked"
  case "$owner" in
    alive)
      # Both sleepers hand their stdout to /dev/null: build_case runs under command substitution, and a
      # background child holding that pipe's write end open blocks the substitution for the sleeper's full life.
      "$CLAUDE_SLEEPER" 600 >/dev/null 2>&1 & opid=$!
      echo "$opid" >> "$OWNER_PIDS"
      await_comm "$opid" '*claude*' || { echo "FIXTURE: owner $opid never exec'd" >&2; exit 1; }
      stamp_owner "$wt" "$opid" ;;
    dead)
      # Stamped while it still LIVES, so a real start time is recorded. With owner-pid-start empty the death
      # verdict would rest on `ps` finding nothing, and a recycled pid landing on an allowlisted comm flips
      # the fixture to alive. The pid then leaves the trap's kill list the instant it is reaped — this OS
      # recycles pids, so a signal aimed at a reaped one lands on whatever inherited it.
      sleep 600 >/dev/null 2>&1 & opid=$!
      echo "$opid" >> "$OWNER_PIDS"
      await_comm "$opid" '*sleep*' || { echo "FIXTURE: owner $opid never exec'd" >&2; exit 1; }
      stamp_owner "$wt" "$opid"
      kill "$opid" 2>/dev/null; wait "$opid" 2>/dev/null
      grep -v -x -F -- "$opid" "$OWNER_PIDS" > "$OWNER_PIDS.tmp" 2>/dev/null
      mv -f "$OWNER_PIDS.tmp" "$OWNER_PIDS" ;;
    released)
      # wt_identity_disown's write shape: both pid keys absent, owner-released-at set, owner-session kept as
      # last-owner attribution rather than a live claim.
      git -C "$wt" config --worktree start.owner-session sess-fixture
      git -C "$wt" config --worktree start.owner-released-at "$(date +%s)" ;;
  esac
  [ "$age" = idle ] && touch -t 200001010000 "$(git -C "$wt" rev-parse --absolute-git-dir)/index"
  printf '%s' "$repo"
}

echo "== zero-commit worktrees: terminal issue is evidence, a trivial 'merged' is not =="

# The leak this path exists to close: /start wt forks a worktree, the issue is canceled in Linear before
# the first commit, and no /start session is left to surface cleanup. Nothing else reclaims it.
r=$(build_case canceled_zero BF-901 canceled 0 0 idle)
ck "zero-commit + canceled + idle + clean → eligible" \
   'REAP-ELIGIBLE.*canceled, no commits' "$($SCRIPT list "$r" 2>&1)"

r=$(build_case dup_zero BF-905 duplicate 0 0 idle)
ck "zero-commit + duplicate (a terminal type too) → eligible" \
   'REAP-ELIGIBLE.*duplicate' "$($SCRIPT list "$r" 2>&1)"

# The PL-459 failure itself: a zero-commit branch is TRIVIALLY an ancestor of its source, so "branch
# merged" alone must never reap one — that fired on a worktree whose session had just set it up.
r=$(build_case active_zero BF-902 started 0 0 idle)
ck "zero-commit + issue active → KEEP despite the trivial merge" \
   'KEEP — no commits since baseline (just-forked' "$($SCRIPT list "$r" 2>&1)"

# Terminal issue is not sufficient on its own — both liveness guards still apply.
r=$(build_case fresh_zero BF-903 canceled 0 0 fresh)
ck "zero-commit + canceled but index FRESH → KEEP (guard B holds)" \
   'KEEP — active within' "$($SCRIPT list "$r" 2>&1)"

r=$(build_case dirty_zero BF-904 canceled 0 1 idle)
ck "zero-commit + canceled + DIRTY → KEEP (untracked work is never destroyed)" \
   'KEEP — no commits since baseline and the worktree is dirty' "$($SCRIPT list "$r" 2>&1)"

echo "== zero-commit worktrees: a gone owner is evidence, a live one is still PL-459 =="

# The leak this path closes: a zero-commit worktree whose owning session died is completion-independent
# abandonment — nothing else in the reaper ever consults ownership, so it was preserved forever. Every case
# here carries a NON-terminal issue, so the owner verdict is the only thing that can decide it.
r=$(build_case dead_owner BF-910 started 0 0 idle dead)
ck "the dead-owner fixture recorded a start time while the owner was alive" '^[A-Za-z]' \
   "$(git -C "$r/.claude/worktrees/bf-910" config --worktree --get start.owner-pid-start)"
ck "zero-commit + owner DEAD + idle + clean → eligible" \
   'REAP-ELIGIBLE.*owner session dead, no commits since baseline' "$($SCRIPT list "$r" 2>&1)"

# The stronger signal, and the one /auto's documented walk-away paths actually leave (they call wt-disown.sh).
r=$(build_case released_owner BF-911 started 0 0 idle released)
ck "zero-commit + owner RELEASED + idle → eligible" \
   'REAP-ELIGIBLE.*owner session released, no commits since baseline' "$($SCRIPT list "$r" 2>&1)"

# PL-459 again, now against the escape hatch: a just-forked worktree's owner is ALIVE, and no owner verdict
# may reap one. This is the case the hatch must never widen.
r=$(build_case alive_owner BF-912 started 0 0 idle alive)
ck "zero-commit + owner ALIVE + idle → KEEP (the PL-459 guard holds)" \
   'KEEP — no commits since baseline (just-forked' "$($SCRIPT list "$r" 2>&1)"

# No owner tier at all (legacy/pre-identity-stamp) resolves `unknown`, which must fail safe exactly as before.
r=$(build_case unstamped_owner BF-913 started 0 0 idle none)
ck "zero-commit + owner UNSTAMPED + idle → KEEP (unknown fails safe)" \
   'KEEP — no commits since baseline (just-forked' "$($SCRIPT list "$r" 2>&1)"

# The dirty gate runs first and outranks the owner verdict: a dead session's untracked work is still work.
r=$(build_case dead_dirty BF-914 started 0 1 idle dead)
ck "zero-commit + owner DEAD + DIRTY → KEEP (untracked work is never destroyed)" \
   'KEEP — no commits since baseline and the worktree is dirty' "$($SCRIPT list "$r" 2>&1)"

echo "== worktrees with commits: unchanged by the zero-commit path =="

r=$(build_case unmerged BF-906 started 1 0 idle)
ck "commits + issue active + unmerged → KEEP" \
   'KEEP — active (not merged' "$($SCRIPT list "$r" 2>&1)"

# Terminal evidence does not override the unsaved-commits gate. Guards against the zero_commit shortcut
# in that gate leaking onto branches that DO have commits of their own.
r=$(build_case unpushed BF-907 canceled 1 0 idle)
ck "commits + canceled + local-only commits → KEEP, reported for manual resolution" \
   'local-only commits' "$($SCRIPT list "$r" 2>&1)"

echo "== reap mode removes what list called eligible =="

r=$(build_case reap_zero BF-908 canceled 0 0 idle)
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the worktree" 'REAPED' "$out"
ck "worktree directory is gone" GONE \
   "$([ -d "$r/.claude/worktrees/bf-908" ] && echo PRESENT || echo GONE)"
ck "branch is deleted" NOBRANCH \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-908 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"

echo "== ancestry exclusion: the sweep never treats its own process tree as a victim =="

# with-repo-lock.py execvp's in place, so only $$/$PPID are visible from the reaper's own shell — the
# ancestry walk has to go further, up to pid 1, or a harness/terminal several hops up (sharing the caller's
# cwd) becomes a candidate. Probed directly (not through a fixture) since it holds regardless of any repo.
# Sourced with an explicit "list <missing-dir>" so the CLI dispatch takes the harmless MISSING-repo branch
# instead of falling through to the unknown-subcommand case, which calls `exit` and would kill this shell
# before the probe lines below ever ran.
probe=$(bash -c '. "$1" list "$2" >/dev/null 2>&1; echo "PID=$$"; echo "ANC=$(sweep_ancestry_pids)"' _ "$SCRIPT" "$ROOT/no-such-repo")
probe_pid=$(printf '%s\n' "$probe" | sed -n 's/^PID=//p')
probe_anc=$(printf '%s\n' "$probe" | sed -n 's/^ANC=//p')
ck "ancestry set includes the sweep's own pid" " $probe_pid " "$probe_anc"
ck "ancestry walk reaches pid 1" " 1 " "$probe_anc"

echo "== orphan host processes: swept only when their worktree is gone from disk =="

# spawn_sleeper <cwd> → pid of a long-lived process parked in that directory.
# Double-forked so the sleeper is ORPHANED rather than a child of this shell: a killed child lingers as a
# zombie until it is waited on, and `kill -0` on a zombie still succeeds — a sweep that worked would read
# alive. Stdout goes to /dev/null for the same reason build_case's sleepers do (callers run it under command
# substitution, and a background child holding that pipe open blocks the substitution for its whole life).
spawn_sleeper() {
  local dir="$1" pf="$ROOT/sleeper-pid" p
  mkdir -p "$dir"
  ( ( cd "$dir" && exec sleep 600 >/dev/null 2>&1 ) & echo $! > "$pf" )
  p=$(cat "$pf"); rm -f "$pf"
  echo "$p" >> "$OWNER_PIDS"
  await_comm "$p" '*sleep*' || { echo "FIXTURE: sleeper $p never exec'd" >&2; exit 1; }
  printf '%s' "$p"
}

proc_state() { kill -0 "$1" 2>/dev/null && echo ALIVE || echo DEAD; }

# Bounded wait for the sweep's TERM (then KILL) to land and the pid to be reaped by init.
await_dead() {
  local i=0
  while [ "$i" -lt 250 ]; do
    kill -0 "$1" 2>/dev/null || { echo DEAD; return 0; }
    i=$((i+1)); sleep 0.02
  done
  echo ALIVE
}

# The fixture repo path is mktemp-unique, so the prefix filter provably cannot select any process outside
# it. It is also under /var/folders (a symlink to /private/var), which is exactly the path form lsof
# reports: a sweep that compared the logical repo path instead of the physical one would match nothing here.
#
# These cases exercise sweep_verify_victim on every real kill (it runs before every signal), but the
# specific race it guards — a pid exiting and getting recycled between selection and signal — isn't
# separately pinned: reproducing it needs a pid reused by an unrelated process inside a ~2s window, which
# isn't reliably arrangeable from a test.
r=$(build_case sweep_reap BF-920 started 1 0 fresh)
gone_pid=$(spawn_sleeper "$r/.claude/worktrees/wt-gone/apps/api")
live_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-920/apps/api")
rm -rf "$r/.claude/worktrees/wt-gone"
out=$($SCRIPT reap "$r" 2>&1)
ck "orphan of a removed worktree is reported" "REAPED-PROC pid=$gone_pid" "$out"
gone_state=$(await_dead "$gone_pid")
ck "orphan of a removed worktree is killed" DEAD "$gone_state"
# Swept — out of the trap's kill list, same reason the dead fixture prunes its pid above. Gated on DEAD:
# if a regression left it alive, the trap must still kill it or the suite leaks a 600s sleeper.
[ "$gone_state" = DEAD ] && { grep -v -x -F -- "$gone_pid" "$OWNER_PIDS" > "$OWNER_PIDS.tmp" 2>/dev/null; mv -f "$OWNER_PIDS.tmp" "$OWNER_PIDS"; }
# The gate that makes killing safe: the worktree dir still EXISTS, so nothing inside it may be touched.
ck "process inside a live worktree survives" ALIVE "$(proc_state "$live_pid")"
ck "process inside a live worktree is never reported" NOMATCH \
   "$(printf '%s' "$out" | grep -q -- "pid=$live_pid" && echo MATCHED || echo NOMATCH)"

r=$(build_case sweep_list BF-921 started 1 0 fresh)
list_pid=$(spawn_sleeper "$r/.claude/worktrees/wt-gone/apps/api")
rm -rf "$r/.claude/worktrees/wt-gone"
out=$($SCRIPT list "$r" 2>&1)
ck "list mode reports the orphan" "ORPHAN-PROC pid=$list_pid" "$out"
ck "list mode kills nothing" ALIVE "$(proc_state "$list_pid")"

# The state with the most orphans: the ENTIRE worktrees/ dir is gone, not just one slug under it. Both
# cmd_reap_one and cmd_list used to early-exit before the sweep call in exactly this state, so an orphan
# left behind by a wholesale removal was never reclaimed. Removes its own fixture worktree along with the
# orphan's — irrelevant here, since the sweep doesn't depend on any worktree dir existing.
r=$(build_case sweep_reap_dirgone BF-922 started 1 0 fresh)
gone_pid=$(spawn_sleeper "$r/.claude/worktrees/wt-orphan/apps/api")
rm -rf "$r/.claude/worktrees"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap: sweep still runs when the whole worktrees dir is gone" "REAPED-PROC pid=$gone_pid" "$out"
gone_state=$(await_dead "$gone_pid")
ck "reap: orphan is killed when the worktrees dir itself is gone" DEAD "$gone_state"
[ "$gone_state" = DEAD ] && { grep -v -x -F -- "$gone_pid" "$OWNER_PIDS" > "$OWNER_PIDS.tmp" 2>/dev/null; mv -f "$OWNER_PIDS.tmp" "$OWNER_PIDS"; }

r=$(build_case sweep_list_dirgone BF-923 started 1 0 fresh)
list_pid2=$(spawn_sleeper "$r/.claude/worktrees/wt-orphan/apps/api")
rm -rf "$r/.claude/worktrees"
out=$($SCRIPT list "$r" 2>&1)
ck "list: sweep still runs when the whole worktrees dir is gone" "ORPHAN-PROC pid=$list_pid2" "$out"
ck "list: kills nothing even when the worktrees dir itself is gone" ALIVE "$(proc_state "$list_pid2")"

# Fail-safe: an unresolvable repo root must sweep NOTHING. This is the one hazard that could turn the sweep
# into a massacre — a degenerate prefix would select processes outside the repo. Driven by sourcing the
# script, since the CLI skips a missing repo before the sweep is ever reached.
ghost="$ROOT/ghost-repo"
ghost_pid=$(spawn_sleeper "$ghost/.claude/worktrees/wt-gone/apps/api")
rm -rf "$ghost"
out=$(bash -c '. "$1" list "$2" >/dev/null 2>&1; set +e; sweep_orphan_processes "$2" reap; echo "EXIT=$?"' _ "$SCRIPT" "$ghost" 2>&1)
# Assert the GUARD fired, not merely that nothing died: with the guard gone the degenerate prefix still
# happens to select nothing here, so a survival-only assertion would pin nothing.
ck "unresolvable repo root skips the sweep outright" 'cannot resolve physical path' "$out"
ck "unresolvable repo root returns success" 'EXIT=0' "$out"
ck "unresolvable repo root selects no process" NOPROC \
   "$(printf '%s' "$out" | grep -q -e ORPHAN-PROC -e REAPED-PROC && echo PROC || echo NOPROC)"
ck "unresolvable repo root kills nothing" ALIVE "$(proc_state "$ghost_pid")"

echo
echo "reap-worktrees: $pass passed, $fail failed"
[ "$fail" = 0 ]
