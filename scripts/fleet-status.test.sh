#!/usr/bin/env bash
# Functional suite for fleet-status.sh — the operator's only during-view of a running fleet. Hermetic:
# a throwaway git repo stands in for the project, HOME is faked so the script's own `$HOME/.cargo/bin`
# prepend resolves to a controlled stub dir, and PATH is reduced to git/jq/system so the machine's real
# linear-cli can never leak into a case. Every section's fixture is driven end to end through the real
# script; nothing is sourced or mocked internally.
#
# GROW THIS SUITE, NEVER PRUNE IT.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-status.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

for cmd in git jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "SKIP: '$cmd' not available"; exit 0; }
done

PASS=0 FAIL=0
ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
}

REPO="$ROOT/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@test.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit -q --allow-empty -m "init"
git -C "$REPO" commit -q --allow-empty -m "XX-1: land the widget"

FHOME="$ROOT/home"
STUB="$FHOME/.cargo/bin"
mkdir -p "$STUB"
RUNPATH="$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin"

OUT="$ROOT/out.md" ERR="$ROOT/err.log" RC=0
run_fs() {
  (cd "$REPO" && env HOME="$FHOME" PATH="$RUNPATH" bash "$SCRIPT" "$@" > "$OUT" 2> "$ERR")
  RC=$?
}
stamp() { python3 -c 'import time,sys; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(int(sys.argv[1]))))' "$1"; }
write_marker() { # write_marker <launch_epoch> [deadline_epoch] [stopped]
  jq -n --argjson le "$1" --argjson de "${2:-0}" --argjson st "${3:-false}" \
    '{deadline: "test-deadline", count: 3, launch_epoch: $le, stopped: $st}
     + (if $de > 0 then {deadline_epoch: $de} else {} end)' > "$REPO/tmp/fleet-deadline.json"
}

echo "== 1. usage"
run_fs --bogus
ck "unknown flag exits 1" "1" "$RC"
ck_has "  usage line printed" "usage: fleet-status.sh" "$ERR"

echo "== 2. bare repo — every empty-state line"
run_fs --no-runway
ck "clean exit" "0" "$RC"
ck_has "  no marker -> no deadline" "**Deadline:** none" "$OUT"
ck_has "  no ledgers" "_No auto-state files" "$OUT"
ck_has "  no worktrees" "_No live worktrees" "$OUT"
ck_has "  no ships recorded" "_No session has recorded a ship here._" "$OUT"
ck_has "  runway honors --no-runway" "_Skipped (--no-runway)._" "$OUT"
ck_lacks "  empty merge queue omitted" "### Merge queue" "$OUT"

echo "== 3. live fleet — sessions, in-flight, shipped joins, Linear-down rows"
mkdir -p "$REPO/tmp" "$REPO/.claude/worktree-identity"
NOW=$(date +%s)
write_marker $((NOW - 500)) $((NOW + 7230))
LSTART=$(ps -p $$ -o lstart= | tr -s ' ' | sed 's/^ //;s/ $//')
jq -n --argjson pid "$$" --arg ps "$LSTART" \
  '{pid: $pid, pidStart: $ps, status: "active", shipped: ["XX-1","XX-2"], canceled: ["XX-5"], failed: ["XX-4"], reviewBlocks: 2}' \
  > "$REPO/tmp/auto-state-sess-a.json"
jq -n '{pid: 999999999, pidStart: "never", status: "active", shipped: [], canceled: [], failed: [], reviewBlocks: 0}' \
  > "$REPO/tmp/auto-state-sess-b.json"
git -C "$REPO" worktree add "$REPO/.claude/worktrees/xx-3" -b xx-3 >/dev/null 2>&1
printf 'WT_IDENTITY_OWNER=sess-a\n' > "$REPO/.claude/worktree-identity/wt-identity-xx-3.env"
# Stub linear-cli: the stalled sweep answers with one canned issue; every other subcommand fails, which
# is the "Linear state unavailable" path for the failed/canceled joins and an empty in-flight state bit.
cat > "$STUB/linear-cli" <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in
  "issues list") echo '[{"identifier":"XX-9","state":{"name":"In Progress"},"title":"stuck mid-flight"}]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/linear-cli"
