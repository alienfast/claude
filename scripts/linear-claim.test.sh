#!/usr/bin/env bash
# Regression suite for linear-claim.sh. Fixture-pins the three outcomes the script exists to keep
# apart — CLAIMED (read-back confirms), NOT-CLAIMED (read-back confirms the write did NOT land, after
# the idempotent retry), UNCONFIRMED (the READ ITSELF failed, which is not a failed claim) — plus the
# intermittent case gotcha #8 describes (first assign silently no-ops, the retry lands it), the
# viewer-unresolvable abort, display-name-vs-email matching, state delegation to linear-set-state.sh in
# both directions, and usage. linear-cli is a PATH shim; HOME is an empty dir so the script's cargo-bin
# PATH prepend cannot resurrect the real CLI. No network, no Linear writes.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-claim.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_pre() { # ck_pre <label> <expected-prefix> <actual>
  case "$3" in "$2"*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: $1 — expected prefix [$2] got [$3]" ;; esac
}

FIX="$WORK/fix"; mkdir -p "$FIX" "$WORK/bin" "$WORK/home"
export HOME="$WORK/home"

cat > "$FIX/viewer.json" <<'EOF'
{"data":{"viewer":{"name":"kevin.ross@example.com","email":"kevin.ross@example.com"}}}
EOF
# A viewer whose DISPLAY NAME is not their email — the shape a naive email-only compare never matches.
cat > "$FIX/viewer-displayname.json" <<'EOF'
{"data":{"viewer":{"name":"Kevin Ross","email":"kevin.ross@example.com"}}}
EOF

# The shim's behaviour is driven by files in $FIX, so a single case can change its answer between the
# first assign and the read-back — which is exactly the intermittency being pinned.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "api query")
    cat "\$FIX/\$(cat "\$FIX/viewer-which" 2>/dev/null || echo viewer).json" 2>/dev/null || exit 1 ;;
  "issues assign")
    if [ -f "\$FIX/assign-fail" ]; then echo "HTTP 500 Service Unavailable" >&2; exit 1; fi
    if [ -f "\$FIX/assign-hardfail" ]; then echo "permission denied" >&2; exit 1; fi
    # The gotcha-#8 shape: reports success, writes nothing the first time.
    if [ -f "\$FIX/assign-noop-once" ]; then rm -f "\$FIX/assign-noop-once"; echo "+ Assigned OK"; exit 0; fi
    cp "\$FIX/get-claimed.json" "\$FIX/get-current.json" 2>/dev/null
    echo "+ Assigned OK"; exit 0 ;;
  "issues get")
    [ -f "\$FIX/read-fail" ] && exit 1
    cat "\$FIX/get-current.json" 2>/dev/null || exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

# Stub linear-set-state.sh next to a copy of the script so delegation is exercised without the real one.
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
cp "$SCRIPT" "$STUBDIR/linear-claim.sh"
cat > "$STUBDIR/linear-set-state.sh" <<'EOF'
#!/bin/bash
if [ -f "$FIXDIR/state-fail" ]; then echo "$2 -> FAILED (reads 'Planned', wanted '$1')"; exit 2; fi
echo "$2 -> In Progress"
exit 0
EOF
chmod +x "$STUBDIR/linear-set-state.sh"
STUB="$STUBDIR/linear-claim.sh"

cat > "$FIX/get-claimed.json" <<'EOF'
{"id":"uuid-TT-1","identifier":"TT-1","assignee":{"name":"kevin.ross@example.com"}}
EOF
cat > "$FIX/get-unassigned.json" <<'EOF'
{"id":"uuid-TT-1","identifier":"TT-1","assignee":null}
EOF

export PATH="$WORK/bin:$PATH"
export FIXDIR="$FIX"

reset() { rm -f "$FIX"/assign-fail "$FIX"/assign-hardfail "$FIX"/assign-noop-once "$FIX"/read-fail "$FIX"/state-fail "$FIX"/viewer-which; cp "$FIX/get-unassigned.json" "$FIX/get-current.json"; }

# --- usage ---
out=$("$STUB" 2>/dev/null); ck_pre "usage: no args" "FAILED-USAGE:" "$out"
ck "usage: exit 1" "1" "$(("$STUB" >/dev/null 2>&1); echo $?)"
out=$("$STUB" "not-an-issue" 2>/dev/null); ck_pre "usage: bad ID" "FAILED-USAGE:" "$out"
out=$("$STUB" TT-1 --state 2>/dev/null); ck_pre "usage: --state without value" "FAILED-USAGE:" "$out"
out=$("$STUB" TT-1 --bogus 2>/dev/null); ck_pre "usage: unknown arg" "FAILED-USAGE:" "$out"

