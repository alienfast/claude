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
# `claude agents` is answered from $WORK/agents.json (empty array when absent).
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
echo "\$@" >> "$WORK/dispatches"
n=\$(( \$(cat "$WORK/seq" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/seq"
printf 'backgrounded · \033[36mab%06d\033[39m\n\033[2m  claude agents             list sessions\033[22m\n\033[2m  claude attach ab%06d    open in this terminal\033[22m\n' "\$n" "\$n"
exit 0
EOF
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"
export FLEET_STAGGER_TIMEOUT=0

# ---- fixture repo ----
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# tmp/ is gitignored in every real project; without this the marker the script writes reads as dirt.
echo 'tmp/' >> "$REPO/.git/info/exclude"
git -C "$REPO" checkout -q -b nextjs-descope-user   # no issue ID — the 2026-08-04 branch shape
run() { ( cd "$REPO" && "$SCRIPT" "$@" ) >"$WORK/out" 2>&1; echo $?; }

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
loop_mtime=$(stat -f %m "$REPO/tmp/auto-state-ab000001.json" 2>/dev/null || stat -c %m "$REPO/tmp/auto-state-ab000001.json")
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

# ---- case 9: an unreadable --bg output warns and launches anyway ----
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
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

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
