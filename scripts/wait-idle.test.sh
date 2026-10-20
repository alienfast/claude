#!/bin/zsh
# Regression suite for wait-idle.sh — the idle gate /pr-merge-deferred waits on. Drives `--once` against a fixture
# checkout (PRM_MAIN_CHECKOUT) and a fixture registry (PRM_REGISTRY_JSON); nothing here shells out to `claude`.
#
# The load-bearing cases are the 2026-10-04 shapes: a fleet member whose ledger reads `drained` while the registry
# still lists it `working` (the gate held a merge all morning on exactly that), and the row `claude stop` leaves
# behind — state unchanged, `status` and `pid` gone beside live rows that carry `status`. The status-less-schema case
# pins the fail-toward-busy side: the same key-less row in a registry where NO row carries `status` is an older
# schema, not a death. Cases 10-12 are the 2026-10-17 shape: a worktree stamp gates only through the registry, never
# through the stamped pid, which for a background session deleted from `claude agents` is the still-running daemon's.
set -u
cd "$(dirname "$0")" || exit 1
SCRIPT=./wait-idle.sh
TMP=$(mktemp -d)
NODEPID=""
trap '[ -n "$NODEPID" ] && kill $NODEPID 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

MAIN="$TMP/repo"; mkdir -p "$MAIN/tmp"
REG="$TMP/agents.json"
export PRM_MAIN_CHECKOUT="$MAIN" PRM_REGISTRY_JSON="$REG"
unset CLAUDE_CODE_SESSION_ID

ck() { # ck <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want [%s] got [%s]\n' "$1" "$2" "$3"; fi
}
ck_has() { # ck_has <name> <needle> <haystack>
  if print -r -- "$3" | grep -qF -- "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — missing [%s] in [%s]\n' "$1" "$2" "$3"; fi
}
once() { OUT=$("$SCRIPT" --once 2>&1); RC=$?; }
reset() { rm -f "$MAIN"/tmp/*.json(N); echo '[]' > "$REG"; }
ledger() { printf '{"status":"%s","shipped":[]}\n' "$2" > "$MAIN/tmp/auto-state-$1.json"; }
marker() { jq -n --arg s "$1" '{fleet_sessions: ($s | split(" ")), count: 1, launch_epoch: 1}' > "$MAIN/tmp/fleet-deadline.json"; }
row_live()    { printf '{"id":"%s","cwd":"%s","kind":"background","sessionId":"%s-0000-4000-8000-000000000000","name":"loop auto backlog","status":"idle","state":"working","pid":1}' "$1" "$MAIN" "$1"; }
row_stopped() { printf '{"id":"%s","cwd":"%s","kind":"background","sessionId":"%s-0000-4000-8000-000000000000","name":"loop auto backlog","state":"working"}' "$1" "$MAIN" "$1"; }
row_done()    { printf '{"id":"%s","cwd":"%s","kind":"background","sessionId":"%s-0000-4000-8000-000000000000","name":"n","status":"idle","state":"done"}' "$1" "$MAIN" "$1"; }

echo "wait-idle.sh"

reset
once
ck "1 nothing anywhere -> FLEET-IDLE, exit 0"                        0 "$RC"
ck_has "1 ... says so"                                               "FLEET-IDLE:" "$OUT"

reset; marker "a1000000"; ledger a1000000 active; printf '[%s]' "$(row_live a1000000)" > "$REG"
once
ck "2 live member with an active ledger -> BUSY, exit 3"             3 "$RC"
ck_has "2 ... fleet-session signal"                                  "fleet-session a1000000" "$OUT"
ck_has "2 ... auto-ledger signal"                                    "auto-ledger a1000000" "$OUT"
ck_has "2 ... background-session signal (joined by id)"              "background-session loop auto backlog (working" "$OUT"

ledger a1000000 drained
once
ck "3 same member, ledger drained -> FLEET-IDLE (finished outranks the registry)" 0 "$RC"
ck_has "3 ... the finished session is named, not waited on"          "finished, ledger terminal: loop auto backlog (working" "$OUT"

ledger a1000000 halted
once
ck "4 ... halted counts as finished too"                             0 "$RC"

reset; marker "a1000000 b2000000"; ledger a1000000 active; ledger b2000000 active
printf '[%s,%s]' "$(row_live a1000000)" "$(row_stopped b2000000)" > "$REG"
once
ck "5 a stopped row beside a live one is not alive -> only the live member gates" 3 "$RC"
ck_has "5 ... live member listed"                                    "fleet-session a1000000" "$OUT"
ck "5 ... stopped member absent from the line"                       0 "$(print -r -- "$OUT" | grep -c 'b2000000')"

reset; marker "b2000000"; ledger b2000000 active; printf '[%s]' "$(row_stopped b2000000)" > "$REG"
once
ck "6 a key-less row in a status-less schema reads live -> BUSY (fail toward busy)" 3 "$RC"
ck_has "6 ... as a fleet member"                                     "fleet-session b2000000" "$OUT"

reset; marker "c3000000"; ledger c3000000 active; printf '[%s]' "$(row_done c3000000)" > "$REG"
once
ck "7 a done row is ended -> FLEET-IDLE"                             0 "$RC"

reset; printf '[%s]' "$(row_live d4000000)" > "$REG"
once
ck "8 a background session rooted here that joins to nothing does not gate" 0 "$RC"
ck_has "8 ... but is reported"                                       "not waiting on: loop auto backlog (working" "$OUT"

reset; printf 'not json' > "$REG"
once
ck "9 unreadable registry -> REGISTRY-UNAVAILABLE, exit 2"           2 "$RC"

# The live node process stands in for the shared daemon: its comm passes wt_owner_alive's claude|node test and the
# fixture owner has no job dir, so a pid-based check reads this stamp alive — which is what turns 10 and 11 red against it.
WTMAIN="$TMP/wtrepo"; WT="$WTMAIN/.claude/worktrees/bf-9999"
git init -q "$WTMAIN" && git -C "$WTMAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WTMAIN" config extensions.worktreeConfig true
git -C "$WTMAIN" worktree add -q "$WT" -b wt 2>/dev/null
mkdir -p "$WTMAIN/tmp"
command -v node >/dev/null 2>&1 && { node -e 'setTimeout(() => {}, 600000)' & NODEPID=$!; }
git -C "$WT" config --worktree start.owner-session e5000000
git -C "$WT" config --worktree start.owner-pid "${NODEPID:-$$}"
git -C "$WT" config --worktree start.owner-claimed-at "$(date +%s)"
export PRM_MAIN_CHECKOUT="$WTMAIN"
row_at() { printf '{"id":"%s","cwd":"%s","kind":"%s","sessionId":"%s-0000-4000-8000-000000000000","name":"%s","status":"busy","state":"working","pid":1}' "$1" "$2" "$3" "$1" "$4"; }

echo '[]' > "$REG"
once
ck "10 a worktree stamped by a session the registry does not list -> FLEET-IDLE" 0 "$RC"

printf '[%s]' "$(row_at e5000000 "$WT" interactive "operator start wt")" > "$REG"
once
ck "11 ... stamped by a live INTERACTIVE session -> FLEET-IDLE (the operator's /start wt does not gate)" 0 "$RC"

printf '[%s]' "$(row_at e5000000 "$WT" background "bf-9999 auto")" > "$REG"
once
ck "12 ... stamped by a live BACKGROUND session rooted in the worktree -> BUSY" 3 "$RC"
ck_has "12 ... through the registry join"                            "background-session bf-9999 auto (working" "$OUT"
export PRM_MAIN_CHECKOUT="$MAIN"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
