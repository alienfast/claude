#!/usr/bin/env bash
# Regression suite for cswap-setup.sh and cswap-auto-run.sh through stubbed uv / cswap / claude / launchctl / uname.
# Every stub appends its argv to calls.log; the checks read that log and the rendered plist.
set -u
here=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cswap-setup.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi; }
has() { case "$2" in *"$1"*) echo 1 ;; *) echo 0 ;; esac; }
count() { grep -c -F -- "$1" "$WORK/calls.log" 2>/dev/null || true; }

export HOME="$WORK/home"; mkdir -p "$HOME"
BIN="$WORK/bin"; mkdir -p "$BIN"
CALLS="$WORK/calls.log"
echo Darwin > "$WORK/os"
echo 0.27.2 > "$WORK/cswap.version"
printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com"}' > "$WORK/auth.json"

cat > "$BIN/uname" <<STUB_UNAME
#!/usr/bin/env bash
cat "$WORK/os"
STUB_UNAME
cat > "$BIN/uv" <<STUB_UV
#!/usr/bin/env bash
echo "uv \$*" >> "$CALLS"
case "\$1 \$2" in
  "tool dir") echo "$WORK/uvbin" ;;
  "tool install") for a in "\$@"; do case "\$a" in claude-swap==*) echo "\${a#claude-swap==}" > "$WORK/cswap.version" ;; esac; done ;;
esac
STUB_UV
cat > "$BIN/cswap" <<STUB_CSWAP
#!/usr/bin/env bash
echo "cswap \$*" >> "$CALLS"
case "\$1" in
  --version) echo "cswap \$(cat "$WORK/cswap.version")" ;;
  list) echo "LIST" ;;
  auto) echo '{"event":"noSwitch","reason":"below-threshold"}'; exit 2 ;;
esac
STUB_CSWAP
cat > "$BIN/claude" <<STUB_CLAUDE
#!/usr/bin/env bash
echo "claude \$*" >> "$CALLS"
case "\$1 \$2" in
  "auth status") cat "$WORK/auth.json" ;;
esac
STUB_CLAUDE
cat > "$BIN/launchctl" <<STUB_LAUNCHCTL
#!/usr/bin/env bash
echo "launchctl \$*" >> "$CALLS"
case "\$1" in
  print) [ -f "$WORK/loaded" ] ;;
  bootstrap) touch "$WORK/loaded" ;;
  bootout) rm -f "$WORK/loaded" ;;
esac
STUB_LAUNCHCTL
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
plist="$HOME/Library/LaunchAgents/com.alienfast.cswap-auto.plist"

