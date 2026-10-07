#!/usr/bin/env bash
# Functional suite for triage-scan.sh — the /triage scan's agent invocation. Drives the real script against a fixture checkout
# with a stub `claude` that records its argv, so the flags that make the unattended pass read-only are pinned where they are
# passed, not only where they are described: --restricted (the settings files' allow rules are ignored), --strict-mcp-config
# (no MCP server), the --disallowedTools deny list beside the read allow-list, and --add-dir on the out dir --restricted would
# otherwise confine the file tools away from. Measured 2026-10-05: without --restricted a headless scan agent inherited the
# keeper's user-level allow rules — rm, mv, cp, tee, pnpm, bundle exec rspec, linear-cli — each prompt-free under dontAsk.
#
# GROW THIS SUITE, NEVER PRUNE IT. A flag dropped from the invocation reopens the write surface silently; add the case WITH the fix.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/triage-scan.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT TERM

command -v jq >/dev/null 2>&1 || { echo "triage-scan.test: jq is required" >&2; exit 2; }
command -v zsh >/dev/null 2>&1 || { echo "triage-scan.test: zsh is required" >&2; exit 2; }

pass=0; fail=0
ck() { # ck <label> <argument> <argv-file> — the exact argument must be one line of the recorded argv
  if grep -qFx -- "$2" "$3"; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; echo "        want argv line: $2"; fi
}
ckeq() { # ckeq <label> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (want '$2' got '$3')"; fi
}

# The script prepends $HOME/.cargo/bin to PATH, so the stub lives there under a faked HOME — the one place guaranteed to outrank
# a real claude. Nothing else under ~ is reached: the digest the script would fetch through ~/.claude/scripts/linear-context.sh
# is pre-written below.
FAKEHOME="$ROOT/home"; mkdir -p "$FAKEHOME/.cargo/bin"
ARGV="$ROOT/claude.argv"
cat > "$FAKEHOME/.cargo/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TRIAGE_TEST_ARGV"
printf '{"structured_output":{"sha":"abcdef0123","issues":[{"id":"TT-1","disposition":"keep","verdict":"ACCURATE","evidence":"stub"}]},"total_cost_usd":0,"is_error":false}'
STUB
chmod +x "$FAKEHOME/.cargo/bin/claude"

R="$ROOT/repo"; mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m base

OUT="$ROOT/out"; mkdir -p "$OUT"
printf '%s\n' '{"id":"TT-1","title":"t","stage":"Backlog","lane":"uncertified","class":"touched","claimed":false,"subjects":["app/x.rb"],"labels":[],"created":"2026-10-01T00:00:00Z","creator":"t"}' > "$OUT/triage-cheap.ndjson"
echo "# TT-1 digest" > "$OUT/triage-digest-TT-1.md"

echo "== the agent invocation carries the read-only flags =="
out=$(cd "$R" && HOME="$FAKEHOME" TRIAGE_TEST_ARGV="$ARGV" zsh "$SCRIPT" --out "$OUT" --max-groups 1 2>&1); rc=$?
ckeq "the scan ran one group to completion" 0 "$rc"
if [ ! -f "$ARGV" ]; then
  echo "  FAIL  the stub claude was never invoked"; echo "$out"; fail=$((fail+1))
  echo; echo "triage-scan: $pass passed, $fail failed"; exit 1
fi
ck "--restricted: the settings files' allow rules are ignored" '--restricted' "$ARGV"
ck "--strict-mcp-config: no MCP server starts" '--strict-mcp-config' "$ARGV"
ck "--permission-mode dontAsk: an unlisted command is refused, never prompted" 'dontAsk' "$ARGV"
ck "the tools stay Bash,Read,Grep,Glob" 'Bash,Read,Grep,Glob' "$ARGV"
ck "the allow-list still carries the Linear read the deny list must not shadow" 'Bash(linear-cli api query:*)' "$ARGV"
ck "the allow-list carries cd: the trial's only denials were compound reads opening with it" 'Bash(cd:*)' "$ARGV"
ck "--disallowedTools is passed" '--disallowedTools' "$ARGV"
for d in 'Bash(rm:*)' 'Bash(mv:*)' 'Bash(tee:*)' 'Bash(pnpm:*)' 'Bash(bundle exec:*)' 'Bash(./tools/ci:*)' 'Bash(git stash:*)' 'Bash(git restore:*)' 'Bash(git checkout:*)' \
         'Bash(linear-cli issues update:*)' 'Bash(linear-cli issues create:*)' 'Bash(linear-cli issues delete:*)' 'Bash(linear-cli issues comment:*)' 'Bash(linear-cli issues assign:*)' \
         'Bash(linear-cli comments create:*)' 'Bash(linear-cli comments delete:*)' 'Bash(linear-cli relations add:*)' 'Bash(linear-cli labels create:*)' 'Bash(linear-cli api mutate:*)'; do
  ck "denied: $d" "$d" "$ARGV"
done
ck "--add-dir is passed" '--add-dir' "$ARGV"
ckeq "--add-dir names the out dir as an absolute path" "$(cd "$OUT" && pwd -P)" "$(grep -A1 -Fx -- '--add-dir' "$ARGV" | tail -n 1)"
ckeq "the proposal the stub returned was written" yes "$([ -s "$OUT/triage-proposals/TT-1.json" ] && echo yes || echo no)"

echo
echo "triage-scan: $pass passed, $fail failed"
[ "$fail" = 0 ]
