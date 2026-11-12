#!/usr/bin/env bash
# Regression suite for fleet-sequence.sh: the pre-dispatch refusals, strict one-at-a-time sequencing, the
# per-issue fork key (start.<id>.wt-source-branch set before each dispatch and unset after — the main
# checkout is never moved, so a concurrent /start wt for another issue is untouched), the landing check,
# the push after each ship, the one PR at the end and the /pr-update child (run from a throwaway worktree),
# `merge` mode, the stop-on-first-non-ship rule, stop/resume (including a resume that only repeats the PR
# step), and the key cleanup on every exit.
#
# `claude` is stubbed: `agents --json --all` answers from $WORK/agents.json, and `--bg` records the dispatch,
# then plays a `/auto <ID>` session out SYNCHRONOUSLY the way /start wt + /finish merge would — resolves the
# source branch exactly as start-wt-setup.sh does (the per-issue key, else HEAD's branch, else the
# checkout-wide key when detached) and records it with the main checkout's branch and how far the source
# branch's REF is ahead of main in $WORK/forks, writes the ledger tmp/auto-state-<id>.json with the issue in the list
# $WORK/outcome-<ID> names (default shipped), and for a shipped issue advances the source branch's REF by one
# commit without touching HEAD, exactly what finish-merge.sh's compare-and-swap does under a parked
# checkout. `none` = no ledger; `hang` = listed running forever; `busy` = shipped but listed running;
# `listed-idle` / `listed-blocked` = no ledger, listed in that state forever (a turn an API error ended; a
# permission decision); `listed-failed` / `listed-stopped` = no ledger, listed in that terminal state;
# `deferred` = shipped with the ref unmoved and the worktree left; `queued` = deferred plus a merge-queue
# marker; `nomention` = shipped with a commit that never names the issue. A `/pr-update` dispatch records the
# branch it ran on. `gh pr create` numbers PRs from $WORK/prseq and records the call; a bare remote backs
# every push. One case launches a real detached runner to measure its process group; everything else runs
# the runner inline. The ~/.claude freshness check runs against a current fixture clone (CLAUDE_FRESHNESS_DIR)
# except in the one case that pushes to its origin.
#
# The solo drain (the last section) adds two stubs behind the script's seams: FLEET_SEQUENCE_LISTER prints $WORK/solo-list
# in next-candidates.sh's listing format (titles carrying quotes, sub-lines and a trailing note, as the real one has) or
# fails with $WORK/lister-rc, and FLEET_SEQUENCE_FLEET_LAUNCHER records `check <args>` / `launch <args>` with the number
# of dispatches and the drain's status at the moment of the launch. It covers the refusals, the read-only `list`, the
# listing re-read before every dispatch, skip-and-continue with its two-in-a-row limit, the budget, then-fleet (checked at
# launch, launched only after a clean end), stop, one drain per checkout, a list never resuming a drain, adoption of a
# session the last drain left working, and the launch from a parked (detached) checkout.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-sequence.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
}

REPO="$WORK/repo"
REMOTE="$WORK/remote.git"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo 'tmp/' >> "$REPO/.git/info/exclude"
echo '.claude/' >> "$REPO/.git/info/exclude"

# ---- stubs (heredoc delimiters are unique per stub: an inner EOF would end an outer one) ----
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<STUB_CLAUDE
#!/usr/bin/env bash
if [ "\${1:-}" = "agents" ]; then [ -f "$WORK/agents-hook" ] && bash "$WORK/agents-hook"; cat "$WORK/agents.json" 2>/dev/null || echo '[]'; exit 0; fi
if [ "\${1:-}" = "plugin" ]; then cat "$WORK/plugins.json" 2>/dev/null || echo '[{"id":"loop-boundary@alienfast-claude","enabled":true}]'; exit 0; fi
echo "\$@" >> "$WORK/dispatches"
n=\$(( \$(cat "$WORK/seq" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/seq"
sid=\$(printf 'ab%06d' "\$n")
last=""; name=""; prev=""; for a in "\$@"; do last="\$a"; [ "\$prev" = "-n" ] && name="\$a"; prev="\$a"; done
state=done
head=\$(git -C "$REPO" branch --show-current)
id=""
if [ "\$last" = "/pr-update" ]; then
  # From the dispatch cwd: the branch /pr-update would read, and whether that cwd is the main checkout or a linked worktree.
  where=main; [ "\$(git rev-parse --git-dir)" = "\$(git rev-parse --git-common-dir)" ] || where=worktree
  echo "pr-update head=\$(git branch --show-current) cwd=\$where main=\$head" >> "$WORK/forks"
else
  id="\${last#/auto }"
  lower=\$(printf '%s' "\$id" | tr '[:upper:]' '[:lower:]')
  src=\$(git -C "$REPO" config --get "start.\$lower.wt-source-branch" 2>/dev/null || true)
  [ -n "\$src" ] || src="\$head"
  [ -n "\$src" ] || src=\$(git -C "$REPO" config --get start.wt-source-branch 2>/dev/null || true)
  outcome=\$(cat "$WORK/outcome-\$id" 2>/dev/null || echo shipped)
  echo "\$id head=\$head src=\$src ahead=\$(git -C "$REPO" rev-list --count "main..refs/heads/\$src")" >> "$WORK/forks"
  case "\$outcome" in
    none) ;;
    hang) state=running ;;
    listed-*) state="\${outcome#listed-}" ;;
    *)
      list="\$outcome"; case "\$outcome" in busy|deferred|queued|nomention) list=shipped ;; esac
      [ "\$outcome" = "busy" ] && state=running
      jq -n --arg id "\$id" --arg o "\$list" '{mode:"single",status:"active",shipped:[],canceled:[],skipped:[],failed:[]} | .[\$o] += [\$id]' > "$REPO/tmp/auto-state-\$sid.json"
      case "\$outcome" in
        deferred|queued)
          git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/\$lower" -b "wt-\$lower" HEAD
          if [ "\$outcome" = "queued" ]; then mkdir -p "$REPO/.claude/merge-queue"; echo '{}' > "$REPO/.claude/merge-queue/\$lower.json"; fi ;;
        *)
          if [ "\$list" = "shipped" ]; then
            msg="\$id: work"; [ "\$outcome" = "nomention" ] && msg="work"
            tip=\$(git -C "$REPO" rev-parse "refs/heads/\$src")
            new=\$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "\$tip" -m "\$msg" "\$tip^{tree}")
            git -C "$REPO" update-ref "refs/heads/\$src" "\$new"
          fi ;;
      esac ;;
  esac