# 1. fresh machine, no TTY: install the pin, enroll the current login, apply the policy, load the agent
echo 0.26.0 > "$WORK/cswap.version"; : > "$CALLS"
rc=0; out=$("$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "fresh exits 0" 0 "$rc"
ck "fresh installs the pin" 1 "$(count 'uv tool install --reinstall claude-swap==0.27.2')"
ck "fresh enrolls the current login once" 1 "$(count 'cswap add')"
ck "fresh sets consume-first" 1 "$(count 'cswap config set autoswitch.strategy consume-first')"
ck "fresh sets threshold 95" 1 "$(count 'cswap config set autoswitch.threshold 95')"
ck "fresh dry-runs one tick" 1 "$(count 'cswap auto --once --dry-run --json')"
ck "fresh renders the plist" 1 "$([ -f "$plist" ] && echo 1 || echo 0)"
ck "plist carries HOME" 0 "$(grep -c __HOME__ "$plist")"
ck "plist names the wrapper" 1 "$(grep -c "$HOME/.claude/scripts/cswap-auto-run.sh" "$plist")"
ck "fresh bootstraps the agent" 1 "$(count 'launchctl bootstrap')"
ck "fresh says how to enroll the rest" 1 "$(has 'claude auth login && cswap add' "$out")"

# 2. re-run on a converged machine: no reinstall, the loaded agent is restarted onto the policy
: > "$CALLS"
rc=0; out=$("$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "rerun exits 0" 0 "$rc"
ck "rerun does not reinstall" 0 "$(count 'uv tool install')"
ck "rerun restarts the agent" 1 "$(count 'launchctl kickstart -k')"
ck "rerun does not bootstrap again" 0 "$(count 'launchctl bootstrap')"

# 3. flags: policy re-applied without enrollment or service
: > "$CALLS"
rc=0; out=$("$here/cswap-setup.sh" --threshold 98.5 --strategy best --no-service --no-enroll </dev/null 2>&1) || rc=$?
ck "flags exit 0" 0 "$rc"
ck "flags set strategy best" 1 "$(count 'cswap config set autoswitch.strategy best')"
ck "flags set threshold 98.5" 1 "$(count 'cswap config set autoswitch.threshold 98.5')"
ck "--no-enroll skips cswap add" 0 "$(count 'cswap add')"
ck "--no-service touches no launchctl" 0 "$(count 'launchctl')"

# 4. validation
rc=0; out=$("$here/cswap-setup.sh" --threshold 40 </dev/null 2>&1) || rc=$?
ck "threshold below 50 exits 2" 2 "$rc"
rc=0; out=$("$here/cswap-setup.sh" --strategy weekly-first </dev/null 2>&1) || rc=$?
ck "unknown strategy exits 2" 2 "$rc"

# 5. the live login must be a claude.ai subscription
: > "$CALLS"
printf '%s' '{"loggedIn":false}' > "$WORK/auth.json"
rc=0; out=$("$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "logged out exits 1" 1 "$rc"
ck "logged out names claude auth login" 1 "$(has 'claude auth login' "$out")"
ck "logged out never runs cswap add" 0 "$(count 'cswap add')"
printf '%s' '{"loggedIn":true,"authMethod":"console","email":"k@example.com"}' > "$WORK/auth.json"
rc=0; out=$("$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "console login exits 1" 1 "$rc"
printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com"}' > "$WORK/auth.json"

# 6. no launchd off macOS: the wrapper is named instead
echo Linux > "$WORK/os"; : > "$CALLS"
rc=0; out=$("$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "linux exits 0" 0 "$rc"
ck "linux touches no launchctl" 0 "$(count 'launchctl')"
ck "linux names the wrapper" 1 "$(has 'cswap-auto-run.sh' "$out")"
echo Darwin > "$WORK/os"

# 7. uv missing: a hard stop that names the install
NOUV="$WORK/nouv"; mkdir -p "$NOUV"; for b in uname cswap claude launchctl; do ln -s "$BIN/$b" "$NOUV/$b"; done
ln -s "$(command -v jq)" "$NOUV/jq"
rc=0; out=$(PATH="$NOUV:/usr/bin:/bin" "$here/cswap-setup.sh" </dev/null 2>&1) || rc=$?
ck "missing uv exits 1" 1 "$rc"
ck "missing uv names brew" 1 "$(has 'brew install uv' "$out")"

# 8. the wrapper: appends the engine's stream, and exits 0 without cswap so launchd does not relaunch it
log="$HOME/.claude/logs/cswap-auto.log"
rc=0; CSWAP_BIN="$BIN/cswap" "$here/cswap-auto-run.sh" || rc=$?
ck "wrapper exits with the engine's status" 2 "$rc"
ck "wrapper logs start then the stream" 1 "$(grep -c '"event":"wrapper-start"' "$log")"
ck "wrapper appends the engine's events" 1 "$(grep -c 'below-threshold' "$log")"
rc=0; CSWAP_BIN="$WORK/absent/cswap" "$here/cswap-auto-run.sh" || rc=$?
ck "wrapper without cswap exits 0" 0 "$rc"
ck "wrapper without cswap logs why" 1 "$(grep -c 'wrapper-error' "$log")"

echo "cswap-setup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
