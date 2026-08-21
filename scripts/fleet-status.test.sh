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
ck_has "  own pid reads ALIVE" "| sess-a | ALIVE (pid $$)" "$OUT"
ck_has "  ledger tallies in the row" "| XX-1, XX-2 | XX-5 | XX-4 | 2 |" "$OUT"
ck_has "  bogus pid reads dead" "| sess-b | dead | active" "$OUT"
ck_has "  dead+active flagged" 'Session sess-b reads `active` but its process is gone' "$OUT"
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

echo "== 6. scoping — prior-run ledgers hidden, launch-second tie shown"
NOW=$(date +%s)
T=$((NOW - 50))
write_marker "$T" $((NOW + 3600))
jq -n '{status: "drained"}' > "$REPO/tmp/auto-state-old.json"
touch -t "$(stamp $((T - 100)))" "$REPO/tmp/auto-state-old.json"
jq -n '{status: "drained"}' > "$REPO/tmp/auto-state-tie.json"
touch -t "$(stamp "$T")" "$REPO/tmp/auto-state-tie.json"
run_fs --no-runway
ck_has "  strictly-older ledger hidden, with count" "_1 prior-run ledger(s) hidden" "$OUT"
ck_lacks "  hidden ledger has no row" "| old |" "$OUT"
# The tie (mtime == launch_epoch) is SHOWN: scoping hides strictly-older ledgers only. If scoping
# ever excludes ties, this arm flips with it — deliberately, not as collateral.
ck_has "  launch-second tie still shown" "| tie | dead | drained" "$OUT"

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

echo ""
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
