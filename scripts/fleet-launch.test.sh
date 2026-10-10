#!/usr/bin/env bash
# Regression suite for fleet-launch.sh's pre-dispatch preflight.
#
# WHY: on 2026-08-04 a 6-line uncommitted .claude/rules/bash.md edit, on a branch carrying no issue
# ID, halted all three sessions of a launch inside 8 minutes — each independently rediscovering it at
# /auto's Step 1 and calling ScheduleWakeup(stop: true). Only a human committing the file at 19:56
# saved the run; unattended, the fleet would have been 100% dead on arrival, and the failure scales
# with the session count. The check now runs ONCE, here, before anything is dispatched.
#
# `claude` is stubbed so a dispatch is observable without launching anything. The stub records every
# invocation — the refusal cases assert it was never called, which is the property that matters — and
# prints the real `--bg` output shape (2026-08-29: `backgrounded · <id>` with the id ANSI-coloured, then
# attach/logs hints) with a monotonic fake id, so the session-set cases can assert exact membership.
# `claude agents` is answered from $WORK/agents.json (empty array when absent). The ~/.claude freshness check runs
# against a fixture clone of a bare origin (CLAUDE_FRESHNESS_DIR), current except in the cases that push to it.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-launch.sh"
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

# ---- stub claude: records calls, never launches ----
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "agents" ]; then cat "$WORK/agents.json" 2>/dev/null || echo '[]'; exit 0; fi
if [ "\${1:-}" = "plugin" ]; then cat "$WORK/plugins.json" 2>/dev/null || echo '[{"id":"loop-boundary@alienfast-claude","enabled":true}]'; exit 0; fi
echo "\$@" >> "$WORK/dispatches"
n=\$(( \$(cat "$WORK/seq" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/seq"
printf 'backgrounded · \033[36mab%06d\033[39m\n\033[2m  claude agents             list sessions\033[22m\n\033[2m  claude attach ab%06d    open in this terminal\033[22m\n' "\$n" "\$n"
exit 0
EOF
chmod +x "$BIN/claude"
# linear-cli stub for epic-graph.sh's walk (the epic-scope cases): EP-1 is an epic whose one child
# EP-3 is itself an epic (a valid second scope); EP-2 carries no epic label; anything else is not
# found. HOME is an empty dir so epic-graph.sh's cargo-bin PATH prepend cannot find the real CLI.
cat > "$BIN/linear-cli" <<'EOF'
#!/usr/bin/env bash
id=""; for a in "$@"; do case "$a" in id=*) id="${a#id=}" ;; esac; done
node() { printf '{"data":{"issue":{"identifier":"%s","title":"t","state":{"name":"Planned","type":"unstarted"},"team":{"key":"EP"},"labels":{"nodes":%s},"parent":null,"children":{"nodes":%s},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}\n' "$1" "$2" "$3"; }
case "$id" in
  EP-1) node EP-1 '[{"name":"epic"}]' '[{"identifier":"EP-3"}]' ;;
  EP-3) node EP-3 '[{"name":"epic"}]' '[]' ;;
  EP-2) node EP-2 '[]' '[]' ;;
  *) echo '{"code":2,"details":[{"message":"Entity not found: Issue"}],"error":true}'; exit 2 ;;
esac
EOF
chmod +x "$BIN/linear-cli"
mkdir -p "$WORK/home"
export PATH="$BIN:$PATH"
export FLEET_STAGGER_TIMEOUT=0

# ---- ~/.claude fixture: a bare origin, an upstream clone that pushes, and the clone the launch checks ----
CL_ORIGIN="$WORK/claude-origin.git"
CL_UP="$WORK/claude-upstream"
export CLAUDE_FRESHNESS_DIR="$WORK/claude-local"
git init -q --bare "$CL_ORIGIN"
git -C "$CL_ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$CL_ORIGIN" "$CL_UP" 2>/dev/null
git -C "$CL_UP" checkout -q -b main
mkdir -p "$CL_UP/hooks"
echo base > "$CL_UP/hooks/auto-rewake.sh"; echo base > "$CL_UP/settings.json"; echo base > "$CL_UP/README.md"
git -C "$CL_UP" add -A
git -C "$CL_UP" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$CL_UP" push -q origin main
claude_upstream() { # <message> <path> — one upstream commit, pushed
  echo "$1" >> "$CL_UP/$2"
  git -C "$CL_UP" -c user.email=t@t -c user.name=t commit -q -am "$1"
  git -C "$CL_UP" push -q origin main
}
claude_fresh() { rm -rf "$CLAUDE_FRESHNESS_DIR"; git clone -q "$CL_ORIGIN" "$CLAUDE_FRESHNESS_DIR"; }
claude_fresh

# ---- fixture repo ----
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# tmp/ is gitignored in every real project; without this the marker the script writes reads as dirt.
echo 'tmp/' >> "$REPO/.git/info/exclude"
git -C "$REPO" checkout -q -b nextjs-descope-user   # no issue ID — the 2026-08-04 branch shape
run() { ( cd "$REPO" && HOME="$WORK/home" "$SCRIPT" "$@" ) >"$WORK/out" 2>&1; echo $?; }

