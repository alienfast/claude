#!/usr/bin/env bash
# Functional suite for reap-tmp.sh — the manifest, the lane rules, and the guards that decide whether a
# tmp/ entry is deleted. Builds throwaway repos and drives the real script end to end (so `reap` also
# exercises the with-repo-lock.py re-exec).
#
# GROW THIS SUITE, NEVER PRUNE IT. The script deletes files unattended (reap-tmp-cron.sh, daily); every
# hole found in a gate belongs below as a case, added WITH the fix.
#
# The last case sweeps the corpus for every `tmp/<name>` a skill, script, hook, or standard writes and
# fails when one resolves to the DEFAULT rule rather than a named one. That is what keeps the manifest
# the safety boundary: a new cross-session handoff file must be classified on purpose, not fall into the
# scratch lane by omission.

set -uo pipefail

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/scripts/reap-tmp.sh"
ROOT=$(mktemp -d)
SLEEPERS="$ROOT/sleepers"; : > "$SLEEPERS"
trap '_p=$(cat "$SLEEPERS" 2>/dev/null); [ -n "$_p" ] && kill $_p 2>/dev/null; rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

# Fake HOME. The reaper resolves SELF and the lock helper through $HOME/.claude/scripts, so those two are
# symlinked in; $HOME/.claude/tmp is a real, empty directory so the no-arg case can never reach the actual
# checkout's tmp/. Every case that names a root passes it explicitly, so the registries are read only by
# the no-arg case, which writes its own.
mkdir -p "$ROOT/home/.claude/scripts" "$ROOT/home/.claude/tmp"
ln -s "$SCRIPT" "$ROOT/home/.claude/scripts/reap-tmp.sh"
ln -s "$CLAUDE_DIR/scripts/with-repo-lock.py" "$ROOT/home/.claude/scripts/with-repo-lock.py"
export HOME="$ROOT/home"
for _v in "${!REAP_TMP_@}"; do unset "$_v"; done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fi
}
ckno() { # ckno <label> <unexpected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then fail=$((fail+1)); echo "  FAIL  $1"; echo "        must not contain: $2"; echo "        got    $3"
  else pass=$((pass+1)); echo "  PASS  $1"; fi
}

NOW=$(date +%s); D=86400; H=3600
stamp() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; }
age() { touch -t "$(stamp $((NOW - $2)))" "$1"; }                 # age <path> <seconds-ago>
mkfile() { mkdir -p "$(dirname "$1")"; printf '%s' "${3:-x}" > "$1"; age "$1" "$2"; }   # mkfile <path> <seconds-ago> [content]

mk_repo() { # mk_repo <name> → path; main with one commit, empty tmp/
  local r="$ROOT/$1"; mkdir -p "$r"
  git -C "$r" init -q >/dev/null 2>&1; git -C "$r" symbolic-ref HEAD refs/heads/main
  printf 'x\n' > "$r/README"; git -C "$r" add README; git -C "$r" commit -qm init
  mkdir -p "$r/tmp"; echo "$r"
}
unmerged_branch() { # unmerged_branch <repo> <branch>: a commit main does not have
  git -C "$1" switch -q -c "$2" && printf 'y\n' > "$1/f-$RANDOM" && git -C "$1" add . && git -C "$1" commit -qm c && git -C "$1" switch -q main
}

echo "== manifest (classify seam) =="
while IFS='|' read -r name kind want; do
  [ -n "$name" ] || continue
  ck "classify $name${kind:+/}" "$want" "$($SCRIPT classify "$name" "${kind:-f}")"
