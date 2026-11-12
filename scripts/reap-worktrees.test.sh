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

# POSIX-only. The fixture symlinks the whole checkout as $HOME/.claude (`ln -s` copies the directory on Git Bash —
# every transcript under projects/ with it) and the ancestry-exclusion case walks `ps -o ppid=` up to pid 1, which MSYS
# `ps` (no -o at all) cannot do; wt_owner_alive degrades to unknown there for the same reason. One counted SKIP the
# runner can see — the same code is verified on macOS/Linux. FORCE_POSIX_SUITES=1 runs it anyway. standards/git-windows.md
# § Native tools behind the shell.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) [ -n "${FORCE_POSIX_SUITES:-}" ] || { echo "SKIP  $(basename "$0"): POSIX process liveness (ps -o) and a symlinked \$HOME/.claude are unavailable on Git Bash — 0 passed, 0 failed, 1 skipped"; exit 0; } ;;
esac

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REAPER="$CLAUDE_DIR/scripts/reap-worktrees.sh"
FM="$CLAUDE_DIR/scripts/finish-merge.sh"
IDLIB="$CLAUDE_DIR/scripts/wt-identity.sh"
ROOT=$(mktemp -d)
# Every case drives the reaper through this wrapper, which refuses an empty repo argument. A fixture that fails
# to build leaves its `r=$(build_case …)` empty, and `reap-worktrees.sh reap ""` then resolves the repo set from
# the REGISTRIES under $HOME/.claude — the symlinked real checkout, so the real worktree-repos.txt — and runs a
# live reap over every registered repo (measured 2026-10-08: one broken fixture sent the suite's `reap` at
# basefund and two other repos; nothing was eligible that pass). The two probes that SOURCE the script use
# $REAPER directly.
SCRIPT="$ROOT/reap-guard.sh"
printf '#!/usr/bin/env bash\n[ -n "${2:-}" ] || { echo "FIXTURE: reap-worktrees.sh invoked with no repo — a fixture failed to build; refusing, since the registries name live repos" >&2; exit 1; }\nexec %q "$@"\n' "$REAPER" > "$SCRIPT"
chmod +x "$SCRIPT"
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

