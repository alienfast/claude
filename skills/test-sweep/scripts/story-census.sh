#!/usr/bin/env bash
# story-census.sh — count a Storybook gate's stories and flag the shapes that inflate it, for /test-sweep.
#
# WHY THIS EXISTS: every story export with a play function is a browser test the check gate runs, and the count only grows —
# a rule that asks for one more arm adds an export, and nothing flags the export that re-runs a mechanism another file
# already pins. The redundant shapes are visible from source alone: a story name repeated across behavior files (a shared
# dialog's rejection arm re-run by each consumer), a helper re-declared in several *.stories.shared.tsx files, a file whose
# exports are one matrix over a single mount, and a play-less spec file whose behavior sibling already carries the tests.
# When a full test-storybook-exec leaves a junit report, the census also ranks story files by measured seconds. The file
# naming (*.behavior.stories.tsx, *.stories.shared.tsx), the render-only tag, and the MATRIX name prefixes are basefund
# conventions, fixed here.
#
# USAGE
#   story-census.sh --repo DIR [--junit REL] [--slow N]
#
#   --repo DIR     the project checkout
#   --junit REL    vitest junit report from a full, unfiltered pnpm test-storybook-exec, relative to the repo (default tmp/storybook-junit.xml)
#   --slow N       how many SLOW rows to print when the junit report exists (default 25)
#
# OUTPUT (one verdict per line)
#   FILES N EXPORTS N BEHAVIOR_FILES N PLAYS N NOPLAY_FILES N TAGGED N
#   BIG <exports> <file>                          a file with 10 or more exports
#   SHARED <StoryName> <count> <file>...          an export name in 3 or more *.behavior.stories.tsx files
#   HELPER <name> <count> <file>...               a top-level function or const defined in 3 or more *.stories.shared.tsx files
#   DETAG-CANDIDATE <file> sibling=<file>         a play-less, untagged spec file whose .behavior.stories.tsx sibling exists
#   MATRIX <file> <prefix> <count>                4 or more exports whose names share a prefix ending in Blocked|Granted|Refused|LandsOn
#   JUNIT <path> <mtime>                          the file's mtime, information only; or  NO-JUNIT <path>
#   WARN junit-subset tests=<n> exports=<m> — differs from the current tree (a filtered run, or exports added/removed since the last
#                                                 full run) — regenerate with a full pnpm test-storybook-exec
#                                                 the junit's testcase count differs from EXPORTS; no SLOW rows follow, since a
#                                                 ranking over a mismatched report is worse than none
#   WARN junit-no-testcases <path>                the report holds no testcases
#   SLOW <seconds> <file>                         story files by summed testcase time, longest first
#
# PLAYS counts the exports of files that declare a play (a `play:` key or a `play(` call); NOPLAY_FILES counts files that never
# do. TAGGED counts files (not exports) carrying the render-only tag. The junit's `tests=` includes skipped (render-only)
# stories, so a full run equals EXPORTS. Story files come from git (tracked plus untracked, ignored excluded), never from a
# tree walk, so nested worktrees under the checkout are not counted.
#
# Exit 0 census printed, 1 no story files found, 2 usage or git error.
# Requires git, awk, grep.

set -uo pipefail
export LC_ALL=C  # spec and story text carries UTF-8; byte-wise awk/sort cannot abort on a multibyte sequence

usage() {
  sed -n '/^# USAGE/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() { echo "story-census: $*" >&2; exit 2; }

need_value() { [ "$2" -ge 2 ] || { echo "story-census: $1 needs a value" >&2; usage; exit 2; }; }

epoch_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

iso_epoch() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }

REPO=""; JUNIT="tmp/storybook-junit.xml"; SLOW=25
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$1" $#; REPO="$2"; shift 2 ;;
    --junit) need_value "$1" $#; JUNIT="$2"; shift 2 ;;
    --slow) need_value "$1" $#; SLOW="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "story-census: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { usage; exit 2; }
case "$SLOW" in ''|*[!0-9]*) die "--slow must be a non-negative integer" ;; esac
cd "$REPO" 2>/dev/null || die "no such directory: $REPO"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git checkout: $REPO"

list_files() {  # list_files <tag> <pathspec>
  git ls-files -co --exclude-standard -- "$2" \
    | grep -vE '(^|/)(node_modules|dist|\.next|storybook-static)/' \
    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\t%s\n' "$1" "$f"; done
}