done <<'ROWS'
keep|d|never keep-hatch
fleet-metrics-history.jsonl||never metrics-history
fleet-linear-window.json||never retro-inputs
fleet-shipped-issues.json||never retro-inputs
fleet-deadline.json||never fleet-marker
fleet-recommendation.json||never fleet-recommendation
auto-state-3eeea4c4.json||never auto-ledger
auto-state.json||scratch legacy-auto-state
triage-proposals|d|never triage-proposals
triage-proposals/raw|d|scratch-dir triage-raw
fleet-sequence-bf-2022.json||state sequence-marker
fleet-sequence.json||state sequence-marker
fleet-sequence-bf-2022.log||state sequence-sidecar
fleet-sequence-bf-2022.pid||state sequence-sidecar
fleet-sequence-pr-update-bf-2022|d|scratch-dir orphan-pr-worktree
quality-review-verdict-bf-123.md||state verdict
quality-review-verdict-no-issue.md||scratch verdict-no-issue
triage-cheap.ndjson||handoff triage-scan-inputs
triage-pool.ndjson||handoff triage-scan-inputs
triage-head.sha||handoff triage-scan-inputs
triage-commit-subjects.txt||handoff triage-scan-inputs
triage-ls-files.txt||handoff triage-scan-inputs
linear-context-bf-123.md||cache presence-cache
triage-digest-BF-123.md||cache presence-cache
run.done||cache poll-marker
triage-scan.done||cache poll-marker
wait-rspec.sh||cache poll-marker
fleet-quota-launch.json||scratch retired
linear-description-bf-123.md||scratch staging-body
linear-comment-bf-123-merge.md||scratch staging-body
spec-bf-123.md||scratch staging-body
spec-comment-bf-123.md||scratch staging-body
keeper-comment-bf123.md||scratch staging-body
canceled-comment-bf-123.md||scratch staging-body
finish-commit-bf-123.md||scratch staging-body
git-merge-msg-bf-123.md||scratch staging-body
pr-body-bf-123.md||scratch staging-body
verdict-body-bf-123.md||scratch staging-body
.qr-verdict-Ab12Cd||scratch staging-body
qr-fix-delta-bf-123-1.diff||scratch review-working
quality-review-nth-bf-123.md||scratch review-working
deferred-Ab12Cd||scratch review-working
reflect-improvement-Ab12Cd||scratch review-working
pool.json||scratch run-output
epic-graph.json||scratch run-output
forecast-3.txt||scratch run-output
check-bf123.log||scratch run-output
bf-1826-graph.err||scratch run-output
next-auto.out||scratch run-output
bf547-desc.md||scratch default-file
whatever||scratch default-file
qr-fix-base-bf-123-2|d|scratch-dir scratch-dir
qr-probe-rails|d|scratch-dir scratch-dir
screenshots|d|scratch-dir scratch-dir
triage-markers|d|scratch-dir scratch-dir
triage-apply-bodies|d|scratch-dir scratch-dir
epic-merge|d|scratch-dir scratch-dir
proposal-my-slug|d|scratch-dir scratch-dir
epic-desc|d|unknown unknown-dir
investigations|d|unknown unknown-dir
ROWS

