#!/usr/bin/env bash
# Regression suite for claude-freshness.sh.
#
# Each case builds a fresh clone of a bare fixture origin, pushes upstream commits from a second clone, and points
# CLAUDE_FRESHNESS_DIR at the first — so the fetch, the behind count, the session-loaded split and the pull-refusal
# probe all run against real git, and the real ~/.claude is never touched. The clone never fetches on its own, so
# its origin/main reads 0 behind until the script fetches: every behind case also pins the fetch.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-freshness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; cat "$3"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; cat "$3"; else PASS=$((PASS+1)); fi
}

ORIGIN="$WORK/origin.git"
UP="$WORK/upstream"
LOCAL="$WORK/local"
g() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$UP" 2>/dev/null
git -C "$UP" checkout -q -b main
mkdir -p "$UP/hooks" "$UP/doc" "$UP/scripts" "$UP/skills/auto" "$UP/pics"
for f in hooks/guard.sh settings.json README.md doc/notes.md scripts/fleet-launch.sh scripts/fleet-launch.test.sh \
         skills/auto/SKILL.md skills/README.md pics/x.png package.json CLAUDE.md; do
  echo base > "$UP/$f"
done
g -C "$UP" add -A
g -C "$UP" commit -q -m init
git -C "$UP" push -q origin main

upstream_commit() { # <message> <path>... — append a line to each path upstream and push
  local msg="$1" f; shift
  for f in "$@"; do mkdir -p "$(dirname "$UP/$f")"; echo "$msg" >> "$UP/$f"; done
  g -C "$UP" add -A
  g -C "$UP" commit -q -m "$msg"
  git -C "$UP" push -q origin main
}
fresh_local() { rm -rf "$LOCAL"; git clone -q "$ORIGIN" "$LOCAL"; }
run() { CLAUDE_FRESHNESS_DIR="$LOCAL" "$SCRIPT" >"$WORK/out" 2>&1; echo $?; }

# ---- current: silent ----
fresh_local
ck "current exits 0"       "0" "$(run)"
ck "current prints nothing" "0" "$(wc -c < "$WORK/out" | tr -d ' ')"

# ---- behind only in files no session loads: one NOTE line, exit 0 ----
fresh_local
upstream_commit "docs: readme" README.md
upstream_commit "docs: notes and a picture" doc/notes.md pics/x.png
upstream_commit "test: a new arm" scripts/fleet-launch.test.sh
upstream_commit "chore: lint deps" package.json skills/README.md
ck "docs-only exits 0"        "0" "$(run)"
ck "docs-only is one line"    "1" "$(wc -l < "$WORK/out" | tr -d ' ')"
ck_has "docs-only NOTE"       "NOTE: ~/.claude is 4 commits behind origin/main, none in a file sessions load — launching" "$WORK/out"
ck_lacks "docs-only not stale" "TOOLING-STALE" "$WORK/out"

# ---- behind in hooks/: exit 4, the hooks commit listed, the docs commit not ----
fresh_local
upstream_commit "docs: readme again" README.md
upstream_commit "hooks: recover a lost wakeup" hooks/guard.sh
ck "hooks exits 4"            "4" "$(run)"
ck_has "stale header"         "TOOLING-STALE: ~/.claude is 2 commits behind origin/main, including:" "$WORK/out"
ck_has "hooks commit listed"  "hooks: recover a lost wakeup" "$WORK/out"
ck_lacks "docs commit unlisted" "docs: readme again" "$WORK/out"
ck_lacks "no refusal when clean" "/keeper" "$WORK/out"

# ---- each session-loaded family counts: settings.json, a skill, a script, CLAUDE.md ----
for f in settings.json skills/auto/SKILL.md scripts/fleet-launch.sh CLAUDE.md rules/new.md; do
  fresh_local
  upstream_commit "touch $f" "$f"
  ck "$f is session-loaded" "4" "$(run)"
done

# ---- one commit: singular count ----
fresh_local
upstream_commit "hooks: one" hooks/guard.sh
run >/dev/null
ck_has "singular count" "TOOLING-STALE: ~/.claude is 1 commit behind origin/main" "$WORK/out"

# ---- more than 8 loaded commits: 8 listed, the rest counted ----
fresh_local
for i in 1 2 3 4 5 6 7 8 9 10; do upstream_commit "hooks: change $i" hooks/guard.sh; done
ck "ten loaded exits 4"       "4" "$(run)"
ck "eight listed"             "8" "$(grep -c '^  [0-9a-f]* hooks: change' "$WORK/out")"
ck_has "rest counted"         "… and 2 more that touch session-loaded files" "$WORK/out"

