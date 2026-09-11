#!/usr/bin/env bash
# Regression suite for mark-ready-for-release.sh — the one transition point /finish and the
# merge-queue drainer share, and since 2026-09-11 the epic auto-close walk. Fixtures pin: the
# verified transition itself (exit 1 when nothing moves it); the parent walk closing an epic when
# the last child releases and recursing to the grand-epic; staying open while a sibling is In
# Review (not terminal here) or In Progress; never touching an unlabeled parent; ignoring a
# childless epic; and a parent failure that WARNs while the child's exit stays 0.
#
# linear-cli is a PATH shim over a tiny file-backed store (state-<ID>, parent-<ID>, labels-<ID>,
# children-<ID>) that records every `issues update` in order; HOME is an empty dir so the script's
# cargo-bin PATH prepend cannot resurrect the real CLI. linear-remove-label.sh runs for real
# against the shim (its `issues get` carries an empty label set, so the stalled check no-ops).
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/mark-ready-for-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

DB="$WORK/db"
mkdir -p "$DB" "$WORK/bin" "$WORK/home"

# The graph:
#   EP-0 (epic) ─┬─ EP-1 (epic) ─┬─ EP-2 In Progress
#                │               └─ EP-3 In Review
#                └─ EP-9 Done
#   EP-5 (no label) ── EP-6 In Progress
#   EP-8 (epic, its update is refused by the shim) ── EP-7 In Progress
#   EP-10 (epic, no children) ── (nothing)      EP-11 In Progress, child of EP-10? no — EP-11 has no parent
#   EP-12 (epic) ── EP-13 In Progress, EP-14 Canceled
set_issue() { # set_issue <ID> <state> [parent|-] [labels-csv|-] [children-space-list]
  printf '%s' "$2" > "$DB/state-$1"
  [ "${3:--}" != "-" ] && printf '%s' "$3" > "$DB/parent-$1"
  [ "${4:--}" != "-" ] && printf '%s' "$4" > "$DB/labels-$1"
  [ -n "${5:-}" ] && printf '%s' "$5" > "$DB/children-$1"
  return 0
}
set_issue EP-0  Planned       -    epic "EP-1 EP-9"
set_issue EP-1  Planned       EP-0 epic "EP-2 EP-3"
set_issue EP-2  "In Progress" EP-1
set_issue EP-3  "In Review"   EP-1
set_issue EP-9  Done          EP-0
set_issue EP-5  Planned       -    -    "EP-6"
set_issue EP-6  "In Progress" EP-5
set_issue EP-8  Planned       -    epic "EP-7"
set_issue EP-7  "In Progress" EP-8
set_issue EP-10 Planned       -    epic
set_issue EP-12 Backlog       -    epic "EP-13 EP-14"
set_issue EP-13 "In Progress" EP-12
set_issue EP-14 Canceled      EP-12
set_issue EP-20 "In Progress" -

cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
DB="$DB"
LOG="$WORK/updates.log"
stype() { case "\$1" in Done|"Ready for Release") echo completed ;; Canceled) echo canceled ;; Duplicate) echo duplicate ;; "In Progress"|"In Review") echo started ;; Backlog) echo backlog ;; *) echo unstarted ;; esac; }
case "\${1:-} \${2:-}" in
  "statuses list")
    echo '{"statuses":[{"name":"Backlog","id":"s1"},{"name":"Planned","id":"s2"},{"name":"In Progress","id":"s3"},{"name":"In Review","id":"s4"},{"name":"Ready for Release","id":"s5"},{"name":"Done","id":"s6"},{"name":"Canceled","id":"s7"}]}' ;;
  "issues update")
    id="\$3"; shift 3
    [ "\$id" = "EP-8" ] && { echo "refused" >&2; exit 1; }
    [ "\$id" = "EP-20" ] && { echo "+ Updated issue (but nothing moved)"; exit 0; }
    while [ \$# -gt 0 ]; do case "\$1" in --state|-s) printf '%s' "\$2" > "\$DB/state-\$id"; printf '%s -> %s\n' "\$id" "\$2" >> "\$LOG"; shift 2 ;; *) shift ;; esac; done
    echo "+ Updated issue" ;;
  "issues get")
    id="\$3"; st=\$(cat "\$DB/state-\$id" 2>/dev/null || echo "?")
    printf '{"id":"uuid-%s","identifier":"%s","state":{"name":"%s"},"labels":{"nodes":[]}}\n' "\$id" "\$id" "\$st" ;;
  "issues assign") exit 0 ;;
  "api mutate") exit 1 ;;
  "api query")
    id=""; for a in "\$@"; do case "\$a" in id=*) id="\${a#id=}" ;; esac; done
    p=\$(cat "\$DB/parent-\$id" 2>/dev/null || true)
    if [ -z "\$p" ]; then echo '{"data":{"issue":{"parent":null}}}'; exit 0; fi
    pst=\$(cat "\$DB/state-\$p"); pl=\$(cat "\$DB/labels-\$p" 2>/dev/null || true)
    labels='[]'; [ -n "\$pl" ] && labels="[{\"name\":\"\$pl\"}]"
    kids='['; sep=''
    for c in \$(cat "\$DB/children-\$p" 2>/dev/null || true); do
      cst=\$(cat "\$DB/state-\$c"); kids="\$kids\$sep{\"identifier\":\"\$c\",\"state\":{\"name\":\"\$cst\",\"type\":\"\$(stype "\$cst")\"}}"; sep=','
    done
    kids="\$kids]"
    printf '{"data":{"issue":{"parent":{"identifier":"%s","state":{"name":"%s","type":"%s"},"labels":{"nodes":%s},"children":{"nodes":%s}}}}}\n' "\$p" "\$pst" "\$(stype "\$pst")" "\$labels" "\$kids" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <outfile> <ID> — echoes the exit code
  : > "$WORK/updates.log"
  HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" "$2" > "$1" 2> "$1.err"
  echo "$?"
}
state() { cat "$DB/state-$1"; }

