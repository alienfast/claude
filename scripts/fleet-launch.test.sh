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
# invocation — the refusal cases assert it was never called, which is the property that matters.
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
echo "\$@" >> "$WORK/dispatches"
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

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