fi
[ -n "\$id" ] && [ -f "$WORK/hook-\$id" ] && bash "$WORK/hook-\$id"
tmp=\$(jq --arg s "\$sid" --arg st "\$state" '. + [{id:\$s, kind:"background", state:\$st}]' "$WORK/agents.json")
printf '%s\n' "\$tmp" > "$WORK/agents.json"
printf 'backgrounded · \033[36m%s\033[39m · %s\n\033[2m  claude attach %s    open in this terminal\033[22m\n' "\$sid" "\$name" "\$sid"
exit 0
STUB_CLAUDE
cat > "$BIN/linear-cli" <<STUB_LINEAR
#!/usr/bin/env bash
id="\${3:-}"
if [ -f "$WORK/issue-\$id.json" ]; then cat "$WORK/issue-\$id.json"
else printf '{"title":"Title of %s","labels":{"nodes":[{"name":"specified"},{"name":"solo"}]},"state":{"name":"Planned"}}\n' "\$id"; fi
STUB_LINEAR
cat > "$BIN/gh" <<STUB_GH
#!/usr/bin/env bash
# "gh pr list --head H --base B" answers from \$WORK/pr-<H>.json (slashes → _) filtered to base B; "gh pr create"
# numbers the PR from \$WORK/prseq, writes that file, copies the body to \$WORK/pr-body-<n>.md and records
# "create H B <title>" in \$WORK/gh-calls; \$WORK/gh-create-fail makes create exit 1.
sub="\${1:-} \${2:-}"
head=""; base=""; title=""; bodyf=""; prev=""
for a in "\$@"; do case "\$prev" in --head) head="\$a" ;; --base) base="\$a" ;; --title) title="\$a" ;; --body-file) bodyf="\$a" ;; esac; prev="\$a"; done
f="$WORK/pr-\${head//\//_}.json"
case "\$sub" in
  "pr list")
    if [ -f "\$f" ]; then jq --arg b "\$base" '[.[] | select(\$b == "" or .baseRefName == \$b)]' "\$f"; else echo '[]'; fi ;;
  "pr create")
    [ -f "$WORK/gh-create-fail" ] && { echo "GraphQL: stub refused the PR" >&2; exit 1; }
    n=\$(( \$(cat "$WORK/prseq" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/prseq"
    printf '[{"url":"https://github.com/x/y/pull/%s","baseRefName":"%s","number":%s}]\n' "\$n" "\$base" "\$n" > "\$f"
    echo "create \$head \$base \$title" >> "$WORK/gh-calls"
    cp "\$bodyf" "$WORK/pr-body-\$n.md"
    echo "https://github.com/x/y/pull/\$n" ;;
  *) echo "stub gh: unsupported \$*" >&2; exit 1 ;;
esac
STUB_GH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
CL_ORIGIN="$WORK/claude-origin.git"
CL_UP="$WORK/claude-upstream"
export CLAUDE_FRESHNESS_DIR="$WORK/claude-local"
git init -q --bare "$CL_ORIGIN"
git -C "$CL_ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$CL_ORIGIN" "$CL_UP" 2>/dev/null
git -C "$CL_UP" checkout -q -b main
mkdir -p "$CL_UP/hooks"; echo base > "$CL_UP/hooks/auto-rewake.sh"
git -C "$CL_UP" add -A
git -C "$CL_UP" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$CL_UP" push -q origin main
git clone -q "$CL_ORIGIN" "$CLAUDE_FRESHNESS_DIR"
export FLEET_SEQUENCE_POLL=0 FLEET_SEQUENCE_GRACE=0 FLEET_SEQUENCE_FOREGROUND=1 FLEET_SEQUENCE_ISSUE_TIMEOUT=5 \
       FLEET_SEQUENCE_MERGE_TIMEOUT=1 FLEET_SEQUENCE_PR_UPDATE_TIMEOUT=5

run() { ( cd "$REPO" && "$SCRIPT" "$@" ) >"$WORK/out" 2>&1; echo $?; }
marker() { jq -r "$1" "$REPO/tmp/fleet-sequence-${2:-bf-1}.json"; } # marker <jq filter> [<slug>, default bf-1]
# An earlier sequence's marker as a crashed or still-live runner leaves it. A pr-mode one is resumable only while its branch exists.
mk_marker() { # mk_marker <slug> <status> <runner pid|null> <pr|merge> <base> <queue json> [<issues json>]
  local branch="\"seq/$1\"" issues="${7:-}"
  [ "$4" = "merge" ] && branch=null
  [ -n "$issues" ] || issues='{}'
  jq -n --arg slug "$1" --arg st "$2" --argjson pid "$3" --arg mode "$4" --arg base "$5" --argjson q "$6" --argjson i "$issues" --argjson br "$branch" \
    '{slug: $slug, queue: $q, base: $base, mode: $mode, branch: $br, claude_args: [], status: $st, reason: "", stop_requested: false,
      current: null, issues: $i, pr_url: null, pr_number: null, launch_epoch: 1, runner_pid: $pid}' > "$REPO/tmp/fleet-sequence-$1.json"
}
dead_pid() { sh -c 'echo $$'; }
dispatches() { grep -c -- '/auto ' "$WORK/dispatches" 2>/dev/null || true; }
prs_created() { local c; c=$(grep -c '^create ' "$WORK/gh-calls" 2>/dev/null); echo "${c:-0}"; }
on_origin() { git -C "$REPO" ls-remote --heads origin "$1" 2>/dev/null | wc -l | tr -d ' '; }
fork_keys() { git -C "$REPO" config --get-regexp '^start\.[^.]+\.wt-source-branch$' 2>/dev/null | awk '{print $1"="$2}' | paste -sd, -; }
worktrees() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }
setup_remote() {
  rm -rf "$REMOTE"; git init -q --bare "$REMOTE"
  git -C "$REPO" remote remove origin 2>/dev/null
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
reset() {
  rm -f "$WORK/dispatches" "$WORK/forks" "$WORK/seq" "$WORK/prseq" "$WORK/gh-calls" "$WORK/gh-create-fail" \
        "$WORK"/outcome-* "$WORK"/hook-* "$WORK"/issue-* "$WORK"/pr-* "$WORK/agents-hook" "$WORK/agents-reads"
  echo '[]' > "$WORK/agents.json"
  rm -rf "$REPO/tmp" "$REPO/.claude"; mkdir -p "$REPO/tmp"
  git -C "$REPO" worktree prune
  for k in $(git -C "$REPO" config --name-only --get-regexp '^start\.' 2>/dev/null); do git -C "$REPO" config --unset "$k"; done
  git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard; git -C "$REPO" clean -qfd
  for b in $(git -C "$REPO" branch --format='%(refname:short)' | grep -v '^main$'); do git -C "$REPO" branch -q -D "$b"; done
  setup_remote
  : > "$WORK/dispatches"; : > "$WORK/forks"
}

# ---- refusals: nothing dispatched, checkout untouched ----
reset
ck "no args exits 1"            "1" "$(run)"
ck_has "usage shown"            "usage:" "$WORK/out"
ck "bad id exits 1"             "1" "$(run foo BF-2)"
ck_has "names the bad id"       "'foo' is not an issue ID" "$WORK/out"
ck "unknown option exits 1"     "1" "$(run --no-pr BF-1 BF-2)"
ck_has "names the option"       "unknown option '--no-pr'" "$WORK/out"
ck "pr and merge together exit 1" "1" "$(run pr merge BF-1)"
ck_has "names the clash"        "'pr' and 'merge' together" "$WORK/out"

printf '{"labels":{"nodes":[]},"state":{"name":"Backlog"}}\n' > "$WORK/issue-BF-2.json"
ck "uncertified exits 1"        "1" "$(run BF-1 BF-2)"
ck_has "names the missing label" "BF-2 is not certified" "$WORK/out"
printf '{"labels":{"nodes":[{"name":"specified"},{"name":"human"}]},"state":{"name":"Planned"}}\n' > "$WORK/issue-BF-2.json"
ck "human exits 1"              "1" "$(run BF-1 BF-2)"
ck_has "names human"            "BF-2 is human-owned work" "$WORK/out"
printf '{"labels":{"nodes":[{"name":"specified"},{"name":"solo"},{"name":"Hold"}]},"state":{"name":"Planned"}}\n' > "$WORK/issue-BF-2.json"
ck "held exits 1"               "1" "$(run BF-1 BF-2)"
ck_has "names the hold"         "BF-2 is on hold (hold label)" "$WORK/out"
printf '{"labels":{"nodes":[{"name":"specified"}]},"state":{"name":"Done"}}\n' > "$WORK/issue-BF-2.json"
ck "terminal exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "names the state"        "BF-2 is already Done" "$WORK/out"
rm -f "$WORK/issue-BF-2.json"
ck "duplicate exits 1"          "1" "$(run BF-1 bf-1)"
ck_has "names the duplicate"    "BF-1 listed twice" "$WORK/out"
ck "refusals dispatched nothing" "0" "$(dispatches)"
ck "refusals left main"         "main" "$(git -C "$REPO" branch --show-current)"
ck "refusals created no branch" "" "$(git -C "$REPO" branch --list 'seq/*')"

# Dirt is refused only on a branch whose name carries an issue ID, where each child's /auto would attribute it.
git -C "$REPO" checkout -q -b rosskevin/bf-9-in-place
printf 'x\n' > "$REPO/stray.txt"
ck "dirty on an issue-ID branch exits 1" "1" "$(run BF-1 BF-2)"
ck_has "names the attribution"  "whose name carries an issue ID" "$WORK/out"
ck_has "lists the file"         "stray.txt" "$WORK/out"
ck_has "says nothing ran"       "Nothing was dispatched." "$WORK/out"
ck "dirty refusal dispatched nothing" "0" "$(dispatches)"
rm -f "$REPO/stray.txt"
git -C "$REPO" checkout -q main; git -C "$REPO" branch -q -D rosskevin/bf-9-in-place

git -C "$REPO" checkout -q --detach
ck "detached exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "names detached"         "HEAD is detached" "$WORK/out"
git -C "$REPO" checkout -q main

git -C "$REPO" branch seq/bf-1 main
ck "stray branch exits 1"       "1" "$(run BF-1 BF-2)"
ck_has "names the stray branch" "branch 'seq/bf-1' already exists but no marker records a sequence on it" "$WORK/out"
git -C "$REPO" branch -q -D seq/bf-1

git -C "$REPO" remote remove origin
ck "no origin exits 1 in pr mode" "1" "$(run BF-1 BF-2)"
ck_has "explains the remote"    "no 'origin' remote" "$WORK/out"
ck "merge mode needs no origin" "0" "$(run merge BF-1)"
setup_remote

# Stale ~/.claude tooling refuses before the branch, the marker or any dispatch; stale-ok launches with a WARN.
reset
echo "hooks: recover a lost wakeup" >> "$CL_UP/hooks/auto-rewake.sh"
git -C "$CL_UP" -c user.email=t@t -c user.name=t commit -q -am "hooks: recover a lost wakeup"
git -C "$CL_UP" push -q origin main
ck "stale tooling exits 4"      "4" "$(run BF-1 BF-2)"
ck_has "stale tooling named"    "TOOLING-STALE: ~/.claude is 1 commit behind origin/main, including:" "$WORK/out"
ck_has "stale says nothing ran" "Nothing was dispatched or written." "$WORK/out"
ck "stale dispatched nothing"   "0" "$(dispatches)"
ck "stale created no branch"    "" "$(git -C "$REPO" branch --list 'seq/*')"
ck "stale wrote no marker"      "no" "$([ -e "$REPO/tmp/fleet-sequence-bf-1.json" ] && echo yes || echo no)"
ck "stale-ok exits 0"           "0" "$(run stale-ok BF-1)"
ck_has "stale-ok warned"        "WARN: launching on the stale ~/.claude above (stale-ok)" "$WORK/out"
ck "stale-ok dispatched"        "1" "$(dispatches)"
ck_lacks "stale-ok not an issue" "stale-ok" "$WORK/dispatches"
git -C "$CLAUDE_FRESHNESS_DIR" pull -q --ff-only

# A checkout-wide start.wt-source-branch (an epic fleet's posture, or one left behind) is no concern of this
# runner: it reads and writes only per-issue keys, and start-wt-setup.sh consults the checkout-wide key
# only under a detached HEAD.
reset
git -C "$REPO" config start.wt-source-branch main
ck "a checkout-wide key does not block" "0" "$(run BF-1)"
ck "children fork by the per-issue key" "BF-1 head=main src=seq/bf-1 ahead=0" "$(sed -n 1p "$WORK/forks")"
ck "checkout-wide key left as found"    "main" "$(git -C "$REPO" config --get start.wt-source-branch)"
git -C "$REPO" config --unset start.wt-source-branch

# A fleet and a sequence are discrete: a live fleet never blocks a launch (its pickers cannot take a queued
# issue — next-candidates.sh hides what a running sequence holds — and neither parks the other's checkout).
reset
printf '{"fleet_sessions":["fe000001"],"count":1,"deadline_epoch":%s}\n' "$(( $(date +%s) + 3600 ))" > "$REPO/tmp/fleet-deadline-team.json"
printf '[{"id":"fe000001","kind":"background","state":"working"}]\n' > "$WORK/agents.json"
ck "live fleet does not block"  "0" "$(run BF-1 BF-2)"
ck "alongside a fleet, both dispatched" "2" "$(dispatches)"
ck "fleet marker left as found" "fe000001" "$(jq -r '.fleet_sessions[0]' "$REPO/tmp/fleet-deadline-team.json")"

# ---- happy path: three issues onto seq/bf-1, each forked from the branch's advanced tip, one PR at the end ----
reset
ck "sequence exits 0"           "0" "$(run BF-1 BF-2 BF-3)"
ck "three /auto dispatches"     "3" "$(dispatches)"
ck "dispatched in order"        "/auto BF-1,/auto BF-2,/auto BF-3" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck_lacks "children never get the pr token" "/auto pr " "$WORK/dispatches"
ck_has "sessions are named"     "-n fleet-sequence BF-2 /auto BF-2" "$WORK/dispatches"
ck_has "default model"          "--model opus[1m]" "$WORK/dispatches"
ck_has "default permission mode" "--permission-mode auto" "$WORK/dispatches"
ck "every fork is from the branch's advancing tip, main checkout untouched" "BF-1 head=main src=seq/bf-1 ahead=0,BF-2 head=main src=seq/bf-1 ahead=1,BF-3 head=main src=seq/bf-1 ahead=2" "$(grep '^BF-' "$WORK/forks" | paste -sd, -)"
ck "marker done"                "done" "$(marker .status)"
ck "mode recorded"              "pr" "$(marker .mode)"
ck "branch recorded"            "seq/bf-1" "$(marker .branch)"
ck "base recorded"              "main" "$(marker .base)"
ck "outcomes recorded"          "shipped shipped shipped" "$(marker '[.queue[] as $id | .issues[$id].outcome] | join(" ")')"
ck "landed shas recorded"       "3" "$(marker '[.queue[] as $id | .issues[$id].landed_sha | select(. != null)] | length')"
ck "sessions recorded"          "ab000001 ab000002 ab000003" "$(marker '[.queue[] as $id | .issues[$id].session] | join(" ")')"
ck "branch carries three commits" "3" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"
ck "branch pushed to origin"    "1" "$(on_origin seq/bf-1)"
ck "one PR created"             "1" "$(prs_created)"
ck_has "PR from the branch onto main" "create seq/bf-1 main seq/bf-1: BF-1, BF-2, BF-3" "$WORK/gh-calls"
ck_has "body lists the issues bare" "- BF-2: Title of BF-2" "$WORK/pr-body-1.md"
ck "body has no close verb before an ID" "0" "$(grep -ciE '(close|fix|resolve|complete|implement)[a-z]* +[A-Z]+-[0-9]+' "$WORK/pr-body-1.md")"
ck "PR url recorded"            "https://github.com/x/y/pull/1" "$(marker .pr_url)"
ck "PR number recorded"         "1" "$(marker .pr_number)"
ck_has "pr-update dispatched last" "-n fleet-sequence pr-update /pr-update" "$WORK/dispatches"
ck "pr-update ran from a worktree on the branch, main checkout still on main" "pr-update head=seq/bf-1 cwd=worktree main=main" "$(grep '^pr-update' "$WORK/forks")"
ck "pr-update session recorded" "ab000004" "$(marker .pr_update_session)"
ck "main checkout never moved"  "main" "$(git -C "$REPO" branch --show-current)"
ck "fork keys unset"            "" "$(fork_keys)"
ck "no worktrees left"          "1" "$(worktrees)"
ck_has "PR logged"              "PR #1 opened: https://github.com/x/y/pull/1 (seq/bf-1 → main)" "$WORK/out"
ck_has "done names the PR"      "done: BF-1, BF-2, BF-3 on seq/bf-1 → main — PR https://github.com/x/y/pull/1" "$WORK/out"
ck_lacks "no warning"           "WARN" "$WORK/out"
ck_lacks "no catch-up note"     "NOTE: main has" "$WORK/out"
ck "status exits 0"             "0" "$(run status)"
ck_has "status shows the row"   "| BF-2 | ab000002 | done | shipped | " "$WORK/out"
ck_has "status shows the PR"    "**PR:** https://github.com/x/y/pull/1" "$WORK/out"
ck_has "status shows the branch position" "**Branch:** \`seq/bf-1\` is 3 commit(s) ahead of \`main\`, 0 behind" "$WORK/out"
ck "stop on a done run exits 0" "0" "$(run stop)"
ck_has "stop says already done" "already done" "$WORK/out"

# ---- merge mode: no branch, no PR, each issue merges into the launch branch ----
reset
before=$(git -C "$REPO" rev-parse main)
ck "merge mode exits 0"         "0" "$(run merge BF-1 BF-2)"
ck "merge mode dispatches"      "/auto BF-1,/auto BF-2" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck "merge mode forks from the launch branch by key" "BF-1 head=main src=main ahead=0,BF-2 head=main src=main ahead=0" "$(grep '^BF-' "$WORK/forks" | paste -sd, -)"
ck "main advanced twice"        "2" "$(git -C "$REPO" rev-list --count "$before..main")"
ck "mode recorded as merge"     "merge" "$(marker .mode)"
ck "no branch recorded"         "null" "$(marker .branch)"
ck "no seq branch created"      "" "$(git -C "$REPO" branch --list 'seq/*')"
ck "no PR created"              "0" "$(prs_created)"
ck_lacks "no pr-update in merge mode" "/pr-update" "$WORK/dispatches"
ck_has "launch line says merge" "merging into main one issue at a time (no PR)" "$WORK/out"
ck_has "done line says merged"  "done: BF-1, BF-2 merged into main" "$WORK/out"
ck "status exits 0 in merge mode" "0" "$(run status)"
ck_has "status shows the target" "**merges into:** \`main\`" "$WORK/out"
ck_lacks "status has no PR line" "**PR:**" "$WORK/out"

# ---- failure mid-queue stops the sequence with the rest untouched; what shipped stays on the branch ----
reset
echo failed > "$WORK/outcome-BF-2"
ck "failure exits 1"            "1" "$(run BF-1 BF-2 BF-3)"
ck "stopped after the failure"  "2" "$(dispatches)"
ck "marker failed"              "failed" "$(marker .status)"
ck_has "reason names the issue" "BF-2 ended 'failed' in session ab000002" "$WORK/out"
ck_has "reason lists the rest"  "not started: BF-3" "$WORK/out"
ck "BF-3 untouched"             "null" "$(marker '.issues["BF-3"]')"
ck "failure left main alone"    "main" "$(git -C "$REPO" branch --show-current)"
ck "failure unset the keys"     "" "$(fork_keys)"
ck "branch keeps the first ship" "1" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"
ck "first ship was pushed"      "1" "$(on_origin seq/bf-1)"
ck "no PR on failure"           "0" "$(prs_created)"
ck "status exits 0 after failure" "0" "$(run status)"
ck_has "status shows queued"    "| BF-3 | — | — | queued | — |" "$WORK/out"
ck_has "status shows the reason" "**Reason:** BF-2 ended" "$WORK/out"
ck_has "status shows no PR yet" "**PR:** not opened yet" "$WORK/out"

# ---- re-running the same list resumes: BF-1 kept, BF-2 forks from the branch carrying it ----
# BF-1 now sits at Ready For Release (where a merge lands it); a carried issue is never probed.
printf '{"labels":{"nodes":[{"name":"specified"}]},"state":{"name":"Ready For Release"}}\n' > "$WORK/issue-BF-1.json"
echo shipped > "$WORK/outcome-BF-2"
: > "$WORK/dispatches"; : > "$WORK/forks"
ck "resume exits 0"             "0" "$(run BF-1 BF-2 BF-3)"
ck_lacks "carried issue not refused" "already Ready For Release" "$WORK/out"
ck_has "resume announced"       "Resuming on seq/bf-1: already shipped, kept — BF-1 (landed " "$WORK/out"
ck_has "BF-1 skipped"           "BF-1 already shipped (landed" "$WORK/out"
ck "resume dispatched the rest" "/auto BF-2,/auto BF-3" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck "resume forked BF-2 past BF-1" "BF-2 head=main src=seq/bf-1 ahead=1" "$(sed -n 1p "$WORK/forks")"
ck "resume finished"            "done" "$(marker .status)"
ck "resume kept BF-1's session" "ab000001" "$(marker '.issues["BF-1"].session')"
ck "resume opened one PR"       "1" "$(prs_created)"
ck "branch carries all three"   "3" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"

# ---- a different base is a fresh run, not a resume ----
git -C "$REPO" checkout -q -b other
git -C "$REPO" push -q -u origin other
: > "$WORK/dispatches"
ck "other base exits 0"         "0" "$(run BF-4)"
ck_lacks "no resume on a new base" "Resuming" "$WORK/out"
ck "fresh marker has only BF-4" "BF-4" "$(marker '.issues | keys | join(" ")' bf-4)"
ck "fresh branch named after the first issue" "seq/bf-4" "$(marker .branch bf-4)"
ck "the earlier sequence's marker is kept" "BF-1 BF-2 BF-3" "$(marker '.queue | join(" ")')"
ck_has "PR targets the launch branch" "create seq/bf-4 other BF-4: Title of BF-4" "$WORK/gh-calls"
ck "still on other"             "other" "$(git -C "$REPO" branch --show-current)"
ck "a shipped issue outside the marker is still refused" "1" "$(run BF-1 BF-5)"
ck_has "refusal names the state" "BF-1 is already Ready For Release" "$WORK/out"

# ---- a PR that could not be opened fails the run; re-running repeats only the PR step ----
reset
touch "$WORK/gh-create-fail"
ck "PR failure exits 1"         "1" "$(run BF-1 BF-2)"
ck "both issues shipped first"  "2" "$(dispatches)"
ck "marker failed on the PR"    "failed" "$(marker .status)"
ck_has "reason names the PR step" "every issue shipped onto seq/bf-1 but its PR onto main could not be opened" "$WORK/out"
ck "ships kept"                 "shipped shipped" "$(marker '[.queue[] as $id | .issues[$id].outcome] | join(" ")')"
ck "PR failure left main alone" "main" "$(git -C "$REPO" branch --show-current)"
ck "PR failure left no worktree" "1" "$(worktrees)"
rm -f "$WORK/gh-create-fail"; : > "$WORK/dispatches"
ck "re-run exits 0"             "0" "$(run BF-1 BF-2)"
ck "re-run dispatched no issue" "0" "$(dispatches)"
ck_has "re-run ran pr-update"   "/pr-update" "$WORK/dispatches"
ck "re-run opened the PR"       "1" "$(prs_created)"
ck "re-run finished"            "done" "$(marker .status)"
ck "re-run recorded the PR"     "https://github.com/x/y/pull/1" "$(marker .pr_url)"

# ---- shipped without a ledger is a failure ----
reset
echo none > "$WORK/outcome-BF-1"
ck "no ledger exits 1"          "1" "$(run BF-1 BF-2)"
ck_has "reason says unknown"    "BF-1 ended 'unknown'" "$WORK/out"

# ---- shipped but not landed: a deferred merge is waited on, then fails the run; a queued one says so ----
reset
echo deferred > "$WORK/outcome-BF-1"
ck "deferred exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "waits for the merge"    "BF-1: ledger says shipped but 'seq/bf-1' has not moved — waiting up to 1s" "$WORK/out"
ck_has "reason names the timeout" "'seq/bf-1' never moved within 1s" "$WORK/out"
ck "deferred stops at once"     "1" "$(dispatches)"
ck "deferred left main alone"   "main" "$(git -C "$REPO" branch --show-current)"
ck "deferred worktree preserved" "1" "$(git -C "$REPO" worktree list | grep -c 'worktrees/bf-1')"
reset
echo queued > "$WORK/outcome-BF-1"
ck "queued exits 1"             "1" "$(run BF-1 BF-2)"
ck_has "names the queue"        "its merge is queued (.claude/merge-queue)" "$WORK/out"
ck "status exits 0 when queued" "0" "$(run status)"
ck_has "status shows queued landing" "| BF-1 | ab000001 | done | shipped | queued |" "$WORK/out"

# ---- a resume waits for a shipped issue whose deferred merge never landed, instead of forking past it ----
# The run above recorded BF-1 shipped with no landed_sha and left its queue marker. Skipping it on a re-run forked BF-2 from
# a tip without BF-1. A tip that moved for another reason (here, an unrelated commit on the branch) is not the landing either.
: > "$WORK/dispatches"; : > "$WORK/forks"
ck "resume before the landing exits 1" "1" "$(run BF-1 BF-2)"
ck_has "says it waits"          "BF-1 shipped but its landing was never recorded" "$WORK/out"
ck_has "names the queue"        "still not landed on 'seq/bf-1'" "$WORK/out"
ck "nothing forked past BF-1"   "0" "$(dispatches)"
other=$(git -C "$REPO" commit-tree "seq/bf-1^{tree}" -p seq/bf-1 -m "unrelated commit on the branch")
git -C "$REPO" update-ref refs/heads/seq/bf-1 "$other"
ck "a moved tip with the merge still queued exits 1" "1" "$(run BF-1 BF-2)"
ck "still nothing forked past BF-1" "0" "$(dispatches)"
# The drainer lands it: the branch gains BF-1's merge and the queue marker goes.
landed=$(git -C "$REPO" commit-tree "seq/bf-1^{tree}" -p seq/bf-1 -m "Merge BF-1")
git -C "$REPO" update-ref refs/heads/seq/bf-1 "$landed"
rm -f "$REPO/.claude/merge-queue/bf-1.json"
ck "resume after the landing exits 0" "0" "$(run BF-1 BF-2)"
ck "BF-1's landing recorded"    "$landed" "$(marker '.issues["BF-1"].landed_sha')"
ck_has "BF-1 landed logged"     "BF-1 landed on seq/bf-1" "$WORK/out"
ck "BF-2 forked past BF-1"      "BF-2 head=main src=seq/bf-1 ahead=2" "$(sed -n 1p "$WORK/forks")"
ck "resume finished"            "done" "$(marker .status)"

# ---- a dirty main checkout on a branch with no issue ID is named, and the sequence runs ----
# Each child's /auto picks past dirt it cannot attribute and finish-merge.sh fast-forwards around it (until 2026-10-12
# this refused the launch and failed the run before each issue, because /auto then halted on it).
reset
printf 'x\n' > "$REPO/stray.txt"
ck "dirty no-ID launch exits 0" "0" "$(run BF-1 BF-2)"
ck_has "warns at launch"        "WARN: main checkout is dirty on 'main'" "$WORK/out"
ck_has "notes it before each issue" "NOTE: main checkout is dirty before BF-2 (?? stray.txt)" "$WORK/out"
ck "both issues dispatched"     "2" "$(dispatches)"
ck "dirty run finished"         "done" "$(marker .status)"
ck "the stray file is untouched" "x" "$(cat "$REPO/stray.txt")"
rm -f "$REPO/stray.txt"

# ---- a landing whose commits never name the issue ships with a WARN, and the sequence continues ----
reset
echo nomention > "$WORK/outcome-BF-1"
ck "unnamed commit exits 0"     "0" "$(run BF-1 BF-2)"
ck_has "warns about the commit" "WARN: none of the commits seq/bf-1 gained mention BF-1" "$WORK/out"
ck "unnamed commit still continues" "2" "$(dispatches)"

# ---- a landing of many commits whose NEWEST names the issue raises no WARN: the check must read git log to its end.
# A grep that exits on the first match leaves git log to die of SIGPIPE on its next subject, which pipefail turns into
# a failed check on a ship that is named (2026-11-11: three of a drain's four multi-commit landings warned). ----
reset
cat > "$WORK/hook-BF-1" <<MANY_COMMITS
tip=\$(git -C "$REPO" rev-parse refs/heads/seq/bf-1)
for i in \$(seq 1 40); do tip=\$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "\$tip" -m "filler \$i" "\$tip^{tree}"); done
tip=\$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "\$tip" -m "Merge BF-1" "\$tip^{tree}")
git -C "$REPO" update-ref refs/heads/seq/bf-1 "\$tip"
MANY_COMMITS
ck "many-commit landing exits 0"    "0" "$(run BF-1 BF-2)"
ck_has "every commit is counted"    "BF-1 landed on seq/bf-1 at" "$WORK/out"
ck_has "the count is the whole range" "(42 commit(s))" "$WORK/out"
ck_lacks "a named landing raises no WARN" "WARN: none of the commits" "$WORK/out"