run_fs --no-runway
ck "clean exit" "0" "$RC"
ck_has "  remaining time computed" "2h00m remaining" "$OUT"
ck_has "  launched count shown" "(3 session(s) launched)" "$OUT"
ck_has "  no registry -> unknown, never ALIVE" "| sess-a | unknown (no registry; pid live)" "$OUT"
ck_has "  ledger tallies in the row" "| XX-1, XX-2 | XX-5 | XX-4 | 2 |" "$OUT"
ck_has "  no registry -> unknown, never dead" "| sess-b | unknown (no registry; pid dead)" "$OUT"
# The pid heuristic alone must NEVER raise the stranded-claim flag: acting on it would release a
# live session's Linear claim and reap its worktree. Only a registry-confirmed absence may flag.
ck_lacks "  no registry -> no stranded-claim flag" 'reads `active` but its process is gone' "$OUT"
ck_has "  in-flight worktree listed" "- **XX-3**" "$OUT"
ck_has "  in-flight branch shown" 'branch `xx-3`' "$OUT"
ck_has "  sidecar owner joined" "session sess-a" "$OUT"
ck_has "  shipped-with-commit resolves" "- XX-1 — merged on" "$OUT"
ck_has "  shipped-without-commit flagged" "- XX-2 — ⚠️ recorded shipped but no commit found" "$OUT"
ck_has "  failed row survives Linear-down" "- XX-4 — recorded failed (session sess-a); Linear state unavailable" "$OUT"
ck_has "  canceled row survives Linear-down" "- XX-5 — recorded canceled (session sess-a); Linear state unavailable" "$OUT"
ck_has "  team inferred, stalled surfaced" '### Needs attention — `stalled`' "$OUT"
ck_has "  stalled issue named" "**XX-9**" "$OUT"
ck_lacks "  nothing hidden by scoping" "prior-run ledger" "$OUT"

echo "== 4. passed deadline"
write_marker $((NOW - 500)) $((NOW - 100))
run_fs --no-runway
ck_has "  passed wording" "— **passed**" "$OUT"

echo "== 5. stopped marker"
write_marker $((NOW - 500)) 0 true
run_fs --no-runway
ck_has "  wind-down banner" "**Deadline: STOPPED**" "$OUT"

echo "== 6. scoping — prior-run ledgers hidden, launch-second tie hidden too"
NOW=$(date +%s)
T=$((NOW - 50))
write_marker "$T" $((NOW + 3600))
jq -n '{status: "drained"}' > "$REPO/tmp/auto-state-old.json"
touch -t "$(stamp $((T - 100)))" "$REPO/tmp/auto-state-old.json"
jq -n '{status: "drained"}' > "$REPO/tmp/auto-state-tie.json"
touch -t "$(stamp "$T")" "$REPO/tmp/auto-state-tie.json"
run_fs --no-runway
ck_has "  both prior-run ledgers hidden, with count" "_2 prior-run ledger(s) hidden" "$OUT"
ck_lacks "  hidden ledger has no row" "| old |" "$OUT"
# The tie (mtime == launch_epoch) is HIDDEN: launch_epoch is stamped at dispatch, so a ledger whose
# last write lands in that same second was written by a session not yet dispatched — prior-run
# history. Scoping hides `mtime <= launch_epoch`. If scoping ever admits ties again, this arm flips
# with it — deliberately, not as collateral.
ck_lacks "  launch-second tie hidden too" "| tie |" "$OUT"

echo "== 7. future launch_epoch — all ledgers prior-run"
write_marker $((NOW + 1000)) $((NOW + 3600))
run_fs --no-runway
ck_has "  fleet-has-no-ledger wording" "_No ledger from this fleet yet" "$OUT"
ck_has "  all four hidden" "_4 prior-run ledger(s) hidden" "$OUT"

echo "== 8. linear-cli absent — joins degrade, never lie"
write_marker $((NOW - 500)) $((NOW + 3600))
rm "$STUB/linear-cli"
run_fs --no-runway
ck "clean exit without linear-cli" "0" "$RC"
ck_has "  cross-check disclosed as skipped" "_linear-cli unavailable — entries not cross-checked._" "$OUT"
ck_lacks "  no stalled sweep without linear-cli" "Needs attention" "$OUT"

# `claude agents --json` stub. Shape re-snapshotted from the live feed 2026-08-25: `id` is the
# 8-char short id that matches the ledger filename key, `pid` is present on only some rows, and
# `state` can be null — the fixture keeps all three properties because the join depends on them.
write_agents() { # write_agents <json-array>
  printf '%s' "$1" > "$ROOT/agents.json"
  printf '#!/bin/bash\n[ "${1:-}" = "agents" ] || exit 1\ncat %s\n' "$ROOT/agents.json" > "$STUB/claude"
  chmod +x "$STUB/claude"
}

echo "== 9. registry present — a bogus recorded pid does NOT mean dead"
write_marker $((NOW - 500)) $((NOW + 3600))
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working","pid":111,"status":"busy"},
               {"id":"sess-b","cwd":"/x","kind":"background","sessionId":"sess-b-full","name":"n","state":null}]'