echo "mark-ready-for-release.sh —"

# ---- 1. a child releases while its sibling is In Review: the epic stays open ----
rc=$(run "$WORK/o1" EP-2)
ck "child transition exits 0"           "0" "$rc"
ck "child moved"                        "Ready for Release" "$(state EP-2)"
ck "epic untouched while a sibling is In Review" "Planned" "$(state EP-1)"
ck_has "sibling named as what keeps it open" "NOTE: epic EP-1 stays open — EP-3 [In Review] still open" "$WORK/o1.err"
ck "only the child was updated"         "EP-2 -> Ready for Release" "$(cat "$WORK/updates.log" | tr '\n' ';' | sed 's/;$//')"

# ---- 2. the last child releases: the epic closes, then the grand-epic (its other child is Done) ----
rc=$(run "$WORK/o2" EP-3)
ck "last child exits 0"                 "0" "$rc"
ck "epic closed"                        "Ready for Release" "$(state EP-1)"
ck "grand-epic closed by recursion"     "Ready for Release" "$(state EP-0)"
ck "transitions in order: child, epic, grand-epic" "EP-3 -> Ready for Release;EP-1 -> Ready for Release;EP-0 -> Ready for Release" "$(cat "$WORK/updates.log" | tr '\n' ';' | sed 's/;$//')"
ck_has "epic close reported"            "NOTE: epic EP-1 moved to 'Ready for Release' — its last child (EP-3) released" "$WORK/o2"
ck_has "grand-epic close reported"      "NOTE: epic EP-0 moved to 'Ready for Release' — its last child (EP-1) released" "$WORK/o2"

# ---- 3. an unlabeled parent is never touched, however complete ----
rc=$(run "$WORK/o3" EP-6)
ck "child under a plain parent exits 0" "0" "$rc"
ck "plain parent untouched"             "Planned" "$(state EP-5)"
ck "no parent update issued"            "EP-6 -> Ready for Release" "$(cat "$WORK/updates.log" | tr '\n' ';' | sed 's/;$//')"

# ---- 4. a parent the API refuses to move: WARN, child exit unchanged ----
rc=$(run "$WORK/o4" EP-7)
ck "parent failure leaves exit 0"       "0" "$rc"
ck "child still moved"                  "Ready for Release" "$(state EP-7)"
ck "refused parent left as it was"      "Planned" "$(state EP-8)"
ck_has "parent failure warned, with the remedy" "WARN: epic EP-8 is complete (every child terminal) but could not be moved to 'Ready for Release' — close it manually." "$WORK/o4.err"

# ---- 5. a sibling In Progress keeps a Backlog epic open; Canceled counts as terminal ----
rc=$(run "$WORK/o5" EP-13)
ck "backlog epic closes when the open sibling was the last (Canceled is terminal)" "Ready for Release" "$(state EP-12)"

# ---- 6. the verified transition itself: an update that reports success but moves nothing exits 1 ----
rc=$(run "$WORK/o6" EP-20)
ck "unmoved issue exits 1"              "1" "$rc"
ck_has "unmoved issue named"            "ERROR: EP-20 still not in 'Ready for Release' after the raw-mutation fallback" "$WORK/o6.err"

# ---- 7. usage ----
if HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$SCRIPT" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: no-args exited 0"; else PASS=$((PASS+1)); fi

echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
