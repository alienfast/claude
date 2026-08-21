#!/usr/bin/env bash
# Regression suite for linear-create-child.sh's label handling (BF-1248 item 1). Pins the
# round trip the corruption broke — a multi-word label must reach `issues update -l` with its
# internal spacing intact (`tr -d '[:space:]'` turned `needs decision` into `needsdecision`,
# missed the canonical label case-insensitively but space-sensitively, then MINTED the
# corruption via `labels create`: BF-1109, BF-1243) — plus the normalized-identity healing
# lifted from linear-add-label.sh: a near-miss heals to the canonical label with a NOTE, an
# ambiguous near-miss is skipped with exit 2, and only a genuinely novel name reaches
# `labels create`. linear-cli is a PATH shim that logs every invocation; HOME is an empty dir
# so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-create-child.sh"
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

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

cat > "$FIX/labels-plain.json" <<'EOF'
{"labels":[{"name":"needs decision"},{"name":"specified"},{"name":"keeper"}]}
EOF
cat > "$FIX/labels-ambiguous.json" <<'EOF'
{"labels":[{"name":"needs decision"},{"name":"needs-decision"},{"name":"specified"}]}
EOF

# The shim logs each invocation as pipe-joined args (spaces inside one arg stay visible) and
# answers the four subcommands the label path exercises. LABELS_FIX selects the workspace
# label fixture per case.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
LOG="$WORK/calls.log"
printf '%s\n' "\$(IFS='|'; printf '%s' "\$*")" >> "\$LOG"
case "\${1:-} \${2:-}" in
  "issues create") cat >/dev/null; printf '{"identifier":"TT-9"}\n' ;;
  "issues get")    printf '{"identifier":"TT-9","state":{"name":"Backlog"}}\n' ;;
  "labels list")   cat "\${LABELS_FIX:?}" ;;
  "labels create") exit 0 ;;
  "issues update") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

BODY="$WORK/body.md"
printf 'test body\n' > "$BODY"

run() { # run <labels-fixture> <label-arg> — resets the call log, runs a top-level create
  : > "$WORK/calls.log"
  LABELS_FIX="$FIX/$1" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    "$SCRIPT" - TT Backlog "Title" "$BODY" "$2" > "$WORK/out" 2> "$WORK/err"
  echo "$?"
}

echo "linear-create-child.sh label handling —"

rc=$(run labels-plain.json "needs decision")
ck "round trip: exit"            "0" "$rc"
ck "round trip: id on stdout"    "TT-9" "$(cat "$WORK/out")"
ck_has  "round trip: internal space survives to -l" "-l|needs decision" "$WORK/calls.log"
ck_lacks "round trip: nothing minted"               "labels|create"     "$WORK/calls.log"

rc=$(run labels-plain.json "needsdecision")
ck "near-miss: exit"             "0" "$rc"
ck_has  "near-miss: heals to canonical label"       "-l|needs decision" "$WORK/calls.log"
ck_has  "near-miss: NOTE names the healing"         "normalized match"  "$WORK/err"
ck_lacks "near-miss: nothing minted"                "labels|create"     "$WORK/calls.log"

rc=$(run labels-plain.json "brand-new")
ck "novel: exit"                 "0" "$rc"
ck_has  "novel: label created"                      "labels|create|brand-new|-t|issue" "$WORK/calls.log"
ck_has  "novel: attached as typed"                  "-l|brand-new"      "$WORK/calls.log"

rc=$(run labels-ambiguous.json "needsdecision")
ck "ambiguous: exit 2 (filed-but-unlabelled)" "2" "$rc"
ck "ambiguous: id still on stdout"            "TT-9" "$(cat "$WORK/out")"
ck_has  "ambiguous: WARN names the candidates"      "several existing labels normalize" "$WORK/err"
ck_lacks "ambiguous: nothing minted"                "labels|create"     "$WORK/calls.log"
ck_lacks "ambiguous: no update sent"                "issues|update"     "$WORK/calls.log"

rc=$(run labels-plain.json " specified ")
ck "padding: exit"               "0" "$rc"
ck_has  "padding: trimmed to exact label"           "-l|specified"      "$WORK/calls.log"

rc=$(run labels-plain.json "specified, needs decision")
ck "multi: exit"                 "0" "$rc"
ck_has  "multi: first label attached"               "-l|specified"      "$WORK/calls.log"
ck_has  "multi: second label keeps its space"       "-l|needs decision" "$WORK/calls.log"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
