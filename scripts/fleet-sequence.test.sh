#!/usr/bin/env bash
# Regression suite for fleet-sequence.sh: the pre-dispatch refusals, strict one-at-a-time sequencing,
# the fork-from-the-previous-branch positioning (detached HEAD + start.wt-source-branch), the PR stack
# the marker records, the stop-on-first-non-ship rule, stop/resume, and the checkout restore.
#
# `claude` is stubbed: `agents --json --all` answers from $WORK/agents.json, and `--bg` records the
# dispatch, then plays a `/auto pr <ID>` session out SYNCHRONOUSLY the way /start wt + /finish pr would —
# records the fork point it saw (HEAD's branch, or "" when detached, and start.wt-source-branch) in
# $WORK/forks, creates the preserved worktree .claude/worktrees/<id> on branch wt-<id> from HEAD with
# one commit, registers an open PR for that branch against the source in $WORK/pr-<branch>.json (which
# the `gh` stub serves), writes the ledger tmp/auto-state-<id>.json with the issue in the list
# $WORK/outcome-<ID> names (default shipped; `none` = no ledger; `hang` = listed running forever;
# `nopr` = shipped without a PR; `nocommit` = shipped with an empty branch), runs $WORK/hook-<ID> if
# present, and lists the session as done.
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
id="\${last#/auto pr }"
outcome=\$(cat "$WORK/outcome-\$id" 2>/dev/null || echo shipped)
head=\$(git -C "$REPO" branch --show-current)
src=\$(git -C "$REPO" config --get start.wt-source-branch 2>/dev/null || true); [ -n "\$src" ] || src="\$head"
echo "\$id head=\$head src=\$src" >> "$WORK/forks"
case "\$outcome" in
  none) ;;
  hang) state=running ;;
  *)
    list="\$outcome"; case "\$outcome" in nopr|nocommit) list=shipped ;; esac
    jq -n --arg id "\$id" --arg o "\$list" '{mode:"single",status:"active",shipped:[],canceled:[],skipped:[],failed:[]} | .[\$o] += [\$id]' > "$REPO/tmp/auto-state-\$sid.json"
    if [ "\$list" = "shipped" ]; then
      lower=\$(printf '%s' "\$id" | tr '[:upper:]' '[:lower:]')
      git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/\$lower" -b "wt-\$lower" HEAD
      [ "\$outcome" = "nocommit" ] || git -C "$REPO/.claude/worktrees/\$lower" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "\$id: work"
      [ "\$outcome" = "nopr" ] || printf '[{"url":"https://github.com/x/y/pull/%s","baseRefName":"%s"}]\n' "\$n" "\$src" > "$WORK/pr-wt-\$lower.json"
    fi
    ;;
esac
[ -f "$WORK/hook-\$id" ] && bash "$WORK/hook-\$id"
tmp=\$(jq --arg s "\$sid" --arg st "\$state" '. + [{id:\$s, kind:"background", state:\$st}]' "$WORK/agents.json")
printf '%s\n' "\$tmp" > "$WORK/agents.json"
printf 'backgrounded · \033[36m%s\033[39m · %s\n\033[2m  claude attach %s    open in this terminal\033[22m\n' "\$sid" "\$name" "\$sid"
exit 0
STUB_CLAUDE
cat > "$BIN/linear-cli" <<STUB_LINEAR
#!/usr/bin/env bash
id="\${3:-}"
if [ -f "$WORK/issue-\$id.json" ]; then cat "$WORK/issue-\$id.json"; else echo '{"labels":{"nodes":[{"name":"specified"},{"name":"solo"}]},"state":{"name":"Planned"}}'; fi
STUB_LINEAR
cat > "$BIN/gh" <<STUB_GH
#!/usr/bin/env bash
head=""; prev=""; for a in "\$@"; do [ "\$prev" = "--head" ] && head="\$a"; prev="\$a"; done
f="$WORK/pr-\${head//\//_}.json"
if [ -f "\$f" ]; then cat "\$f"; else echo '[]'; fi
STUB_GH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export FLEET_SEQUENCE_POLL=0 FLEET_SEQUENCE_GRACE=0 FLEET_SEQUENCE_FOREGROUND=1 FLEET_SEQUENCE_ISSUE_TIMEOUT=5