# ---- a session that never ends times out; nothing is killed; keys cleared ----
reset
echo hang > "$WORK/outcome-BF-1"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=1
ck "hang exits 1"               "1" "$(run BF-1 BF-2)"
ck_has "hang names the session" "BF-1: session ab000001 still running after 1s — not killed" "$WORK/out"
ck "hang dispatched once"       "1" "$(dispatches)"
ck "hang left main alone"       "main" "$(git -C "$REPO" branch --show-current)"
ck "hang unset the keys"        "" "$(fork_keys)"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5

# ---- a session the registry lists failed or stopped ended without a ledger: no timeout wait, the reason names the state ----
for st in failed stopped; do
  reset
  echo "listed-$st" > "$WORK/outcome-BF-1"
  export FLEET_SEQUENCE_ISSUE_TIMEOUT=30
  t0=$(date +%s)
  ck "$st exits 1"                      "1" "$(run BF-1 BF-2)"
  ck "$st did not wait out the timeout" "1" "$(( $(date +%s) - t0 < 20 ))"
  ck_has "$st names the registry state" "BF-1 ended without a ledger — the registry lists session ab000001 as $st" "$WORK/out"
  ck "$st dispatched once"              "1" "$(dispatches)"
  ck "$st unset the keys"               "" "$(fork_keys)"