census=$({ list_files S '*.stories.tsx'; list_files H '*.stories.shared.tsx'; } | awk -F'\t' '
  $1 == "S" {
    f = $2; nexp = 0; hasplay = 0; tagged = 0; files++
    beh = (f ~ /\.behavior\.stories\.tsx$/); if (beh) bfiles++
    all[f] = 1
    while ((getline line < f) > 0) {
      if (line ~ /^export const /) {
        n = line; sub(/^export const /, "", n); sub(/[^A-Za-z0-9_$].*$/, "", n)
        if (n != "") ex[++nexp] = n
      }
      if (line ~ /(^|[^A-Za-z0-9_$])play[[:space:]]*[:(]/) hasplay = 1
      if (line ~ /tags:[[:space:]]*\[[^]]*\047render-only\047/) tagged = 1
    }
    close(f)
    exports += nexp
    if (hasplay) plays += nexp; else noplay++
    if (tagged) ntagged++
    if (nexp >= 10) printf "BIG\t%d\t%s\n", nexp, f
    split("", pc)
    for (i = 1; i <= nexp; i++) {
      if (beh) { sc[ex[i]]++; sf[ex[i]] = sf[ex[i]] " " f }
      if (match(ex[i], /(Blocked|Granted|Refused|LandsOn)/)) pc[substr(ex[i], 1, RSTART + RLENGTH - 1)]++
    }
    for (p in pc) if (pc[p] >= 4) printf "MATRIX\t%s\t%s\t%d\n", f, p, pc[p]
    if (!beh && !hasplay && !tagged) { base = f; sub(/\.stories\.tsx$/, "", base); detag[f] = base ".behavior.stories.tsx" }
    next
  }
  $1 == "H" {
    f = $2; split("", seen)
    while ((getline line < f) > 0) {
      name = ""
      if (match(line, /^(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z0-9_$]+/)) {
        name = substr(line, RSTART, RLENGTH); sub(/^.*function[[:space:]]+/, "", name)
      } else if (match(line, /^(export[[:space:]]+)?const[[:space:]]+[A-Za-z0-9_$]+[[:space:]]*(:[^=]*)?=/)) {
        name = substr(line, RSTART, RLENGTH); sub(/^.*const[[:space:]]+/, "", name); sub(/[^A-Za-z0-9_$].*$/, "", name)
      }
      if (name != "" && !(name in seen)) { seen[name] = 1; hc[name]++; hf[name] = hf[name] " " f }
    }
    close(f)
    next
  }
  END {
    printf "TOTALS\tFILES %d EXPORTS %d BEHAVIOR_FILES %d PLAYS %d NOPLAY_FILES %d TAGGED %d\n", files, exports, bfiles, plays, noplay, ntagged
    for (n in sc) if (sc[n] >= 3) printf "SHARED\t%s\t%d\t%s\n", n, sc[n], substr(sf[n], 2)
    for (n in hc) if (hc[n] >= 3) printf "HELPER\t%s\t%d\t%s\n", n, hc[n], substr(hf[n], 2)
    for (f in detag) if (detag[f] in all) printf "DETAG\t%s\t%s\n", f, detag[f]
  }')

totals=$(printf '%s\n' "$census" | awk -F'\t' '$1 == "TOTALS" { print $2 }')
case "$totals" in
  "FILES 0 "*|"") echo "story-census: no *.stories.tsx files under $REPO" >&2; exit 1 ;;
esac
echo "$totals"
printf '%s\n' "$census" | awk -F'\t' '$1 == "BIG" { print "BIG " $2 " " $3 }' | sort -k2,2nr -k3,3
printf '%s\n' "$census" | awk -F'\t' '$1 == "SHARED" { print "SHARED " $2 " " $3 " " $4 }' | sort -k3,3nr -k2,2
printf '%s\n' "$census" | awk -F'\t' '$1 == "HELPER" { print "HELPER " $2 " " $3 " " $4 }' | sort -k3,3nr -k2,2
printf '%s\n' "$census" | awk -F'\t' '$1 == "DETAG" { print "DETAG-CANDIDATE " $2 " sibling=" $3 }' | sort
printf '%s\n' "$census" | awk -F'\t' '$1 == "MATRIX" { print "MATRIX " $2 " " $3 " " $4 }' | sort -k4,4nr -k2,2

if [ ! -s "$JUNIT" ]; then
  if [ -f "$JUNIT" ]; then echo "NO-JUNIT $JUNIT (empty)"; else echo "NO-JUNIT $JUNIT"; fi
  exit 0
fi
echo "JUNIT $JUNIT $(iso_epoch "$(epoch_mtime "$JUNIT")")"

# A filtered test-storybook run overwrites the junit with only its own stories, and a cache-hit check never rewrites it, so the
# file's age says nothing; its testcase count against the story exports does. `tests=` counts skipped (render-only) stories too.
exports=$(printf '%s\n' "$totals" | awk '{ for (i = 1; i < NF; i++) if ($i == "EXPORTS") print $(i + 1) }')
jtests=$({ grep -o '<testsuites [^>]*' "$JUNIT" || true; } | head -n 1 | awk '
  { if (match($0, " tests=\"[0-9]+\"")) print substr($0, RSTART + 8, RLENGTH - 9) }')
[ -n "$jtests" ] || jtests=$({ grep -o '<testcase ' "$JUNIT" || true; } | wc -l | tr -d ' ')
if [ "$jtests" -gt 0 ] && [ "$jtests" != "$exports" ]; then
  echo "WARN junit-subset tests=$jtests exports=$exports — differs from the current tree (a filtered run, or exports added/removed since the last full run) — regenerate with a full pnpm test-storybook-exec"
  exit 0
fi
slow=$({ grep -o '<testcase [^>]*' "$JUNIT" || true; } | awk '
  function attr(s, k) {
    if (match(s, " " k "=\"[^\"]*\"")) return substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4)
    return ""
  }
  { f = attr($0, "file"); if (f == "") f = attr($0, "classname"); if (f != "") t[f] += attr($0, "time") + 0 }
  END { for (f in t) printf "SLOW %.3f %s\n", t[f], f }' | sort -k2,2nr)
if [ -z "$slow" ]; then
  echo "WARN junit-no-testcases $JUNIT"
else
  printf '%s\n' "$slow" | head -n "$SLOW"
fi
exit 0
