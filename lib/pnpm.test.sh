#!/bin/bash
# pnpm.test.sh — tests for lib/pnpm.sh: the pin parse, numeric version order, channel detection by install layout, and
# converge_pnpm's dispatch. Every installer is a stub on PATH that records its argv and bumps a version file, so the
# suite is offline and touches nothing outside its temp dir.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/pnpm.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "contains: $2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) no "$1" "does not contain: $2" "$3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d) || { echo "cannot mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
ORIG_PATH=$PATH

echo "lib/pnpm.sh"

# --- pin parse ---------------------------------------------------------------------------------------

printf '{\n  "name": "x",\n  "packageManager": "pnpm@11.21.0+sha512.abc",\n  "scripts": {}\n}\n' > "$TMP/pkg.json"
eq "pin parses the bare version off the integrity suffix" "11.21.0" "$(pnpm_pin_from "$TMP/pkg.json")"
printf '{ "packageManager": "pnpm@12.4.2" }\n' > "$TMP/pkg-nohash.json"
eq "pin parses without an integrity suffix" "12.4.2" "$(pnpm_pin_from "$TMP/pkg-nohash.json")"
eq "pin is empty when the field is absent" "" "$(pnpm_pin_from /dev/null)"
eq "pin is empty when the file is missing" "" "$(pnpm_pin_from "$TMP/nope.json")"

# --- version order -----------------------------------------------------------------------------------

lt() { local r=false; if version_lt "$2" "$3"; then r=true; fi; eq "$1" "$4" "$r"; }
lt "10.30.0 < 11.21.0" 10.30.0 11.21.0 true
lt "11.9.0 < 11.21.0 (numeric, not lexical)" 11.9.0 11.21.0 true
lt "equal versions are not less-than" 11.21.0 11.21.0 false
lt "a newer base is not less-than the pin" 12.4.2 11.21.0 false

# --- channel detection by layout ---------------------------------------------------------------------

VER="$TMP/ver"; CALLS="$TMP/calls"
: > "$CALLS"

# A pnpm stub answers --version from $VER and, for the standalone channel, honours self-update by rewriting it.
write_pnpm_stub() {
  cat > "$1" <<STUB
#!/bin/sh
echo "pnpm \$*" >> "$CALLS"
case "\$1" in
  --version) cat "$VER" ;;
  self-update) echo "\$2" > "$VER" ;;
esac
STUB
  chmod +x "$1"
}

# Symlink layouts mirror what `readlink -f` sees on a real install.
mkdir -p "$TMP/cp/lib/node_modules/corepack/dist" "$TMP/cp/bin"
write_pnpm_stub "$TMP/cp/lib/node_modules/corepack/dist/pnpm.js"
ln -s ../lib/node_modules/corepack/dist/pnpm.js "$TMP/cp/bin/pnpm"

mkdir -p "$TMP/np/lib/node_modules/pnpm/bin" "$TMP/np/bin"
write_pnpm_stub "$TMP/np/lib/node_modules/pnpm/bin/pnpm.cjs"
ln -s ../lib/node_modules/pnpm/bin/pnpm.cjs "$TMP/np/bin/pnpm"

mkdir -p "$TMP/hb/Cellar/pnpm/12.4.2/bin" "$TMP/hb/bin"
write_pnpm_stub "$TMP/hb/Cellar/pnpm/12.4.2/bin/pnpm"
ln -s ../Cellar/pnpm/12.4.2/bin/pnpm "$TMP/hb/bin/pnpm"

mkdir -p "$TMP/sa"
write_pnpm_stub "$TMP/sa/pnpm"

# Git for Windows shims: small sh scripts, no symlink.
mkdir -p "$TMP/wincp" "$TMP/winnp"
printf '#!/bin/sh\nbasedir=$(dirname "$0")\nexec node "$basedir/node_modules/corepack/dist/pnpm.js" "$@"\n' > "$TMP/wincp/pnpm"
printf '#!/bin/sh\nbasedir=$(dirname "$0")\nexec node "$basedir/node_modules/pnpm/bin/pnpm.cjs" "$@"\n' > "$TMP/winnp/pnpm"
chmod +x "$TMP/wincp/pnpm" "$TMP/winnp/pnpm"

# A working pnpm whose file is large and mentions Corepack, the way pnpm's own bundle does, at a path no rule names —
# must NOT read as the Corepack channel.
mkdir -p "$TMP/unk"
write_pnpm_stub "$TMP/unk/pnpm"
{ printf '# Corepack is mentioned here\n'; yes '# padding to carry the file past the shim size gate' | head -200; } >> "$TMP/unk/pnpm"

channel_with() { PATH="$1:$ORIG_PATH" PNPM_HOME="$2" pnpm_channel; }
eq "corepack layout (symlink through corepack/dist)" corepack "$(channel_with "$TMP/cp/bin" "$TMP/sa")"
eq "npm layout (symlink through node_modules/pnpm)" npm "$(channel_with "$TMP/np/bin" "$TMP/sa")"
eq "brew layout (symlink into Cellar/pnpm)" brew "$(channel_with "$TMP/hb/bin" "$TMP/sa")"
eq "standalone layout (binary under PNPM_HOME)" standalone "$(channel_with "$TMP/sa" "$TMP/sa")"
eq "Windows corepack shim (small script naming corepack)" corepack "$(channel_with "$TMP/wincp" "$TMP/sa")"
eq "Windows npm shim (small script naming node_modules/pnpm)" npm "$(channel_with "$TMP/winnp" "$TMP/sa")"
eq "a large file mentioning Corepack is unknown, not corepack" unknown "$(channel_with "$TMP/unk" "$TMP/sa")"
eq "no pnpm on PATH is unknown" unknown "$(PATH="$TMP/empty" PNPM_HOME="$TMP/sa" pnpm_channel)"