# ---- case 1: clean tree launches ----
: > "$WORK/dispatches"
ck "clean tree exits 0"      "0" "$(run 1)"
ck "clean tree dispatched"   "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

# ---- case 2: dirty + branch with no issue ID → refuse, dispatch nothing ----
printf 'x\n' > "$REPO/rules.md"
git -C "$REPO" add rules.md
: > "$WORK/dispatches"
ck "unattributable exits 1"  "1" "$(run 1)"
ck "nothing dispatched"      "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "names the halt"      "would halt at" "$WORK/out"
ck_has "names the branch"    "branch: nextjs-descope-user" "$WORK/out"
ck_has "lists the file"      "rules.md" "$WORK/out"
ck_has "says nothing ran"    "Nothing was dispatched." "$WORK/out"

# A refused launch must not disturb a RUNNING fleet's deadline: the check sits before the
# unconditional `rm -f $marker`, or refusing one launch silently un-deadlines the live fleet.
printf '{"deadline_epoch":9999999999,"deadline":"later","count":3}\n' > "$REPO/tmp/fleet-deadline.json"
ck "refusal exits 1 again"   "1" "$(run 2 5h)"
ck "live marker survives"    "9999999999" "$(jq -r '.deadline_epoch' "$REPO/tmp/fleet-deadline.json")"
rm -f "$REPO/tmp/fleet-deadline.json"

# ---- case 3: dirty + branch WITH an issue ID → warn, still launch ----
# /auto can attribute this to an in-progress issue and finish it, so refusing would block the
# designed resume path.
git -C "$REPO" checkout -q -b rosskevin/bf-727-email-audit
: > "$WORK/dispatches"
ck "attributable exits 0"    "0" "$(run 1)"
ck "attributable dispatched" "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "warns about dirt"    "carries an issue ID" "$WORK/out"
ck_lacks "does not refuse"   "Nothing was dispatched." "$WORK/out"

# ---- case 4: untracked-only dirt counts too ----
# git status --porcelain reports ?? rows; /auto's preflight treats them as dirt just the same.
git -C "$REPO" checkout -q nextjs-descope-user
git -C "$REPO" reset -q --hard
printf 'y\n' > "$REPO/stray.txt"
: > "$WORK/dispatches"
ck "untracked refuses"       "1" "$(run 1)"
ck "untracked no dispatch"   "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "lists untracked"     "stray.txt" "$WORK/out"

# ---- case 5: `stop` is never gated ----
# Winding down a fleet must work regardless of tree state — it is the remedy, not a launch.
ck "stop exits 0 when dirty" "0" "$(run stop)"
ck "stop wrote marker"       "true" "$(jq -r '.stopped' "$REPO/tmp/fleet-deadline.json")"
# A stop never moves a deadline later: a passed deadline is left byte-identical, a future one becomes now.
past=$(( $(date +%s) - 10800 ))
printf '{"deadline_epoch":%s,"deadline":"earlier","count":3,"launch_epoch":1}\n' "$past" > "$REPO/tmp/fleet-deadline.json"
cp "$REPO/tmp/fleet-deadline.json" "$WORK/marker.before"
ck "stop past deadline exits 0"       "0" "$(run stop)"
ck "stop past deadline leaves marker" "same" "$(cmp -s "$WORK/marker.before" "$REPO/tmp/fleet-deadline.json" && echo same || echo changed)"
ck_has "stop past deadline says so"   "marker left unchanged" "$WORK/out"
printf '{"deadline_epoch":9999999999,"deadline":"later","count":3,"launch_epoch":1}\n' > "$REPO/tmp/fleet-deadline.json"
ck "stop future deadline exits 0"     "0" "$(run stop)"
ck "stop future deadline moves to now" "true" "$(jq -r '.stopped == true and .deadline_epoch < 9999999999 and .launch_epoch == 1' "$REPO/tmp/fleet-deadline.json")"
rm -f "$REPO/tmp/fleet-deadline.json"
ck "stop with no marker exits 0"      "0" "$(run stop)"
ck "stop with no marker writes one"   "true" "$(jq -r '.stopped == true and (.deadline_epoch > 0)' "$REPO/tmp/fleet-deadline.json")"

# ---- case 6: the marker is written on EVERY launch and records the session set ----
# A fleet is a session set, not a time window (header). ab000001/ab000002 went to cases 1 and 3.
git -C "$REPO" checkout -q nextjs-descope-user
git -C "$REPO" reset -q --hard
rm -f "$REPO/stray.txt" "$REPO/tmp/fleet-deadline.json" "$REPO"/tmp/auto-state-*.json
echo '[]' > "$WORK/agents.json"
: > "$WORK/dispatches"
ck "undated launch exits 0"       "0" "$(run 2)"
ck "undated launch writes marker" "yes" "$([ -s "$REPO/tmp/fleet-deadline.json" ] && echo yes || echo no)"
ck "marker carries no deadline"   "" "$(jq -r '.deadline_epoch // empty' "$REPO/tmp/fleet-deadline.json")"
ck "session set recorded"         "ab000003 ab000004" "$(jq -r '.fleet_sessions | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "count recorded"               "2" "$(jq -r '.count' "$REPO/tmp/fleet-deadline.json")"
ck_has "each id surfaced"         "session ab000003 recorded" "$WORK/out"
ck_has "set surfaced at the end"  "Fleet session set: ab000003 ab000004" "$WORK/out"
# The ceiling every pick will park against is named at launch; HOME is empty here, so the probe answers
# with its default and the launch warns that the calibration file is missing.
ck_has "ceiling in effect printed"   "Headroom ceiling: ceiling=" "$WORK/out"
ck_has "default ceiling warned"       "WARN: the headroom probe is on its built-in default ceiling" "$WORK/out"