echo "== age lanes and the fresh guard =="
r=$(mk_repo lanes)
mkfile "$r/tmp/fresh.log" 0
mkfile "$r/tmp/young.log" $((3*D))
mkfile "$r/tmp/old.log" $((8*D))
mkfile "$r/tmp/old-cache-linear-context-bf-1.md" 0; mv "$r/tmp/old-cache-linear-context-bf-1.md" "$r/tmp/linear-context-bf-1.md"; age "$r/tmp/linear-context-bf-1.md" $((2*D))
mkfile "$r/tmp/linear-context-bf-2.md" $((12*H))
mkfile "$r/tmp/run.done" $((2*D))
mkfile "$r/tmp/triage-head.sha" $((20*D))
mkfile "$r/tmp/triage-ls-files.txt" $((40*D))
mkfile "$r/tmp/fleet-metrics-history.jsonl" $((60*D)) '{"session_set":["zzz"]}'
mkfile "$r/tmp/auto-state-deadbeef.json" $((60*D)) '{"status":"active"}'
mkfile "$r/tmp/auto-state.json" $((60*D)) '{}'
mkfile "$r/tmp/keep/notes.md" $((60*D)); age "$r/tmp/keep" $((60*D))
mkfile "$r/tmp/README-sibling" $((60*D))   # a top-level file of any name is scratch
ln -s ../README "$r/tmp/link"
out=$($SCRIPT list "$r" 2>&1)
ck "fresh file is kept whatever its lane"            'KEEP      fresh.log — modified within 24h' "$out"
ck "scratch younger than 7d is kept"                 'KEEP      young.log — run-output — 3d old, kept 7d' "$out"
ck "scratch older than 7d is eligible"               'ELIGIBLE  old.log — run-output — 8d old (> 7d)' "$out"
ck "presence cache older than 1d is eligible"        'ELIGIBLE  linear-context-bf-1.md — presence-cache — 2d old (> 1d)' "$out"
ck "presence cache younger than 1d is kept"          'KEEP      linear-context-bf-2.md — modified within 24h' "$out"
ck "poll marker older than 1d is eligible"           'ELIGIBLE  run.done — poll-marker' "$out"
ck "handoff younger than 30d is kept"                'KEEP      triage-head.sha — triage-scan-inputs — 20d old, kept 30d' "$out"
ck "handoff older than 30d is eligible"              'ELIGIBLE  triage-ls-files.txt — triage-scan-inputs — 40d old (> 30d)' "$out"
ck "metrics history is never eligible"               'KEEP      fleet-metrics-history.jsonl — metrics-history' "$out"
ck "auto ledger is never eligible"                   'KEEP      auto-state-deadbeef.json — auto-ledger' "$out"
ck "legacy auto-state.json is scratch"               'ELIGIBLE  auto-state.json — legacy-auto-state' "$out"
ck "keep/ hatch is never eligible"                   'KEEP      keep — keep-hatch' "$out"
ck "unknown top-level file ages out as scratch"      'ELIGIBLE  README-sibling — default-file' "$out"
ck "symlink is kept and never followed"              'KEEP      link — symlink' "$out"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the eligible scratch file"          'REAPED    old.log' "$out"
ck "reap prints a summary"                           'summary: reaped 6 (' "$out"
[ -e "$r/tmp/old.log" ] && ck "old.log gone" GONE PRESENT || ck "old.log gone" GONE GONE
[ -e "$r/tmp/young.log" ] && ck "young.log survives" OK OK || ck "young.log survives" OK GONE
[ -e "$r/tmp/fresh.log" ] && ck "fresh.log survives" OK OK || ck "fresh.log survives" OK GONE
[ -e "$r/tmp/fleet-metrics-history.jsonl" ] && ck "history survives" OK OK || ck "history survives" OK GONE
[ -e "$r/tmp/auto-state-deadbeef.json" ] && ck "ledger survives" OK OK || ck "ledger survives" OK GONE
[ -e "$r/tmp/keep/notes.md" ] && ck "keep/ survives" OK OK || ck "keep/ survives" OK GONE
[ -e "$r/tmp/auto-state.json" ] && ck "legacy auto-state.json gone" GONE PRESENT || ck "legacy auto-state.json gone" GONE GONE
[ -L "$r/tmp/link" ] && [ -e "$r/README" ] && ck "symlink and its target survive" OK OK || ck "symlink and its target survive" OK GONE
[ -d "$r/tmp" ] && ck "tmp/ itself survives" OK OK || ck "tmp/ itself survives" OK GONE
ckno "reap mode prints no KEEP lines"               'KEEP      ' "$out"