done
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5

# ---- an ended listing before the session was ever listed live is not its end. 2026-11-11: a drain's session read ended
# in the second it was dispatched, the runner recorded `unknown` and started the next solo issue beside it. born_ended
# plays that session: done on the registry's first read, working on the second, its ledger and commit on the third, in
# rows carrying the keys a `--bg` row had on 2026-11-12. ----
born_ended() { # born_ended <target branch> — arms the registry hook for the first dispatch (BF-1, session ab000001)
  cat > "$WORK/agents-hook" <<BORN_ENDED
jq -e 'any(.[]; .id == "ab000001")' "$WORK/agents.json" >/dev/null 2>&1 || exit 0
n=\$(( \$(cat "$WORK/agents-reads" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/agents-reads"
state=working; status=busy; if [ "\$n" -eq 1 ]; then state=done; status=idle; fi
tmp=\$(jq --arg st "\$state" --arg s "\$status" 'map(if .id == "ab000001" then {cwd: "$REPO", id, kind: "background", name: "fleet-sequence BF-1", pid: 4242, sessionId: "ab000001-0000-4000-8000-000000000000", startedAt: 1794509181225, state: \$st, status: \$s} else . end)' "$WORK/agents.json")
printf '%s\n' "\$tmp" > "$WORK/agents.json"
if [ "\$n" -eq 3 ]; then
  jq -n '{mode:"single",status:"active",shipped:["BF-1"],canceled:[],skipped:[],failed:[]}' > "$REPO/tmp/auto-state-ab000001.json"
  tip=\$(git -C "$REPO" rev-parse "refs/heads/$1")
  new=\$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "\$tip" -m "BF-1: work" "\$tip^{tree}")
  git -C "$REPO" update-ref "refs/heads/$1" "\$new"
fi
BORN_ENDED
}
reset
echo listed-done > "$WORK/outcome-BF-1"
born_ended seq/bf-1
ck "born-ended exits 0"                  "0" "$(FLEET_SEQUENCE_GRACE=3 run BF-1 BF-2)"
ck "born-ended was waited on, then the next ran" "/auto BF-1,/auto BF-2" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck "the next forked from its landed work" "BF-2 head=main src=seq/bf-1 ahead=1" "$(sed -n 2p "$WORK/forks")"
ck_has "the early listing is logged"     "BF-1: the registry lists session ab000001 as done before it was ever listed live" "$WORK/out"
ck_has "and its return to work"          "BF-1: session ab000001 is working again" "$WORK/out"
ck_lacks "born-ended is not read as an end" "BF-1 ended" "$WORK/out"
# An ended listing that outlasts the grace is still an end, and still names the state.
reset
echo listed-failed > "$WORK/outcome-BF-1"
ck "ended past the grace exits 1"        "1" "$(FLEET_SEQUENCE_GRACE=2 run BF-1 BF-2)"
ck_has "ended past the grace names the state" "BF-1 ended without a ledger — the registry lists session ab000001 as failed" "$WORK/out"
ck "ended past the grace dispatched once" "1" "$(dispatches)"

# ---- a session listed idle with no ledger (2026-09-21: an API 500 ended its turn) is waited on, logged once, and named on timeout ----
reset
echo listed-idle > "$WORK/outcome-BF-1"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=1
ck "idle exits 1"                    "1" "$(run BF-1 BF-2)"
ck_has "idle is logged when seen"    "BF-1: session ab000001 is idle — its turn ended without a ledger" "$WORK/out"
ck "idle is logged once"             "1" "$(grep -c 'is idle — its turn ended' "$WORK/out")"
ck_has "idle timeout names the state" "BF-1: session ab000001 still idle after 1s — its turn ended without a ledger and no rewake followed" "$WORK/out"
ck_has "idle timeout says how to recover" "claude attach ab000001 and prompt it forward" "$WORK/out"
ck "idle unset the keys"             "" "$(fork_keys)"
reset
echo listed-blocked > "$WORK/outcome-BF-1"
ck "blocked exits 1"                 "1" "$(run BF-1 BF-2)"
ck_has "blocked timeout names the state" "BF-1: session ab000001 still blocked after 1s — waiting on a decision only a human can give" "$WORK/out"
# The row `claude stop` leaves behind (measured 2026-10-04): state unchanged, `status` and `pid` gone, beside a live row
# that carries `status`. The stub's dispatch row never carries `status`, so the pre-seeded live row is what makes the
# shape read as stopped; without it the same row is the older status-less schema and reads as working.
reset
printf '[{"id":"zzzzzzzz","kind":"background","sessionId":"zzzzzzzz-0000-4000-8000-000000000000","state":"working","status":"idle","pid":1}]\n' > "$WORK/agents.json"
echo listed-working > "$WORK/outcome-BF-1"
ck "stopped-shape exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "stopped-shape ends the wait as stopped" "BF-1 ended without a ledger — the registry lists session ab000001 as stopped" "$WORK/out"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5

# ---- the detached runner leads a session of its own, outside the launching shell's process group ----
reset
echo hang > "$WORK/outcome-BF-1"
ck "detached launch exits 0"         "0" "$(FLEET_SEQUENCE_FOREGROUND=0 FLEET_SEQUENCE_POLL=1 FLEET_SEQUENCE_ISSUE_TIMEOUT=60 run BF-1 BF-2)"
rp=$(marker .runner_pid)
sleep 1
ck "detached runner is alive"        "0" "$(kill -0 "$rp" 2>/dev/null; echo $?)"
ck "detached runner leads its own group" "$rp" "$(ps -o pgid= -p "$rp" | tr -d ' ')"
ck "detached runner is outside this shell's group" "1" "$(( $(ps -o pgid= -p "$rp" | tr -d ' ') != $(ps -o pgid= -p $$ | tr -d ' ') ))"
ck_has "detached runner logged its start" "sequence started: BF-1, BF-2 onto seq/bf-1" "$REPO/tmp/fleet-sequence-bf-1.log"
kill "$rp" 2>/dev/null; sleep 2
ck "detached runner is gone once killed" "1" "$(kill -0 "$rp" 2>/dev/null; echo $?)"

# ---- stop requested mid-run: the in-flight issue finishes, nothing else starts, no PR ----
reset
printf 'tmp=$(jq ".stop_requested = true" "%s/tmp/fleet-sequence-bf-1.json"); printf "%%s\\n" "$tmp" > "%s/tmp/fleet-sequence-bf-1.json"\n' "$REPO" "$REPO" > "$WORK/hook-BF-1"
ck "stop exits 0"               "0" "$(run BF-1 BF-2 BF-3)"
ck "stop dispatched once"       "1" "$(dispatches)"
ck "marker stopped"             "stopped" "$(marker .status)"
ck_has "reason names the rest"  "stopped before BF-2; not started: BF-2, BF-3" "$WORK/out"
ck "BF-1 still shipped"         "shipped" "$(marker '.issues["BF-1"].outcome')"
ck "BF-1 stays on the branch"   "1" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"
ck "stop opened no PR"          "0" "$(prs_created)"
ck "stop left main alone"       "main" "$(git -C "$REPO" branch --show-current)"
ck "stop unset the keys"        "" "$(fork_keys)"

# ---- the main checkout is not the runner's: moved mid-run, the next fork still comes from the branch's tip,
# and a /start wt for an issue outside the queue resolves the checkout's own branch. 2026-09-16: the old
# detach-and-set-config posture pointed a concurrent targeted `/auto BFP-117` at seq/bfp-112. ----
reset
printf 'git -C "%s" checkout -q -b scratch\ngit -C "%s" config --get start.bf-9.wt-source-branch >> "%s/other-key" 2>&1 || echo unset >> "%s/other-key"\n' "$REPO" "$REPO" "$WORK" "$WORK" > "$WORK/hook-BF-1"
ck "moved checkout exits 0"     "0" "$(run BF-1 BF-2)"
ck "BF-2 forked from the branch, not the moved checkout" "BF-2 head=scratch src=seq/bf-1 ahead=1" "$(sed -n 2p "$WORK/forks")"
ck "an issue outside the queue has no key" "unset" "$(cat "$WORK/other-key")"
ck "checkout left where the human put it" "scratch" "$(git -C "$REPO" branch --show-current)"
ck "pr-update still ran on the branch" "pr-update head=seq/bf-1 cwd=worktree main=scratch" "$(grep '^pr-update' "$WORK/forks")"
ck "moved checkout still opened the PR" "1" "$(prs_created)"
ck "moved checkout left no key" "" "$(fork_keys)"

# ---- a per-issue key a crashed runner left behind is cleared at launch and never outlives the run ----
reset
git -C "$REPO" config start.bf-2.wt-source-branch stale-branch
ck "stale key launch exits 0"   "0" "$(run BF-1 BF-2)"
ck "stale key replaced before its dispatch" "BF-2 head=main src=seq/bf-1 ahead=1" "$(sed -n 2p "$WORK/forks")"
ck "no keys after the run"      "" "$(fork_keys)"

# ---- claude flags pass through; the pr-update child can be skipped ----
reset
ck "flags exit 0"               "0" "$(run BF-1 -- --model fable --effort high)"
ck_has "flag passthrough"       "--model fable --effort high" "$WORK/dispatches"
ck_lacks "no default model"     "opus[1m]" "$WORK/dispatches"
ck_lacks "no default autocompact"  "--autocompact" "$WORK/dispatches"
ck_has "single-issue PR title"  "create seq/bf-1 main BF-1: Title of BF-1" "$WORK/gh-calls"
# loop-boundary guard: refuse without the mod; an explicit cap softens the refusal to a WARN
reset
echo '[{"id":"effort-phase@alienfast-claude","enabled":true}]' > "$WORK/plugins.json"
ck "missing mod exits 5"            "5" "$(run BF-1)"
ck "missing mod dispatches nothing" "0" "$(dispatches)"
ck_has "missing mod names install"  "claude plugin install loop-boundary@alienfast-claude" "$WORK/out"
reset
ck "explicit cap launches"          "0" "$(run BF-1 -- --autocompact 700000)"
ck_has "explicit cap warns"         "WARN: launching without the loop-boundary mod" "$WORK/out"
ck_has "explicit cap passes through" "--autocompact 700000" "$WORK/dispatches"
rm -f "$WORK/plugins.json"
reset
export FLEET_SEQUENCE_PR_UPDATE=0
ck "explicit pr token exits 0"  "0" "$(run pr BF-1)"
ck "explicit pr token is pr mode" "pr" "$(marker .mode)"
ck_lacks "pr-update skipped"    "/pr-update" "$WORK/dispatches"
ck "PR still opened"            "1" "$(prs_created)"
unset FLEET_SEQUENCE_PR_UPDATE

# ---- the ledger ends the wait, not the registry: a session that stays busy after shipping still advances ----
# 2026-09-10: BF-1832's session sat busy for 7h after its ledger said shipped; a registry-only wait burned the
# 6h timeout and BF-1839 never dispatched.
reset
echo busy > "$WORK/outcome-BF-1"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=1
ck "busy session exits 0"       "0" "$(run BF-1 BF-2)"
ck "busy session did not block the next" "2" "$(dispatches)"
ck "busy run finished"          "done" "$(marker .status)"
ck "busy session still listed running" "running" "$(jq -r '.[] | select(.id=="ab000001") | .state' "$WORK/agents.json")"
ck_lacks "no timeout on a busy-but-shipped session" "still running after" "$WORK/out"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5

# ---- a previous run's ledger naming the same issue is not this session's outcome ----
reset
echo none > "$WORK/outcome-BF-1"
jq -n '{mode:"single",status:"active",shipped:["BF-1"],canceled:[],skipped:[],failed:[]}' > "$REPO/tmp/auto-state-old00001.json"
touch -t 202001010000 "$REPO/tmp/auto-state-old00001.json"
ck "stale ledger exits 1"       "1" "$(run BF-1 BF-2)"
ck_has "stale ledger reads unknown" "BF-1 ended 'unknown'" "$WORK/out"

# ---- the base moving during the run is one catch-up, noted when the PR opens ----
reset
printf 'tip=$(git -C "%s" rev-parse main); new=$(git -C "%s" -c user.email=t@t -c user.name=t commit-tree -p "$tip" -m "base moved" "$tip^{tree}"); git -C "%s" push -q origin "$new:refs/heads/main"\n' "$REPO" "$REPO" "$REPO" > "$WORK/hook-BF-1"
ck "moved base exits 0"         "0" "$(run BF-1 BF-2)"
ck_has "notes the catch-up"     "NOTE: main has 1 commit(s) the branch lacks — one catch-up merge" "$WORK/out"
ck "moved base still opened the PR" "1" "$(prs_created)"

# ---- launching from a branch: it must be on origin; the PR then targets it ----
reset
git -C "$REPO" checkout -q -b feature
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feature: unmerged work"
ck "unpushed launch branch exits 1" "1" "$(run BF-1 BF-2)"
ck_has "explains the remote base"  "'feature' does not exist on origin" "$WORK/out"
ck "unpushed dispatched nothing"   "0" "$(dispatches)"
ck "unpushed created no branch"    "" "$(git -C "$REPO" branch --list 'seq/*')"
git -C "$REPO" push -q -u origin feature
ck "pushed launch branch exits 0"  "0" "$(run BF-1 BF-2)"
ck_has "notes the non-default base" "NOTE: launching from 'feature', not 'main'" "$WORK/out"
ck "forks from the branch off feature" "BF-1 head=feature src=seq/bf-1" "$(sed -n 1p "$WORK/forks" | cut -d' ' -f1-3)"
ck_has "PR targets feature"        "create seq/bf-1 feature seq/bf-1: BF-1, BF-2" "$WORK/gh-calls"
ck "feature's commit is under the branch" "1" "$(git -C "$REPO" rev-list --count main..feature)"
ck "branch carries feature and the ships" "3" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"
ck "still on feature"              "feature" "$(git -C "$REPO" branch --show-current)"
git -C "$REPO" checkout -q main
: > "$WORK/dispatches"
ck "default branch launch has no note" "0" "$(run BF-3)"
ck_lacks "no note on the default branch" "NOTE: launching from" "$WORK/out"

# ---- sequences are discrete: a list sharing no issue with an earlier sequence from the same branch is a NEW one ----
# 2026-09-21: `BF-2034 BF-1794` launched from the branch an earlier `BF-2022 …` sequence had used — its runner
# dead, its BF-2022 session still working — was read as a resume, shipped onto seq/bf-2022, and rewrote that
# sequence's marker and log.
reset
echo failed > "$WORK/outcome-BF-2"
ck "earlier sequence fails"          "1" "$(run BF-1 BF-2 BF-3)"
tmpm=$(jq --argjson p "$(dead_pid)" '.status = "running" | .runner_pid = $p' "$REPO/tmp/fleet-sequence-bf-1.json"); printf '%s\n' "$tmpm" > "$REPO/tmp/fleet-sequence-bf-1.json"
: > "$WORK/forks"; : > "$WORK/gh-calls"
ck "disjoint list exits 0"           "0" "$(run BF-7 BF-8)"
ck_lacks "disjoint list is no resume" "Resuming" "$WORK/out"
ck "disjoint list gets its own branch" "seq/bf-7" "$(marker .branch bf-7)"
ck "its forks never touch the earlier branch" "BF-7 head=main src=seq/bf-7 ahead=0,BF-8 head=main src=seq/bf-7 ahead=1" "$(grep '^BF-' "$WORK/forks" | paste -sd, -)"
ck "earlier branch keeps only its own ship" "1" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"
ck "earlier marker's queue untouched" "BF-1 BF-2 BF-3" "$(marker '.queue | join(" ")')"
ck "earlier marker's ship untouched" "shipped" "$(marker '.issues["BF-1"].outcome')"
ck_has "its PR carries only its own issues" "create seq/bf-7 main seq/bf-7: BF-7, BF-8" "$WORK/gh-calls"
ck "status names the other sequence" "0" "$(run status)"
ck_has "status lists the earlier one" "**Other sequences here:** BF-1 → BF-2 → BF-3 (running)" "$WORK/out"
ck "status by issue reads the earlier one" "0" "$(run status BF-2)"
ck_has "status by issue shows its branch" "**branch:** \`seq/bf-1\`" "$WORK/out"
ck "status for an unknown issue exits 0" "0" "$(run status BF-99)"
ck_has "status says no sequence names it" "No sequence here names BF-99" "$WORK/out"

# A finished sequence is not reopened either: the next list from the same branch gets its own branch and its own PR.
reset
ck "first sequence done"             "0" "$(run BF-1 BF-2)"
ck "second sequence done"            "0" "$(run BF-5)"
ck "second PR is its own"            "https://github.com/x/y/pull/2" "$(marker .pr_url bf-5)"
ck "first PR untouched"              "https://github.com/x/y/pull/1" "$(marker .pr_url)"
ck "first branch untouched"          "2" "$(git -C "$REPO" rev-list --count main..seq/bf-1)"

# ---- a list resumes the sequence it shares an issue with — even with the first issue dropped ----
reset
echo failed > "$WORK/outcome-BF-1"
ck "first issue fails"               "1" "$(run BF-1 BF-2 BF-3)"
: > "$WORK/forks"
ck "dropping the failed head resumes" "0" "$(run BF-2 BF-3)"
ck "resumed onto the same branch"    "seq/bf-1" "$(marker .branch)"
ck "no second branch"                "seq/bf-1" "$(git -C "$REPO" branch --list 'seq/*' --format='%(refname:short)' | paste -sd, -)"
ck "no second marker"                "1" "$(ls "$REPO"/tmp/fleet-sequence-*.json | wc -l | tr -d ' ')"
ck "resumed forks from the kept branch" "BF-2 head=main src=seq/bf-1 ahead=0" "$(sed -n 1p "$WORK/forks")"

# A list sharing issues with two earlier sequences cannot say which one it resumes.
reset
echo failed > "$WORK/outcome-BF-2"; echo failed > "$WORK/outcome-BF-6"
ck "sequence one fails"              "1" "$(run BF-1 BF-2)"
ck "sequence two fails"              "1" "$(run BF-5 BF-6)"
: > "$WORK/dispatches"
ck "ambiguous list exits 1"          "1" "$(run BF-2 BF-6)"
ck_has "names the ambiguity"         "shares issues with 2 earlier sequences" "$WORK/out"
ck "ambiguous list dispatched nothing" "0" "$(dispatches)"

# ---- a live sequence: its issues are refused, a disjoint list runs alongside, two merge runs never share a base ----
reset
mk_marker bf-1 running $$ pr main '["BF-1","BF-2"]'
ck "an issue in a live sequence exits 1" "1" "$(run BF-2 BF-5)"
ck_has "names the live sequence"     "BF-2 already in a running sequence (BF-1 → BF-2, runner pid $$)" "$WORK/out"
ck "refusal created no branch"       "" "$(git -C "$REPO" branch --list 'seq/*')"
ck "a disjoint list runs alongside"  "0" "$(run BF-5)"
ck "alongside, on its own branch"    "seq/bf-5" "$(marker .branch bf-5)"
ck "live marker untouched"           "running" "$(marker .status)"
reset
mk_marker bf-1 running $$ merge main '["BF-1","BF-2"]'
ck "second merge run on the same base exits 1" "1" "$(run merge BF-5)"
ck_has "explains the ambiguity"      "a merge-mode sequence is already merging into 'main'" "$WORK/out"
ck "a pr-mode list still runs alongside it" "0" "$(run BF-5)"

# ---- stop / status choose among several ----
reset
mk_marker bf-1 running $$ pr main '["BF-1","BF-2"]'
mk_marker bf-5 running $$ pr main '["BF-5"]'
ck "bare stop with two running exits 1" "1" "$(run stop)"
ck_has "asks for an issue"           "2 sequences are running" "$WORK/out"
ck "stop by issue exits 0"           "0" "$(run stop BF-5)"
ck "that sequence is stopping"       "true" "$(marker .stop_requested bf-5)"
ck "the other is not"                "false" "$(marker .stop_requested)"
ck "bare status exits 0"             "0" "$(run status)"
ck_has "bare status shows one running sequence" "**Sequence:** BF-1 → BF-2" "$WORK/out"
ck_has "and the other"               "**Sequence:** BF-5" "$WORK/out"

# ---- a resume adopts the session an earlier run dispatched: a runner can die under a restart its child survives ----
# The adopted session is waited on, never dispatched twice; its issue may already sit at Ready For Release.
reset
git -C "$REPO" branch seq/bf-1 main
tip=$(git -C "$REPO" rev-parse seq/bf-1)
mk_marker bf-1 failed null pr main '["BF-1","BF-2"]' "{\"BF-1\":{\"session\":\"ab000009\",\"started_epoch\":1,\"tip_before\":\"$tip\",\"outcome\":\"unknown\"}}"
printf '[{"id":"ab000009","kind":"background","state":"running"}]\n' > "$WORK/agents.json"
ck "unlisted in-flight issue exits 1" "1" "$(run BF-2)"
ck_has "asks for it to be listed"    "BF-1 was dispatched by an earlier run of this sequence (session ab000009)" "$WORK/out"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=1
ck "adopted session still working times out" "1" "$(run BF-1 BF-2)"
ck "and was never dispatched again"  "0" "$(dispatches)"
ck_has "the wait names the adopted session" "BF-1: session ab000009 still running after 1s" "$WORK/out"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5
# The adopted session ships: its ledger appears and the branch moves, as /finish merge would leave them.
jq -n '{mode:"single",status:"active",shipped:["BF-1"],canceled:[],skipped:[],failed:[]}' > "$REPO/tmp/auto-state-ab000009.json"
new=$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "$tip" -m "BF-1: work" "$tip^{tree}"); git -C "$REPO" update-ref refs/heads/seq/bf-1 "$new"
printf '{"labels":{"nodes":[{"name":"specified"}]},"state":{"name":"Ready For Release"}}\n' > "$WORK/issue-BF-1.json"
: > "$WORK/dispatches"; : > "$WORK/forks"
ck "adopting resume exits 0"         "0" "$(run BF-1 BF-2)"
ck_has "adoption announced"          "still in its earlier session, waited on and not dispatched again — BF-1 (session ab000009)" "$WORK/out"
ck "only the rest was dispatched"    "/auto BF-2" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck "adopted outcome recorded"        "shipped ab000009" "$(marker '.issues["BF-1"] | "\(.outcome) \(.session)"')"
ck "adopted landing recorded"        "$new" "$(marker '.issues["BF-1"].landed_sha')"
ck "the next issue forks past it"    "BF-2 head=main src=seq/bf-1 ahead=1" "$(sed -n 1p "$WORK/forks")"
ck_has "PR roster carries the adopted issue" "seq/bf-1: BF-1, BF-2" "$WORK/gh-calls"
# A recorded session that ended without shipping is a retry, exactly as re-listing a failed issue always was.
reset
git -C "$REPO" branch seq/bf-1 main
mk_marker bf-1 failed null pr main '["BF-1","BF-2"]' "{\"BF-1\":{\"session\":\"ab000009\",\"started_epoch\":1,\"tip_before\":\"$(git -C "$REPO" rev-parse main)\",\"outcome\":\"unknown\"}}"
ck "ended session is re-dispatched"  "0" "$(run BF-1 BF-2)"
ck "both issues dispatched"          "/auto BF-1,/auto BF-2" "$(grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"

# ---- status / stop with no marker ----
reset
ck "status without marker"      "0" "$(run status)"
ck_has "status says nothing launched" "No sequence marker" "$WORK/out"
ck "stop without marker"        "0" "$(run stop)"
ck_has "stop says nothing to stop" "nothing to stop" "$WORK/out"

# =====================================================================================
# The solo drain (`fleet-sequence.sh solo`, /fleet-solo): the queue is discovered, never typed.
cat > "$BIN/solo-lister" <<STUB_LISTER
#!/usr/bin/env bash
echo "\$*" >> "$WORK/lister-calls"
if [ -f "$WORK/lister-rc" ]; then echo "ERROR: Linear unreachable (stub)" >&2; exit "\$(cat "$WORK/lister-rc")"; fi
printf '## Suggested next\n\n'
n=0
while IFS= read -r id; do
  [ -n "\$id" ] || continue
  n=\$((n+1))
  printf '%s. **%s** — "Fix "the thing" in %s"\n   - State: Planned | Priority: High\n   - Tier 4: highest-priority workable\n' "\$n" "\$id" "\$id"
done < "$WORK/solo-list"
[ "\$n" -gt 0 ] || printf '_No workable issues with label solo in BF._\n'
printf '\n_2 issue(s) hidden as held by a running /fleet-sequence (BF-90 → BF-91) — the sequence ships them in order._\n'
STUB_LISTER
cat > "$BIN/fleet-launcher" <<STUB_LAUNCHER
#!/usr/bin/env bash
if [ "\${FLEET_LAUNCH_CHECK:-0}" = "1" ]; then
  echo "check \$*" >> "$WORK/fleet-calls"
  if [ -f "$WORK/fleet-check-rc" ]; then echo "ERROR: no count given and no recommendation (stub)" >&2; exit "\$(cat "$WORK/fleet-check-rc")"; fi
  echo "Using /auto-prep's recommendation: 3 session(s) (stub)"; echo "CHECK-OK: 3 session(s)"; exit 0
fi
echo "launch \$*" >> "$WORK/fleet-calls"
echo "dispatched-before=\$(grep -c -- '/auto ' "$WORK/dispatches") drain=\$(jq -r .status "$REPO/tmp/fleet-sequence-solo.json")" >> "$WORK/fleet-calls"
if [ -f "$WORK/fleet-launch-rc" ]; then echo "TOOLING-STALE (stub)" >&2; exit "\$(cat "$WORK/fleet-launch-rc")"; fi
echo "fleet launched (stub)"
STUB_LAUNCHER
chmod +x "$BIN/solo-lister" "$BIN/fleet-launcher"
export FLEET_SEQUENCE_LISTER="$BIN/solo-lister" FLEET_SEQUENCE_FLEET_LAUNCHER="$BIN/fleet-launcher" \
       FLEET_SEQUENCE_LIST_WAIT=0 FLEET_SEQUENCE_LIST_RETRIES=2 LINEAR_TEAM=BF
dreset() { # reset, plus the drain's stubs; the arguments become the listing, in order
  reset
  rm -f "$WORK/lister-rc" "$WORK/lister-calls" "$WORK/fleet-calls" "$WORK/fleet-check-rc" "$WORK/fleet-launch-rc" "$WORK/stop-out"
  : > "$WORK/solo-list"
  local id; for id in "$@"; do echo "$id" >> "$WORK/solo-list"; done
}
smarker() { marker "$1" solo; }
solo_marker_exists() { [ -e "$REPO/tmp/fleet-sequence-solo.json" ] && echo yes || echo no; }
fleet_calls() { [ -f "$WORK/fleet-calls" ] && paste -sd, - < "$WORK/fleet-calls"; }
auto_order() { grep -o -- '/auto [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -; }
mk_drain() { # mk_drain <status> <runner pid|null> <base> <queue json> [<issues json>] — a drain's marker as an earlier run leaves it
  local issues="${5:-}"
  [ -n "$issues" ] || issues='{}'
  jq -n --arg st "$1" --argjson pid "$2" --arg base "$3" --argjson q "$4" --argjson i "$issues" \
    '{slug: "solo", drain: true, team: "BF", queue: $q, plan: [], base: $base, mode: "merge", branch: null, claude_args: [], status: $st,
      reason: "", stop_requested: false, current: null, issues: $i, launch_epoch: 1, runner_pid: $pid}' > "$REPO/tmp/fleet-sequence-solo.json"
}

# ---- refusals and the read-only listing: nothing dispatched, nothing written ----
dreset BF-1 BF-2
ck "drain without LINEAR_TEAM exits 1" "1" "$(LINEAR_TEAM='' run solo)"
ck_has "names the variable"        "LINEAR_TEAM is not set" "$WORK/out"
ck "solo list exits 0"             "0" "$(run solo list)"
ck_has "list is the running order" '  2. BF-2 — Fix "the thing" in BF-2' "$WORK/out"
ck_has "lister asked for the team's solo issues" "--team BF --label solo" "$WORK/lister-calls"
printf '{"labels":{"nodes":[{"name":"solo"}]},"state":{"name":"Planned"}}\n' > "$WORK/issue-BF-2.json"
ck "list with an uncertified issue exits 0" "0" "$(run solo list)"
ck_has "list flags what the probe will refuse" "[will be skipped: BF-2 is not certified" "$WORK/out"
rm -f "$WORK/issue-BF-2.json"
ck "pr is refused"                 "1" "$(run solo pr)"
ck_has "says why a drain merges"   "a solo drain lands by merge" "$WORK/out"
ck "an issue ID is refused"        "1" "$(run solo BF-1)"
ck_has "points at the list form"   "cannot read 'BF-1' as a duration" "$WORK/out"
ck "an unknown option is refused"  "1" "$(run solo --fast)"
ck "then-fleet stop is refused"    "1" "$(run solo then-fleet stop)"
ck_has "names the launch tokens"   "'stop' is not one" "$WORK/out"
echo 1 > "$WORK/fleet-check-rc"
ck "then-fleet tokens fleet-launch refuses exit 1" "1" "$(run solo then-fleet)"
ck_has "the refusal is relayed"    "no count given and no recommendation" "$WORK/out"
ck_has "and attributed"            "fleet-launch.sh refused the then-fleet arguments" "$WORK/out"
rm -f "$WORK/fleet-check-rc"
echo 2 > "$WORK/lister-rc"
ck "an unreadable listing exits 1" "1" "$(run solo)"
ck_has "names the listing"         "could not list the solo issues for BF" "$WORK/out"
rm -f "$WORK/lister-rc"
ck "refusals dispatched nothing"   "0" "$(dispatches)"
ck "refusals wrote no marker"      "no" "$(solo_marker_exists)"
dreset
ck "an empty pool exits 0"         "0" "$(run solo)"
ck_has "says there is nothing"     "nothing to drain" "$WORK/out"
ck "an empty pool wrote no marker" "no" "$(solo_marker_exists)"

# ---- happy path: the listing, in its order, one at a time into the launch branch; no branch, no PR ----
dreset BF-1 BF-2 BF-3
base0=$(git -C "$REPO" rev-parse main)
ck "drain exits 0"                 "0" "$(run solo)"
ck "dispatched in listing order"   "/auto BF-1,/auto BF-2,/auto BF-3" "$(auto_order)"
ck "every child forks from the launch branch" "BF-1 head=main src=main ahead=0,BF-2 head=main src=main ahead=0,BF-3 head=main src=main ahead=0" "$(grep '^BF-' "$WORK/forks" | paste -sd, -)"
ck "the launch branch gained three commits" "3" "$(git -C "$REPO" rev-list --count "$base0..main")"
ck "marker is a merge-mode drain"  "true merge null BF" "$(smarker '"\(.drain) \(.mode) \(.branch) \(.team)"')"
ck "marker done"                   "done" "$(smarker .status)"
ck "queue is what the drain took"  "BF-1 BF-2 BF-3" "$(smarker '.queue | join(" ")')"
ck "landings recorded"             "3" "$(smarker '[.queue[] as $id | .issues[$id].landed_sha | select(. != null)] | length')"
ck_has "the plan is printed at launch" '  3. BF-3 — Fix "the thing" in BF-3' "$WORK/out"
ck_has "reason says drained"       "drained, no workable solo issue is left — shipped into main: BF-1, BF-2, BF-3" "$WORK/out"
ck "no PR"                         "0" "$(prs_created)"
ck "no integration branch"         "" "$(git -C "$REPO" branch --list 'seq/*')"
ck "keys unset"                    "" "$(fork_keys)"
ck "no fleet without then-fleet"   "" "$(fleet_calls)"
ck "status solo exits 0"           "0" "$(run status solo)"
ck_has "status names the drain"    "**Solo drain:** BF-1 → BF-2 → BF-3" "$WORK/out"

# ---- a non-ship costs the drain that issue only ----
dreset BF-1 BF-2 BF-3
echo failed > "$WORK/outcome-BF-2"
ck "a failed issue does not stop the drain" "0" "$(run solo)"
ck "the next issue still ran"      "/auto BF-1,/auto BF-2,/auto BF-3" "$(auto_order)"
ck "outcomes recorded"             "shipped failed shipped" "$(smarker '[.queue[] as $id | .issues[$id].outcome] | join(" ")')"
ck "marker done after a skip"      "done" "$(smarker .status)"
ck_has "the reason names the miss" "not shipped: BF-2 (failed)" "$WORK/out"
# A session that ends without a ledger leaves the registry's last word in the log, the one trace of why the drain moved on.
dreset BF-1 BF-2 BF-3
echo listed-failed > "$WORK/outcome-BF-2"
ck "a ledger-less end does not stop the drain" "0" "$(run solo)"
ck_has "the skip names the registry state" "BF-2 did not ship (the registry last listed session ab000002 as failed)" "$WORK/out"
# The 2026-11-11 drain: BF-1's session reads ended at dispatch. The drain waits, and BF-2 forks from BF-1's landing.
dreset BF-1 BF-2
echo listed-done > "$WORK/outcome-BF-1"
born_ended main
ck "a born-ended drain session exits 0" "0" "$(FLEET_SEQUENCE_GRACE=3 run solo)"
ck "both shipped, in order"        "shipped shipped" "$(smarker '[.queue[] as $id | .issues[$id].outcome] | join(" ")')"
ck "the second forked from the first's landing" "true" "$(smarker '.issues["BF-2"].tip_before == .issues["BF-1"].landed_sha')"

# ---- two failures in a row are a pattern: the drain stops and no fleet follows ----
dreset BF-1 BF-2 BF-3 BF-4
echo failed > "$WORK/outcome-BF-1"; echo none > "$WORK/outcome-BF-2"
ck "two in a row exit 1"           "1" "$(run solo then-fleet 2)"
ck "the third was not dispatched"  "/auto BF-1,/auto BF-2" "$(auto_order)"
ck "marker failed"                 "failed" "$(smarker .status)"
ck_has "the reason names the limit" "2 issues in a row ended without shipping" "$WORK/out"
ck_has "and says no fleet followed" "the fleet was not launched" "$WORK/out"
ck "the fleet was only checked"    "check 2" "$(fleet_calls)"
# A ship between two failures resets the count; /auto declining an issue (skipped, canceled) never counts.
dreset BF-1 BF-2 BF-3 BF-4
echo failed > "$WORK/outcome-BF-1"; echo failed > "$WORK/outcome-BF-3"
ck "failures a ship apart do not stop it" "0" "$(run solo)"
ck "all four ran"                  "4" "$(dispatches)"
dreset BF-1 BF-2 BF-3
echo skipped > "$WORK/outcome-BF-1"; echo canceled > "$WORK/outcome-BF-2"; echo skipped > "$WORK/outcome-BF-3"
ck "declined issues do not trip the limit" "0" "$(run solo)"
ck "all three ran"                 "3" "$(dispatches)"

# ---- the listing is read again before every dispatch ----
dreset BF-1 BF-2
printf 'printf "BF-1\\nBF-9\\n" > "%s/solo-list"\n' "$WORK" > "$WORK/hook-BF-1"
ck "a moved pool exits 0"          "0" "$(run solo)"
ck "the issue that left is not dispatched; the one that joined is" "/auto BF-1,/auto BF-9" "$(auto_order)"
# An issue the probe refuses at its turn is recorded and skipped without a session.
dreset BF-1 BF-2 BF-3
printf '{"labels":{"nodes":[{"name":"specified"},{"name":"solo"}]},"state":{"name":"Done"}}\n' > "$WORK/issue-BF-2.json"
ck "a refused issue exits 0"       "0" "$(run solo)"
ck "it got no session"             "/auto BF-1,/auto BF-3" "$(auto_order)"
ck "its refusal is recorded"       "refused" "$(smarker '.issues["BF-2"].outcome')"
ck_has "and summarized"            "not shipped: BF-2 (refused)" "$WORK/out"
# A listing that stops answering mid-run is retried, then fails the drain with what shipped kept.
dreset BF-1 BF-2
printf 'echo 2 > "%s/lister-rc"\n' "$WORK" > "$WORK/hook-BF-1"
ck "an unreadable listing mid-run exits 1" "1" "$(run solo)"
ck "nothing more was dispatched"   "/auto BF-1" "$(auto_order)"
ck "marker failed on the listing"  "failed" "$(smarker .status)"
ck_has "the reason counts the tries" "could not be read in 2 tries" "$WORK/out"
ck "launch, first pick, then two tries" "4" "$(wc -l < "$WORK/lister-calls" | tr -d ' ')"

# ---- then-fleet: checked at launch, launched once the drain has ended clean ----
dreset BF-1 BF-2
ck "then-fleet exits 0"            "0" "$(run solo then-fleet 6 10h)"
ck "checked first, launched after the last ship, the drain already done" "check 6 10h,launch 6 10h,dispatched-before=2 drain=done" "$(fleet_calls)"
ck "the launch is recorded"        "0" "$(smarker .fleet.exit)"
ck_has "the hand-off is announced" "Then: fleet-launch.sh 6 10h — only after a drain that ends clean" "$WORK/out"
ck_has "fleet-launch's own check output is relayed" "Using /auto-prep's recommendation: 3 session(s)" "$WORK/out"
ck_lacks "the verdict line is not" "CHECK-OK" "$WORK/out"
ck "status after a hand-off exits 0" "0" "$(run status solo)"
ck_has "status reports the hand-off" '**Then:** `fleet-launch.sh 6 10h` — launched' "$WORK/out"
# The claude flags after -- reach the drain's sessions and the fleet.
dreset BF-1
ck "flags with then-fleet exit 0"  "0" "$(run solo then-fleet 3 -- --model sonnet)"
ck_has "the child got the flag"    "--model sonnet" "$WORK/dispatches"
ck_lacks "the default model is not added over it" "opus[1m]" "$WORK/dispatches"
ck_has "the fleet got it after --" "launch 3 -- --model sonnet" "$WORK/fleet-calls"
# An empty pool still owes the fleet.
dreset
ck "an empty pool with then-fleet exits 0" "0" "$(run solo then-fleet 3)"
ck "nothing was dispatched"        "0" "$(dispatches)"
ck "the fleet launched"            "check 3,launch 3,dispatched-before=0 drain=done" "$(fleet_calls)"
# A fleet launch that fails after the drain fails the run, with the drain's result kept in the reason.
dreset BF-1
echo 4 > "$WORK/fleet-launch-rc"
ck "a refused fleet launch exits 1" "1" "$(run solo then-fleet 3)"
ck "marker failed on the hand-off" "failed 4" "$(smarker '"\(.status) \(.fleet.exit)"')"
ck_has "the reason keeps the drain's result" "the drain finished but the fleet did not launch (fleet-launch.sh exit 4" "$WORK/out"
ck_has "with what shipped"         "shipped into main: BF-1" "$WORK/out"

# ---- the budget: nothing starts after it, and running out of time is a clean end ----
dreset BF-1 BF-2
ck "a spent budget exits 0"        "0" "$(run solo 0m then-fleet 3)"
ck "nothing started"               "0" "$(dispatches)"
ck_has "the reason says so"        "out of time, so nothing new was started" "$WORK/out"
ck "the fleet still launched"      "launch 3" "$(sed -n 2p "$WORK/fleet-calls")"
ck "a two-word budget exits 0"     "0" "$(run solo 3 hours)"
ck "inside the budget both ran"    "2" "$(dispatches)"
ck "the deadline is recorded"      "true" "$(smarker '.deadline_epoch > 0 and (.deadline | length) > 0')"
ck_has "and announced"             "Budget: nothing new starts after" "$WORK/out"

# ---- stop: the issue in flight finishes, nothing else starts, no fleet ----
dreset BF-1 BF-2
printf '( cd "%s" && "%s" stop solo ) > "%s/stop-out" 2>&1\n' "$REPO" "$SCRIPT" "$WORK" > "$WORK/hook-BF-1"
ck "a stopped drain exits 0"       "0" "$(run solo then-fleet 3)"
ck "stop dispatched once"          "/auto BF-1" "$(auto_order)"
ck "marker stopped"                "stopped" "$(smarker .status)"
ck_has "stop names the drain"      "Stop requested for the solo drain (BF-1)" "$WORK/stop-out"
ck "the reason keeps what shipped" "stopped — shipped into main: BF-1; the fleet was not launched; re-run the drain to continue" "$(smarker .reason)"
ck "the fleet was never launched"  "check 3" "$(fleet_calls)"
ck "status of a stopped drain exits 0" "0" "$(run status solo)"
ck_has "status says the fleet did not launch" '**Then:** `fleet-launch.sh 3` — not launched' "$WORK/out"

# ---- one drain per checkout, and a list never mixes with one ----
dreset BF-1
mk_drain running $$ main '["BF-7"]'
ck "a second drain is refused"     "1" "$(run solo)"
ck_has "names the running drain"   "a solo drain is already running here (solo drain (BF-7)" "$WORK/out"
ck "a merge list beside it is refused" "1" "$(run merge BF-1)"
ck_has "names the drain as the merger" "a merge-mode sequence is already merging into 'main' (solo drain (BF-7))" "$WORK/out"
ck "a list naming its issue is refused" "1" "$(run BF-7 BF-8)"
ck_has "names the holder"          "BF-7 already in a running sequence (solo drain (BF-7)" "$WORK/out"
ck "none of them dispatched"       "0" "$(dispatches)"
tmp=$(jq '.plan = ["BF-7","BF-8","BF-9"]' "$REPO/tmp/fleet-sequence-solo.json"); printf '%s\n' "$tmp" > "$REPO/tmp/fleet-sequence-solo.json"
ck "status of a running drain exits 0" "0" "$(run status solo)"
ck_has "up next leaves out what it already took" "read again before each dispatch): BF-8, BF-9" "$WORK/out"
# A list sharing an issue with an ENDED drain is its own sequence — it neither resumes the drain nor rewrites its marker.
dreset
mk_drain failed null main '["BF-7"]' "{\"BF-7\":{\"session\":\"cd000001\",\"started_epoch\":1,\"tip_before\":\"$(git -C "$REPO" rev-parse main)\",\"outcome\":\"failed\"}}"
ck "a list after an ended drain exits 0" "0" "$(run merge BF-7 BF-8)"
ck "it is its own sequence"        "merge null" "$(marker '"\(.mode) \(.drain)"' bf-7)"
ck "the drain's marker is left as found" "failed BF-7" "$(smarker '"\(.status) \(.queue | join(" "))"')"
# …unless the drain's session for that issue is still working: dispatching it again would run it twice.
dreset
mk_drain failed null main '["BF-7"]' "{\"BF-7\":{\"session\":\"cd000001\",\"started_epoch\":1,\"tip_before\":\"$(git -C "$REPO" rev-parse main)\"}}"
printf '[{"id":"cd000001","kind":"background","state":"running"}]\n' > "$WORK/agents.json"
ck "a list naming an in-flight drain issue is refused" "1" "$(run merge BF-7 BF-8)"
ck_has "points back at the drain"  "BF-7 is still in flight from the last solo drain (session cd000001)" "$WORK/out"
ck "it dispatched nothing"         "0" "$(dispatches)"

# ---- a re-launch waits on what the last drain left unfinished, then carries on from the listing ----
dreset BF-8
tip=$(git -C "$REPO" rev-parse main)
mk_drain failed null main '["BF-7"]' "{\"BF-7\":{\"session\":\"cd000001\",\"started_epoch\":1,\"tip_before\":\"$tip\"}}"
jq -n '{mode:"single",status:"active",shipped:["BF-7"],canceled:[],skipped:[],failed:[]}' > "$REPO/tmp/auto-state-cd000001.json"
new=$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree -p "$tip" -m "BF-7: work" "$tip^{tree}"); git -C "$REPO" update-ref refs/heads/main "$new"
ck "an adopting drain exits 0"     "0" "$(run solo)"
ck_has "adoption announced"        "Waiting first on what the last drain left unfinished, not dispatching it again: BF-7" "$WORK/out"
ck "only the listed issue was dispatched" "/auto BF-8" "$(auto_order)"
ck "the queue leads with the adopted issue" "BF-7 BF-8" "$(smarker '.queue | join(" ")')"
ck "the adopted landing is recorded" "$new" "$(smarker '.issues["BF-7"].landed_sha')"
# Left on another branch, it cannot be waited on from here.
dreset BF-8
mk_drain failed null release '["BF-7"]' "{\"BF-7\":{\"session\":\"cd000001\",\"started_epoch\":1,\"tip_before\":\"$(git -C "$REPO" rev-parse main)\"}}"
printf '[{"id":"cd000001","kind":"background","state":"running"}]\n' > "$WORK/agents.json"
ck "unfinished work on another branch is refused" "1" "$(run solo)"
ck_has "names the branch to launch from" "the last drain left BF-7 unfinished on 'release'" "$WORK/out"
ck "it dispatched nothing either"  "0" "$(dispatches)"