# ---- case 7: a dated launch carries the deadline AND the set; a dead prior set is not inherited ----
: > "$WORK/dispatches"
ck "dated launch exits 0"         "0" "$(run 1 5h)"
ck "deadline present"             "true" "$(jq -r '.deadline_epoch > 0' "$REPO/tmp/fleet-deadline.json")"
ck "prior set not inherited"      "ab000005" "$(jq -r '.fleet_sessions | join(" ")' "$REPO/tmp/fleet-deadline.json")"

# ---- case 8: a top-up carries the members the registry still runs, anchors only on loop ledgers ----
# Prior launch: ab000001 (registry: working) and ab000002 (registry: done — listed is not alive).
# Ledgers: ab000001 loop (kept, carried, pulls launch_epoch back to its mtime); cafe0001 single-run
# (registry lists it as an interactive row with no id, so it is alive: kept, but neither carried nor
# anchoring — its older mtime must NOT win); dead0001 absent from the registry (cleared).
jq -n '{fleet_sessions: ["ab000001", "ab000002"], count: 2, launch_epoch: 1}' > "$REPO/tmp/fleet-deadline.json"
echo '{"status":"active","shipped":["XX-1"]}' > "$REPO/tmp/auto-state-ab000001.json"
echo '{"status":"active","mode":"single","shipped":["XX-2"]}' > "$REPO/tmp/auto-state-cafe0001.json"
echo '{"status":"active","shipped":["XX-3"]}' > "$REPO/tmp/auto-state-dead0001.json"
touch -t 202601011200 "$REPO/tmp/auto-state-ab000001.json"
touch -t 202506011200 "$REPO/tmp/auto-state-cafe0001.json"
loop_mtime=$(stat -c %Y "$REPO/tmp/auto-state-ab000001.json" 2>/dev/null || stat -f %m "$REPO/tmp/auto-state-ab000001.json")
cat > "$WORK/agents.json" <<'EOF'
[{"id":"ab000001","kind":"background","sessionId":"ab000001-0000-4000-8000-000000000000","state":"working"},
 {"kind":"interactive","sessionId":"cafe0001-0000-4000-8000-000000000000","pid":1},
 {"id":"ab000002","kind":"background","sessionId":"ab000002-0000-4000-8000-000000000000","state":"done"}]
EOF
: > "$WORK/dispatches"
ck "top-up exits 0"                      "0" "$(run 1)"
ck "live member carried, new appended"   "ab000001 ab000006" "$(jq -r '.fleet_sessions | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "launch_epoch anchored on the loop ledger" "$loop_mtime" "$(jq -r '.launch_epoch' "$REPO/tmp/fleet-deadline.json")"
ck "single-run ledger kept"              "yes" "$([ -f "$REPO/tmp/auto-state-cafe0001.json" ] && echo yes || echo no)"
ck "loop ledger kept"                    "yes" "$([ -f "$REPO/tmp/auto-state-ab000001.json" ] && echo yes || echo no)"
ck "unlisted ledger cleared"             "no" "$([ -f "$REPO/tmp/auto-state-dead0001.json" ] && echo yes || echo no)"
ck_has "clearing reported"               "Cleared prior-run ledger(s): dead0001" "$WORK/out"

# ---- case 8b: the row `claude stop` leaves behind is an ended session; a status-less row in a status-less schema is not ----
# Measured 2026-10-04: a stopped session stays listed with its state unchanged and the `status`/`pid` keys gone, while
# every live row carries `status`. The second launch has no `status` anywhere — the pre-2026-10 shape — so the same
# key-less row must read alive and its ledger must be kept.
jq -n '{fleet_sessions: ["ab000001", "ab000003"], count: 2, launch_epoch: 1}' > "$REPO/tmp/fleet-deadline.json"
echo '{"status":"active","shipped":["XX-1"]}' > "$REPO/tmp/auto-state-ab000001.json"
echo '{"status":"drained","shipped":["XX-4"]}' > "$REPO/tmp/auto-state-ab000003.json"
cat > "$WORK/agents.json" <<'EOF'
[{"id":"ab000001","kind":"background","sessionId":"ab000001-0000-4000-8000-000000000000","state":"working","status":"idle","pid":11},
 {"id":"ab000003","kind":"background","sessionId":"ab000003-0000-4000-8000-000000000000","state":"working"}]