echo "== verdicts: branch state gates the /finish handoff =="
r=$(mk_repo verdicts)
unmerged_branch "$r" user/bf-100-unmerged
git -C "$r" branch user/bf-101-merged main
mkfile "$r/tmp/quality-review-verdict-bf-100.md" $((8*D))
mkfile "$r/tmp/quality-review-verdict-bf-101.md" $((8*D))
mkfile "$r/tmp/quality-review-verdict-bf-102.md" $((8*D))
mkfile "$r/tmp/quality-review-verdict-bf-10.md"  $((8*D))    # prefix of bf-100: must not inherit its branch
mkfile "$r/tmp/quality-review-verdict-bf-103.md" $((3*D))
mkfile "$r/tmp/quality-review-verdict-no-issue.md" $((8*D))
out=$($SCRIPT list "$r" 2>&1)
ck "unmerged branch keeps the verdict"               'KEEP      quality-review-verdict-bf-100.md — branch user/bf-100-unmerged not merged into main' "$out"
ck "merged branch releases the verdict"              'ELIGIBLE  quality-review-verdict-bf-101.md — every bf-101 branch is merged into main — 8d old' "$out"
ck "no branch releases the verdict"                  'ELIGIBLE  quality-review-verdict-bf-102.md — no local branch for bf-102' "$out"
ck "issue prefix does not match a longer issue"      'ELIGIBLE  quality-review-verdict-bf-10.md — no local branch for bf-10' "$out"
ck "consumed verdict still honours the 7d floor"     'KEEP      quality-review-verdict-bf-103.md — no local branch for bf-103 — 3d old, kept 7d' "$out"
ck "no-issue verdict is plain scratch"               'ELIGIBLE  quality-review-verdict-no-issue.md — verdict-no-issue' "$out"
out=$($SCRIPT reap "$r" 2>&1)
[ -e "$r/tmp/quality-review-verdict-bf-100.md" ] && ck "unmerged verdict survives reap" OK OK || ck "unmerged verdict survives reap" OK GONE
[ -e "$r/tmp/quality-review-verdict-bf-101.md" ] && ck "merged verdict reaped" GONE PRESENT || ck "merged verdict reaped" GONE GONE

echo "== verdicts: a fleet window is held until /fleet-retro measures it =="
r=$(mk_repo fleetwindow)
mkfile "$r/tmp/fleet-deadline.json" $((10*D)) "{\"launch_epoch\": $((NOW - 10*D)), \"stopped\": true, \"fleet_sessions\": [\"abc12345\"]}"
mkfile "$r/tmp/quality-review-verdict-bf-200.md" $((8*D))     # written after the launch
mkfile "$r/tmp/quality-review-verdict-bf-201.md" $((12*D))    # written before it
out=$($SCRIPT list "$r" 2>&1)
ck "in-window verdict is held before the retro"     'KEEP      quality-review-verdict-bf-200.md — written during the fleet launched' "$out"
ck "pre-window verdict is not held"                  'ELIGIBLE  quality-review-verdict-bf-201.md — no local branch for bf-201' "$out"
mkfile "$r/tmp/fleet-metrics-history.jsonl" $((1*D)) "{\"session_set\":[\"abc12345\"],\"fleet_start\":\"x\"}"
out=$($SCRIPT list "$r" 2>&1)
ck "retro row releases the in-window verdict"       'ELIGIBLE  quality-review-verdict-bf-200.md — no local branch for bf-200' "$out"