# ---- a fleet still working here is named, never refused; an ended fleet's marker is not ----
dreset BF-1
printf '{"fleet_sessions":["fe000001"],"count":1,"deadline_epoch":%s}\n' "$(( $(date +%s) + 3600 ))" > "$REPO/tmp/fleet-deadline-team.json"
printf '[{"id":"fe000001","kind":"background","state":"working"}]\n' > "$WORK/agents.json"
ck "a live fleet does not block the drain" "0" "$(run solo)"
ck_has "but it is named"           "WARN: a fleet is still working in this checkout (team)" "$WORK/out"
dreset BF-1
printf '{"fleet_sessions":["fe000001"],"count":1,"deadline_epoch":%s}\n' "$(( $(date +%s) + 3600 ))" > "$REPO/tmp/fleet-deadline-team.json"
ck "an ended fleet's marker exits 0" "0" "$(run solo)"
ck_lacks "and draws no warning"    "a fleet is still working" "$WORK/out"

# ---- a checkout parked for a fleet (detached, start.wt-source-branch set) drains into the branch the key names ----
dreset BF-1
git -C "$REPO" config start.wt-source-branch main
git -C "$REPO" checkout -q --detach
base0=$(git -C "$REPO" rev-parse main)
ck "a parked checkout exits 0"     "0" "$(run solo)"
ck "it ships into the keyed branch" "main 1" "$(smarker .base) $(git -C "$REPO" rev-list --count "$base0..main")"
ck "the child forks by its per-issue key" "BF-1 head= src=main ahead=0" "$(sed -n 1p "$WORK/forks")"
ck "the checkout stays detached"   "" "$(git -C "$REPO" branch --show-current)"
git -C "$REPO" config --unset start.wt-source-branch
: > "$WORK/dispatches"
ck "detached with no key is refused" "1" "$(run solo)"
ck_has "names the key"             "start.wt-source-branch names no local branch" "$WORK/out"
ck "and dispatched nothing"        "0" "$(dispatches)"
git -C "$REPO" checkout -q main
unset LINEAR_TEAM

# ---- a checkout with many worktrees: the main-checkout lookup reads the whole listing. git lists worktrees with work
# between rows, so a consumer that exited at the first row left it to die of SIGPIPE, and under pipefail and errexit the
# runner ended on that assignment with nothing said. ----
reset
for i in $(seq 1 150); do git -C "$REPO" worktree add "$WORK/many/a-long-worktree-directory-name-for-width-$i" -b "many-$i" >/dev/null 2>&1; done
ck "many worktrees: status still runs" "0" "$(run status)"
ck_has "many worktrees: and answers"   "No sequence marker" "$WORK/out"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