# --- happy path: assign lands, read-back confirms ---
reset
out=$("$STUB" TT-1 2>/dev/null); rc=$?
ck "claimed: verdict" "CLAIMED TT-1 assignee=kevin.ross@example.com" "$out"
ck "claimed: exit 0" "0" "$rc"

# --- lowercase ID normalizes ---
reset
out=$("$STUB" tt-1 2>/dev/null)
ck "claimed: lowercase ID normalized" "CLAIMED TT-1 assignee=kevin.ross@example.com" "$out"

# --- gotcha #8 intermittency: first assign reports success and writes nothing; retry lands it ---
reset; touch "$FIX/assign-noop-once"
out=$("$STUB" TT-1 2>/dev/null); rc=$?
ck "noop-once: retry rescues" "CLAIMED TT-1 assignee=kevin.ross@example.com" "$out"
ck "noop-once: exit 0" "0" "$rc"

# --- confirmed NOT landed: assign never writes, both attempts ---
reset; cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "api query") cat "\$FIX/viewer.json" ;;
  "issues assign") echo "+ Assigned OK"; exit 0 ;;
  "issues get") cat "\$FIX/get-unassigned.json" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"
out=$("$STUB" TT-1 2>/dev/null); rc=$?
ck_pre "not-claimed: verdict" "NOT-CLAIMED TT-1: assignee reads 'none'" "$out"
ck "not-claimed: exit 2" "2" "$rc"

# --- UNCONFIRMED: the read itself fails — must NOT be reported as a failed claim ---
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "api query") cat "\$FIX/viewer.json" ;;
  "issues assign") echo "+ Assigned OK"; exit 0 ;;
  "issues get") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"
out=$("$STUB" TT-1 2>/dev/null); rc=$?
ck_pre "unconfirmed: verdict" "UNCONFIRMED TT-1:" "$out"
ck "unconfirmed: exit 3" "3" "$rc"
case "$out" in NOT-CLAIMED*) FAIL=$((FAIL+1)); echo "FAIL: unconfirmed must not read as NOT-CLAIMED" ;; *) PASS=$((PASS+1)) ;; esac

# --- viewer unresolvable: abort before attempting a claim we could never verify ---
cat > "$WORK/bin/linear-cli" <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in
  "api query") exit 1 ;;
  "issues assign") echo "ASSIGN-SHOULD-NOT-RUN" >&2; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"
out=$("$STUB" TT-1 2>&1 >/dev/null); vout=$("$STUB" TT-1 2>/dev/null); rc=$?
ck_pre "viewer-unresolvable: verdict" "UNCONFIRMED TT-1: could not resolve the viewer" "$vout"
ck "viewer-unresolvable: exit 3" "3" "$rc"
case "$out" in *ASSIGN-SHOULD-NOT-RUN*) FAIL=$((FAIL+1)); echo "FAIL: assign ran despite unresolvable viewer" ;; *) PASS=$((PASS+1)) ;; esac

# --- display-name viewer: read-back carries the NAME, not the email ---
cat > "$FIX/get-displayname.json" <<'EOF'
{"id":"uuid-TT-1","identifier":"TT-1","assignee":{"name":"Kevin Ross"}}
EOF
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "api query") cat "\$FIX/viewer-displayname.json" ;;
  "issues assign") echo "+ Assigned OK"; exit 0 ;;
  "issues get") cat "\$FIX/get-displayname.json" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"
out=$("$STUB" TT-1 2>/dev/null)
ck "display-name matches on .name" "CLAIMED TT-1 assignee=Kevin Ross" "$out"

# --- state delegation: success reports the state linear-set-state.sh confirmed ---
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
case "\${1:-} \${2:-}" in
  "api query") cat "\$FIX/viewer.json" ;;
  "issues assign") echo "+ Assigned OK"; exit 0 ;;
  "issues get") cat "\$FIX/get-claimed.json" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"
rm -f "$FIX/state-fail"
out=$("$STUB" TT-1 --state "in progress" 2>/dev/null); rc=$?
ck "state: resolved spelling reported, not the argument" "CLAIMED TT-1 assignee=kevin.ross@example.com state=In Progress" "$out"
ck "state: exit 0" "0" "$rc"

# --- state delegation failure: assignee landed, state did not ---
touch "$FIX/state-fail"
out=$("$STUB" TT-1 --state "In Progress" 2>/dev/null); rc=$?
ck_pre "state-fail: verdict" "NOT-CLAIMED TT-1: assignee landed but state did not" "$out"
ck "state-fail: exit 2" "2" "$rc"
rm -f "$FIX/state-fail"

# --- verdict is always exactly the first line of stdout ---
out=$("$STUB" TT-1 2>/dev/null | wc -l | tr -d ' ')
ck "stdout is a single verdict line" "1" "$out"

echo "--- linear-claim.test.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