echo "== sequence markers =="
r=$(mk_repo sequences)
sleep 600 & echo $! >> "$SLEEPERS"; live=$!
mkfile "$r/tmp/fleet-sequence-bf-1.json" $((8*D)) "{\"status\":\"running\",\"runner_pid\":$live,\"branch\":\"seq/bf-1\"}"
git -C "$r" branch seq/bf-2 main
mkfile "$r/tmp/fleet-sequence-bf-2.json" $((8*D)) '{"status":"failed","runner_pid":null,"branch":"seq/bf-2"}'
mkfile "$r/tmp/fleet-sequence-bf-3.json" $((8*D)) '{"status":"failed","runner_pid":999999,"branch":"seq/bf-3"}'
mkfile "$r/tmp/fleet-sequence-bf-3.log" $((8*D))
mkfile "$r/tmp/fleet-sequence-bf-4.log" $((8*D))     # no marker beside it
out=$($SCRIPT list "$r" 2>&1)
ck "running sequence under a live pid is kept"      "KEEP      fleet-sequence-bf-1.json — sequence running (pid $live)" "$out"
ck "failed sequence whose branch exists is kept"    'KEEP      fleet-sequence-bf-2.json — resumable — branch seq/bf-2 still exists' "$out"
ck "failed sequence whose branch is gone is eligible" 'ELIGIBLE  fleet-sequence-bf-3.json — failed, branch seq/bf-3 gone' "$out"
ck "sidecar log follows its marker"                  'ELIGIBLE  fleet-sequence-bf-3.log — failed, branch seq/bf-3 gone' "$out"
ck "orphan sidecar ages out on its own"              'ELIGIBLE  fleet-sequence-bf-4.log — no marker beside it' "$out"
out=$($SCRIPT reap "$r" 2>&1)
[ -e "$r/tmp/fleet-sequence-bf-1.json" ] && ck "running marker survives reap" OK OK || ck "running marker survives reap" OK GONE
[ -e "$r/tmp/fleet-sequence-bf-3.json" ] && ck "dead marker reaped" GONE PRESENT || ck "dead marker reaped" GONE GONE
[ -e "$r/tmp/fleet-sequence-bf-3.log" ] && ck "dead marker's log reaped" GONE PRESENT || ck "dead marker's log reaped" GONE GONE

echo "== directories: scratch dirs age by their newest file; unknown dirs are never deleted =="
r=$(mk_repo dirs)
mkfile "$r/tmp/qr-fix-base-bf-1-1/skills/x.md" $((8*D)); age "$r/tmp/qr-fix-base-bf-1-1/skills" $((8*D)); age "$r/tmp/qr-fix-base-bf-1-1" $((8*D))
mkfile "$r/tmp/qr-fix-base-bf-2-1/old.md" $((8*D)); mkfile "$r/tmp/qr-fix-base-bf-2-1/new.md" 0; age "$r/tmp/qr-fix-base-bf-2-1" $((8*D))
mkfile "$r/tmp/epic-desc/a.md" $((60*D)); age "$r/tmp/epic-desc" $((60*D))
mkfile "$r/tmp/investigations/b.md" $((2*D)); age "$r/tmp/investigations" $((2*D))
mkfile "$r/tmp/triage-proposals/BF-1.json" $((60*D)); mkfile "$r/tmp/triage-proposals/applied/BF-2.json" $((60*D))
mkfile "$r/tmp/triage-proposals/raw/group-1.json" $((60*D)); age "$r/tmp/triage-proposals/raw" $((60*D)); age "$r/tmp/triage-proposals/applied" $((60*D)); age "$r/tmp/triage-proposals" $((60*D))
git -C "$r" worktree add -q "$r/tmp/epic-merge" -b epic-x >/dev/null 2>&1
age "$r/tmp/epic-merge" $((60*D)); age "$r/tmp/epic-merge/README" $((60*D))
out=$($SCRIPT list "$r" 2>&1)
ck "aged scratch dir is eligible"                    'ELIGIBLE  qr-fix-base-bf-1-1 — scratch-dir — 8d old' "$out"
ck "scratch dir with a fresh file is kept"           'KEEP      qr-fix-base-bf-2-1 — modified within 24h' "$out"
ck "unknown dir is reported, not eligible"           'UNKNOWN   epic-desc/ — directory not in the manifest (1 files' "$out"
ck "triage proposals are kept"                       'KEEP      triage-proposals — triage-proposals' "$out"
ck "triage raw output ages out"                      'ELIGIBLE  triage-proposals/raw — triage-raw' "$out"
ck "registered worktree under tmp/ is kept"          'KEEP      epic-merge — registered git worktree' "$out"
out=$($SCRIPT reap "$r" 2>&1)
ck "reap removes the aged scratch dir"               'REAPED    qr-fix-base-bf-1-1' "$out"
ck "reap reports the unknown dir once it is 30d old" 'UNKNOWN   epic-desc/' "$out"
ckno "reap is quiet about a young unknown dir"      'UNKNOWN   investigations/' "$out"
[ -d "$r/tmp/qr-fix-base-bf-1-1" ] && ck "aged scratch dir gone" GONE PRESENT || ck "aged scratch dir gone" GONE GONE
[ -e "$r/tmp/qr-fix-base-bf-2-1/new.md" ] && ck "fresh scratch dir survives" OK OK || ck "fresh scratch dir survives" OK GONE
[ -e "$r/tmp/epic-desc/a.md" ] && ck "unknown dir survives at 60d" OK OK || ck "unknown dir survives at 60d" OK GONE
[ -e "$r/tmp/investigations/b.md" ] && ck "young unknown dir survives" OK OK || ck "young unknown dir survives" OK GONE
[ -e "$r/tmp/triage-proposals/BF-1.json" ] && [ -e "$r/tmp/triage-proposals/applied/BF-2.json" ] && ck "proposals and applied/ survive" OK OK || ck "proposals and applied/ survive" OK GONE
[ -d "$r/tmp/triage-proposals/raw" ] && ck "raw/ gone" GONE PRESENT || ck "raw/ gone" GONE GONE
[ -e "$r/tmp/epic-merge/README" ] && ck "worktree survives" OK OK || ck "worktree survives" OK GONE