run_fs --no-runway
ck "clean exit" "0" "$RC"
# sess-b's ledger pid is 999999999 and has never existed. Pre-fix this row read `dead` and raised
# the stranded-claim flag; the registry says the session is live. This is the Defect A regression.
ck_has "  registry overrides a dead recorded pid" "| sess-b | ALIVE (running) |" "$OUT"
ck_has "  registry state rendered, not a pid" "| sess-a | ALIVE (working) |" "$OUT"
ck_lacks "  no stranded-claim flag when registry confirms life" 'reads `active` but its process is gone' "$OUT"

echo "== 10. registry present but omits a session — that IS death"
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working"}]'
run_fs --no-runway
ck_has "  absent from registry reads dead" "| sess-b | dead | active" "$OUT"
ck_has "  and only then is it flagged" 'Session sess-b reads `active` but its process is gone' "$OUT"
ck_lacks "  the live one is not flagged" "Session sess-a reads" "$OUT"

echo "== 11. two ledgers sharing one recorded pid resolve independently"
# The fleet-root pid is shared by every session in a fleet, so a shared value must not make two
# sessions share a verdict. sess-c carries sess-a's exact pid/pidStart and is absent from the registry.
jq -n --argjson pid "$$" --arg ps "$LSTART" \
  '{pid: $pid, pidStart: $ps, status: "active", shipped: [], canceled: [], failed: [], reviewBlocks: 0}' \
  > "$REPO/tmp/auto-state-sess-c.json"
run_fs --no-runway
ck_has "  registry-listed sibling is ALIVE" "| sess-a | ALIVE (working) |" "$OUT"
ck_has "  same-pid sibling absent from registry is dead" "| sess-c | dead | active" "$OUT"
rm -f "$REPO/tmp/auto-state-sess-c.json"

echo "== 12. a LEDGER-LESS /AUTO session gets a row; an interactive worktree owner does not"
# Resolve the projects dir exactly as the script does, so the mangled name matches on macOS where
# mktemp's /var/folders is a symlink to /private/var/folders.
MANGLED=$( (cd "$REPO" && git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}') | tr / - )
PDIR="$FHOME/.claude/projects/$MANGLED"
mkdir -p "$PDIR"

git -C "$REPO" worktree add "$REPO/.claude/worktrees/xx-7" -b xx-7 >/dev/null 2>&1
printf 'WT_IDENTITY_OWNER=a1b2c3d4-9722-4503-9f27-d7156e65ecfb\n' > "$REPO/.claude/worktree-identity/wt-identity-xx-7.env"
# Opening turn re-snapshotted from a real fleet transcript 2026-08-25: content is a single string
# carrying EMBEDDED NEWLINES. A single-line hand-written version passes while the script is broken.
printf '%s\n' '{"type":"user","timestamp":"2026-08-25T10:00:00Z","message":{"role":"user","content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>/auto</command-args>"}}' > "$PDIR/a1b2c3d4-0000.jsonl"

# The narrowing this case exists to pin: an INTERACTIVE session holding a worktree here is the
# operator's own work, not a fleet member that lost its ledger. Its transcript opens with a typed
# bug report and mentions /auto only on a LATER turn — which must not count, because the verdict
# comes from the first human turn (mirroring fleet-metrics.py's is_auto_session). Measured
# 2026-08-25: the operator's own session was read as a fourth fleet member for a whole retro.
git -C "$REPO" worktree add "$REPO/.claude/worktrees/xx-8" -b xx-8 >/dev/null 2>&1
printf 'WT_IDENTITY_OWNER=beefcafe-1111-2222-3333-444455556666\n' > "$REPO/.claude/worktree-identity/wt-identity-xx-8.env"
cat > "$PDIR/beefcafe-0000.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-08-25T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"batch import hangs on every third order"}]}}
{"type":"user","timestamp":"2026-08-25T11:00:00Z","message":{"role":"user","content":"<command-name>/auto</command-name>"}}
JSONL

# A sidecar whose worktree is gone must NOT produce a row — the directory keeps one per worktree
# ever created, so an ungated glob yields every session that ever touched the repo.
printf 'WT_IDENTITY_OWNER=sess-stale\n' > "$REPO/.claude/worktree-identity/wt-identity-xx-99.env"
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working"},
               {"id":"beefcafe","cwd":"/x","kind":"background","sessionId":"beefcafe-full","name":"n","state":"working"},
               {"id":"a1b2c3d4","cwd":"/x","kind":"background","sessionId":"a1b2c3d4-9722-4503-9f27-d7156e65ecfb","name":"n","state":"working"}]'