# --- converge_pnpm dispatch --------------------------------------------------------------------------

# Installer stubs: record argv; an install of pnpm@X (corepack, npm) or a brew upgrade rewrites $VER as a real one would.
mkdir -p "$TMP/tools"
cat > "$TMP/tools/corepack" <<STUB
#!/bin/sh
echo "corepack \$*" >> "$CALLS"
[ "\$1" = install ] && echo "\${3#pnpm@}" > "$VER"
exit 0
STUB
cat > "$TMP/tools/npm" <<STUB
#!/bin/sh
echo "npm \$*" >> "$CALLS"
[ "\$1" = install ] && echo "\${3#pnpm@}" > "$VER"
exit 0
STUB
cat > "$TMP/tools/brew" <<STUB
#!/bin/sh
echo "brew \$*" >> "$CALLS"
[ "\$1" = upgrade ] && echo 12.4.2 > "$VER"
exit 0
STUB
chmod +x "$TMP/tools/corepack" "$TMP/tools/npm" "$TMP/tools/brew"

# converge_with <pnpm dir> <PNPM_HOME> <current version> — runs converge_pnpm against the stubs, capturing output + rc.
converge_with() {
  echo "$3" > "$VER"; : > "$CALLS"
  out=$(PATH="$1:$TMP/tools:$ORIG_PATH" PNPM_HOME="$2" converge_pnpm "$TMP/pkg.json" 2>&1); rc=$?
}

converge_with "$TMP/cp/bin" "$TMP/sa" 11.21.0
eq "at the pin: exit 0" 0 "$rc"
has "at the pin: reports the version" "✓ pnpm 11.21.0 (pinned: 11.21.0)" "$out"
eq "at the pin: no installer called" "pnpm --version" "$(cat "$CALLS")"

converge_with "$TMP/cp/bin" "$TMP/sa" 12.4.2
has "newer than the pin: left alone" "✓ pnpm 12.4.2 (pinned: 11.21.0)" "$out"
eq "newer than the pin: no installer called" "pnpm --version" "$(cat "$CALLS")"

converge_with "$TMP/cp/bin" "$TMP/sa" 10.30.0
has "corepack: upgrades through corepack install -g" "corepack install -g pnpm@11.21.0" "$(cat "$CALLS")"
has "corepack: re-measures and reports the new version" "✓ pnpm 11.21.0 (pinned: 11.21.0)" "$out"
eq "corepack: exit 0" 0 "$rc"

converge_with "$TMP/np/bin" "$TMP/sa" 10.30.0
has "npm: upgrades through npm install -g" "npm install -g pnpm@11.21.0" "$(cat "$CALLS")"
lacks "npm: never calls self-update (it would write a shadowed copy)" "self-update" "$(cat "$CALLS")"
has "npm: reports the new version" "✓ pnpm 11.21.0" "$out"

converge_with "$TMP/sa" "$TMP/sa" 10.30.0
has "standalone: upgrades through pnpm self-update <pin>" "pnpm self-update 11.21.0" "$(cat "$CALLS")"
has "standalone: reports the new version" "✓ pnpm 11.21.0" "$out"

converge_with "$TMP/hb/bin" "$TMP/sa" 10.30.0
has "brew: upgrades through brew upgrade pnpm" "brew upgrade pnpm" "$(cat "$CALLS")"
has "brew: a formula newer than the pin satisfies it" "✓ pnpm 12.4.2 (pinned: 11.21.0)" "$out"

converge_with "$TMP/unk" "$TMP/sa" 10.30.0
eq "unknown channel: exit 0 (the rest of the bootstrap still runs)" 0 "$rc"
lacks "unknown channel: no installer guessed" "install" "$(cat "$CALLS")"
has "unknown channel: warns with the version still in place" "pnpm is still 10.30.0 (pinned: 11.21.0)" "$out"
for cmd in "corepack install -g pnpm@11.21.0" "brew upgrade pnpm" "pnpm self-update 11.21.0" "npm install -g pnpm@11.21.0"; do
  has "unknown channel: hands over '$cmd'" "$cmd" "$out"
done

# An upgrade that runs but changes nothing must surface, not read as success.
cat > "$TMP/tools/corepack" <<STUB
#!/bin/sh
echo "corepack \$*" >> "$CALLS"
exit 0
STUB
converge_with "$TMP/cp/bin" "$TMP/sa" 10.30.0
has "ineffective upgrade: attempted" "corepack install -g pnpm@11.21.0" "$(cat "$CALLS")"
has "ineffective upgrade: warns rather than reporting ✓" "pnpm is still 10.30.0" "$out"
lacks "ineffective upgrade: no ✓" "✓" "$out"
eq "ineffective upgrade: exit 0" 0 "$rc"

out=$(PATH="$TMP/empty:$TMP/tools" PNPM_HOME="$TMP/sa" converge_pnpm "$TMP/pkg.json" 2>&1); rc=$?
eq "no pnpm at all: exit 1" 1 "$rc"
has "no pnpm at all: says so" "pnpm is not on PATH" "$out"

converge_with "$TMP/cp/bin" "$TMP/sa" 10.30.0
out=$(PATH="$TMP/cp/bin:$TMP/tools:$ORIG_PATH" PNPM_HOME="$TMP/sa" converge_pnpm /dev/null 2>&1); rc=$?
eq "no pin: exit 0" 0 "$rc"
has "no pin: warns and leaves pnpm alone" "no pnpm pin found" "$out"

echo ""
echo "pnpm.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