echo "== a running fleet widens the fresh guard to its launch =="
r=$(mk_repo fleetrun)
mkfile "$r/tmp/fleet-deadline.json" $((40*H)) "{\"launch_epoch\": $((NOW - 40*H)), \"fleet_sessions\": [\"s1\"]}"
mkfile "$r/tmp/linear-context-bf-9.md" $((30*H))
mkfile "$r/tmp/old.log" $((8*D))
out=$($SCRIPT list "$r" 2>&1)
ck "file written since the launch is kept"           'KEEP      linear-context-bf-9.md — written since the running fleet launched' "$out"
ck "older scratch is still eligible during a fleet"  'ELIGIBLE  old.log' "$out"
ckno "a running marker is not flagged stale"         'FLAG      fleet-deadline.json' "$out"

echo "== flags: stale markers that hold gates up =="
r=$(mk_repo flags)
mkfile "$r/tmp/fleet-recommendation.json" $((2*D)) '{"sessions": 3, "scope": "BF-1826"}'
mkfile "$r/tmp/fleet-deadline.json" $((5*D)) "{\"launch_epoch\": $((NOW - 5*D)), \"fleet_sessions\": [\"s1\"]}"
out=$($SCRIPT reap "$r" 2>&1)
ck "scoped recommendation older than a day is flagged" 'FLAG      fleet-recommendation.json — carries scope BF-1826 and is 2d old' "$out"
ck "deadline marker with no deadline, never stopped, past the fleet horizon is flagged" 'FLAG      fleet-deadline.json — no deadline, never stopped' "$out"
[ -e "$r/tmp/fleet-recommendation.json" ] && [ -e "$r/tmp/fleet-deadline.json" ] && ck "flagged files are never deleted" OK OK || ck "flagged files are never deleted" OK GONE

if command -v lsof >/dev/null 2>&1; then
  echo "== open handles =="
  r=$(mk_repo open)
  mkfile "$r/tmp/held.log" $((8*D))
  bash -c 'exec 3<"$1"; exec sleep 600' _ "$r/tmp/held.log" & echo $! >> "$SLEEPERS"
  sleep 1
  out=$($SCRIPT reap "$r" 2>&1)
  ckno "held-open file is not reaped"                 'REAPED    held.log' "$out"
  [ -e "$r/tmp/held.log" ] && ck "held-open file survives" OK OK || ck "held-open file survives" OK GONE