# build_case <name> <issue> <linear-state> <commits:0|1> <dirty:0|1> <age:fresh|idle> [owner] [stamp] → repo path
# age=idle backdates the worktree's index so liveness guard B sees no session; fresh leaves it now.
# owner (default none) stamps the identity tier wt_owner_alive adjudicates: none|alive|dead|released.
# stamp (default stamped) writes the config keys start-wt-setup.sh leaves; unstamped is a hand-made or
# EnterWorktree worktree, which carries none.
build_case() {
  local name="$1" issue="$2" state="$3" commits="$4" dirty="$5" age="$6" owner="${7:-none}" stamp="${8:-stamped}"
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
  if [ "$stamp" = stamped ]; then
    git -C "$wt" config --worktree start.source-branch main
    git -C "$wt" config --worktree start.baseline-sha "$base"
  fi
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

echo "== provenance and pinning: only a /start wt stamp admits a worktree, and a pin refuses every gate =="

# Lands the worktree branch on main — the evidence every /start wt reap rests on.
merge_into_main() { git -C "$1" merge -q --ff-only "user/$2"; }

# The 2026-09-08 api-memo reap: a hand-made worktree (no stamp), committed, merged to the default branch, idle
# and clean — every evidence gate passed, and the reaper took the directory and the branch. The stamped twin
# below is the control: identical in every other respect, and eligible.
r=$(build_case unmanaged_merged BF-930 started 1 0 idle none unstamped)
merge_into_main "$r" bf-930
ck "unstamped + merged + idle + clean → KEEP — unmanaged" 'KEEP — unmanaged' "$($SCRIPT list "$r" 2>&1)"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap leaves an unmanaged worktree's directory in place" PRESENT \
   "$([ -d "$r/.claude/worktrees/bf-930" ] && echo PRESENT || echo GONE)"
ck "reap leaves an unmanaged worktree's branch in place" PRESENT \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-930 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"

r=$(build_case managed_merged BF-931 started 1 0 idle none stamped)
merge_into_main "$r" bf-931
ck "the same worktree stamped → eligible (the stamp is what decides)" \
   'REAP-ELIGIBLE — branch merged into main' "$($SCRIPT list "$r" 2>&1)"

# The opt-in: a hand-made worktree the user does want reclaimed on the /start wt rules. It authorizes
# destruction, so only an exact boolean true counts — a mistyped value stays unmanaged.
r=$(build_case optin_merged BF-932 started 1 0 idle none unstamped)
merge_into_main "$r" bf-932
git -C "$r/.claude/worktrees/bf-932" config --worktree reap.managed garbage
ck "unstamped + reap.managed=garbage → still KEEP — unmanaged" 'KEEP — unmanaged' "$($SCRIPT list "$r" 2>&1)"
git -C "$r/.claude/worktrees/bf-932" config --worktree reap.managed true
ck "unstamped + reap.managed=true + merged → eligible" 'REAP-ELIGIBLE — branch merged into main' "$($SCRIPT list "$r" 2>&1)"

# The pin holds on a stamped worktree that clears every other gate — a /start interactive worktree the user
# keeps merging from is exactly this shape.
r=$(build_case pinned BF-933 started 1 0 idle none stamped)
merge_into_main "$r" bf-933
git -C "$r/.claude/worktrees/bf-933" config --worktree reap.keep true
ck "stamped + merged + reap.keep=true → KEEP — pinned" 'KEEP — pinned' "$($SCRIPT list "$r" 2>&1)"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap leaves a pinned worktree's directory in place" PRESENT \
   "$([ -d "$r/.claude/worktrees/bf-933" ] && echo PRESENT || echo GONE)"
ck "reap leaves a pinned worktree's branch in place" PRESENT \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-933 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"

# A pin is a request to preserve: an unparseable value still pins; only an explicit false releases it.
git -C "$r/.claude/worktrees/bf-933" config --worktree reap.keep tru
ck "reap.keep=tru (unparseable) still pins" 'KEEP — pinned' "$($SCRIPT list "$r" 2>&1)"
git -C "$r/.claude/worktrees/bf-933" config --worktree reap.keep false
ck "reap.keep=false releases the pin → eligible" 'REAP-ELIGIBLE' "$($SCRIPT list "$r" 2>&1)"

# A queued merge outranks the pin: the drainer removes that worktree when its merge lands whatever the config says.
git -C "$r/.claude/worktrees/bf-933" config --worktree reap.keep true
mkdir -p "$r/.claude/merge-queue" && : > "$r/.claude/merge-queue/bf-933.json"
ck "pinned + merge queued → SKIP (the drainer owns it)" 'SKIP — merge queued' "$($SCRIPT list "$r" 2>&1)"

# spawn_sleeper <cwd> [binary] → pid of a long-lived process parked in that directory, exec'd from <binary>
# (default sleep; $CLAUDE_SLEEPER for one that clears is_harness_pid's comm allowlist — a session fixture).
# Double-forked so the sleeper is ORPHANED rather than a child of this shell: a killed child lingers as a
# zombie until it is waited on, and `kill -0` on a zombie still succeeds — a sweep that worked would read
# alive. Stdout goes to /dev/null for the same reason build_case's sleepers do (callers run it under command
# substitution, and a background child holding that pipe open blocks the substitution for its whole life).
spawn_sleeper() {
  local dir="$1" bin="${2:-sleep}" pf="$ROOT/sleeper-pid" p
  mkdir -p "$dir"
  ( ( cd "$dir" && exec "$bin" 600 >/dev/null 2>&1 ) & echo $! > "$pf" )
  p=$(cat "$pf"); rm -f "$pf"
  echo "$p" >> "$OWNER_PIDS"
  await_comm "$p" "*$(basename "$bin")*" || { echo "FIXTURE: sleeper $p ($bin) never exec'd" >&2; exit 1; }
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

echo "== liveness guard C: a live Claude session inside the worktree outranks every evidence rule =="

# The BF-2074 shape (2026-09-23, reaped twice in one day): stamped, committed, merged into its source from
# inside the worktree, then the human kept working there — Storybook/Chromatic rounds, no git ops for over an
# hour. Every evidence gate reads "done"; the session's cwd is the only signal left, and it must be enough.
r=$(build_case inuse_merged BF-940 started 1 0 idle none stamped)
merge_into_main "$r" bf-940
sess_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-940" "$CLAUDE_SLEEPER")
ck "stamped + merged + idle + clean + live session inside → KEEP — in use" \
   "KEEP — in use: a live Claude session (pid $sess_pid)" "$($SCRIPT list "$r" 2>&1)"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap leaves an in-use worktree's directory in place" PRESENT \
   "$([ -d "$r/.claude/worktrees/bf-940" ] && echo PRESENT || echo GONE)"
ck "reap leaves an in-use worktree's branch in place" PRESENT \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-940 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"
ck "reap never signals the session inside a kept worktree" ALIVE "$(proc_state "$sess_pid")"

# The BF-2101 shape (2026-09-24): issue marked Done, zero commits, clean, idle — the human had moved on to the
# next issue in the same worktree and was an hour into planning it. A terminal issue is the one evidence guard
# A admits without commits; guard C must still outrank it.
r=$(build_case inuse_done_zero BF-941 completed 0 0 idle none stamped)
sess_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-941" "$CLAUDE_SLEEPER")
ck "zero-commit + issue completed + idle + clean + live session inside → KEEP — in use" \
   'KEEP — in use' "$($SCRIPT list "$r" 2>&1)"

# The session's cwd may sit anywhere UNDER the worktree (a package dir), and it is the harness comm that makes
# a process a session: a leftover dev server inside must not hold the worktree, or every reaped worktree that
# ever started one would be pinned forever and the sweep would never reach it.
r=$(build_case inuse_subdir BF-942 started 1 0 idle none stamped)
merge_into_main "$r" bf-942
sess_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-942/apps/api" "$CLAUDE_SLEEPER")
ck "session cwd in a subdirectory of the worktree → KEEP — in use" 'KEEP — in use' "$($SCRIPT list "$r" 2>&1)"
r=$(build_case notsession_merged BF-943 started 1 0 idle none stamped)
merge_into_main "$r" bf-943
srv_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-943")
ck "a non-harness process inside (a dev server) does not hold the worktree → eligible" \
   'REAP-ELIGIBLE — branch merged into main' "$($SCRIPT list "$r" 2>&1)"

echo "== reap mode removes what list called eligible =="

# write_sidecar <id_dir> <slug> <wt_dir|''> <old|new> [baseline] — the repo-level identity sidecar as
# wt_identity_stamp lays it out, with the recorded worktree path and the mtime under the case's control. An
# empty <wt_dir> omits the field, as a stamp from before it was recorded did; `old` backdates past the grace.
write_sidecar() {
  local f="$1/wt-identity-$2.env" sha="${5:-0000000000000000000000000000000000000000}"
  mkdir -p "$1"
  { printf 'WT_IDENTITY_VERSION=1\nWT_IDENTITY_ISSUE=%s\nWT_IDENTITY_BRANCH=user/%s\nWT_IDENTITY_SOURCE_BRANCH=main\n' \
      "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')" "$2"
    printf 'WT_IDENTITY_BASELINE_SHA=%s\nWT_IDENTITY_HEAD_SHA=%s\nWT_IDENTITY_STAMPED_AT=946684800\n' "$sha" "$sha"
    [ -n "$3" ] && printf 'WT_IDENTITY_WT_DIR=%s\n' "$3"
    printf 'WT_IDENTITY_OWNER=sess-fixture\nWT_IDENTITY_CREATED_AT=2000-01-01T00:00:00Z\n'
  } > "$f"
  [ "$4" = old ] && touch -t 200001010000 "$f"
  return 0
}

r=$(build_case reap_zero BF-908 canceled 0 0 idle)
# A FRESH sidecar for the worktree being reaped: the stale-sidecar sweep leaves anything inside the grace
# alone, so only the removal path itself can be what deletes this one.
write_sidecar "$r/.claude/worktree-identity" bf-908 "$r/.claude/worktrees/bf-908" new "$(git -C "$r" rev-parse main)"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the worktree" 'REAPED' "$out"
ck "worktree directory is gone" GONE \
   "$([ -d "$r/.claude/worktrees/bf-908" ] && echo PRESENT || echo GONE)"
ck "branch is deleted" NOBRANCH \
   "$(git -C "$r" rev-parse --verify --quiet user/bf-908 >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH)"
ck "the worktree's identity sidecar goes with it" GONE \
   "$([ -f "$r/.claude/worktree-identity/wt-identity-bf-908.env" ] && echo PRESENT || echo GONE)"

echo "== identity sidecars: one outlives its worktree only until the next pass =="

# The leak this sweep closes: the removal paths now delete a worktree's sidecar with it, but a worktree removed
# by hand never did, and before 2026-10-07 nothing deleted any — basefund held 1,025 against one live worktree.
# Stale iff the recorded directory is gone AND the conventional path for the slug is gone; the grace applies as
# to worktrees; only wt-identity-*.env files are candidates.
r=$(build_case sidecars BF-950 started 1 1 fresh)      # dirty + fresh => the worktree itself is KEPT
idd="$r/.claude/worktree-identity"
base=$(git -C "$r" rev-parse main)
write_sidecar "$idd" bf-950 "$r/.claude/worktrees/bf-950" old "$base"             # live worktree → keep
write_sidecar "$idd" bf-951 "$r/.claude/worktrees/bf-951" old                     # worktree gone, old → stale
write_sidecar "$idd" bf-952 "$r/.claude/worktrees/bf-952" new                     # worktree gone, inside the grace → keep
write_sidecar "$idd" bf-953 "$ROOT/old-location/.claude/worktrees/bf-953" old     # recorded path gone, no conventional one → stale
write_sidecar "$idd" bf-955 "" old                                                # pre-field stamp, slug has no worktree → stale
# A repo moved since the stamp: the recorded path is gone but the worktree stands at the conventional path.
git -C "$r" worktree add -q -b user/bf-954 "$r/.claude/worktrees/bf-954" main
write_sidecar "$idd" bf-954 "$ROOT/old-location/.claude/worktrees/bf-954" old "$base"
printf '*\n' > "$idd/.gitignore"
: > "$idd/recover-bf-951.patch"
out=$($SCRIPT list "$r" 2>&1)
ck "list counts the stale sidecars" 'STALE-IDENTITY 3 sidecar(s)' "$out"
ck "list names the stale slugs" 'bf-951 bf-953 bf-955' "$out"
ck "list deletes nothing" '^6$' "$(ls "$idd"/wt-identity-*.env | wc -l | tr -d ' ')"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the stale sidecars" 'REAPED-IDENTITY 3 sidecar(s)' "$out"
ck "a gone worktree's old sidecar is removed" GONE "$([ -f "$idd/wt-identity-bf-951.env" ] && echo PRESENT || echo GONE)"
ck "a sidecar recording a path that no longer exists is removed" GONE "$([ -f "$idd/wt-identity-bf-953.env" ] && echo PRESENT || echo GONE)"
ck "a pre-field sidecar whose slug has no worktree is removed" GONE "$([ -f "$idd/wt-identity-bf-955.env" ] && echo PRESENT || echo GONE)"
ck "a live worktree's sidecar is kept" PRESENT "$([ -f "$idd/wt-identity-bf-950.env" ] && echo PRESENT || echo GONE)"
ck "a sidecar inside the grace is kept whatever it points at" PRESENT "$([ -f "$idd/wt-identity-bf-952.env" ] && echo PRESENT || echo GONE)"
ck "a moved repo's sidecar is kept while the conventional path stands" PRESENT "$([ -f "$idd/wt-identity-bf-954.env" ] && echo PRESENT || echo GONE)"
ck "the directory's .gitignore is never a candidate" PRESENT "$([ -f "$idd/.gitignore" ] && echo PRESENT || echo GONE)"
ck "a recovery patch beside the sidecars is never a candidate" PRESENT "$([ -f "$idd/recover-bf-951.patch" ] && echo PRESENT || echo GONE)"
out=$($SCRIPT reap "$r" 2>&1)
ck "a second pass finds nothing to sweep" NOLINE "$(printf '%s' "$out" | grep -q 'REAPED-IDENTITY' && echo LINE || echo NOLINE)"

# The sweep does not depend on the worktrees dir existing — the state with the most leftovers.
r=$(build_case sidecars_dirgone BF-960 started 1 0 fresh)
write_sidecar "$r/.claude/worktree-identity" bf-961 "$r/.claude/worktrees/bf-961" old
rm -rf "$r/.claude/worktrees"
out=$($SCRIPT reap "$r" 2>&1)
ck "sweep runs when the whole worktrees dir is gone" 'REAPED-IDENTITY 1 sidecar(s)' "$out"

echo "== husk directories: a ledger-only remnant is reclaimed into <repo>/tmp/, anything else stays STRAY =="

# The 2026-10-19 shape: /finish removed the worktree, and a session started before the ledger mods resolved their
# root to the owning checkout kept writing tmp/*.jsonl under the old path, recreating the directory with no .git.
# build_husk <repo> <slug> <age:old|fresh> <name>... writes each named file under <repo>/.claude/worktrees/<slug>/tmp/.
build_husk() {
  local repo="$1" slug="$2" age="$3" d="$1/.claude/worktrees/$2/tmp" f; shift 3
  mkdir -p "$d"
  for f in "$@"; do printf '{"event":"step"}\n' > "$d/$f"; [ "$age" = old ] && touch -t 200001010000 "$d/$f"; done
}

r=$(build_case husk_repo BF-980 started 1 0 fresh)   # a live worktree beside the husks, never touched
build_husk "$r" bf-981 old effort-ledger-x.jsonl loop-boundary-x.jsonl spawn-policy-x.jsonl
out=$($SCRIPT list "$r" 2>&1)
ck "list: a ledger-only husk past the grace is HUSK" 'BF-981 *HUSK — 3 ledger file(s) only' "$out"
ck "list moves nothing" PRESENT "$([ -f "$r/.claude/worktrees/bf-981/tmp/effort-ledger-x.jsonl" ] && echo PRESENT || echo GONE)"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap: the husk is reclaimed" 'BF-981 *REAPED-HUSK — 3 ledger file(s) moved' "$out"
ck "reap: the ledgers land in the repo's tmp/" '^3$' \
   "$(ls "$r/tmp/effort-ledger-x.jsonl" "$r/tmp/loop-boundary-x.jsonl" "$r/tmp/spawn-policy-x.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
ck "reap: the husk directory is gone" GONE "$([ -e "$r/.claude/worktrees/bf-981" ] && echo PRESENT || echo GONE)"
ck "reap: the live worktree beside it is untouched" PRESENT "$([ -d "$r/.claude/worktrees/bf-980" ] && echo PRESENT || echo GONE)"

# Anything the ledger lanes do not name makes it a STRAY, and nothing is moved out of a STRAY.
build_husk "$r" bf-982 old effort-ledger-y.jsonl notes.txt
out=$($SCRIPT reap "$r" 2>&1)
ck "a husk holding an off-lane file is STRAY" 'BF-982 *STRAY — not a registered worktree' "$out"
ck "the STRAY line names the ledger-mod cause" 'ledger mods kept writing' "$out"
ck "nothing is moved out of a STRAY" PRESENT "$([ -f "$r/.claude/worktrees/bf-982/tmp/effort-ledger-y.jsonl" ] && echo PRESENT || echo GONE)"

# auto-state is never a candidate: /auto writes it only to the main checkout, so one in a husk is an anomaly to read.
build_husk "$r" bf-983 old auto-state-abc.json
ck "a husk holding auto-state is STRAY" 'BF-983 *STRAY' "$($SCRIPT reap "$r" 2>&1)"

# A nested path is never a ledger, whatever its name.
mkdir -p "$r/.claude/worktrees/bf-987/tmp/sub"; : > "$r/.claude/worktrees/bf-987/tmp/sub/effort-ledger-n.jsonl"
touch -t 200001010000 "$r/.claude/worktrees/bf-987/tmp/sub/effort-ledger-n.jsonl"
ck "a husk with a nested ledger is STRAY" 'BF-987 *STRAY' "$($SCRIPT reap "$r" 2>&1)"

# Within the grace a session may still be writing: deferred, nothing moved.
build_husk "$r" bf-984 fresh effort-ledger-z.jsonl
out=$($SCRIPT reap "$r" 2>&1)
ck "a husk whose newest ledger is within the grace is deferred" 'BF-984 *HUSK — .*deferring' "$out"
ck "a deferred husk keeps its ledger" PRESENT "$([ -f "$r/.claude/worktrees/bf-984/tmp/effort-ledger-z.jsonl" ] && echo PRESENT || echo GONE)"

# A live Claude session parked inside outranks the rule, as guard C does for a worktree; it is never signaled.
build_husk "$r" bf-985 old effort-ledger-w.jsonl
sess_pid=$(spawn_sleeper "$r/.claude/worktrees/bf-985" "$CLAUDE_SLEEPER")
out=$($SCRIPT reap "$r" 2>&1)
ck "a husk with a live session inside is kept" "BF-985 *HUSK — .*live Claude session (pid $sess_pid)" "$out"
ck "a kept husk's session is never signaled" ALIVE "$(proc_state "$sess_pid")"
ck "a kept husk's directory stays" PRESENT "$([ -d "$r/.claude/worktrees/bf-985" ] && echo PRESENT || echo GONE)"

# A name already present in <repo>/tmp/ is never overwritten: the file stays, the directory stays, the pass says so.
build_husk "$r" bf-986 old effort-ledger-dup.jsonl effort-ledger-ok.jsonl
mkdir -p "$r/tmp"; printf 'keep\n' > "$r/tmp/effort-ledger-dup.jsonl"
out=$($SCRIPT reap "$r" 2>&1)
ck "a colliding ledger leaves the husk partly reclaimed" 'BF-986 *STRAY — husk partly reclaimed: 1 ledger file(s) moved' "$out"
ck "the repo's copy is not overwritten" '^keep$' "$(cat "$r/tmp/effort-ledger-dup.jsonl")"
ck "the colliding ledger stays in the husk" PRESENT "$([ -f "$r/.claude/worktrees/bf-986/tmp/effort-ledger-dup.jsonl" ] && echo PRESENT || echo GONE)"
ck "the non-colliding ledger beside it was moved" PRESENT "$([ -f "$r/tmp/effort-ledger-ok.jsonl" ] && echo PRESENT || echo GONE)"

echo "== ancestry exclusion: the sweep never treats its own process tree as a victim =="

# with-repo-lock.py execvp's in place, so only $$/$PPID are visible from the reaper's own shell — the
# ancestry walk has to go further, up to pid 1, or a harness/terminal several hops up (sharing the caller's
# cwd) becomes a candidate. Probed directly (not through a fixture) since it holds regardless of any repo.
# Sourced with an explicit "list <missing-dir>" so the CLI dispatch takes the harmless MISSING-repo branch
# instead of falling through to the unknown-subcommand case, which calls `exit` and would kill this shell
# before the probe lines below ever ran.
probe=$(bash -c '. "$1" list "$2" >/dev/null 2>&1; echo "PID=$$"; echo "ANC=$(sweep_ancestry_pids)"' _ "$REAPER" "$ROOT/no-such-repo")
probe_pid=$(printf '%s\n' "$probe" | sed -n 's/^PID=//p')
probe_anc=$(printf '%s\n' "$probe" | sed -n 's/^ANC=//p')
ck "ancestry set includes the sweep's own pid" " $probe_pid " "$probe_anc"
ck "ancestry walk reaches pid 1" " 1 " "$probe_anc"

echo "== orphan host processes: swept only when their worktree is gone from disk =="

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

# A harness session whose worktree is gone is a broken session, not a host process: reported, never signaled.
# The dev server beside it is still an orphan and still goes.
r=$(build_case sweep_session BF-924 started 1 0 fresh)
sess_pid=$(spawn_sleeper "$r/.claude/worktrees/wt-gone" "$CLAUDE_SLEEPER")
srv_pid=$(spawn_sleeper "$r/.claude/worktrees/wt-gone/apps/api")
rm -rf "$r/.claude/worktrees/wt-gone"
out=$($SCRIPT reap "$r" 2>&1)
ck "sweep reports a session parked in a removed worktree" "LIVE-SESSION pid=$sess_pid" "$out"
ck "sweep never signals a session" ALIVE "$(proc_state "$sess_pid")"
ck "sweep still kills the dev server beside the session" "REAPED-PROC pid=$srv_pid" "$out"
srv_state=$(await_dead "$srv_pid")
ck "the dev server beside the session is dead" DEAD "$srv_state"
[ "$srv_state" = DEAD ] && { grep -v -x -F -- "$srv_pid" "$OWNER_PIDS" > "$OWNER_PIDS.tmp" 2>/dev/null; mv -f "$OWNER_PIDS.tmp" "$OWNER_PIDS"; }

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
out=$(bash -c '. "$1" list "$2" >/dev/null 2>&1; set +e; sweep_orphan_processes "$2" reap; echo "EXIT=$?"' _ "$REAPER" "$ghost" 2>&1)
# Assert the GUARD fired, not merely that nothing died: with the guard gone the degenerate prefix still
# happens to select nothing here, so a survival-only assertion would pin nothing.
ck "unresolvable repo root skips the sweep outright" 'cannot resolve physical path' "$out"
ck "unresolvable repo root returns success" 'EXIT=0' "$out"
ck "unresolvable repo root selects no process" NOPROC \
   "$(printf '%s' "$out" | grep -q -e ORPHAN-PROC -e REAPED-PROC && echo PROC || echo NOPROC)"
ck "unresolvable repo root kills nothing" ALIVE "$(proc_state "$ghost_pid")"

# ── stack sweep: which invocation the teardown gate selects ────────────────────────────────────────────
# The gate (a reclaimable registry entry, or an unregistered non-listening bf-s<N> project) is right for the
# TEARDOWN passes and wrong for the disk pass, so sweep_orphan_stacks branches on it rather than returning early.
# Pinning the branch, not merely that something ran: the regression this
# guards is silent in the worst way — every slot owner alive is the NORMAL state of a busy machine, and a
# gate that skips the disk pass there simply never reclaims anything, while the VM fills to 100% and redis
# stops accepting writes machine-wide (measured 2026-09-25: 121 rspec failures that read as a broken diff).
stack_stub="$ROOT/stack-stub"; mkdir -p "$stack_stub"
# docker answers `info` (down when FAKE_DOCKER_DOWN is set, wedged when FAKE_DOCKER_INFO_HANG is) and EXACTLY
# `compose ls --all -q` from FAKE_COMPOSE_LS, a space-separated project list (failing when FAKE_COMPOSE_LS_FAIL is set,
# wedged when FAKE_COMPOSE_LS_HANG is); any other `compose ls` spelling exits 1 printing nothing, as compose rejects a
# --format Go template. lsof answers only the listener probe, from FAKE_LISTEN_PORTS, and passes every other
# invocation to the real one so the orphan-process sweep keeps working under the same PATH.
cat > "$stack_stub/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = info ]; then
  [ -n "${FAKE_DOCKER_DOWN:-}" ] && exit 1
  [ -n "${FAKE_DOCKER_INFO_HANG:-}" ] && sleep 30
fi
if [ "$1" = compose ] && [ "${2:-}" = ls ]; then
  [ "$*" = "compose ls --all -q" ] || exit 1
  [ -n "${FAKE_COMPOSE_LS_FAIL:-}" ] && exit 1
  [ -n "${FAKE_COMPOSE_LS_HANG:-}" ] && sleep 30
  for p in ${FAKE_COMPOSE_LS:-}; do printf '%s\n' "$p"; done
fi
exit 0
EOF
cat > "$stack_stub/lsof" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -ti ] && [ "\${3:-}" = -sTCP:LISTEN ]; then
  for p in \${FAKE_LISTEN_PORTS:-}; do [ "tcp:\$p" = "\$2" ] && { echo 1; exit 0; }; done
  exit 1
fi
exec $(command -v lsof) "\$@"
EOF
chmod +x "$stack_stub/docker" "$stack_stub/lsof"
r=$(build_case sweep_stack BF-941 started 1 1 fresh)   # dirty + active issue => worktree kept, no reap noise
mkdir -p "$r/tools"
# The stub carries the real tool's parser arm, which is what the reaper probes for before it uses the flag.
stack_slot_stub() {   # stack_slot_stub <with-disk-only|pre-disk-only> [fail-full]: a bare `reap` exits non-zero, as when the registry lock is held
  { printf '#!/usr/bin/env bash\n'
    [ "$1" = with-disk-only ] && printf 'case "${2:-}" in --disk-only) ;; esac\n'
    printf 'echo "STACK-SLOT args=[$*]"\n'
    [ "${2:-}" = fail-full ] && printf '[ "${1:-}" = reap ] && [ -z "${2:-}" ] && exit 3\nexit 0\n'
  } > "$r/tools/stack-slot"
  chmod +x "$r/tools/stack-slot"
}
stack_slot_stub with-disk-only
REG="$HOME/.basefund/stack-slots"; mkdir -p "$REG"

printf 'owner=%s\nmode=test\n' "$r" > "$REG/2.slot"          # owner present => no teardown work to do
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: all owners alive still runs the disk pass" 'STACK-SLOT args=\[reap --disk-only\]' "$out"

# A tool from before the flag has no parser: `cmd_reap "$@"` drops the unknown arg and `reap --disk-only`
# runs the FULL reap. With every owner alive the reaper must not call such a tool at all.
stack_slot_stub pre-disk-only
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: all owners alive + a tool without --disk-only calls nothing" NOCALL \
   "$(printf '%s' "$out" | grep -q 'STACK-SLOT args=' && echo CALLED || echo NOCALL)"

printf 'owner=%s\nmode=test\n' "$ROOT/checkout-that-is-gone" > "$REG/3.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a dead owner runs the full reap on a tool without --disk-only" 'STACK-SLOT args=\[reap\]' "$out"
stack_slot_stub with-disk-only
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a dead owner runs the full reap, not the disk pass" 'STACK-SLOT args=\[reap\]' "$out"

# A husk owner -- the directory exists with no .git entry, recreated by a session's ledger writes after the worktree
# was removed -- is dead too: under a bare -d it read alive and kept two basefund slots and their stacks for nine days
# (2026-10-19). The linked worktree beside it, whose .git is a FILE, is the control.
mkdir -p "$r/husk-owner/tmp"; : > "$r/husk-owner/tmp/effort-ledger-h.jsonl"
printf 'owner=%s\nmode=test\n' "$r/husk-owner" > "$REG/3.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a husk owner (directory, no .git) runs the full reap" 'STACK-SLOT args=\[reap\]' "$out"
printf 'owner=%s\nmode=test\n' "$r/.claude/worktrees/bf-941" > "$REG/3.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a linked-worktree owner (.git file) is alive, disk pass only" 'STACK-SLOT args=\[reap --disk-only\]' "$out"

# An unreachable daemon must skip BOTH, the same way it always skipped the teardown: `reap` reads docker to
# decide what is abandoned AND to read the VM's disk, so a daemon answering nothing makes every stack look
# gone and every disk reading undeterminable.
out=$(FAKE_DOCKER_DOWN=1 FAKE_COMPOSE_LS="bf-s5" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an unreachable daemon skips the sweep entirely" 'daemon unavailable' "$out"
ck "stack sweep: an unreachable daemon calls stack-slot not at all" NOCALL \
   "$(printf '%s' "$out" | grep -q 'STACK-SLOT args=' && echo CALLED || echo NOCALL)"

# An owner git cannot resolve (a plain directory outside any repository) is kept and warned about by stack-slot, so the
# gate must not read it as dead: the old `-d` plus `.git` test did, and fired a full reap every hour.
# GIT_CEILING_DIRECTORIES keeps git from discovering a repository above $ROOT, so a TMPDIR inside a checkout cannot make this owner resolve.
mkdir -p "$ROOT/plain-owner"
ck "fixture: the plain owner is outside any repository" UNRESOLVABLE \
   "$(GIT_CEILING_DIRECTORIES="$ROOT" git -C "$ROOT/plain-owner" rev-parse --show-toplevel >/dev/null 2>&1 && echo RESOLVES || echo UNRESOLVABLE)"
printf 'owner=%s\nmode=test\n' "$ROOT/plain-owner" > "$REG/4.slot"
out=$(GIT_CEILING_DIRECTORIES="$ROOT" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an owner git cannot resolve is not dead, disk pass only" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
rm -f "$REG/4.slot"

# stack-slot's pass 1 skips the reserved slots, so a gone owner on slot 1 reclaims nothing.
printf 'owner=%s\nmode=test\n' "$ROOT/checkout-that-is-gone" > "$REG/1.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a gone owner on reserved slot 1 is no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
rm -f "$REG/1.slot"

# An entry corrupt_slot_reason flags (here a non-absolute owner) is kept and warned about, never torn down.
printf 'owner=relative/checkout\nmode=test\n' > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a corrupt entry is no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
# A well-formed entry with no owner= line reads as gone to pass 1, which reclaims it.
printf 'mode=test\n' > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an entry with no owner line runs the full reap" 'STACK-SLOT args=\[reap\]' "$out"
rm -f "$REG/4.slot"

# Each corrupt_slot_reason check has a shape that would otherwise read as gone and fire the full reap: the gate keeps all of them.
# The gone owner makes the shape the only thing separating "kept" from "torn down".
gone="$ROOT/checkout-that-is-gone"
: > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an empty entry is corrupt, no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
printf 'owner=%s\nowner=\n' "$gone" > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a doubled owner= line is corrupt, no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
printf 'owner=%s \nmode=test\n' "$gone" > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an owner with trailing whitespace is corrupt, no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
: > "$ROOT/owner-is-a-file"
printf 'owner=%s\nmode=test\n' "$ROOT/owner-is-a-file" > "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an owner that is a regular file is corrupt, no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
if [ "$(id -u)" != 0 ]; then
  printf 'owner=%s\nmode=test\n' "$gone" > "$REG/4.slot"; chmod 000 "$REG/4.slot"
  out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
  ck "stack sweep: an unreadable entry is corrupt, no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
  chmod 600 "$REG/4.slot"
fi
rm -f "$REG/4.slot"
# A <N>.slot that is a directory passes every corrupt_slot_reason check (grep's error on it leaves the owner-line count empty), so the tool
# reads it as ownerless and reclaims it; the gate agrees and keeps grep's and test's complaints out of the hourly log.
mkdir "$REG/4.slot"
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a directory entry reads as ownerless, runs the full reap" 'STACK-SLOT args=\[reap\]' "$out"
ck "stack sweep: a directory entry leaves no grep or test noise" NONOISE \
   "$(printf '%s' "$out" | grep -q -e 'Is a directory' -e 'integer expression' && echo NOISE || echo NONOISE)"
rmdir "$REG/4.slot"

# Pass 2 reclaims a bf-s<N> compose project (N >= 2) with no registry entry and nothing listening on its ingress port
# 8443 + (N-1)*100. Every registered owner here is alive, so only the docker arm can fire.
out=$(FAKE_COMPOSE_LS="local bf-s1 bf-s5" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an unregistered non-listening bf-s5 runs the full reap" 'STACK-SLOT args=\[reap\]' "$out"
out=$(FAKE_COMPOSE_LS="local bf-s1 bf-s5" FAKE_LISTEN_PORTS="8843" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an unregistered but listening bf-s5 is only reported, disk pass only" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
out=$(FAKE_COMPOSE_LS="local bf-s1" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: the reserved local and bf-s1 projects never count" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
out=$(FAKE_COMPOSE_LS="bf-s2 other-project bf-s7x" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a registered bf-s2 and non-slot project names never count" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
stack_slot_stub pre-disk-only
out=$(FAKE_COMPOSE_LS="bf-s5" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: an unregistered orphan runs the full reap on a tool without --disk-only" 'STACK-SLOT args=\[reap\]' "$out"
stack_slot_stub with-disk-only

# A leading-zero project name is never created by stack_derive and would abort the port arithmetic (invalid octal) before the sweep reached
# stack-slot at all; it must be skipped, not crash the run.
out=$(FAKE_COMPOSE_LS="bf-s08" PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a leading-zero bf-s08 is not counted, and the run goes on to the disk pass" 'STACK-SLOT args=\[reap --disk-only\]' "$out"

# A failing `compose ls` (no compose plugin) or a wedged one probes nothing: no trigger, and the skipped probe is logged.
out=$(FAKE_COMPOSE_LS="bf-s5" FAKE_COMPOSE_LS_FAIL=1 PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a failing compose ls is no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
ck "stack sweep: a failing compose ls logs the skipped probe" 'unregistered stack probe skipped' "$out"
# The hang cases also time the run: the stub sleeps 30s, so a bound that stops killing the wedged call still reports 124 and passes every
# other assertion — only after waiting the wedge out under the repo lock.
t0=$SECONDS
out=$(FAKE_COMPOSE_LS="bf-s5" FAKE_COMPOSE_LS_HANG=1 REAP_STACK_DOCKER_BOUND_SECS=1 PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
el=$((SECONDS - t0))
ck "stack sweep: a compose ls that outlasts the bound is no trigger" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
ck "stack sweep: a compose ls that outlasts the bound logs the skipped probe" 'unregistered stack probe skipped' "$out"
ck "stack sweep: a compose ls that outlasts the bound is killed, not waited out" FAST "$([ "$el" -lt 15 ] && echo FAST || echo "SLOW ${el}s")"
# The daemon answers nothing before the bound: the sweep is skipped like an unreachable one rather than hanging under the repo lock.
t0=$SECONDS
out=$(FAKE_DOCKER_INFO_HANG=1 FAKE_COMPOSE_LS="bf-s5" REAP_STACK_DOCKER_BOUND_SECS=1 PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
el=$((SECONDS - t0))
ck "stack sweep: a docker info that outlasts the bound skips the sweep" 'daemon unavailable' "$out"
ck "stack sweep: a docker info that outlasts the bound is killed, not waited out" FAST "$([ "$el" -lt 15 ] && echo FAST || echo "SLOW ${el}s")"
ck "stack sweep: a docker info that outlasts the bound calls stack-slot not at all" NOCALL \
   "$(printf '%s' "$out" | grep -q 'STACK-SLOT args=' && echo CALLED || echo NOCALL)"

# stack-slot's pass 2 reads a missing lsof as "nothing listening" and tears down a live unregistered stack, so with lsof absent the full
# reap is never chosen, whichever arm fired: both do here (a dead owner on slot 3, an unregistered bf-s5).
nolsof_path=""; _n=0
IFS=: read -r -a _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  if [ -e "$_d/lsof" ]; then
    _n=$((_n+1)); _m="$ROOT/nolsof-$_n"; mkdir -p "$_m"
    for _f in "$_d"/*; do [ "${_f##*/}" = lsof ] || ln -s "$_f" "$_m/"; done
    _d="$_m"
  fi
  nolsof_path="$nolsof_path:$_d"
done
nolsof_stub="$ROOT/stack-stub-nolsof"; mkdir -p "$nolsof_stub"; ln -sf "$stack_stub/docker" "$nolsof_stub/docker"
NOLSOF_PATH="$nolsof_stub$nolsof_path"
ck "fixture: lsof is absent from the restricted PATH" ABSENT "$(PATH="$NOLSOF_PATH" command -v lsof >/dev/null && echo PRESENT || echo ABSENT)"
printf 'owner=%s\nmode=test\n' "$gone" > "$REG/3.slot"
out=$(FAKE_COMPOSE_LS="bf-s5" PATH="$NOLSOF_PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: without lsof both arms would fire, yet only the disk pass runs" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
ck "stack sweep: without lsof the full stack reap is logged as skipped" 'lsof not found -- full stack reap skipped' "$out"
ck "stack sweep: without lsof the full reap is never called" NOFULL \
   "$(printf '%s' "$out" | grep -q 'STACK-SLOT args=\[reap\]' && echo FULL || echo NOFULL)"
stack_slot_stub pre-disk-only
out=$(FAKE_COMPOSE_LS="bf-s5" PATH="$NOLSOF_PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: without lsof a tool lacking --disk-only calls nothing" NOCALL \
   "$(printf '%s' "$out" | grep -q 'STACK-SLOT args=' && echo CALLED || echo NOCALL)"
stack_slot_stub with-disk-only

# A full reap that dies (the registry lock held past its bound, a stale lock) must not cost the hour's disk pass.
stack_slot_stub with-disk-only fail-full
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a failed full reap is followed by the disk pass" 'STACK-SLOT args=\[reap --disk-only\]' "$out"
ck "stack sweep: a failed full reap logs the fallback" "stack sweep 'reap' failed -- running the disk pass" "$out"
stack_slot_stub pre-disk-only fail-full
out=$(PATH="$stack_stub:$PATH" $SCRIPT reap "$r" 2>&1)
ck "stack sweep: a failed full reap on a tool without --disk-only is logged and skipped" "stack sweep 'reap' failed -- skipped" "$out"
ck "stack sweep: a failed full reap on a tool without --disk-only runs nothing more" NODISK \
   "$(printf '%s' "$out" | grep -q 'reap --disk-only' && echo DISK || echo NODISK)"
stack_slot_stub with-disk-only
rm -f "$REG/3.slot"

# The registry arm is driven directly for the two properties the end-to-end run cannot show: it is not saved by running inside an `if`
# (an unresolvable owner makes git fail, a directory entry makes grep fail, and neither may abort a caller under set -e), and it ignores a
# GIT_DIR / GIT_WORK_TREE inherited from a hook or `rebase --exec`, which would otherwise answer for every -C. plain mode prints FIRED or QUIET;
# errexit mode prints FIRED only when the arm fired and ran to the end.
registry_gate() {   # registry_gate <errexit|plain> <KEY=VALUE>...
  local mode="$1"; shift
  bash -c '. "$1" list "$2" >/dev/null 2>&1; mode=$3; shift 3; export "$@"
    if [ "$mode" = errexit ]; then set -e; _stack_slot_registry_has_reclaimable_entry; echo FIRED
    else set +e; _stack_slot_registry_has_reclaimable_entry && echo FIRED || echo QUIET; fi' _ "$REAPER" "$ghost" "$mode" "$@" 2>&1
}
printf 'owner=%s\nmode=test\n' "$ROOT/plain-owner" > "$REG/5.slot"      # git cannot resolve it: kept, and git exits non-zero
printf 'owner=%s\nmode=test\n' "$gone" > "$REG/6.slot"                  # the entry after it must still be reached
ck "registry arm: an unresolvable owner does not stop the scan under set -e" FIRED \
   "$(registry_gate errexit GIT_CEILING_DIRECTORIES="$ROOT")"
rm -f "$REG/5.slot" "$REG/6.slot"
mkdir "$REG/5.slot"
ck "registry arm: a directory entry does not stop the scan under set -e" FIRED "$(registry_gate errexit REAP_TEST=1)"
rmdir "$REG/5.slot"
# The owner is spelled physically: an inherited variable makes git answer with the owner's own toplevel, and a symlinked spelling ($TMPDIR is one on
# macOS) would read as husk anyway, hiding the effect.
husk_phys=$(cd "$r/husk-owner" && pwd -P)
printf 'owner=%s\nmode=test\n' "$husk_phys" > "$REG/5.slot"
ck "registry arm: a husk owner fires" FIRED "$(registry_gate plain REAP_TEST=1)"
ck "registry arm: an inherited GIT_DIR does not turn the husk into its own toplevel" FIRED "$(registry_gate plain GIT_DIR="$r/.git")"
ck "registry arm: an inherited GIT_WORK_TREE does not turn the husk into its own toplevel" FIRED \
   "$(registry_gate plain GIT_WORK_TREE="$husk_phys")"
ck "registry arm: an inherited GIT_COMMON_DIR does not make git fail on the husk" FIRED \
   "$(registry_gate plain GIT_COMMON_DIR="$ROOT/no-such-common-dir")"
rm -f "$REG/5.slot"
rm -f "$REG/2.slot" "$REG/3.slot"

echo "== merged by content: the finish-merge.sh shape, whose branch tip is a sibling of source and never its ancestor =="

# build_fm_shape <name> <issue> → repo path. The 2026-10-07 leftover, produced by the REAL finish-merge.sh: the branch
# commits, source advances underneath it, a tool drops an untracked file into the worktree, and the merge lands on
# main as a merge commit built with commit-tree — parents [main, original tip] — while `git worktree remove`
# refuses. The branch tip is then a sibling of main, which the ancestor test can never see; eleven basefund
# issues sat in exactly this state reading "active". The first invocation merges source into the worktree and
# stops at the merged-tree gate (exit 5); the second lands it (exit 0).
# An optional third argument names the source branch (default main): it is forked from main and the main checkout
# moves onto it, so the merge lands there and the default branch stays behind — the basefund shape (day branch
# `wednesday`, default `main`).
build_fm_shape() {
  local name="$1" issue="$2" source="${3:-main}" repo slug wt msg rc1 rc2
  repo=$(build_case "$name" "$issue" started 1 0 idle)
  slug=$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')
  wt="$repo/.claude/worktrees/$slug"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t   # the merge and commit-tree need an identity
  if [ "$source" != main ]; then
    git -C "$repo" checkout -q -b "$source" main
    git -C "$wt" config --worktree start.source-branch "$source"
  fi
  echo sibling > "$repo/sibling"; git -C "$repo" add sibling; git -C "$repo" commit -q -m sibling
  echo stray > "$wt/AGENTS.md"
  msg="$repo/msg.md"; printf 'Merge %s\n' "$issue" > "$msg"
  (cd "$repo" && _WT_SKIP_IDENTITY_CHECK=1 "$FM" "$wt" "$source" "user/$slug" "$msg") > "$ROOT/fm-$slug-1.log" 2>&1; rc1=$?
  (cd "$repo" && _WT_SKIP_IDENTITY_CHECK=1 "$FM" "$wt" "$source" "user/$slug" "$msg") > "$ROOT/fm-$slug-2.log" 2>&1; rc2=$?
  [ "$rc1/$rc2" = 5/0 ] || { echo "FIXTURE: finish-merge.sh exited $rc1 then $rc2 (want 5 then 0)" >&2; cat "$ROOT/fm-$slug-1.log" "$ROOT/fm-$slug-2.log" >&2; exit 1; }
  idle_index "$wt"   # the catch-up merge touched the index
  printf '%s' "$repo"
}
# Backdating the index makes every entry racily clean (file mtime ≥ index mtime), so the reaper's own `git status`
# rewrites the index on its first pass through a fixture and the next pass reads it as live. Production indexes are
# older than their files, so a real pass does not refresh them; a fixture evaluated twice re-idles in between.
idle_index() { touch -t 200001010000 "$(git -C "$1" rev-parse --absolute-git-dir)/index"; }
orig_ref_state() { git -C "$1" show-ref --verify --quiet "refs/finish-merge/$2-orig" && echo PRESENT || echo GONE; }
branch_state() { git -C "$1" rev-parse --verify --quiet "$2" >/dev/null 2>&1 && echo PRESENT || echo NOBRANCH; }

r=$(build_fm_shape fm_dirty BF-970)
wt="$r/.claude/worktrees/bf-970"
ck "fixture: the merge landed on main as a two-parent merge commit" '^2$' "$(git -C "$r" cat-file -p main | grep -c '^parent ')"
ck "fixture: the branch tip is a sibling of main, not an ancestor" NOTANCESTOR \
   "$(git -C "$r" merge-base --is-ancestor user/bf-970 main && echo ANCESTOR || echo NOTANCESTOR)"
ck "fixture: worktree, branch and orig ref were all left behind" 'PRESENT/PRESENT/PRESENT' \
   "$([ -d "$wt" ] && echo PRESENT || echo GONE)/$(branch_state "$r" user/bf-970)/$(orig_ref_state "$r" user-bf-970)"

if git -C "$r" merge-tree --write-tree main main >/dev/null 2>&1; then
  # The dirty-tree rule is unchanged: a merged-but-dirty worktree is reported with the blocker and the clear
  # command, and never auto-removed — this is the line the AGENTS.md leftovers would have printed on the first pass.
  ck "merged by content + dirty → KEEP, reported, never auto-removed" \
     'KEEP — branch merged into main (by content), but the worktree is dirty' "$($SCRIPT list "$r" 2>&1)"
  out=$($SCRIPT reap "$r" 2>&1)
  ck "reap leaves a merged-but-dirty worktree in place" PRESENT "$([ -d "$wt" ] && echo PRESENT || echo GONE)"
  rm -f "$wt/AGENTS.md"; idle_index "$wt"
  ck "merged by content + clean → eligible" 'REAP-ELIGIBLE — branch merged into main (by content)' "$($SCRIPT list "$r" 2>&1)"
  idle_index "$wt"
  out=$($SCRIPT reap "$r" 2>&1)
  ck "reap removes it" 'REAPED — branch merged into main (by content)' "$out"
  ck "worktree gone" GONE "$([ -d "$wt" ] && echo PRESENT || echo GONE)"
  ck "branch gone" NOBRANCH "$(branch_state "$r" user/bf-970)"
  ck "its refs/finish-merge orig ref goes with it" GONE "$(orig_ref_state "$r" user-bf-970)"
  ck "main still carries the work" '^x$' "$(git -C "$r" show main:f)"

  # The PL-459 guard is load-bearing here: a just-forked worktree's tip equals its baseline, so a dry-run merge
  # returns source's own tree and the content test reads "contained" — measured on a fresh basefund worktree.
  r=$(build_case zero_contained BF-971 started 0 0 idle)
  echo sibling > "$r/sibling"; git -C "$r" add sibling; git -C "$r" -c user.email=t@t -c user.name=t commit -q -m sibling
  ck "fixture: a zero-commit branch reads contained by the dry-run merge" yes \
     "$([ "$(git -C "$r" merge-tree --write-tree main user/bf-971 | head -n1)" = "$(git -C "$r" rev-parse 'main^{tree}')" ] && echo yes || echo no)"
  ck "zero-commit + source advanced + issue active → KEEP (guard A gates the content evidence too)" \
     'KEEP — no commits since baseline (just-forked' "$($SCRIPT list "$r" 2>&1)"

  # Genuinely unmerged content: the dry-run merge produces a tree main does not have.
  r=$(build_case unmerged_content BF-972 started 1 0 idle)
  echo sibling > "$r/sibling"; git -C "$r" add sibling; git -C "$r" -c user.email=t@t -c user.name=t commit -q -m sibling
  ck "commits main lacks + source advanced → KEEP — active" 'KEEP — active (not merged' "$($SCRIPT list "$r" 2>&1)"

  # A conflicting dry-run merge exits 1 and still prints a tree id on its first line; that must never read as merged.
  r=$(build_case conflicting BF-973 started 1 0 idle)
  echo y > "$r/f"; git -C "$r" add f; git -C "$r" -c user.email=t@t -c user.name=t commit -q -m "main adds f too"
  ck "fixture: the dry-run merge conflicts (exit 1)" '^1$' "$(git -C "$r" merge-tree --write-tree main user/bf-973 >/dev/null 2>&1; echo $?)"
  ck "a conflicting dry-run merge → KEEP — active" 'KEEP — active (not merged' "$($SCRIPT list "$r" 2>&1)"

  echo "== branch-only leftovers: a finish-merge.sh orig ref whose worktree is gone =="

  # bf-1501/2428/2437 on 2026-10-07: the worktree went by hand, the branch and its refs/finish-merge ref stayed.
  r=$(build_fm_shape fm_branch_only BF-974)
  git -C "$r" worktree remove --force "$r/.claude/worktrees/bf-974"
  git -C "$r" update-ref refs/finish-merge/user-bf-999-orig "$(git -C "$r" rev-parse main)"     # its branch is gone entirely
  # Control: a branch-only leftover with an orig ref but unmerged content (finish-merge.sh ran and never landed it).
  git -C "$r" worktree add -q -b user/bf-975 "$r/wt975" main
  echo z > "$r/wt975/z"; git -C "$r/wt975" add z; git -C "$r/wt975" -c user.email=t@t -c user.name=t commit -q -m unlanded
  git -C "$r" worktree remove "$r/wt975"
  git -C "$r" update-ref refs/finish-merge/user-bf-975-orig user/bf-975
  out=$($SCRIPT list "$r" 2>&1)
  ck "list: a branch-only leftover merged by content is reported" 'STALE-BRANCH user/bf-974 — merged into main (by content)' "$out"
  ck "list: an orig ref whose branch is gone is reported" 'STALE-MERGE-REF refs/finish-merge/user-bf-999-orig' "$out"
  ck "list: an unmerged branch-only leftover is never a candidate" NOMATCH "$(printf '%s' "$out" | grep -q 'bf-975' && echo MATCHED || echo NOMATCH)"
  ck "list deletes nothing" 'PRESENT/PRESENT' "$(branch_state "$r" user/bf-974)/$(orig_ref_state "$r" user-bf-999)"
  out=$($SCRIPT reap "$r" 2>&1)
  ck "reap deletes the merged branch-only leftover" 'REAPED-BRANCH user/bf-974' "$out"
  ck "and its orig ref" GONE "$(orig_ref_state "$r" user-bf-974)"
  ck "reap deletes the orig ref whose branch is gone" GONE "$(orig_ref_state "$r" user-bf-999)"
  ck "the unmerged leftover and its orig ref survive" 'PRESENT/PRESENT' "$(branch_state "$r" user/bf-975)/$(orig_ref_state "$r" user-bf-975)"
  ck "main still carries bf-974's work" '^x$' "$(git -C "$r" show main:f)"
  # The basefund shape: the merge landed on a day branch the default branch does not carry, and a sibling leftover
  # forked from that day branch afterwards contains the work too (and sorts before it). The target must be the day
  # branch — a branch with an orig ref of its own is never a mainline.
  r=$(build_fm_shape fm_day_branch BF-977 wednesday)
  git -C "$r" worktree remove --force "$r/.claude/worktrees/bf-977"
  git -C "$r" worktree add -q -b rosskevin/bf-978 "$r/wt978" wednesday
  echo later > "$r/wt978/later"; git -C "$r/wt978" add later; git -C "$r/wt978" -c user.email=t@t -c user.name=t commit -q -m later
  git -C "$r" worktree remove "$r/wt978"
  git -C "$r" update-ref refs/finish-merge/rosskevin-bf-978-orig rosskevin/bf-978
  ck "fixture: the default branch does not carry the work" NO "$(git -C "$r" merge-base --is-ancestor refs/finish-merge/user-bf-977-orig main && echo YES || echo NO)"
  out=$($SCRIPT list "$r" 2>&1)
  ck "a leftover merged into a day branch names that branch, not a sibling leftover that also contains it" \
     'STALE-BRANCH user/bf-977 — merged into wednesday (by content)' "$out"
  ck "the sibling leftover with unmerged content is untouched" NOMATCH "$(printf '%s' "$out" | grep -q 'STALE-BRANCH rosskevin/bf-978' && echo MATCHED || echo NOMATCH)"
  # A branch checked out somewhere is live work whatever its refs say.
  r=$(build_fm_shape fm_checked_out BF-976)
  ck "a branch with a worktree is the worktree's verdict, never a branch-only candidate" NOMATCH \
     "$($SCRIPT list "$r" 2>&1 | grep 'STALE-BRANCH' >/dev/null && echo MATCHED || echo NOMATCH)"
else
  echo "  SKIP  git merge-tree --write-tree is unsupported ($(git --version)); the content-containment arms need git >= 2.38"
fi

echo
echo "reap-worktrees: $pass passed, $fail failed"
[ "$fail" = 0 ]