# ---- a local edit to a file upstream also changed: the pull will refuse, so /keeper is named ----
fresh_local
echo '{"outputStyle":"local"}' >> "$LOCAL/settings.json"
echo local >> "$LOCAL/CLAUDE.md"
upstream_commit "settings: new hook" settings.json
ck "modified-and-upstream exits 4" "4" "$(run)"
ck_has "refusal names the file"    "the ~/.claude pull will refuse (settings.json modified locally) — run /keeper first" "$WORK/out"
ck_lacks "an edit upstream left alone is not named" "CLAUDE.md" "$WORK/out"

# The same clash on a docs-only behind still launches, carrying the refusal on its NOTE line.
fresh_local
echo local >> "$LOCAL/README.md"
upstream_commit "docs: readme" README.md
ck "docs clash exits 0"       "0" "$(run)"
ck_has "docs clash on the NOTE" "none in a file sessions load — launching; the ~/.claude pull will refuse (README.md modified locally) — run /keeper first" "$WORK/out"

# An untracked file upstream now adds blocks the pull the same way.
fresh_local
echo mine > "$LOCAL/hooks/added.sh"
upstream_commit "hooks: add one" hooks/added.sh
ck "untracked clash exits 4"  "4" "$(run)"
ck_has "untracked clash named" "(hooks/added.sh modified locally)" "$WORK/out"

# ---- local commits ahead: the --ff-only pull refuses ----
fresh_local
echo local >> "$LOCAL/CLAUDE.md"
g -C "$LOCAL" commit -q -am "local: drift"
upstream_commit "skills: change" skills/auto/SKILL.md
ck "ahead exits 4"            "4" "$(run)"
ck_has "ahead named"          "the ~/.claude pull will refuse (1 local commit(s) not on origin/main) — run /keeper first" "$WORK/out"

# ---- ahead only, nothing behind: nothing to pull, so silent ----
fresh_local
echo local >> "$LOCAL/CLAUDE.md"
g -C "$LOCAL" commit -q -am "local: drift"
ck "ahead-only exits 0"       "0" "$(run)"
ck "ahead-only silent"        "0" "$(wc -c < "$WORK/out" | tr -d ' ')"

# ---- origin unreachable: NOTE, exit 0 ----
fresh_local
git -C "$LOCAL" remote set-url origin "$WORK/no-such-origin.git"
ck "unreachable exits 0"      "0" "$(run)"
ck_has "unreachable NOTE"     "NOTE: could not check ~/.claude freshness (fetch failed) — launching" "$WORK/out"

# ---- not a git checkout: NOTE, exit 0 ----
mkdir -p "$WORK/plain"
ck "non-repo exits 0"         "0" "$(CLAUDE_FRESHNESS_DIR="$WORK/plain" "$SCRIPT" >"$WORK/out" 2>&1; echo $?)"
ck_has "non-repo NOTE"        "is not a git checkout) — launching" "$WORK/out"

# ---- a hanging fetch: the watchdog kills it at its limit and the launch proceeds ----
# A git stub hangs on `fetch` and defers everything else to the real git.
REAL_GIT=$(command -v git)
mkdir -p "$WORK/hangbin"
cat > "$WORK/hangbin/git" <<STUB_GIT
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "fetch" ] && exec sleep 23; done
exec "$REAL_GIT" "\$@"
STUB_GIT
chmod +x "$WORK/hangbin/git"
fresh_local
upstream_commit "hooks: unseen" hooks/guard.sh
start=$SECONDS
rc=$(PATH="$WORK/hangbin:$PATH" CLAUDE_FRESHNESS_DIR="$LOCAL" CLAUDE_FRESHNESS_TIMEOUT=1 "$SCRIPT" >"$WORK/out" 2>&1; echo $?)
elapsed=$(( SECONDS - start ))
ck "hanging fetch exits 0"    "0" "$rc"
ck_has "hanging fetch NOTE"   "NOTE: could not check ~/.claude freshness (fetch failed) — launching" "$WORK/out"
ck "hanging fetch ended by the watchdog" "yes" "$([ "$elapsed" -le 4 ] && echo yes || echo "no (${elapsed}s)")"
ck "hung fetch killed"        "0" "$(pgrep -fx "sleep 23" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
