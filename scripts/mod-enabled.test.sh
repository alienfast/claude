#!/usr/bin/env bash
# Regression suite for mod-enabled.sh: the three registry states a launcher can meet, through a stubbed `claude`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mod-enabled.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi; }
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<STUB_CLAUDE_MOD
#!/usr/bin/env bash
[ -f "$WORK/fail" ] && exit 1
cat "$WORK/plugins.json"
STUB_CLAUDE_MOD
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

echo '[{"id":"loop-boundary@alienfast-claude","enabled":true},{"id":"other@x","enabled":false}]' > "$WORK/plugins.json"
rc=0; out=$("$here/mod-enabled.sh" loop-boundary 2>&1) || rc=$?
ck "enabled exits 0" "0" "$rc"; ck "enabled prints nothing" "" "$out"

echo '[{"id":"loop-boundary@alienfast-claude","enabled":false}]' > "$WORK/plugins.json"
rc=0; out=$("$here/mod-enabled.sh" loop-boundary 2>&1) || rc=$?
ck "disabled exits 5" "5" "$rc"
case "$out" in *"claude plugin enable loop-boundary@alienfast-claude"*) ck "disabled names enable" 1 1 ;; *) ck "disabled names enable" 1 0 ;; esac

echo '[{"id":"effort-phase@alienfast-claude","enabled":true}]' > "$WORK/plugins.json"
rc=0; out=$("$here/mod-enabled.sh" loop-boundary 2>&1) || rc=$?
ck "missing exits 5" "5" "$rc"
case "$out" in *"claude plugin install loop-boundary@alienfast-claude"*) ck "missing names install" 1 1 ;; *) ck "missing names install" 1 0 ;; esac

touch "$WORK/fail"
rc=0; out=$("$here/mod-enabled.sh" loop-boundary 2>&1) || rc=$?
ck "unreadable registry exits 1" "1" "$rc"
rm -f "$WORK/fail"

rc=0; "$here/mod-enabled.sh" >/dev/null 2>&1 || rc=$?
ck "usage error exits 1" "1" "$rc"

echo "mod-enabled: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