EOF
: > "$WORK/dispatches"
ck "stopped-row launch exits 0"          "0" "$(run 1)"
ck "stopped-row ledger cleared"          "no" "$([ -f "$REPO/tmp/auto-state-ab000003.json" ] && echo yes || echo no)"
ck "live-row ledger kept"                "yes" "$([ -f "$REPO/tmp/auto-state-ab000001.json" ] && echo yes || echo no)"
echo '{"status":"drained","shipped":["XX-5"]}' > "$REPO/tmp/auto-state-ab000005.json"
cat > "$WORK/agents.json" <<'EOF'
[{"id":"ab000001","kind":"background","sessionId":"ab000001-0000-4000-8000-000000000000","state":"working"},
 {"id":"ab000005","kind":"background","sessionId":"ab000005-0000-4000-8000-000000000000","state":"working"}]
EOF
: > "$WORK/dispatches"
ck "status-less schema launch exits 0"   "0" "$(run 1)"
ck "status-less row's ledger kept"       "yes" "$([ -f "$REPO/tmp/auto-state-ab000005.json" ] && echo yes || echo no)"

# ---- case 9: an unreadable --bg output warns and launches anyway ----
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "plugin" ]; then cat "$WORK/plugins.json" 2>/dev/null || echo '[{"id":"loop-boundary@alienfast-claude","enabled":true}]'; exit 0; fi
if [ "\${1:-}" = "agents" ]; then echo '[]'; exit 0; fi
echo "\$@" >> "$WORK/dispatches"
echo "started"
exit 0
EOF
rm -f "$REPO"/tmp/auto-state-*.json
: > "$WORK/dispatches"
ck "unparseable id still launches"  "0" "$(run 1)"
ck "dispatched once"                "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "warns about the missing id" "could not read the session id" "$WORK/out"
ck "set left empty, not invented"   "" "$(jq -r '.fleet_sessions | join(" ")' "$REPO/tmp/fleet-deadline.json")"

