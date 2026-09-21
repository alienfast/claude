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
# `deferred` = shipped with the ref unmoved and the worktree left; `queued` = deferred plus a merge-queue
# marker; `nomention` = shipped with a commit that never names the issue. A `/pr-update` dispatch records the
# branch it ran on. `gh pr create` numbers PRs from $WORK/prseq and records the call; a bare remote backs
# every push.
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
if [ "\${1:-}" = "agents" ]; then cat "$WORK/agents.json" 2>/dev/null || echo '[]'; exit 0; fi
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
        "$WORK"/outcome-* "$WORK"/hook-* "$WORK"/issue-* "$WORK"/pr-*
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
printf '{"labels":{"nodes":[{"name":"specified"}]},"state":{"name":"Done"}}\n' > "$WORK/issue-BF-2.json"
ck "terminal exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "names the state"        "BF-2 is already Done" "$WORK/out"
rm -f "$WORK/issue-BF-2.json"
ck "duplicate exits 1"          "1" "$(run BF-1 bf-1)"
ck_has "names the duplicate"    "BF-1 listed twice" "$WORK/out"
ck "refusals dispatched nothing" "0" "$(dispatches)"
ck "refusals left main"         "main" "$(git -C "$REPO" branch --show-current)"
ck "refusals created no branch" "" "$(git -C "$REPO" branch --list 'seq/*')"

printf 'x\n' > "$REPO/stray.txt"
ck "dirty exits 1"              "1" "$(run BF-1 BF-2)"
ck_has "lists the file"         "stray.txt" "$WORK/out"
ck_has "says nothing ran"       "Nothing was dispatched." "$WORK/out"
rm -f "$REPO/stray.txt"

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

# A checkout-wide start.wt-source-branch (an epic fleet's posture, or one left behind) is no concern of this
# runner: it reads and writes only per-issue keys, and start-wt-setup.sh consults the checkout-wide key
# only under a detached HEAD.
reset
git -C "$REPO" config start.wt-source-branch main
ck "a checkout-wide key does not block" "0" "$(run BF-1)"
ck "children fork by the per-issue key" "BF-1 head=main src=seq/bf-1 ahead=0" "$(sed -n 1p "$WORK/forks")"
ck "checkout-wide key left as found"    "main" "$(git -C "$REPO" config --get start.wt-source-branch)"
git -C "$REPO" config --unset start.wt-source-branch

reset
printf '{"fleet_sessions":["fe000001"],"count":1}\n' > "$REPO/tmp/fleet-deadline.json"
printf '[{"id":"fe000001","kind":"background"}]\n' > "$WORK/agents.json"
ck "live fleet exits 1"         "1" "$(run BF-1 BF-2)"
ck_has "names the fleet"        "a fleet is running (sessions: fe000001)" "$WORK/out"
printf '[{"id":"fe000001","kind":"background","state":"done"}]\n' > "$WORK/agents.json"
ck "dead fleet does not block"  "0" "$(run BF-1 BF-2)"
ck "refusal-free run dispatched" "2" "$(dispatches)"

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

# ---- a landing whose commits never name the issue ships with a WARN, and the sequence continues ----
reset
echo nomention > "$WORK/outcome-BF-1"
ck "unnamed commit exits 0"     "0" "$(run BF-1 BF-2)"
ck_has "warns about the commit" "WARN: none of the commits seq/bf-1 gained mention BF-1" "$WORK/out"
ck "unnamed commit still continues" "2" "$(dispatches)"

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
ck_has "default autocompact still added" "--autocompact 500000" "$WORK/dispatches"
ck_has "single-issue PR title"  "create seq/bf-1 main BF-1: Title of BF-1" "$WORK/gh-calls"
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

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