run_fs --no-runway
ck "clean exit" "0" "$RC"
# The owner is recorded as a full uuid here and as a short id on xx-3; both must normalize to the
# short id the ledger filenames and the registry use.
ck_has "  ledger-less /auto session rowed" "| a1b2c3d4 | ALIVE (working) | **no ledger** |" "$OUT"
ck_has "  its uncounted work disclosed" "have written no \`auto-state\` ledger" "$OUT"
# beefcafe IS in the registry and DOES own a live worktree, so only the /auto gate can exclude it
# from the SESSIONS table. It still belongs in the In-flight list, which reports who holds a
# worktree regardless of how that session was started — assert both halves, or a fix that dropped
# the worktree entirely would pass.
ck_lacks "  interactive owner gets no session row" "| beefcafe |" "$OUT"
ck_has   "  but its worktree is still in-flight" "session beefcafe-1111" "$OUT"
ck_lacks "  stale sidecar produces no row" "sess-stale" "$OUT"
rm -f "$REPO/.claude/worktree-identity/wt-identity-xx-99.env"

echo "== 13. a registry row WITHOUT an id joins on the sessionId prefix"
# Live shape 2026-08-29: `--bg` rows carry `id`, interactive rows do not, and the 2026-08-17 snapshot
# auto-stall-watch.sh was rebuilt against had none at all. A targeted /auto run in a terminal is
# exactly a ledger whose registry row has no `id`: keyed on `.id` alone it read `dead` with the
# registry present and raised the stranded-claim flag — the false death the join exists to prevent.
jq -n '{status: "active", shipped: [], canceled: [], failed: [], reviewBlocks: 0}' > "$REPO/tmp/auto-state-c0ffee01.json"
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working"},
               {"cwd":"/x","kind":"interactive","sessionId":"c0ffee01-1111-4222-8333-444455556666","name":"n","pid":1,"startedAt":1}]'
run_fs --no-runway
ck "clean exit" "0" "$RC"
ck_has "  id-less row joins on the sessionId prefix" "| c0ffee01 | ALIVE (running) | active" "$OUT"
ck_lacks "  and raises no stranded-claim flag" 'Session c0ffee01 reads `active`' "$OUT"
rm -f "$REPO/tmp/auto-state-c0ffee01.json"

echo "== 14. a marker carrying fleet_sessions scopes by membership; single-run ledgers never row"
# Every launch since 2026-08-29 records the set. sess-a is a member; sess-b (a loop ledger newer than
# launch_epoch) is not — under the mtime scope it rowed as a fleet session, which is how a 3-session
# fleet retro'd as 21. sess-z is a member with no ledger yet (preflight). c0ffee02 is a single run.
jq -n --argjson le "$((NOW - 500))" '{count: 2, launch_epoch: $le, fleet_sessions: ["sess-a", "sess-z"]}' > "$REPO/tmp/fleet-deadline.json"
jq -n '{status: "active", mode: "single", shipped: ["XX-9"], canceled: [], failed: [], reviewBlocks: 0}' > "$REPO/tmp/auto-state-c0ffee02.json"
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working"},
               {"id":"sess-z","cwd":"/x","kind":"background","sessionId":"sess-z-full","name":"n","state":"working"},
               {"id":"sess-b","cwd":"/x","kind":"background","sessionId":"sess-b-full","name":"n","state":"working"}]'
run_fs --no-runway
ck "clean exit" "0" "$RC"
ck_has "  undated marker reads as no deadline, with the set size" "**Deadline:** none — loops run until the certified backlog drains. (2 session(s) in the fleet)" "$OUT"
ck_has "  member rowed"                       "| sess-a | ALIVE (working) |" "$OUT"
ck_lacks "  non-member loop ledger not rowed" "| sess-b |" "$OUT"
# old, tie and sess-b: every ledger outside the set, whatever its mtime.
ck_has "  non-members counted as hidden"      "3 prior-run ledger(s) hidden" "$OUT"
ck_lacks "  single-run ledger not rowed"      "| c0ffee02 |" "$OUT"
ck_has "  single-run ledger disclosed"        "1 single-run ledger(s) not listed" "$OUT"
ck_has "  member without a ledger rowed"      "| sess-z | ALIVE (working) | **no ledger** |" "$OUT"
rm -f "$REPO/tmp/auto-state-c0ffee02.json"

echo "== 15. a registry row in state done is an ended session, not a live one"
# `claude agents --json` keeps listing a finished background session with state "done" (measured
# 2026-08-29), so listed is not alive: an active ledger on a done row is the stranded-claim shape.
write_marker $((NOW - 500)) $((NOW + 3600))
write_agents '[{"id":"sess-a","cwd":"/x","kind":"background","sessionId":"sess-a-full","name":"n","state":"working"},
               {"id":"sess-b","cwd":"/x","kind":"background","sessionId":"sess-b-full","name":"n","state":"done"}]'
run_fs --no-runway
ck "clean exit" "0" "$RC"
ck_has "  done row reads dead"                "| sess-b | dead (ended) | active" "$OUT"
ck_has "  and the stranded-claim flag fires"  'Session sess-b reads `active` but its process is gone' "$OUT"

echo ""
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