run() { ( cd "$REPO" && "$SCRIPT" "$@" ) >"$WORK/out" 2>&1; echo $?; }
marker() { jq -r "$1" "$REPO/tmp/fleet-sequence.json"; }
dispatches() { grep -c -- '/auto pr ' "$WORK/dispatches" 2>/dev/null || true; }
src_cfg() { git -C "$REPO" config --get start.wt-source-branch 2>/dev/null || echo "(unset)"; }
reset() {
  rm -f "$WORK/dispatches" "$WORK/forks" "$WORK/seq" "$WORK"/outcome-* "$WORK"/hook-* "$WORK"/issue-* "$WORK"/pr-*
  echo '[]' > "$WORK/agents.json"
  rm -rf "$REPO/tmp" "$REPO/.claude"; mkdir -p "$REPO/tmp"
  git -C "$REPO" worktree prune
  git -C "$REPO" config --unset start.wt-source-branch 2>/dev/null
  git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard; git -C "$REPO" clean -qfd
  for b in $(git -C "$REPO" branch --format='%(refname:short)' | grep -v '^main$'); do git -C "$REPO" branch -q -D "$b"; done
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
ck "batch flag is gone"         "1" "$(run --branch seq/x BF-1 BF-2)"

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

printf 'x\n' > "$REPO/stray.txt"
ck "dirty exits 1"              "1" "$(run BF-1 BF-2)"
ck_has "lists the file"         "stray.txt" "$WORK/out"
ck_has "says nothing ran"       "Nothing was dispatched." "$WORK/out"
rm -f "$REPO/stray.txt"

git -C "$REPO" checkout -q --detach
ck "detached exits 1"           "1" "$(run BF-1 BF-2)"
ck_has "names detached"         "HEAD is detached" "$WORK/out"
git -C "$REPO" checkout -q main

printf '{"fleet_sessions":["fe000001"],"count":1}\n' > "$REPO/tmp/fleet-deadline.json"
printf '[{"id":"fe000001","kind":"background"}]\n' > "$WORK/agents.json"
ck "live fleet exits 1"         "1" "$(run BF-1 BF-2)"
ck_has "names the fleet"        "a fleet is running (sessions: fe000001)" "$WORK/out"
printf '[{"id":"fe000001","kind":"background","state":"done"}]\n' > "$WORK/agents.json"
ck "dead fleet does not block"  "0" "$(run BF-1 BF-2)"
ck "refusal-free run dispatched" "2" "$(dispatches)"

# ---- happy path: three stacked PRs, each forked from the previous branch ----
reset
ck "sequence exits 0"           "0" "$(run BF-1 BF-2 BF-3)"
ck "three /auto pr dispatches"  "3" "$(dispatches)"
ck "dispatched in order"        "/auto pr BF-1,/auto pr BF-2,/auto pr BF-3" "$(grep -o -- '/auto pr [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck_has "sessions are named"     "-n fleet-sequence BF-2 /auto pr BF-2" "$WORK/dispatches"
ck_has "default model"          "--model opus[1m]" "$WORK/dispatches"
ck_has "default permission mode" "--permission-mode auto" "$WORK/dispatches"
ck "first forks from main on main" "BF-1 head=main src=main" "$(sed -n 1p "$WORK/forks")"
ck "second forks detached from wt-bf-1" "BF-2 head= src=wt-bf-1" "$(sed -n 2p "$WORK/forks")"
ck "third forks detached from wt-bf-2" "BF-3 head= src=wt-bf-2" "$(sed -n 3p "$WORK/forks")"
ck "marker done"                "done" "$(marker .status)"
ck "base recorded"              "main" "$(marker .base)"
ck "outcomes recorded"          "shipped shipped shipped" "$(marker '[.queue[] as $id | .issues[$id].outcome] | join(" ")')"
ck "branches recorded"          "wt-bf-1 wt-bf-2 wt-bf-3" "$(marker '[.queue[] as $id | .issues[$id].branch] | join(" ")')"
ck "PR bases form the stack"    "main wt-bf-1 wt-bf-2" "$(marker '[.queue[] as $id | .issues[$id].pr_base] | join(" ")')"
ck "PR urls recorded"           "https://github.com/x/y/pull/1 https://github.com/x/y/pull/2 https://github.com/x/y/pull/3" "$(marker '[.queue[] as $id | .issues[$id].pr_url] | join(" ")')"
ck "sessions recorded"          "ab000001 ab000002 ab000003" "$(marker '[.queue[] as $id | .issues[$id].session] | join(" ")')"
ck "checkout restored to main"  "main" "$(git -C "$REPO" branch --show-current)"
ck "source config unset"        "(unset)" "$(src_cfg)"
ck "stack is linear in git"     "3" "$(git -C "$REPO" rev-list --count main..wt-bf-3)"
ck "worktrees preserved"        "3" "$(git -C "$REPO" worktree list | grep -c 'worktrees/bf-')"
ck_has "done logged with the stack" "done: BF-1, BF-2, BF-3 stacked on main — merge bottom-up: BF-1 https://github.com/x/y/pull/1  →  BF-2 https://github.com/x/y/pull/2  →  BF-3 https://github.com/x/y/pull/3" "$WORK/out"
ck_lacks "no integrity warning" "WARN" "$WORK/out"
ck "status exits 0"             "0" "$(run status)"
ck_has "status shows the row"   "| BF-2 | ab000002 | done | shipped | wt-bf-2 | https://github.com/x/y/pull/2 |" "$WORK/out"
ck_has "status shows the stack" "- BF-2: \`wt-bf-2\` → \`wt-bf-1\` — https://github.com/x/y/pull/2" "$WORK/out"
ck "stop on a done run exits 0" "0" "$(run stop)"
ck_has "stop says already done" "already done" "$WORK/out"

# ---- failure mid-queue stops the sequence with the rest untouched; checkout restored ----
reset
echo failed > "$WORK/outcome-BF-2"
ck "failure exits 1"            "1" "$(run BF-1 BF-2 BF-3)"
ck "stopped after the failure"  "2" "$(dispatches)"
ck "marker failed"              "failed" "$(marker .status)"
ck_has "reason names the issue" "BF-2 ended 'failed' in session ab000002" "$WORK/out"
ck_has "reason lists the rest"  "not started: BF-3" "$WORK/out"
ck "BF-3 untouched"             "null" "$(marker '.issues["BF-3"]')"
ck "failure restored main"      "main" "$(git -C "$REPO" branch --show-current)"
ck "failure unset the config"   "(unset)" "$(src_cfg)"
ck "status exits 0 after failure" "0" "$(run status)"
ck_has "status shows queued"    "| BF-3 | — | — | queued | — | — |" "$WORK/out"
ck_has "status shows the reason" "**Reason:** BF-2 ended" "$WORK/out"
ck_has "status shows the partial stack" "- BF-1: \`wt-bf-1\` → \`main\` — https://github.com/x/y/pull/1" "$WORK/out"

# ---- re-running the same list resumes: BF-1 kept, BF-2 forks from wt-bf-1 ----
echo shipped > "$WORK/outcome-BF-2"
: > "$WORK/dispatches"; : > "$WORK/forks"
ck "resume exits 0"             "0" "$(run BF-1 BF-2 BF-3)"
ck_has "resume announced"       "Resuming on main: already shipped, kept — BF-1 (https://github.com/x/y/pull/1)" "$WORK/out"
ck_has "BF-1 skipped"           "BF-1 already shipped (https://github.com/x/y/pull/1) — skipping" "$WORK/out"
ck "resume dispatched the rest" "/auto pr BF-2,/auto pr BF-3" "$(grep -o -- '/auto pr [A-Z]*-[0-9]*' "$WORK/dispatches" | paste -sd, -)"
ck "resume forked BF-2 from wt-bf-1" "BF-2 head= src=wt-bf-1" "$(sed -n 1p "$WORK/forks")"
ck "resume finished"            "done" "$(marker .status)"
ck "resume kept BF-1's session" "ab000001" "$(marker '.issues["BF-1"].session')"
ck "resume stack bases"         "main wt-bf-1 wt-bf-2" "$(marker '[.queue[] as $id | .issues[$id].pr_base] | join(" ")')"

# ---- a different base is a fresh run, not a resume ----
git -C "$REPO" checkout -q -b other
: > "$WORK/dispatches"
ck "other base exits 0"         "0" "$(run BF-4)"
ck_lacks "no resume on a new base" "Resuming" "$WORK/out"
ck "fresh marker has only BF-4" "BF-4" "$(marker '.issues | keys | join(" ")')"
ck "restored to other"          "other" "$(git -C "$REPO" branch --show-current)"

# ---- shipped without a PR, or without a ledger, is a failure ----
reset
echo nopr > "$WORK/outcome-BF-1"
ck "no PR exits 1"              "1" "$(run BF-1 BF-2)"
ck "no PR stops at once"        "1" "$(dispatches)"
ck_has "reason says no PR"      "BF-1 shipped on 'wt-bf-1' but no open PR was found" "$WORK/out"
reset
echo none > "$WORK/outcome-BF-1"
ck "no ledger exits 1"          "1" "$(run BF-1 BF-2)"
ck_has "reason says unknown"    "BF-1 ended 'unknown'" "$WORK/out"

# ---- an empty branch ships with a WARN, and the stack continues ----
reset
echo nocommit > "$WORK/outcome-BF-1"
ck "empty branch exits 0"       "0" "$(run BF-1 BF-2)"
ck_has "warns about no commits" "WARN: 'wt-bf-1' has no commits beyond 'main'" "$WORK/out"
ck "empty branch still stacks"  "2" "$(dispatches)"

# ---- a session that never ends times out; nothing is killed; checkout restored ----
reset
echo hang > "$WORK/outcome-BF-1"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=1
ck "hang exits 1"               "1" "$(run BF-1 BF-2)"
ck_has "hang names the session" "BF-1: session ab000001 still running after 1s — not killed" "$WORK/out"
ck "hang dispatched once"       "1" "$(dispatches)"
ck "hang restored main"         "main" "$(git -C "$REPO" branch --show-current)"
export FLEET_SEQUENCE_ISSUE_TIMEOUT=5

# ---- stop requested mid-run: the in-flight issue finishes, nothing else starts, PRs stand ----
reset
printf 'tmp=$(jq ".stop_requested = true" "%s/tmp/fleet-sequence.json"); printf "%%s\\n" "$tmp" > "%s/tmp/fleet-sequence.json"\n' "$REPO" "$REPO" > "$WORK/hook-BF-1"
ck "stop exits 0"               "0" "$(run BF-1 BF-2 BF-3)"
ck "stop dispatched once"       "1" "$(dispatches)"
ck "marker stopped"             "stopped" "$(marker .status)"
ck_has "reason names the rest"  "stopped before BF-2; not started: BF-2, BF-3" "$WORK/out"
ck "BF-1 still shipped"         "shipped" "$(marker '.issues["BF-1"].outcome')"
ck "BF-1's PR stands"           "https://github.com/x/y/pull/1" "$(marker '.issues["BF-1"].pr_url')"
ck "stop restored main"         "main" "$(git -C "$REPO" branch --show-current)"

# ---- claude flags pass through ----
reset
ck "flags exit 0"               "0" "$(run BF-1 -- --model fable --effort high)"
ck_has "flag passthrough"       "--model fable --effort high" "$WORK/dispatches"
ck_lacks "no default model"     "opus[1m]" "$WORK/dispatches"
ck_has "default autocompact still added" "--autocompact 500000" "$WORK/dispatches"

# ---- status / stop with no marker ----
reset
ck "status without marker"      "0" "$(run status)"
ck_has "status says nothing launched" "No sequence marker" "$WORK/out"
ck "stop without marker"        "0" "$(run stop)"
ck_has "stop says nothing to stop" "nothing to stop" "$WORK/out"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