else
  echo "  SKIP  open handles (lsof not installed)"
fi

echo "== no-arg mode covers the registries and ~/.claude, never the checkout under test =="
r=$(mk_repo registered)
mkfile "$r/tmp/old.log" $((8*D))
printf '%s\n' "$r" > "$HOME/.claude/worktree-repos.txt"
out=$(cd "$ROOT" && $SCRIPT reap 2>&1)
ck "registered repo is swept"                        "REAPED    old.log" "$out"
ck "fake ~/.claude/tmp is visited"                   "$HOME/.claude/tmp:" "$out"
ckno "the real checkout is never a root"            "$CLAUDE_DIR/tmp:" "$out"

echo "== env overrides are validated =="
out=$(REAP_TMP_SCRATCH_D=abc $SCRIPT list "$r" 2>&1)
ck "non-numeric override falls back with a message"  "REAP_TMP_SCRATCH_D='abc' is not a non-negative integer; using 7" "$out"
r=$(mk_repo override)
mkfile "$r/tmp/old.log" $((3*D))
out=$(REAP_TMP_SCRATCH_D=2 $SCRIPT list "$r" 2>&1)
ck "numeric override changes the lane age"           'ELIGIBLE  old.log — run-output — 3d old (> 2d)' "$out"

echo "== corpus sweep: every tmp/ name the corpus writes resolves to a named rule =="
# Names the corpus uses as generic examples or abbreviations, which legitimately fall to the default rule.
EXPECT_DEFAULT=" bf-123 bf-123.md bf-123.sh comment.md bf1087-review linear-description finish-commit "
offenders=""
while IFS=$'\t' read -r name kind; do
  [ -n "$name" ] || continue
  res=$("$SCRIPT" classify "$name" "$kind")
  case "$res" in
    *default-file*)
      # A directory mentioned without its trailing slash classifies as a file; retry as one.
      res2=$("$SCRIPT" classify "$name" d)
      case "$res2" in *unknown-dir*) ;; *) continue ;; esac
      case "$EXPECT_DEFAULT" in *" $name "*) continue ;; esac
      offenders="$offenders $name" ;;
    *unknown-dir*)
      offenders="$offenders $name/" ;;
  esac
done < <(
  find "$CLAUDE_DIR/skills" "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/standards" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/CLAUDE.md" \
       -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' \) ! -name '*.test.sh' ! -name 'reap-tmp.sh' \
       ! -path '*/skills/synced/*' ! -path '*/skills/.trash/*' ! -path '*/node_modules/*' -print0 2>/dev/null \
  | xargs -0 grep -hoE '(^|[^/])tmp/[A-Za-z0-9_.<>${}*-]+(/[A-Za-z0-9_.<>${}*-]+)*' \
  | sed -E 's/^.?tmp\///; s/[.,:)*]+$//' \
  | awk -F/ 'NF>1{print $1"\td"} NF==1{print $1"\tf"}' \
  | sed -E 's/<[^>]*>/bf-123/g; s/\$\{[^}]*\}/bf-123/g; s/\$[A-Za-z_]+/bf-123/g; s/XXXXXX/abc123/g; s/\*/x/g' \
  | grep -vE '[{}$<>]' | grep -vE '^.{0,3}\t' | grep -vE -- '-\t' | sort -u
)
if [ -z "$offenders" ]; then pass=$((pass+1)); echo "  PASS  every corpus tmp/ name is classified by a named rule"
else fail=$((fail+1)); echo "  FAIL  unclassified tmp/ names written by the corpus — add a rule to reap-tmp.sh classify(), or the name to EXPECT_DEFAULT if it is a generic example:"; echo "        $offenders"; fi

echo
echo "reap-tmp: $pass passed, $fail failed"
[ "$fail" = 0 ]
