#!/usr/bin/env bash
# Regression suite for linear-set-state.sh. Fixture-pins the three verification outcomes per
# issue (wrapped update verifies by read-back; stale read-back rescued by the raw-mutation
# fallback whose own response carries the state; both missing -> FAILED line + exit 2), plus
# case-insensitive exact state resolution, the unknown-state and unresolvable-team aborts
# (exit 1, prior verified lines stand), the not-an-issue-key line, and usage. linear-cli is a
# PATH shim; HOME is an empty dir so the script's cargo-bin PATH prepend cannot resurrect the
# real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-set-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

cat > "$FIX/statuses-TT.json" <<'EOF'
{"statuses":[{"name":"Backlog","id":"st-backlog"},{"name":"Planned","id":"st-planned"},{"name":"In Progress","id":"st-inprog"}]}
EOF
# TT-1: wrapped update took (read-back already shows the target).
cat > "$FIX/get-TT-1.json" <<'EOF'
{"id":"uuid-TT-1","identifier":"TT-1","state":{"name":"Planned"}}
EOF
# TT-2: gotcha #8 — read-back stale; the raw-mutation fallback lands it.
cat > "$FIX/get-TT-2.json" <<'EOF'
{"id":"uuid-TT-2","identifier":"TT-2","state":{"name":"Backlog"}}
EOF
# TT-3: read-back stale AND the fallback's response still shows the old state.
cat > "$FIX/get-TT-3.json" <<'EOF'
{"id":"uuid-TT-3","identifier":"TT-3","state":{"name":"Backlog"}}
EOF
cat > "$FIX/mutate-ok.json" <<'EOF'
{"data":{"issueUpdate":{"success":true,"issue":{"state":{"name":"Planned"}}}}}
EOF
cat > "$FIX/mutate-stale.json" <<'EOF'
{"data":{"issueUpdate":{"success":true,"issue":{"state":{"name":"Backlog"}}}}}
EOF

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "statuses list")
    [ -f "\$FIX/statuses-\${4:-}.json" ] || exit 1
    cat "\$FIX/statuses-\${4:-}.json" ;;
  "issues update") exit 0 ;;
  "issues get")
    [ -f "\$FIX/get-\${3:-}.json" ] || exit 1
    cat "\$FIX/get-\${3:-}.json" ;;
  "api mutate")
    for a in "\$@"; do
      case "\$a" in
        id=uuid-TT-2) cat "\$FIX/mutate-ok.json"; exit 0 ;;
        id=uuid-TT-3) cat "\$FIX/mutate-stale.json"; exit 0 ;;
      esac
    done
    exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" "$@"; }

# ---- one batch covering all three per-issue outcomes plus a malformed key ----
OUT="$WORK/out.txt"
run Planned TT-1 TT-2 TT-3 foo > "$OUT" 2>"$OUT.err"
ck "mixed batch exits 2" "2" "$?"
ck "read-back verified"      "TT-1 -> Planned" "$(sed -n 1p "$OUT")"
ck "fallback rescued"        "TT-2 -> Planned" "$(sed -n 2p "$OUT")"
ck "unverified is FAILED"    "TT-3 -> FAILED (reads 'Backlog', wanted 'Planned')" "$(sed -n 3p "$OUT")"
ck "malformed key is FAILED" "foo -> FAILED (not an issue key)" "$(sed -n 4p "$OUT")"

# ---- all-good batch exits 0; state name resolves case-insensitively to the team's casing ----
OUT2="$WORK/out2.txt"
run planned TT-1 TT-2 > "$OUT2" 2>/dev/null
ck "clean batch exits 0" "0" "$?"
ck "lowercase input resolves to exact state" "TT-1 -> Planned" "$(sed -n 1p "$OUT2")"

# ---- resolution failures abort with exit 1; already-verified lines stand ----
OUT3="$WORK/out3.txt"
run Shipped TT-1 > "$OUT3" 2>"$OUT3.err"
ck "unknown state exits 1" "1" "$?"
ck_has "unknown state names the miss" "has no state named 'Shipped'" "$OUT3.err"
ck_has "unknown state lists available" "Available: Backlog, Planned, In Progress" "$OUT3.err"

OUT4="$WORK/out4.txt"
run Planned TT-1 XX-1 > "$OUT4" 2>"$OUT4.err"
ck "unresolvable team exits 1" "1" "$?"
ck "verified line before the abort stands" "TT-1 -> Planned" "$(sed -n 1p "$OUT4")"
ck_has "unresolvable team names the team" "could not list workflow states for team 'XX'" "$OUT4.err"

if run Planned >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: single-arg exited 0"; else PASS=$((PASS+1)); fi
if run >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: no-args exited 0"; else PASS=$((PASS+1)); fi

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