# ---- epic scope: the token, the prepared recommendation, and the integration-branch posture ----
# The id-printing claude stub again (case 9 swapped in the unparseable variant).
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "agents" ]; then cat "$WORK/agents.json" 2>/dev/null || echo '[]'; exit 0; fi
if [ "\${1:-}" = "plugin" ]; then cat "$WORK/plugins.json" 2>/dev/null || echo '[{"id":"loop-boundary@alienfast-claude","enabled":true}]'; exit 0; fi
echo "\$@" >> "$WORK/dispatches"
n=\$(( \$(cat "$WORK/seq" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/seq"
printf 'backgrounded · \033[36mab%06d\033[39m\n' "\$n"
exit 0
EOF
git -C "$REPO" checkout -q nextjs-descope-user
git -C "$REPO" reset -q --hard
rm -f "$REPO"/tmp/auto-state-*.json "$REPO/tmp/fleet-recommendation.json"
echo '[]' > "$WORK/agents.json"

# case 10: an explicit token with no prep — prompt scoped, marker records the scope and the LIVE
# membership, the missing integration branch is warned about, the checkout is not moved.
: > "$WORK/dispatches"
ck "token launch exits 0"             "0" "$(run 1 epic:ep-1)"
ck_has "token prompt scoped"          "/loop /auto epic:EP-1" "$WORK/dispatches"
ck "token marker scope"               "EP-1" "$(jq -r '.scope' "$REPO/tmp/fleet-deadline.json")"
ck "token members from the live graph" "EP-1 EP-3" "$(jq -r '.members | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "token records no branch"          "" "$(jq -r '.branch // empty' "$REPO/tmp/fleet-deadline.json")"
ck_has "scope surfaced"               "Scope: epic EP-1 — 2 non-terminal member(s) across EP" "$WORK/out"
ck_has "missing branch warned"        "no integration branch recorded for epic EP-1" "$WORK/out"
ck "token leaves the checkout alone"  "nextjs-descope-user" "$(git -C "$REPO" branch --show-current)"

# case 11: a bare launch after /epic-prep STOPS — an inherited scope is asked about, never assumed
# (2026-09-29: a bare launch four days after prep inherited BF-1826 unnoticed and drained it). Nothing
# is dispatched, and the marker case 10 wrote is untouched.
git -C "$REPO" branch -q epic/ep-1 nextjs-descope-user
jq -n --argjson e "$(date +%s)" '{sessions: 1, team: "EP", generated_epoch: $e, scope: "EP-1", members: ["EP-1","EP-3","EP-9"], branch: "epic/ep-1", base: "nextjs-descope-user"}' > "$REPO/tmp/fleet-recommendation.json"
: > "$WORK/dispatches"
ck "bare launch over a scoped recommendation exits 3" "3" "$(run)"
ck_has "scope confirm named"          "SCOPE-CONFIRM: " "$WORK/out"
ck_has "scope confirm names the epic" "carries epic scope EP-1 (written by /epic-prep 0h ago). Nothing was dispatched or written." "$WORK/out"
ck_has "scope confirm remedies"       "Re-run with 'epic:EP-1' to launch the epic fleet, or 'team' to launch team-wide." "$WORK/out"
ck "scope confirm dispatched nothing" "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck "scope confirm left the marker"    "EP-1 EP-3" "$(jq -r '.members | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "a count without a token asks too" "3" "$(run 1)"

# case 11a: the typed token is the confirmation — the recommendation supplies count, the membership
# snapshot, and the branch; the checkout is not moved and no checkout-wide config is written.
: > "$WORK/dispatches"
ck "prepared launch exits 0"          "0" "$(run epic:ep-1)"
ck_has "prepared prompt scoped"       "/loop /auto epic:EP-1" "$WORK/dispatches"
ck_has "prepared scope announced"     "Using /epic-prep's recommendation for epic EP-1" "$WORK/out"
ck "members are the prep snapshot"    "EP-1 EP-3 EP-9" "$(jq -r '.members | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "branch recorded"                  "epic/ep-1" "$(jq -r '.branch' "$REPO/tmp/fleet-deadline.json")"
ck "base recorded"                    "nextjs-descope-user" "$(jq -r '.base' "$REPO/tmp/fleet-deadline.json")"
ck "no checkout-wide config written"  "" "$(git -C "$REPO" config --get start.wt-source-branch || true)"
ck "main checkout not moved"          "nextjs-descope-user" "$(git -C "$REPO" branch --show-current)"
ck_has "steering surfaced"            "Sessions fork from and merge into epic/ep-1 by ref (per-issue fork keys; the main checkout stays on nextjs-descope-user)" "$WORK/out"
ck_lacks "no detach"                  "detached" "$WORK/out"

# case 11b: a checkout sitting ON the integration branch launches with a WARN — merges would touch its tree.
git -C "$REPO" checkout -q epic/ep-1
: > "$WORK/dispatches"
ck "on-branch launch exits 0"         "0" "$(run epic:ep-1)"
ck_has "on-branch warned"             "WARN: the main checkout is ON the integration branch 'epic/ep-1'" "$WORK/out"
ck "on-branch still dispatched"       "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck "on-branch checkout not moved"     "epic/ep-1" "$(git -C "$REPO" branch --show-current)"
git -C "$REPO" checkout -q nextjs-descope-user

# case 11c: a leftover checkout-wide key naming the same branch (the retired posture) is noted, not refused.
git -C "$REPO" config start.wt-source-branch epic/ep-1
: > "$WORK/dispatches"
ck "same-branch config exits 0"       "0" "$(run epic:ep-1)"
ck_has "same-branch config noted"     "NOTE: start.wt-source-branch=epic/ep-1 is set (the retired parked-checkout posture)" "$WORK/out"
ck "same-branch config left alone"    "epic/ep-1" "$(git -C "$REPO" config --get start.wt-source-branch)"
ck "same-branch checkout not moved"   "nextjs-descope-user" "$(git -C "$REPO" branch --show-current)"
git -C "$REPO" config --unset start.wt-source-branch

# case 11d: a fractional generated_epoch (a python time.time() writer) still announces the count and the staleness WARN.
cp "$REPO/tmp/fleet-recommendation.json" "$WORK/rec.keep"
jq --argjson e "$(( $(date +%s) - 2*86400 ))" '.generated_epoch = $e + 0.412131' "$WORK/rec.keep" > "$REPO/tmp/fleet-recommendation.json"
: > "$WORK/dispatches"
ck "fractional epoch exits 0"         "0" "$(run epic:ep-1)"
ck_lacks "fractional epoch no bash error" "syntax error" "$WORK/out"
ck_has "fractional epoch count announced" "Using /auto-prep's recommendation: 1 session(s)" "$WORK/out"
ck_has "fractional epoch staleness warned" "WARN: that recommendation is 48h old" "$WORK/out"
mv "$WORK/rec.keep" "$REPO/tmp/fleet-recommendation.json"

# case 11e: `team` launches team-wide over the same recommendation — unscoped prompt, no scope in the
# marker, and a WARN that the inherited count was sized for the epic; an explicit count is not warned.
: > "$WORK/dispatches"
ck "team launch exits 0"              "0" "$(run team)"
ck_has "team prompt unscoped"         "/loop /auto" "$WORK/dispatches"
ck_lacks "team prompt carries no epic" "epic:" "$WORK/dispatches"
ck "team marker has no scope"         "" "$(jq -r '.scope // empty' "$REPO/tmp/fleet-deadline.json")"
ck_has "team announced"               "Team-wide launch: ignoring the epic EP-1 scope" "$WORK/out"
ck_has "team count sizing warned"     "WARN: the recommendation's count (1) was sized for epic EP-1 by /epic-prep" "$WORK/out"
: > "$WORK/dispatches"
ck "team with a count exits 0"        "0" "$(run 1 team)"
ck_lacks "explicit count not warned"  "was sized for epic" "$WORK/out"
ck "team and epic refuse"             "1" "$(run team epic:ep-1)"
ck_has "team and epic named"          "ERROR: 'team' and 'epic:EP-1' are mutually exclusive" "$WORK/out"
ck "team and epic dispatched nothing" "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

# case 12: an explicit token overrides the prepared scope — live membership, and no branch, since the
# prep was for another epic.
: > "$WORK/dispatches"
ck "override exits 0"                 "0" "$(run 1 epic:EP-3)"
ck_has "override prompt"              "/loop /auto epic:EP-3" "$WORK/dispatches"
ck "override members live"            "EP-3" "$(jq -r '.members | join(" ")' "$REPO/tmp/fleet-deadline.json")"
ck "override records no branch"       "" "$(jq -r '.branch // empty' "$REPO/tmp/fleet-deadline.json")"

# case 13: an invalid scope refuses before any dispatch or write — the live marker survives.
printf '{"deadline_epoch":9999999999,"deadline":"later","count":3}\n' > "$REPO/tmp/fleet-deadline.json"
: > "$WORK/dispatches"
ck "non-epic scope exits 1"           "1" "$(run 1 epic:EP-2)"
ck "non-epic scope dispatches nothing" "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "non-epic scope names the label" "does not carry the 'epic' label" "$WORK/out"
ck_has "non-epic scope says nothing ran" "nothing was dispatched" "$WORK/out"
ck "live marker survives a scope refusal" "9999999999" "$(jq -r '.deadline_epoch' "$REPO/tmp/fleet-deadline.json")"
ck "missing scope exits 1"            "1" "$(run 1 epic:EP-404)"
ck "malformed token exits 1"          "1" "$(run 1 epic:nope)"
ck "two tokens exit 1"                "1" "$(run 1 epic:EP-1 epic:EP-3)"

# case 14: a prepared branch that no longer exists, or a foreign source-branch config, refuses.
jq '.branch = "epic/gone"' "$REPO/tmp/fleet-recommendation.json" > "$WORK/rec.tmp" && mv "$WORK/rec.tmp" "$REPO/tmp/fleet-recommendation.json"
: > "$WORK/dispatches"
ck "missing branch exits 1"           "1" "$(run epic:ep-1)"
ck_has "missing branch named"         "integration branch 'epic/gone' but no such local branch" "$WORK/out"
jq '.branch = "epic/ep-1"' "$REPO/tmp/fleet-recommendation.json" > "$WORK/rec.tmp" && mv "$WORK/rec.tmp" "$REPO/tmp/fleet-recommendation.json"
git -C "$REPO" config start.wt-source-branch nextjs-descope-user
ck "foreign source-branch config exits 1" "1" "$(run epic:ep-1)"
ck_has "foreign config named"         "start.wt-source-branch is 'nextjs-descope-user'" "$WORK/out"
ck "nothing dispatched across the refusals" "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck "checkout untouched by the refusals" "nextjs-descope-user" "$(git -C "$REPO" branch --show-current)"
git -C "$REPO" config --unset start.wt-source-branch

# case 15: a FLEET_PROMPT override that drops the scope launches as typed, with a WARN.
: > "$WORK/dispatches"
ck "prompt override exits 0"          "0" "$(FLEET_PROMPT='/loop /auto EP' run 1 epic:EP-3)"
ck_has "override dispatched as typed" "/loop /auto EP" "$WORK/dispatches"
ck_has "override warned"              "does not carry epic:EP-3" "$WORK/out"

# case 16: a /fleet-sequence running alongside is discrete from the fleet — the launch proceeds with a NOTE,
# and the ledger expiry leaves the sequence's child sessions alone: its runner re-reads a child's ledger
# across a poll after the child has ended (unlisted in the registry by then), and a launch landing between
# the two reads would otherwise clear it and fail the sequence. A crashed sequence (marker `running`, pid
# gone) protects nothing. The scope token keeps the launch on the checkout's own branch, as in case 15.
rm -f "$REPO"/tmp/auto-state-*.json
dead=$(sh -c 'echo $$')
printf '{"status":"done","queue":["SQ-7"],"runner_pid":%s}\n' "$$" > "$REPO/tmp/fleet-sequence-sq-7.json"
printf '{"status":"running","queue":["SQ-1","SQ-2"],"runner_pid":%s,"issues":{"SQ-1":{"session":"cafe0002"}}}\n' "$$" > "$REPO/tmp/fleet-sequence-sq-1.json"
echo '{"status":"active","mode":"single","shipped":["SQ-1"]}' > "$REPO/tmp/auto-state-cafe0002.json"
echo '{"status":"active","shipped":["XX-9"]}' > "$REPO/tmp/auto-state-dead0002.json"
echo '[]' > "$WORK/agents.json"
: > "$WORK/dispatches"
ck "running sequence does not block"     "0" "$(run 1 epic:EP-3)"
ck "launch alongside dispatched"         "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "running sequence noted"          "NOTE: a /fleet-sequence is running alongside (SQ-1 → SQ-2)" "$WORK/out"
ck "sequence child's ledger kept"        "yes" "$([ -f "$REPO/tmp/auto-state-cafe0002.json" ] && echo yes || echo no)"
ck "unrelated dead ledger still cleared" "no" "$([ -f "$REPO/tmp/auto-state-dead0002.json" ] && echo yes || echo no)"
printf '{"status":"running","queue":["SQ-1"],"runner_pid":%s,"issues":{"SQ-1":{"session":"cafe0002"}}}\n' "$dead" > "$REPO/tmp/fleet-sequence-sq-1.json"
ck "crashed sequence launches too"       "0" "$(run 1 epic:EP-3)"
ck_lacks "crashed sequence not noted"    "running alongside" "$WORK/out"
ck "crashed sequence protects no ledger" "no" "$([ -f "$REPO/tmp/auto-state-cafe0002.json" ] && echo yes || echo no)"
rm -f "$REPO/tmp/fleet-sequence-sq-1.json" "$REPO/tmp/fleet-sequence-sq-7.json" "$REPO"/tmp/auto-state-*.json

# case 17: the `backlog` token (keeper ruling 2026-10-01) rides the prompt — composing with an epic scope —
# and the marker records it for the observers; a launch without it records nothing, and a FLEET_PROMPT
# override that drops it is warned about like a dropped scope. No recommendation on disk, so a bare
# count launches team-wide without the SCOPE-CONFIRM stop.
rm -f "$REPO/tmp/fleet-recommendation.json"
: > "$WORK/dispatches"
ck "backlog launch exits 0"               "0" "$(run 1 backlog)"
ck_has "backlog prompt"                   "/loop /auto backlog" "$WORK/dispatches"
ck "backlog marker"                       "true" "$(jq -r '.backlog' "$REPO/tmp/fleet-deadline.json")"
ck_has "backlog announced"                "Backlog fallback: on" "$WORK/out"
: > "$WORK/dispatches"
ck "backlog with epic exits 0"            "0" "$(run 1 epic:EP-3 BACKLOG)"
ck_has "backlog composes with epic"       "/loop /auto epic:EP-3 backlog" "$WORK/dispatches"
ck "backlog with epic marker"             "EP-3 true" "$(jq -r '"\(.scope) \(.backlog)"' "$REPO/tmp/fleet-deadline.json")"
: > "$WORK/dispatches"
ck "plain launch exits 0"                 "0" "$(run 1)"
ck "plain launch records no backlog"      "" "$(jq -r '.backlog // empty' "$REPO/tmp/fleet-deadline.json")"
ck_lacks "plain prompt carries no backlog" "backlog" "$WORK/dispatches"
ck "override without backlog exits 0"     "0" "$(FLEET_PROMPT='/loop /auto EP' run 1 backlog)"
ck_has "override without backlog warned"  "does not carry backlog" "$WORK/out"

# ---- tooling freshness: a stale ~/.claude refuses before anything is written or dispatched ----
# The prior-run ledger is the write the refusal must precede: the registry is empty, so a launch that got past the
# check would clear it.
stale_setup() {
  rm -f "$REPO/tmp/fleet-deadline.json" "$REPO"/tmp/auto-state-*.json
  echo '{"status":"active","shipped":["XX-7"]}' > "$REPO/tmp/auto-state-dead0003.json"
  echo '[]' > "$WORK/agents.json"
  : > "$WORK/dispatches"
}
claude_fresh
claude_upstream "hooks: recover a lost wakeup" hooks/auto-rewake.sh
stale_setup
ck "stale tooling exits 4"               "4" "$(run 1)"
ck_has "stale tooling named"             "TOOLING-STALE: ~/.claude is 1 commit behind origin/main, including:" "$WORK/out"
ck_has "stale commit listed"             "hooks: recover a lost wakeup" "$WORK/out"
ck_has "stale says nothing ran"          "Nothing was dispatched or written. Run /update and re-launch, or re-run with 'stale-ok'" "$WORK/out"
ck "stale dispatched nothing"            "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck "stale wrote no marker"               "no" "$([ -e "$REPO/tmp/fleet-deadline.json" ] && echo yes || echo no)"
ck "stale cleared no ledger"             "yes" "$([ -f "$REPO/tmp/auto-state-dead0003.json" ] && echo yes || echo no)"

stale_setup
ck "stale-ok exits 0"                    "0" "$(run 1 STALE-OK)"
ck "stale-ok dispatched"                 "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "stale-ok warned"                 "WARN: launching on the stale ~/.claude above (stale-ok)" "$WORK/out"
ck_lacks "stale-ok prompt untouched"     "stale" "$WORK/dispatches"

claude_fresh
claude_upstream "docs: readme" README.md
stale_setup
ck "docs-only behind exits 0"            "0" "$(run 1)"
ck_has "docs-only behind noted"          "NOTE: ~/.claude is 1 commit behind origin/main, none in a file sessions load — launching" "$WORK/out"
ck "docs-only behind dispatched"         "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

claude_fresh
stale_setup
ck "current tooling exits 0"             "0" "$(run 1)"
ck_lacks "current tooling silent"        "~/.claude" "$WORK/out"
ck "current tooling dispatched"          "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

git -C "$CLAUDE_FRESHNESS_DIR" remote set-url origin "$WORK/no-such-origin.git"
stale_setup
ck "unreachable origin exits 0"          "0" "$(run 1)"
ck_has "unreachable origin noted"        "NOTE: could not check ~/.claude freshness (fetch failed) — launching" "$WORK/out"
ck "unreachable origin dispatched"       "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

claude_fresh
echo '{"outputStyle":"local"}' >> "$CLAUDE_FRESHNESS_DIR/settings.json"
claude_upstream "settings: register a hook" settings.json
stale_setup
ck "settings clash exits 4"              "4" "$(run 1)"
ck_has "settings clash names the pull"   "the ~/.claude pull will refuse (settings.json modified locally) — run /keeper first" "$WORK/out"
ck "settings clash dispatched nothing"   "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

# A fetch that hangs is killed at its limit and the launch proceeds; the stub hangs on `fetch` alone.
mkdir -p "$WORK/hangbin"
cat > "$WORK/hangbin/git" <<STUB_GIT
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "fetch" ] && exec sleep 29; done
exec "$(command -v git)" "\$@"
STUB_GIT
chmod +x "$WORK/hangbin/git"
claude_fresh
claude_upstream "hooks: unseen behind a hung fetch" hooks/auto-rewake.sh
stale_setup
start=$SECONDS
ck "hung fetch launch exits 0"           "0" "$(PATH="$WORK/hangbin:$PATH" CLAUDE_FRESHNESS_TIMEOUT=1 run 1)"
ck "hung fetch bounded by the watchdog"  "yes" "$([ $(( SECONDS - start )) -le 5 ] && echo yes || echo "no ($(( SECONDS - start ))s)")"
ck_has "hung fetch noted"                "NOTE: could not check ~/.claude freshness (fetch failed) — launching" "$WORK/out"
ck "hung fetch dispatched"               "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"

# ---- loop-boundary guard: no cap by default; refuse without the mod; an explicit cap softens the refusal to a WARN ----
claude_fresh
: > "$WORK/dispatches"
ck "no-cap launch exits 0"           "0" "$(run 1)"
ck "no-cap launch dispatched"        "1" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_lacks "no default autocompact"    "--autocompact" "$WORK/dispatches"
echo '[{"id":"effort-phase@alienfast-claude","enabled":true}]' > "$WORK/plugins.json"
: > "$WORK/dispatches"
ck "missing mod exits 5"             "5" "$(run 1)"
ck "missing mod dispatches nothing"  "0" "$(wc -l < "$WORK/dispatches" | tr -d ' ')"
ck_has "missing mod names install"   "claude plugin install loop-boundary@alienfast-claude" "$WORK/out"
ck_has "missing mod says nothing ran" "Nothing was dispatched or written." "$WORK/out"
: > "$WORK/dispatches"
ck "explicit cap launches"           "0" "$(run 1 -- --autocompact 700000)"
ck_has "explicit cap warns"          "WARN: launching without the loop-boundary mod" "$WORK/out"
ck_has "explicit cap passes through" "--autocompact 700000" "$WORK/dispatches"
rm -f "$WORK/plugins.json"

# ---- the weekly readout: never silent, never blocking ----
# Read from the rate-limits mod's file under HOME. With no file and no mod (the stub registry lists loop-boundary only) the line
# says both; a reading past 70% warns when the reset falls after the deadline or the launch has none, and only notes when the
# reset falls inside a dated run; below 70% it is the reading alone. Each shape launches.
: > "$WORK/dispatches"
ck "weekly: no file launches"           "0" "$(run 1)"
ck_has "weekly: no file explained"      "Weekly: no reading (" "$WORK/out"
ck_has "weekly: no file names the fix"  "rate-limits@alienfast-claude is not enabled on this machine" "$WORK/out"
mkdir -p "$WORK/home/.claude/local"
iso_at() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
reading() { # <percent> <resets-epoch>
  printf '{"measured_at":"%s","session":"s","windows":[{"kind":"five_hour","percentUsed":12.5},{"kind":"seven_day","percentUsed":%s,"resetsAt":"%s"}]}\n' \
    "$(iso_at "$(date +%s)")" "$1" "$(iso_at "$2")" > "$WORK/home/.claude/local/rate-limits.json"
}
far=$(( $(date +%s) + 3 * 86400 ))
reading 71 "$far"
ck "weekly: reading launches"           "0" "$(run 1)"
ck_has "weekly: reading printed"        "Weekly (seven_day): 71% used, resets $(iso_at "$far"), measured 0m ago" "$WORK/out"
ck_has "weekly: undated past 70 warns"  "WARN: the weekly window is 71% used" "$WORK/out"
ck "weekly: dated, reset after, launches" "0" "$(run 1 5h)"
ck_has "weekly: reset after deadline warns" "WARN: the weekly window is 71% used" "$WORK/out"
reading 71 $(( $(date +%s) + 3600 ))
ck "weekly: dated, reset inside, launches" "0" "$(run 1 5h)"
ck_has "weekly: reset inside run notes"  "NOTE: the weekly window is 71% used but resets before this fleet's deadline" "$WORK/out"
ck_lacks "weekly: reset inside run no warn" "WARN: the weekly window" "$WORK/out"
reading 30 "$far"
ck "weekly: low launches"                "0" "$(run 1)"
ck_has "weekly: low printed"             "Weekly (seven_day): 30% used" "$WORK/out"
ck_lacks "weekly: low says nothing more" "the weekly window is" "$WORK/out"
printf '{"measured_at":"%s","session":"s","windows":[{"kind":"five_hour","percentUsed":1}]}\n' "$(iso_at "$(date +%s)")" > "$WORK/home/.claude/local/rate-limits.json"
ck "weekly: no seven_day launches"       "0" "$(run 1)"
ck_has "weekly: no seven_day explained"  "Weekly: no reading (the last measurement in" "$WORK/out"
echo 'not json' > "$WORK/home/.claude/local/rate-limits.json"
ck "weekly: unreadable launches"         "0" "$(run 1)"
ck_has "weekly: unreadable explained"    "is not readable JSON)" "$WORK/out"
rm -rf "$WORK/home/.claude"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
